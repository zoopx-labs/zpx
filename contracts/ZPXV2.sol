// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ZPXV1.sol";

/**
 * @title ZPXV2
 * @dev Future upgrade: adds SuperchainERC20 hooks (IERC-7802) and bridge-restricted functions.
 * This is a stub that preserves storage layout of ZPXV1. Add real bridge logic during upgrade.
 */
contract ZPXV2 is ZPXV1 {
    // Events for cross-chain operations
    event CrosschainMint(address indexed to, uint256 amount);
    event CrosschainBurn(address indexed from, uint256 amount);

    // Placeholder role for bridge (could be a dedicated BRIDGE_ROLE)
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    // One-time initializer for enabling superchain hooks
    function upgradeToSuperchain(address bridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // TODO: grant BRIDGE_ROLE to bridge and perform any one-time setup
        _grantRole(BRIDGE_ROLE, bridge);
    }

    function crosschainMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        // Implement bridge-restricted mint; enforce cap as needed
        require(totalSupply() + amount <= MAX_SUPPLY, "ZPX: cap exceeded");
        _mint(to, amount);
        emit CrosschainMint(to, amount);
    }

    function crosschainBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        // Implement bridge-restricted burn
        _burn(from, amount);
        emit CrosschainBurn(from, amount);
    }
}
