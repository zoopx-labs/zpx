// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library SafeCast {
    // Minimal safe cast utilities — expand as needed for contracts.
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: overflow");
        return uint128(value);
    }
}
