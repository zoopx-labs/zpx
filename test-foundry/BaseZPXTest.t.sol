// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {ZPXV2} from "contracts/ZPXV2.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

abstract contract BaseZPXTest is Test {
    address internal admin = address(0xA11CE);
    address internal minter = address(0xBEEF);
    address internal pauser = address(0xCAFE);
    address internal rescuer = address(0xD00D);

    ZPXV1 internal implV1;
    ZPXV1 internal token; // proxy as V1 interface

    function deployV1(uint256 cap) internal {
        implV1 = new ZPXV1();
        bytes memory data = abi.encodeCall(
            ZPXV1.initialize,
            ("ZoopX", "ZPX", admin, minter, pauser, rescuer, cap)
        );
        LocalERC1967Proxy proxy = new LocalERC1967Proxy(address(implV1), data);
        token = ZPXV1(address(proxy));
    }

    function upgradeToV2(address bridge) internal returns (ZPXV2 v2) {
        v2 = new ZPXV2();
        vm.prank(admin);
        (bool ok,) = address(token).call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(v2),
                abi.encodeCall(ZPXV2.upgradeToSuperchainERC20, (bridge))
            )
        );
        require(ok, "upgrade fail");
    }
}
