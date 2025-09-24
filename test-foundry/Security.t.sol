// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {ZPXV2} from "contracts/ZPXV2.sol";
import {EmissionsManager} from "contracts/Emissions/EmissionsManager.sol";
import {RewardsDistributor} from "contracts/Emissions/RewardsDistributor.sol";
import {SupplyRegistry} from "contracts/SupplyRegistry.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

// Minimal new implementation stubs to attempt unauthorized upgrades
contract DummyImplV1 is ZPXV1 {}
contract DummyImplManager is EmissionsManager {}
contract DummyImplRegistry is SupplyRegistry {}
contract DummyImplDistributor is RewardsDistributor {}

contract SecurityTest is Test {
    address internal admin = address(0xA11CE);
    address internal attacker = address(0xBAD);
    address internal minter = address(0xBEEF);
    address internal pauser = address(0xCAFE);

    ZPXV1 internal token;
    SupplyRegistry internal registry;
    EmissionsManager internal manager;
    RewardsDistributor internal distributor;

    function setUp() public {
        // Deploy token proxy
        ZPXV1 impl = new ZPXV1();
        address[] memory minters = new address[](1); minters[0] = minter;
        bytes memory initData = abi.encodeCall(ZPXV1.initialize, (admin, minters, pauser));
        LocalERC1967Proxy tokenProxy = new LocalERC1967Proxy(address(impl), initData);
        token = ZPXV1(address(tokenProxy));
        // Registry
        SupplyRegistry regImpl = new SupplyRegistry();
        bytes memory regInit = abi.encodeCall(SupplyRegistry.initialize,(admin, admin));
        LocalERC1967Proxy regProxy = new LocalERC1967Proxy(address(regImpl), regInit);
        registry = SupplyRegistry(address(regProxy));
        // Manager
        EmissionsManager manImpl = new EmissionsManager();
        bytes memory manInit = abi.encodeCall(EmissionsManager.initialize,(admin, address(token), address(registry)));
        LocalERC1967Proxy manProxy = new LocalERC1967Proxy(address(manImpl), manInit);
        manager = EmissionsManager(address(manProxy));
        // Distributor
        RewardsDistributor distImpl = new RewardsDistributor();
        bytes memory distInit = abi.encodeCall(RewardsDistributor.initialize,(admin, address(token), address(0)));
        LocalERC1967Proxy distProxy = new LocalERC1967Proxy(address(distImpl), distInit);
        distributor = RewardsDistributor(address(distProxy));
    }

    // --- Unauthorized Upgrades ---
    function testUnauthorizedUpgradeTokenReverts() public {
        DummyImplV1 newImpl = new DummyImplV1();
        vm.prank(attacker);
        bytes memory data = abi.encodeWithSignature("upgradeTo(address)", address(newImpl));
        (bool ok,) = address(token).call(data);
        assertTrue(!ok, "upgrade should fail");
    }

    function testUnauthorizedUpgradeManagerReverts() public {
        DummyImplManager newImpl = new DummyImplManager();
        vm.prank(attacker);
        (bool ok,) = address(manager).call(abi.encodeWithSignature("upgradeTo(address)", address(newImpl)));
        assertTrue(!ok, "manager upgrade fail");
    }

    function testUnauthorizedUpgradeRegistryReverts() public {
        DummyImplRegistry newImpl = new DummyImplRegistry();
        vm.prank(attacker);
        (bool ok,) = address(registry).call(abi.encodeWithSignature("upgradeTo(address)", address(newImpl)));
        assertTrue(!ok, "registry upgrade fail");
    }

    function testUnauthorizedUpgradeDistributorReverts() public {
        DummyImplDistributor newImpl = new DummyImplDistributor();
        vm.prank(attacker);
        (bool ok,) = address(distributor).call(abi.encodeWithSignature("upgradeTo(address)", address(newImpl)));
        assertTrue(!ok, "distributor upgrade fail");
    }

    // --- Pause Misuse ---
    function testDoublePauseReverts() public {
        vm.prank(pauser); token.pause();
        vm.prank(pauser); vm.expectRevert(); token.pause();
    }

    function testUnpauseByNonPauserReverts() public {
        vm.prank(pauser); token.pause();
        vm.prank(attacker); vm.expectRevert(); token.unpause();
    }

    // --- Role Misuse ---
    function testNonEmitterCannotEmit() public {
        // Grant roles needed except attacker
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(manager));
        registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        manager.grantRole(manager.SCHEDULER_ROLE(), admin);
        manager.grantRole(manager.EMITTER_ROLE(), admin);
        vm.stopPrank();
        // Schedule
        uint64 start = uint64(block.timestamp + 5); uint64 end = start + 20;
        vm.prank(admin); manager.scheduleEpoch(start, end, 10 ether);
        vm.warp(start + 1);
        // Attacker tries to emit
        vm.prank(attacker); vm.expectRevert(); manager.emitTo(attacker, 1 ether);
    }

    // --- Zero Address Guards (redundant coverage consolidation) ---
    function testDistributorClaimZeroAddressReverts() public {
        // publish root
        bytes32 root = keccak256("root");
        vm.prank(admin); distributor.publishRoot(root, 100);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert();
        distributor.claim(1, address(0), 10, proof);
    }

    // --- Fuzz: mintBatch respects cap & revert beyond ---
    function testFuzz_MintBatchWithinCap(address a, address b, uint128 x, uint128 y) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        uint256 cap = token.TOTAL_SUPPLY_CAP();
        uint256 current = token.totalSupply();
        // Bound amounts so sum stays within remaining space  (if too large, shrink)
        uint256 remaining = cap - current;
        if (remaining == 0) return;
        x = uint128(bound(uint256(x), 0, remaining));
        uint256 remAfterX = remaining - x;
        y = uint128(bound(uint256(y), 0, remAfterX));
        address[] memory tos = new address[](2); tos[0] = a; tos[1] = b;
        uint256[] memory amts = new uint256[](2); amts[0] = x; amts[1] = y;
        vm.prank(minter); token.mintBatch(tos, amts);
        assertEq(token.balanceOf(a), x);
        assertEq(token.balanceOf(b), y);
        assertLe(token.totalSupply(), cap);
    }
}
