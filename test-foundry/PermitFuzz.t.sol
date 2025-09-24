// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {BaseZPXTest} from "./BaseZPXTest.t.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";

contract PermitFuzz is BaseZPXTest {
    bytes32 private DOMAIN_SEPARATOR;

    function setUp() public {
        deployV1(1_000_000 ether);
        DOMAIN_SEPARATOR = token.DOMAIN_SEPARATOR();
    }

    function testFuzzPermit(uint256 privateKey, uint256 value, uint256 deadlineOffset) public {
        privateKey = bound(privateKey, 1, type(uint256).max - 1);
        address owner = vm.addr(privateKey);
        value = bound(value, 0, 1_000_000 ether);
        uint256 nonce = token.nonces(owner);
        uint256 deadline = block.timestamp + (deadlineOffset % 30 days);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(this),
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        token.permit(owner, address(this), value, deadline, v, r, s);
        assertEq(token.allowance(owner, address(this)), value);
        assertEq(token.nonces(owner), nonce + 1);
    }
}
