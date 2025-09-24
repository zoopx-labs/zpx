// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {BaseZPXTest} from "./BaseZPXTest.t.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";

contract Handler is Test {
    ZPXV1 internal token;
    address internal minter;
    constructor(ZPXV1 _token, address _minter) { token = _token; minter = _minter; }

    function mint(uint256 amount) external {
        amount = bound(amount, 0, 10_000 ether);
        vm.prank(minter);
        token.mint(address(this), amount);
    }

    function burn(uint256 amount) external {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        token.burn(amount);
    }
}

contract ZPXInvariants is StdInvariant, BaseZPXTest {
    Handler internal handler;
    uint256 internal cap = 1_000_000 ether;

    function setUp() public {
        deployV1(cap);
        handler = new Handler(token, minter);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyLeCap() public {
        assertLe(token.totalSupply(), cap);
    }

    function invariant_NoOverflowBalance() public {
        // Simple sanity: handler balance <= cap
        assertLe(token.balanceOf(address(handler)), cap);
    }
}
