// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

contract MockPreimageOracle {
    function challengePeriod() external pure returns (uint256) {
        return 100;
    }
}