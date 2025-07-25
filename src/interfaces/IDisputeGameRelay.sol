// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IDisputeGame } from "optimism/interfaces/dispute/IDisputeGame.sol";

interface IDisputeGameRelay is IDisputeGame {
    function underlyingDisputeGames() external view returns (address[] memory);
}