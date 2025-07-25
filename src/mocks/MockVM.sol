// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { IBigStepper, IPreimageOracle } from "optimism/interfaces/dispute/IBigStepper.sol";

contract MockVM is IBigStepper {
    IPreimageOracle public oracle;

    constructor(IPreimageOracle _oracle) {
        oracle = _oracle;
    }

    function step(bytes calldata _stateData, bytes calldata _proof, bytes32 _localContext) external returns (bytes32 postState_) {
        // Do nothing
    }
}