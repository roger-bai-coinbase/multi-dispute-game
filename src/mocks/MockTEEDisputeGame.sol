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
    AnchorRootNotFound,
    AlreadyInitialized,
    UnexpectedRootClaim,
    GameNotInProgress,
    GameNotResolved,
    GamePaused,
    GameNotFinalized
} from "optimism/src/dispute/lib/Errors.sol";
import { Types } from "optimism/src/libraries/Types.sol";

// Interfaces
import { IAnchorStateRegistry } from "optimism/src/dispute/FaultDisputeGame.sol";
import { IDisputeGame } from "optimism/src/dispute/AnchorStateRegistry.sol";
import { IOutputOracle } from "src/interfaces/IOutputOracle.sol";

contract MockTEEDisputeGame is Clone {
    ////////////////////////////////////////////////////////////////
    //                         Structs                            //
    ////////////////////////////////////////////////////////////////

    /// @notice Parameters for creating a new DisputeGameRelay.
    struct TEEConstructorParams {
        GameType gameType;
        IAnchorStateRegistry anchorStateRegistry;
        uint256 l2ChainId;
        address outputOracle;
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
    GameType internal immutable GAME_TYPE;

    /// @notice The anchor state registry.
    IAnchorStateRegistry internal immutable ANCHOR_STATE_REGISTRY;

    /// @notice The chain ID of the L2 network this contract argues about.
    uint256 internal immutable L2_CHAIN_ID;

    /// @notice The output oracle.
    IOutputOracle immutable public outputOracle;

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

    /// @param _params Parameters for creating a new DisputeGameRelay.
    constructor(TEEConstructorParams memory _params) {
        // Set up initial game state.
        GAME_TYPE = _params.gameType;
        ANCHOR_STATE_REGISTRY = _params.anchorStateRegistry;
        L2_CHAIN_ID = _params.l2ChainId;
        outputOracle = IOutputOracle(_params.outputOracle);
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
        // Expected length: 0x7A
        // - 0x04 selector
        // - 0x14 creator address
        // - 0x20 root claim
        // - 0x20 l1 head
        // - 0x20 extraData
        // - 0x02 CWIA bytes
        assembly {
            if iszero(eq(calldatasize(), 0x7A)) {
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
        wasRespectedGameTypeWhenCreated =
            (GameType.unwrap(ANCHOR_STATE_REGISTRY.respectedGameType()) == GameType.unwrap(GAME_TYPE));
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
    function resolve(uint256 _l2OutputIndex) external returns (GameStatus status_) {
        // INVARIANT: Resolution cannot occur unless the game is currently in progress.
        if (status != GameStatus.IN_PROGRESS) revert GameNotInProgress();

        Types.OutputProposal memory output = outputOracle.getL2Output(_l2OutputIndex);

        require(output.outputRoot == rootClaim().raw(), "TEE: Unexpected root claim");
        require(output.l2BlockNumber == l2SequenceNumber(), "TEE: Unexpected l2 sequence number");

        status_ = GameStatus.DEFENDER_WINS;

        resolvedAt = Timestamp.wrap(uint64(block.timestamp));

        // Update the status and emit the resolved event, note that we're performing an assignment here.
        emit Resolved(status = status_);
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

    /// @notice Getter for the extra data.
    /// @dev `clones-with-immutable-args` argument #4
    /// @return extraData_ Any extra data supplied to the dispute game contract by the creator.
    function extraData() public pure returns (bytes memory extraData_) {
        extraData_ = _getArgBytes(0x54, 0x20);
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

    ////////////////////////////////////////////////////////////////
    //                     IMMUTABLE GETTERS                      //
    ////////////////////////////////////////////////////////////////

    /// @notice Returns the anchor state registry contract.
    function anchorStateRegistry() external view returns (IAnchorStateRegistry registry_) {
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
