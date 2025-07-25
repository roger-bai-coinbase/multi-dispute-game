// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Claim } from "optimism/src/dispute/lib/Types.sol";

interface IZKVerifier {
    function verify(bytes calldata _proof, bytes32 _rootClaim, bytes32 _l2SequenceNumber) external view returns (bool);
}