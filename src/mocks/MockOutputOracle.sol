// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Types } from "optimism/src/libraries/Types.sol";
import { IOutputOracle } from "src/interfaces/IOutputOracle.sol";

contract MockOutputOracle is IOutputOracle {
    Types.OutputProposal[] public l2Outputs;

    function getL2Output(uint256 _l2OutputIndex) external view returns (Types.OutputProposal memory) {
        return l2Outputs[_l2OutputIndex];
    }

    function proposeL2Output(bytes32 _outputRoot, uint256 _l2BlockNumber, uint256 /*_l1BlockNumber*/, bytes calldata /*_signature*/) external {
        l2Outputs.push(Types.OutputProposal({ outputRoot: _outputRoot, timestamp: uint128(block.timestamp), l2BlockNumber: uint128(_l2BlockNumber) }));
    }
}