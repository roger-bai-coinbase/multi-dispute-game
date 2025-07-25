// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Claim, GameStatus } from "optimism/src/dispute/lib/Types.sol";

interface IKailuaTournament {
    function KAILUA_TREASURY() external view returns (IKailuaTreasury);
    function proveValidity(address payoutRecipient, address l1HeadSource, uint64 childIndex, bytes calldata encodedSeal) external;
    function parentGame() external view returns (IKailuaTournament);
}

interface IKailuaTreasury is IKailuaTournament {
    function propose(Claim _rootClaim, bytes calldata _extraData) external payable returns (address tournament);
    function resolve() external returns (GameStatus status);
    function setParticipationBond(uint256 amount) external;
    function participationBond() external view returns (uint256);
}

interface IKailuaGame is IKailuaTournament {
    function resolve() external returns (GameStatus status);
}

