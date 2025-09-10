// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title TokenVesting
 * @dev Simple bucket-based vesting with cliff + linear unlocks.
 * NOTE: This is a basic reference implementation for tests and should be audited.
 */
contract TokenVesting is Context {
    IERC20 public immutable token;
    address public beneficiary;
    uint256 public cliff; // timestamp
    uint256 public start; // timestamp
    uint256 public duration; // total duration after cliff for linear unlock
    uint256 public released;

    constructor(IERC20 _token, address _beneficiary, uint256 _start, uint256 _cliffDuration, uint256 _duration) {
        token = _token;
        beneficiary = _beneficiary;
        start = _start;
        cliff = _start + _cliffDuration;
        duration = _duration;
    }

    function releasable() public view returns (uint256) {
        uint256 vested = vestedAmount();
        return vested - released;
    }

    function vestedAmount() public view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + released;
        if (block.timestamp < cliff) {
            return 0;
        } else if (block.timestamp >= cliff + duration) {
            return total;
        } else {
            uint256 timeSinceCliff = block.timestamp - cliff;
            return (total * timeSinceCliff) / duration;
        }
    }

    function release() external {
        uint256 amount = releasable();
        require(amount > 0, "No tokens to release");
        released += amount;
        token.transfer(beneficiary, amount);
    }
}
