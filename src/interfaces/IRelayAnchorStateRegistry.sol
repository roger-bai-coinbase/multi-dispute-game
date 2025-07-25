// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { GameType, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { IAnchorStateRegistry } from "optimism/interfaces/dispute/IAnchorStateRegistry.sol";
import { RelayGameType } from "src/RelayAnchorStateRegistry.sol";

interface IRelayAnchorStateRegistry is IAnchorStateRegistry {
    function setRelayGameTypesAndThreshold(RelayGameType[] memory _relayGameTypes, uint256 _threshold) external;
    function setThreshold(uint256 _threshold) external;
    function relayGameTypes() external view returns (RelayGameType[] memory);
    function requiredGameTypes() external view returns (GameType[] memory);
    function threshold() external view returns (uint256);
    function nullify() external;
    function isGameTypeRequired(GameType gameType_) external view returns (bool);
    function setBackUpGameType(GameType gameType_) external;
    function setBackUpGameTypes(RelayGameType[] memory gameTypes_) external;
    function backUpGameType() external view returns (GameType);
    function backUpGameTypes() external view returns (RelayGameType[] memory);
    function evaluateGameStatuses(GameStatus[] memory statuses, GameType[] memory gameTypes) external view returns (GameStatus);
}