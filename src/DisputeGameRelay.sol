// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

// Libraries
import { Clone } from "@solady/utils/Clone.sol";
import {
    GameStatus,
    GameType,
    Claim,
    Timestamp,
    Hash,
    Proposal
} from "optimism/src/dispute/lib/Types.sol";
import {
    RelayGameType
} from "src/RelayAnchorStateRegistry.sol";
import {
    AnchorRootNotFound,
    AlreadyInitialized,
    UnexpectedRootClaim,
    GameNotInProgress,
    GameNotResolved,
    GamePaused,
    GameNotFinalized
} from "optimism/src/dispute/lib/Errors.sol";

// Interfaces
import { IRelayAnchorStateRegistry } from "src/interfaces/IRelayAnchorStateRegistry.sol";
import { IDisputeGame, IDisputeGameFactory } from "optimism/src/dispute/AnchorStateRegistry.sol";

contract DisputeGameRelay is Clone {
    ////////////////////////////////////////////////////////////////
    //                         Structs                            //
    ////////////////////////////////////////////////////////////////

    /// @notice Parameters for creating a new DisputeGameRelay.
    struct RelayConstructorParams {
        IRelayAnchorStateRegistry anchorStateRegistry;
        uint256 l2ChainId;
    }

    ////////////////////////////////////////////////////////////////
    //                         Events                             //
    ////////////////////////////////////////////////////////////////

    event Resolved(GameStatus indexed status);

    event GameClosed();

    ////////////////////////////////////////////////////////////////
    //                         State Vars                         //
    ////////////////////////////////////////////////////////////////

    /// @notice The game type ID.
    GameType constant GAME_TYPE = GameType.wrap(type(uint32).max);

    /// @notice The anchor state registry.
    IRelayAnchorStateRegistry internal immutable ANCHOR_STATE_REGISTRY;

    /// @notice The dispute game factory.
    IDisputeGameFactory internal immutable DISPUTE_GAME_FACTORY;

    /// @notice The chain ID of the L2 network this contract argues about.
    uint256 internal immutable L2_CHAIN_ID;

    /// @notice The starting timestamp of the game
    Timestamp public createdAt;

    /// @notice The timestamp of the game's global resolution.
    Timestamp public resolvedAt;

    /// @notice Returns the current status of the game.
    GameStatus public status;

    /// @notice Flag for the `initialize` function to prevent re-initialization.
    bool internal initialized;

    /// @notice The latest finalized output root
    Proposal public startingOutputRoot;

    /// @notice A boolean for whether or not the game type was respected when the game was created.
    bool public wasRespectedGameTypeWhenCreated;

    /// @notice The threshold when the game was created.
    uint256 public thresholdWhenCreated;

    /// @notice The required game types when the game was created.
    GameType[] public requiredGameTypesWhenCreated;

    /// @notice The underlying dispute games.
    address[] internal _underlyingDisputeGames;

    /// @param _params Parameters for creating a new DisputeGameRelay.
    constructor(RelayConstructorParams memory _params) {
        // Set up initial game state.
        ANCHOR_STATE_REGISTRY = _params.anchorStateRegistry;
        L2_CHAIN_ID = _params.l2ChainId;
        DISPUTE_GAME_FACTORY = ANCHOR_STATE_REGISTRY.disputeGameFactory();
    }

    /// @notice Initializes the contract.
    /// @dev This function may only be called once.
    function initialize() public payable virtual {
        // SAFETY: Any revert in this function will bubble up to the DisputeGameFactory and
        // prevent the game from being created.
        //
        // Implicit assumptions:
        // - The `gameStatus` state variable defaults to 0, which is `GameStatus.IN_PROGRESS`
        //
        // Explicit checks:
        // - The game must not have already been initialized.
        // - An output root cannot be proposed at or before the starting block number.

        // INVARIANT: The game must not have already been initialized.
        if (initialized) revert AlreadyInitialized();

        // Grab the latest anchor root.
        (Hash root, uint256 rootBlockNumber) = ANCHOR_STATE_REGISTRY.getAnchorRoot();

        // Should only happen if this is a new game type that hasn't been set up yet.
        if (root.raw() == bytes32(0)) revert AnchorRootNotFound();

        // Set the starting proposal.
        startingOutputRoot = Proposal({ l2SequenceNumber: rootBlockNumber, root: root });

        // Revert if the calldata size is not the expected length.
        //
        // This is to prevent adding extra or omitting bytes from to `extraData` that result in a different game UUID
        // in the factory, but are not used by the game, which would allow for multiple dispute games for the same
        // output proposal to be created.
        //
        // Expected length: 0x5A + extra data length
        // - 0x04 selector
        // - 0x14 creator address
        // - 0x20 root claim
        // - 0x20 l1 head
        // - 0x20 l2 sequence number
        // - 0x20 # of game types
        // - 0x04 * # of game types
        // - 0x20 extra data length 1
        // - n extra data 1
        // - 0x20 extra data length 2
        // - n extra data 2
        // - ...
        // - 0x02 CWIA bytes
        uint256 extraDataLength_ = extraDataLength();
        assembly {
            if iszero(eq(calldatasize(), add(0x5A, extraDataLength_))) {
                // Store the selector for `BadExtraData()` & revert
                mstore(0x00, 0x9824bdab)
                revert(0x1C, 0x04)
            }
        }

        // Do not allow the game to be initialized if the root claim corresponds to a block at or before the
        // configured starting block number.
        if (l2BlockNumber() <= rootBlockNumber) revert UnexpectedRootClaim(rootClaim());

        // Set the game as initialized.
        initialized = true;

        // Set the game's starting timestamp
        createdAt = Timestamp.wrap(uint64(block.timestamp));

        // Set whether the game type was respected when the game was created.
        RelayGameType[] memory relayGameTypes = ANCHOR_STATE_REGISTRY.relayGameTypes();
        GameType[] memory gameTypes_ = gameTypes();

        // Respected if:
        // - The game type in the anchor state registry is relay
        // - The number of game types in the anchor state registry is the same as the number of game types of this relay
        // - The game types in the anchor state registry are the same as the game types of this relay
        wasRespectedGameTypeWhenCreated =
            (GameType.unwrap(ANCHOR_STATE_REGISTRY.respectedGameType()) == GameType.unwrap(GAME_TYPE)) &&
            (relayGameTypes.length == gameTypes_.length);

        for (uint256 i = 0; i < gameTypes_.length; i++) {
            if (GameType.unwrap(relayGameTypes[i].gameType) != GameType.unwrap(gameTypes_[i])) {
                wasRespectedGameTypeWhenCreated = false;
                break;
            }
        }

        // Required game types are used if game types are respected
        if (wasRespectedGameTypeWhenCreated) {
            requiredGameTypesWhenCreated = ANCHOR_STATE_REGISTRY.requiredGameTypes();
        }

        // Set the threshold for when the game was created.
        thresholdWhenCreated = ANCHOR_STATE_REGISTRY.threshold();

        // Deploy underlying dispute games
        bytes[] memory extraData_ = extraDataArray();
        GameType prevGameType = GAME_TYPE; // relay game type is uint32.max
        for (uint256 i = 0; i < gameTypes_.length; i++) { 
            // Prevent duplicate game types
            require(prevGameType.raw() > gameTypes_[i].raw(), "Game types must be in descending order");
            prevGameType = gameTypes_[i];

            IDisputeGame game = DISPUTE_GAME_FACTORY.create{ value: DISPUTE_GAME_FACTORY.initBonds(gameTypes_[i]) }(gameTypes_[i], rootClaim(), extraData_[i]);
            require(game.l2SequenceNumber() == l2SequenceNumber(), "L2 sequence number must match");
            _underlyingDisputeGames.push(address(game));
        }
        require(address(this).balance == 0, "Incorrect bond amount");
    }

    /// @notice The l2BlockNumber of the disputed output root in the `L2OutputOracle`.
    function l2BlockNumber() public pure returns (uint256 l2BlockNumber_) {
        l2BlockNumber_ = _getArgUint256(0x54);
    }

    /// @notice The l2SequenceNumber of the disputed output root in the `L2OutputOracle` (in this case - block number).
    function l2SequenceNumber() public pure returns (uint256 l2SequenceNumber_) {
        l2SequenceNumber_ = l2BlockNumber();
    }

    /// @notice Only the starting block number of the game.
    function startingBlockNumber() external view returns (uint256 startingBlockNumber_) {
        startingBlockNumber_ = startingOutputRoot.l2SequenceNumber;
    }

    /// @notice Starting output root and block number of the game.
    function startingRootHash() external view returns (Hash startingRootHash_) {
        startingRootHash_ = startingOutputRoot.root;
    }

    ////////////////////////////////////////////////////////////////
    //                    `IDisputeGame` impl                     //
    ////////////////////////////////////////////////////////////////

    /// @notice If all necessary information has been gathered, this function should mark the game
    ///         status as either `CHALLENGER_WINS` or `DEFENDER_WINS` and return the status of
    ///         the resolved game.
    /// @dev May only be called if the `status` is `IN_PROGRESS`.
    /// @return status_ The status of the game after resolution.
    function resolve() external returns (GameStatus status_) {
        // INVARIANT: Resolution cannot occur unless the game is currently in progress.
        if (status != GameStatus.IN_PROGRESS) revert GameNotInProgress();

        // Collect game statuses and types
        address[] memory gameProxies_ = _underlyingDisputeGames;
        GameStatus[] memory statuses = new GameStatus[](gameProxies_.length);
        GameType[] memory gameTypes_ = new GameType[](gameProxies_.length);
        
        for (uint256 i = 0; i < gameProxies_.length; i++) {
            IDisputeGame game = IDisputeGame(gameProxies_[i]);
            statuses[i] = GameStatus(uint256(game.status()));
            gameTypes_[i] = game.gameType();
        }

        // Check if the number of games defended is greater than the threshold.
        uint256 numDefenderWins;

        // Check if all games are resolved.
        bool allGamesResolved = true;
        
        for (uint256 i = 0; i < statuses.length; i++) {
            // Check if the game is required.
            if (gameTypeIsRequired(gameTypes_[i])) {
                require(uint256(statuses[i]) != uint256(GameStatus.IN_PROGRESS), "Required game not resolved");
                if (uint256(statuses[i]) == uint256(GameStatus.CHALLENGER_WINS)) {
                    status_ = GameStatus.CHALLENGER_WINS;
                    break;
                }
                numDefenderWins++;
                continue;
            }

            if (uint256(statuses[i]) == uint256(GameStatus.IN_PROGRESS)) {
                allGamesResolved = false;
                continue;
            }

            if (uint256(statuses[i]) == uint256(GameStatus.DEFENDER_WINS)) {
                numDefenderWins++;
            }
        }

        if (numDefenderWins >= thresholdWhenCreated) {
            status_ = GameStatus.DEFENDER_WINS;
        } else if (allGamesResolved && numDefenderWins < thresholdWhenCreated) {
            status_ = GameStatus.CHALLENGER_WINS;
        } else {
            revert("Game not resolved");
        }

        resolvedAt = Timestamp.wrap(uint64(block.timestamp));

        // Update the status and emit the resolved event, note that we're performing an assignment here.
        emit Resolved(status = status_);
    }

    /// @notice Checks if a game type is required.
    /// @param _gameType The game type.
    /// @return isRequired_ True if the game type is required, false otherwise.
    function gameTypeIsRequired(GameType _gameType) public view returns (bool) {
        for (uint256 i = 0; i < requiredGameTypesWhenCreated.length; i++) {
            if (GameType.unwrap(requiredGameTypesWhenCreated[i]) == GameType.unwrap(_gameType)) {
                return true;
            }
        }
        return false;
    }

    /// @notice Getter for the game type.
    /// @dev The reference impl should be entirely different depending on the type (fault, validity)
    ///      i.e. The game type should indicate the security model.
    /// @return gameType_ The type of proof system being used.
    function gameType() public view returns (GameType gameType_) {
        gameType_ = GAME_TYPE;
    }

    /// @notice Getter for the creator of the dispute game.
    /// @dev `clones-with-immutable-args` argument #1
    /// @return creator_ The creator of the dispute game.
    function gameCreator() public pure returns (address creator_) {
        creator_ = _getArgAddress(0x00);
    }

    /// @notice Getter for the root claim.
    /// @dev `clones-with-immutable-args` argument #2
    /// @return rootClaim_ The root claim of the DisputeGame.
    function rootClaim() public pure returns (Claim rootClaim_) {
        rootClaim_ = Claim.wrap(_getArgBytes32(0x14));
    }

    /// @notice Getter for the parent hash of the L1 block when the dispute game was created.
    /// @dev `clones-with-immutable-args` argument #3
    /// @return l1Head_ The parent hash of the L1 block when the dispute game was created.
    function l1Head() public pure returns (Hash l1Head_) {
        l1Head_ = Hash.wrap(_getArgBytes32(0x34));
    }

    /// @notice Getter for the number of underlying games.
    /// @dev `clones-with-immutable-args` argument #5
    /// @return numberOfUnderlyingGames_ The number of underlying games.
    function numberOfUnderlyingGames() public pure returns (uint256 numberOfUnderlyingGames_) {
        numberOfUnderlyingGames_ = _getArgUint256(0x74);
    }

    /// @notice Getter for the game types.
    /// @dev `clones-with-immutable-args` argument #6
    /// @return gameTypes_ The game types.
    function gameTypes() public pure returns (GameType[] memory gameTypes_) {
        uint256 gameTypesLength = numberOfUnderlyingGames();
        gameTypes_ = new GameType[](gameTypesLength);
        for (uint256 i = 0; i < gameTypesLength; i++) {
            gameTypes_[i] = GameType.wrap(_getArgUint32(0x94 + i * 0x04));
        }
    }

    /// @notice Getter for the extra data array.
    /// @dev `clones-with-immutable-args` argument #7
    /// @return extraDataArray_ The extra data array.
    function extraDataArray() public pure returns (bytes[] memory extraDataArray_) {
        extraDataArray_ = new bytes[](numberOfUnderlyingGames());
        uint256 extraDataLengthOffset = 0x94 + numberOfUnderlyingGames() * 0x04;
        uint256 extraDataLength_ = _getArgUint256(extraDataLengthOffset);

        for (uint256 i = 0; i < numberOfUnderlyingGames(); i++) {
            extraDataArray_[i] = _getArgBytes(extraDataLengthOffset + 0x20, extraDataLength_);
            extraDataLengthOffset += 0x20 + extraDataLength_;
            extraDataLength_ = _getArgUint256(extraDataLengthOffset);
        }
    }

    /// @notice Getter for the extra data length.
    /// @return extraDataLength_ The extra data length.
    function extraDataLength() public pure returns (uint256 extraDataLength_) {
        extraDataLength_ = 0x40 + numberOfUnderlyingGames() * 0x04;
        uint256 extraDataLengthOffset = 0x94 + numberOfUnderlyingGames() * 0x04;
        for (uint256 i = 0; i < numberOfUnderlyingGames(); i++) {
            uint256 extraLength = _getArgUint256(extraDataLengthOffset);
            extraDataLength_ += 0x20 + extraLength;
            extraDataLengthOffset += 0x20 + extraLength;
        }
    }

    /// @notice Getter for the extra data.
    /// @return extraData_ Any extra data supplied to the dispute game contract by the creator.
    function extraData() public pure returns (bytes memory extraData_) {
        extraData_ = _getArgBytes(0x54, extraDataLength());
    }

    /// @notice A compliant implementation of this interface should return the components of the
    ///         game UUID's preimage provided in the cwia payload. The preimage of the UUID is
    ///         constructed as `keccak256(gameType . rootClaim . extraData)` where `.` denotes
    ///         concatenation.
    /// @return gameType_ The type of proof system being used.
    /// @return rootClaim_ The root claim of the DisputeGame.
    /// @return extraData_ Any extra data supplied to the dispute game contract by the creator.
    function gameData() external view returns (GameType gameType_, Claim rootClaim_, bytes memory extraData_) {
        gameType_ = gameType();
        rootClaim_ = rootClaim();
        extraData_ = extraData();
    }

    /// @notice Getter for the underlying dispute games.
    /// @return underlyingDisputeGames_ The underlying dispute games.
    function underlyingDisputeGames() external view returns (address[] memory underlyingDisputeGames_) {
        underlyingDisputeGames_ = _underlyingDisputeGames;
    }

    ////////////////////////////////////////////////////////////////
    //                     IMMUTABLE GETTERS                      //
    ////////////////////////////////////////////////////////////////

    /// @notice Returns the anchor state registry contract.
    function anchorStateRegistry() external view returns (IRelayAnchorStateRegistry registry_) {
        registry_ = ANCHOR_STATE_REGISTRY;
    }

    /// @notice Returns the chain ID of the L2 network this contract argues about.
    function l2ChainId() external view returns (uint256 l2ChainId_) {
        l2ChainId_ = L2_CHAIN_ID;
    }

    ////////////////////////////////////////////////////////////////
    //                       MISC EXTERNAL                        //
    ////////////////////////////////////////////////////////////////

    function closeGame() public {
        // We won't close the game if the system is currently paused. Paused games are temporarily
        // invalid which would cause the game to go into refund mode and potentially cause some
        // confusion for honest challengers. By blocking the game from being closed while the
        // system is paused, the game will only go into refund mode if it ends up being explicitly
        // invalidated in the AnchorStateRegistry. If the game has already been closed and a refund
        // mode has been selected, we'll already have returned and we won't hit this revert.
        if (ANCHOR_STATE_REGISTRY.paused()) {
            revert GamePaused();
        }

        // Make sure that the game is resolved.
        // AnchorStateRegistry should be checking this but we're being defensive here.
        if (resolvedAt.raw() == 0) {
            revert GameNotResolved();
        }

        // Game must be finalized according to the AnchorStateRegistry.
        bool finalized = ANCHOR_STATE_REGISTRY.isGameFinalized(IDisputeGame(address(this)));
        if (!finalized) {
            revert GameNotFinalized();
        }

        // Try to update the anchor game first. Won't always succeed because delays can lead
        // to situations in which this game might not be eligible to be a new anchor game.
        // eip150-safe
        try ANCHOR_STATE_REGISTRY.setAnchorState(IDisputeGame(address(this))) { } catch { }

        // Emit an event to signal that the game has been closed.
        emit GameClosed();
    }
}
