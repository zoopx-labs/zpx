// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./ZPXV1.sol";

/**
 * @title ZPXV2
 * @dev Upgrade to add Superchain/ERC-7802 style bridge hooks. This contract
 * preserves the storage layout of ZPXV1 and appends new storage only.
 *
 * The `upgradeToSuperchainERC20` initializer must be called once after upgrade
 * to configure the canonical bridge address and grant the BRIDGE_ROLE.
 */
contract ZPXV2 is ZPXV1 {
    /// @notice Role granted to the SuperchainTokenBridge predeploy
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Configured bridge address (set during one-time initializer)
    address private _bridge;

    /// @notice Emitted when the bridge mints tokens on this chain
    event CrosschainMint(address indexed to, uint256 amount);

    /// @notice Emitted when the bridge burns tokens on this chain
    event CrosschainBurn(address indexed from, uint256 amount);

    /// @notice Emitted when the bridge address is configured
    event BridgeConfigured(address indexed bridge);

    // ===== One-time upgrade initializer =====

    /**
     * @notice One-time initializer to configure Superchain bridge hooks.
     * @dev Can only be called once (reinitializer(2)) after upgrading the proxy to V2.
     * Grants `BRIDGE_ROLE` to the provided bridge address.
     * @param bridge_ The bridge predeploy address to grant the BRIDGE_ROLE
     */
    function upgradeToSuperchainERC20(address bridge_) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bridge_ != address(0), "ZPXV2: zero bridge");
        _bridge = bridge_;
        _grantRole(BRIDGE_ROLE, bridge_);
        emit BridgeConfigured(bridge_);
    }

    // ===== Bridge-restricted hooks =====

    /**
     * @notice Mint tokens on this chain as instructed by the Superchain bridge.
     * @dev Restricted to BRIDGE_ROLE. Respects pause state and cap.
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function crosschainMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        require(to != address(0), "ZPXV2: zero recipient");
        require(totalSupply() + amount <= TOTAL_SUPPLY_CAP, "ZPXV2: cap exceeded");
        _mint(to, amount);
        emit CrosschainMint(to, amount);
    }

    /**
     * @notice Burn tokens on this chain as instructed by the Superchain bridge.
     * @dev Restricted to BRIDGE_ROLE. Respects pause state.
     * @param from Address whose tokens will be burned
     * @param amount Amount to burn
     */
    function crosschainBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        _burn(from, amount);
        emit CrosschainBurn(from, amount);
    }

    /**
     * @notice Returns the configured superchain bridge address.
     */
    function superchainBridge() external view returns (address) {
        return _bridge;
    }

    // ===== Storage gap for V2 additions =====
    // Preserve V1's __gap[50] and add a smaller gap for future V2 storage additions.
    uint256[49] private __gapV2;
}
