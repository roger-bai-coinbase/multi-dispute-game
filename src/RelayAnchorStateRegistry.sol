// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IRelayAnchorStateRegistry } from "src/interfaces/IRelayAnchorStateRegistry.sol";
import { GameType, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { IDisputeGame, AnchorStateRegistry } from "optimism/src/dispute/AnchorStateRegistry.sol";
import { IDisputeGameRelay } from "src/interfaces/IDisputeGameRelay.sol";

contract RelayAnchorStateRegistry is AnchorStateRegistry {
    /// @notice The game type for the relay game.
    /// @dev Should be put into optimism/src/dispute/lib/Types.sol
    GameType public constant RELAY_GAME_TYPE = GameType.wrap(uint32(1) << 31);

    /// @notice The threshold for the relay game.
    uint256 internal _threshold;

    /// @notice The backup game type. Default is PermissionedDisputeGame.
    GameType internal _backUpGameType;

    /// @notice The finality delays for the game types.
    mapping(GameType => uint256) internal _finalityDelays;

    /// @notice Emitted when the threshold is set.
    event ThresholdSet(uint256 threshold);
    /// @notice Emitted when the backup game type is set.
    event BackUpGameTypeSet(GameType gameType);
    /// @notice Emitted when the finality delay is set.
    event FinalityDelaySet(GameType gameType, uint256 finalityDelay);
    /// @notice Emitted when a soundness issue is detected.
    event SoundnessIssue(IDisputeGame indexed game, GameType gameType);

    constructor(uint256 _defaultFinalityDelaySeconds) AnchorStateRegistry(_defaultFinalityDelaySeconds) {
        _disableInitializers();
    }

    /// @notice Sets the threshold.
    function setThreshold(uint256 threshold_) external {
        _assertOnlyGuardian();
        
        require(threshold_ > 0, "Threshold must be greater than 0");
        _threshold = threshold_;

        emit ThresholdSet(threshold_);
    }

    /// @notice Gets the threshold for the relay game.
    /// @return The threshold.
    function threshold() external view returns (uint256) {
        return _threshold;
    }

    /// @notice Sets the finality delay for a game type.
    /// @param gameType_ The game type.
    /// @param finalityDelay_ The finality delay.
    /// @dev Only callable by the guardian. Requires the game type to be different from RELAY_GAME_TYPE.
    ///      Fianlity delay must be greater than 0.
    function setFinalityDelay(GameType gameType_, uint256 finalityDelay_) external {
        _assertOnlyGuardian();
        require(finalityDelay_ > 0, "Finality delay must be greater than 0");

        _finalityDelays[gameType_] = finalityDelay_;
        emit FinalityDelaySet(gameType_, finalityDelay_);
    }

    /// @notice Gets the finality delay for a game type.
    /// @param gameType_ The game type.
    /// @return The finality delay.
    function finalityDelay(GameType gameType_) public view returns (uint256) {
        if (_finalityDelays[gameType_] == 0) return DISPUTE_GAME_FINALITY_DELAY_SECONDS;
        return _finalityDelays[gameType_];
    }

    /// @notice Checks if a game is blacklisted.
    /// @param _game The game.
    /// @return True if the game is blacklisted, false otherwise.
    function isGameBlacklisted(IDisputeGame _game) public view override returns (bool) {
        if (GameType.unwrap(_game.gameType()) & GameType.unwrap(RELAY_GAME_TYPE) == 1) {
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
        if (GameType.unwrap(_game.gameType()) & GameType.unwrap(RELAY_GAME_TYPE) == GameType.unwrap(RELAY_GAME_TYPE)) {
            address[] memory underlyingDisputeGames = IDisputeGameRelay(address(_game)).underlyingDisputeGames();
            uint256 finalized;
            for (uint256 i = 0; i < underlyingDisputeGames.length; i++) {
                if (isGameFinalized(IDisputeGame(underlyingDisputeGames[i]))) finalized++;
            }
            return finalized >= _threshold;
        }

        return block.timestamp - _game.resolvedAt().raw() > finalityDelay(_game.gameType());
    }

    /// @notice Sets the backup game type.
    /// @param gameType_ The game type.
    /// @dev Only callable by the guardian.
    function setBackUpGameType(GameType gameType_) external {
        _assertOnlyGuardian();
        _backUpGameType = gameType_;
        emit BackUpGameTypeSet(gameType_);
    }

    /// @notice Gets the backup game type.
    /// @return The backup game type.
    function backUpGameType() external view returns (GameType) {
        return _backUpGameType;
    }

    /// @notice Nullifies the relay anchor state registry.
    /// @dev Only callable by the guardian. Requires the game to be registered and respected.
    ///      If the game is respected, the relay game types are set to the backup game types.
    ///      If the game is not respected, the respected game type is set to the backup game type.
    function nullify() external {
        IDisputeGame game = IDisputeGame(msg.sender);
        GameType gameType = game.gameType();
        
        require(isGameRegistered(game), "Game must be registered");
        bool respected = GameType.unwrap(gameType) & GameType.unwrap(respectedGameType) != 0;

        require(respected || isGameRespected(game), "Game must be respected");

        respectedGameType = _backUpGameType;
        emit RespectedGameTypeSet(_backUpGameType);

        retirementTimestamp = uint64(block.timestamp);
        emit RetirementTimestampSet(block.timestamp);
        emit SoundnessIssue(game, gameType);
    }
}