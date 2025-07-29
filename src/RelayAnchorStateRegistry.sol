// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IRelayAnchorStateRegistry } from "src/interfaces/IRelayAnchorStateRegistry.sol";
import { GameType, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { IDisputeGame, AnchorStateRegistry } from "optimism/src/dispute/AnchorStateRegistry.sol";
import { IDisputeGameRelay } from "src/interfaces/IDisputeGameRelay.sol";

struct RelayGameType {
    GameType gameType;
    bool required;
}

contract RelayAnchorStateRegistry is AnchorStateRegistry {
    /// @notice The game type for the relay game.
    /// @dev Should be put into optimism/src/dispute/lib/Types.sol
    GameType public constant RELAY_GAME_TYPE = GameType.wrap(type(uint32).max);

    /// @notice The threshold for the relay game.
    uint256 internal _threshold;

    /// @notice The relay game types.
    RelayGameType[] internal _relayGameTypes;

    /// @notice The required game types.
    GameType[] internal _requiredGameTypes;

    /// @notice The backup game type. Default is PermissionedDisputeGame.
    GameType internal _backUpGameType;

    /// @notice The backup game types.
    RelayGameType[] internal _backUpGameTypes;

    /// @notice The finality delays for the game types.
    mapping(GameType => uint256) internal _finalityDelays;

    /// @notice Emitted when the threshold is set.
    event ThresholdSet(uint256 threshold);
    /// @notice Emitted when the relay game types are set.
    event RelayGameTypesSet(RelayGameType[] relayGameTypes);
    /// @notice Emitted when the backup game types are set.
    event BackUpGameTypesSet(RelayGameType[] backUpGameTypes);
    /// @notice Emitted when the backup game type is set.
    event BackUpGameTypeSet(GameType gameType);
    /// @notice Emitted when the finality delay is set.
    event FinalityDelaySet(GameType gameType, uint256 finalityDelay);
    /// @notice Emitted when a soundness issue is detected.
    event SoundnessIssue(IDisputeGame indexed game, GameType gameType);

    constructor(uint256 _defaultFinalityDelaySeconds) AnchorStateRegistry(_defaultFinalityDelaySeconds) {
        _disableInitializers();
    }

    /// @notice Sets the relay game types and threshold.
    function setRelayGameTypesAndThreshold(RelayGameType[] memory relayGameTypes_, uint256 threshold_) external {
        _assertOnlyGuardian();
        
        require(GameType.unwrap(respectedGameType) == GameType.unwrap(RELAY_GAME_TYPE), "Relay game type must be relay");
        require(relayGameTypes_.length > 1, "Must have at least 2 game types");
        
        delete _requiredGameTypes;
        uint32 gameType = GameType.unwrap(RELAY_GAME_TYPE);
        for (uint256 i = 1; i < relayGameTypes_.length; i++) {
            require(GameType.unwrap(relayGameTypes_[i].gameType) != GameType.unwrap(RELAY_GAME_TYPE), "Relay game type must not be relay");
            require(GameType.unwrap(relayGameTypes_[i].gameType) < gameType, "Relay game types must be in descending order");
            if (relayGameTypes_[i].required) {
                _requiredGameTypes.push(relayGameTypes_[i].gameType);
            }
            gameType = GameType.unwrap(relayGameTypes_[i].gameType);
        }

        require(threshold_ <= relayGameTypes_.length, "Threshold must be less than or equal to the number of game types");
        require(threshold_ > 0, "Threshold must be greater than 0");
        require(threshold_ >= _requiredGameTypes.length, "Threshold must be greater than the number of required game types");
        _threshold = threshold_;

        _relayGameTypes = relayGameTypes_;
        emit RelayGameTypesSet(relayGameTypes_);
        emit ThresholdSet(threshold_);
    }

    /// @notice Sets the threshold for the relay game.
    /// @param threshold_ The threshold.
    /// @dev Only callable by the guardian. Requires the respected game type to be RELAY_GAME_TYPE.
    ///      Threshold must be greater than 0 and less than or equal to the number of game types.
    ///      Threshold must be greater than or equal to the number of required game types.
    function setThreshold(uint256 threshold_) external {
        _assertOnlyGuardian();
        require(GameType.unwrap(respectedGameType) == GameType.unwrap(RELAY_GAME_TYPE), "Respected game type must be relay");
        require(threshold_ > 0, "Threshold must be greater than 0");
        require(threshold_ >= _requiredGameTypes.length, "Threshold must be greater than the number of required game types");
        require(threshold_ <= _relayGameTypes.length, "Threshold must be less than or equal to the number of game types");

        _threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    /// @notice Gets the relay game types.
    /// @return The relay game types.
    function relayGameTypes() external view returns (RelayGameType[] memory) {
        if (GameType.unwrap(respectedGameType) != GameType.unwrap(RELAY_GAME_TYPE)) return new RelayGameType[](0);
        return _relayGameTypes;
    }

    /// @notice Gets the required game types.
    /// @return The required game types.
    function requiredGameTypes() external view returns (GameType[] memory) {
        if (GameType.unwrap(respectedGameType) != GameType.unwrap(RELAY_GAME_TYPE)) {
            GameType[] memory _gameTypes = new GameType[](1);
            _gameTypes[0] = respectedGameType;
            return _gameTypes;
        }
        return _requiredGameTypes;
    }

    /// @notice Checks if a game type is required.
    /// @param gameType_ The game type.
    /// @return True if the game type is required, false otherwise.
    function isGameTypeRequired(GameType gameType_) public view returns (bool) {
        for (uint256 i = 0; i < _requiredGameTypes.length; i++) {
            if (GameType.unwrap(gameType_) == GameType.unwrap(_requiredGameTypes[i])) {
                return true;
            }
        }
        return false;
    }

    /// @notice Gets the threshold for the relay game.
    /// @return The threshold.
    function threshold() external view returns (uint256) {
        if (GameType.unwrap(respectedGameType) != GameType.unwrap(RELAY_GAME_TYPE)) return 0;
        return _threshold;
    }

    /// @notice Sets the finality delay for a game type.
    /// @param gameType_ The game type.
    /// @param finalityDelay_ The finality delay.
    /// @dev Only callable by the guardian. Requires the game type to be different from RELAY_GAME_TYPE.
    ///      Fianlity delay must be greater than 0.
    function setFinalityDelay(GameType gameType_, uint256 finalityDelay_) external {
        _assertOnlyGuardian();
        require(GameType.unwrap(gameType_) != GameType.unwrap(RELAY_GAME_TYPE), "Game type must be relay");
        require(finalityDelay_ > 0, "Finality delay must be greater than 0");

        _finalityDelays[gameType_] = finalityDelay_;
        emit FinalityDelaySet(gameType_, finalityDelay_);
    }

    /// @notice Gets the finality delay for a game type.
    /// @param gameType_ The game type.
    /// @return The finality delay.
    function finalityDelay(GameType gameType_) public view returns (uint256) {
        require(GameType.unwrap(gameType_) != GameType.unwrap(RELAY_GAME_TYPE), "Game type must not be relay");
        
        if (_finalityDelays[gameType_] == 0) return DISPUTE_GAME_FINALITY_DELAY_SECONDS;
        return _finalityDelays[gameType_];
    }

    /// @notice Checks if a game is blacklisted.
    /// @param _game The game.
    /// @return True if the game is blacklisted, false otherwise.
    function isGameBlacklisted(IDisputeGame _game) public view override returns (bool) {
        if (GameType.unwrap(_game.gameType()) == GameType.unwrap(RELAY_GAME_TYPE)) {
            address[] memory underlyingDisputeGames = IDisputeGameRelay(address(_game)).underlyingDisputeGames();
            for (uint256 i = 0; i < underlyingDisputeGames.length; i++) {
                if (disputeGameBlacklist[IDisputeGame(underlyingDisputeGames[i])]) return true;
            }
        }
        return super.isGameBlacklisted(_game);
    }

    /// @notice Checks if a game is finalized.
    /// @param _game The game.
    /// @return True if the game is finalized, false otherwise.
    function isGameFinalized(IDisputeGame _game) public view override returns (bool) {
        if (!isGameResolved(_game)) return false;

        // If the game is a relay game, check if the number of finalized games is greater than the threshold.
        if (GameType.unwrap(_game.gameType()) == GameType.unwrap(RELAY_GAME_TYPE)) {
            address[] memory underlyingDisputeGames = IDisputeGameRelay(address(_game)).underlyingDisputeGames();
            uint256 finalized;
            for (uint256 i = 0; i < underlyingDisputeGames.length; i++) {
                if (isGameTypeRequired(IDisputeGame(underlyingDisputeGames[i]).gameType())) {
                    require(isGameFinalized(IDisputeGame(underlyingDisputeGames[i])), "Required game not finalized");
                    finalized++;
                    continue;
                } else if (isGameFinalized(IDisputeGame(underlyingDisputeGames[i]))) finalized++;
            }
            return finalized >= _threshold;
        }

        return block.timestamp - _game.resolvedAt().raw() > finalityDelay(_game.gameType());
    }

    /// @notice Sets the backup game type.
    /// @param gameType_ The game type.
    /// @dev Only callable by the guardian. Requires the backup game type to be different from RELAY_GAME_TYPE.
    function setBackUpGameType(GameType gameType_) external {
        _assertOnlyGuardian();
        _backUpGameType = gameType_;
        emit BackUpGameTypeSet(gameType_);
    }

    /// @notice Sets the backup game types.
    /// @param gameTypes_ The game types.
    /// @dev Only callable by the guardian. Requires the backup game type to be different from RELAY_GAME_TYPE.
    function setBackUpGameTypes(RelayGameType[] memory gameTypes_) external {
        _assertOnlyGuardian();
        require(GameType.unwrap(_backUpGameType) == GameType.unwrap(RELAY_GAME_TYPE), "Back up game type must be relay");
        for (uint256 i = 0; i < gameTypes_.length; i++) {
            require(GameType.unwrap(gameTypes_[i].gameType) != GameType.unwrap(RELAY_GAME_TYPE), "Game type must not be relay");
        }
        _backUpGameTypes = gameTypes_;
        emit BackUpGameTypesSet(gameTypes_);
    }

    /// @notice Gets the backup game type.
    /// @return The backup game type.
    function backUpGameType() external view returns (GameType) {
        return _backUpGameType;
    }

    /// @notice Gets the backup game types.
    /// @return The backup game types.
    function backUpGameTypes() external view returns (RelayGameType[] memory) {
        return _backUpGameTypes;
    }

    /// @notice Nullifies the relay anchor state registry.
    /// @dev Only callable by the guardian. Requires the game to be registered and respected.
    ///      If the game is respected, the relay game types are set to the backup game types.
    ///      If the game is not respected, the respected game type is set to the backup game type.
    function nullify() external {
        IDisputeGame game = IDisputeGame(msg.sender);
        GameType gameType = game.gameType();
        
        require(isGameRegistered(game), "Game must be registered");
        bool respected;
        for (uint256 i = 0; i < _relayGameTypes.length; i++) {
            if (GameType.unwrap(gameType) == GameType.unwrap(_relayGameTypes[i].gameType)) {
                respected = true;
                break;
            }
        }

        require(respected || isGameRespected(game), "Game must be respected");

        if (respected && _backUpGameTypes.length > 0) {
            _relayGameTypes = _backUpGameTypes;
            delete _requiredGameTypes;
            for (uint256 i = 0; i < _backUpGameTypes.length; i++) {
                if (_backUpGameTypes[i].required) {
                    _requiredGameTypes.push(_backUpGameTypes[i].gameType);
                }
            }
            if (_threshold > _backUpGameTypes.length) {
                _threshold = _backUpGameTypes.length;
                emit ThresholdSet(_threshold);
            }
            emit RelayGameTypesSet(_backUpGameTypes);
        } else {
            respectedGameType = _backUpGameType;
            emit RespectedGameTypeSet(_backUpGameType);
        }

        retirementTimestamp = uint64(block.timestamp);
        emit RetirementTimestampSet(block.timestamp);
        emit SoundnessIssue(game, gameType);
    }
}