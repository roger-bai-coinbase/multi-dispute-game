// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { GameType, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { IAnchorStateRegistry } from "optimism/interfaces/dispute/IAnchorStateRegistry.sol";

interface IRelayAnchorStateRegistry is IAnchorStateRegistry {
    function setThreshold(uint256 _threshold) external;
    function threshold() external view returns (uint256);
    function nullify() external;
    function setBackUpGameType(GameType gameType_) external;
    function backUpGameType() external view returns (GameType);
}