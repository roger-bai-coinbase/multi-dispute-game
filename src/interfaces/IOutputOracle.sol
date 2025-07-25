// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Types } from "optimism/src/libraries/Types.sol";

interface IOutputOracle {
    function getL2Output(uint256 _l2OutputIndex) external view returns (Types.OutputProposal memory);
    function proposeL2Output(bytes32 _outputRoot, uint256 _l2BlockNumber, uint256 _l1BlockNumber, bytes calldata _signature) external;
}