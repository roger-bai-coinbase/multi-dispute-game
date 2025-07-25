// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { IZKVerifier } from "../interfaces/IZKVerifier.sol";
import { Claim } from "optimism/src/dispute/lib/Types.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32, bytes32) external pure returns (bool) {
        return true;
    }
}