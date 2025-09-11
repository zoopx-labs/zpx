// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZPXV1
 * @dev Upgradeable ERC20 token for ZoopX (ZPX) with fixed cap, EIP-2612 permit,
 * AccessControl multi-minter, optional pausing, and UUPS upgradeability.
 *
 * The contract is designed for deployment behind a UUPS proxy. The initializer
 * sets admin and initial minters. The total supply cap is enforced on every mint.
 */
contract ZPXV1 is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Role that can mint tokens (emissions manager, vaults)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role that can pause/unpause token transfers
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Fixed total supply cap (100,000,000 * 1e18)
    uint256 public constant TOTAL_SUPPLY_CAP = 100_000_000 * 10 ** 18;

    /// @notice Emitted when tokens are minted via mint/mintBatch
    event Minted(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned
    event Burned(address indexed from, uint256 amount);

    /// @notice Thrown when a mint would exceed the cap
    error CapExceeded();

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    // ===== Initializer =====

    /**
     * @dev Disable initializers for the implementation contract.
     * This constructor will be executed on the implementation contract, not the proxy.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer for the proxied contract.
     * @param admin Address that receives DEFAULT_ADMIN_ROLE (timelocked multisig)
     * @param initialMinters Array of addresses to grant MINTER_ROLE
     * @param pauser Address to grant PAUSER_ROLE (optional, pass address(0) to skip)
     */
    function initialize(address admin, address[] calldata initialMinters, address pauser) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __ERC20_init("ZoopX", "ZPX");
        __ERC20Permit_init("ZoopX");
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant admin role
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Grant initial minters
        for (uint256 i = 0; i < initialMinters.length; ++i) {
            address m = initialMinters[i];
            if (m == address(0)) revert ZeroAddress();
            _grantRole(MINTER_ROLE, m);
        }

        // Grant pauser if provided
        if (pauser != address(0)) {
            _grantRole(PAUSER_ROLE, pauser);
        }
    }

    // ===== Mint / Burn =====

    /**
     * @notice Mint `amount` tokens to `to`.
     * @dev Caller must have MINTER_ROLE. Enforces TOTAL_SUPPLY_CAP.
     * @param to Recipient address
     * @param amount Amount to mint (in wei)
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() + amount > TOTAL_SUPPLY_CAP) revert CapExceeded();

        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @notice Mint multiple amounts to multiple recipients in a single call.
     * @dev Arrays must have equal length. Caller must have MINTER_ROLE. Enforces cap.
     * @param tos Array of recipient addresses
     * @param amounts Array of amounts to mint
     */
    function mintBatch(address[] calldata tos, uint256[] calldata amounts) external onlyRole(MINTER_ROLE) whenNotPaused {
        uint256 len = tos.length;
        if (len != amounts.length) revert();

        // Calculate total first to validate cap in one check
        uint256 totalToMint = 0;
        for (uint256 i = 0; i < len; ++i) {
            address to = tos[i];
            if (to == address(0)) revert ZeroAddress();
            totalToMint += amounts[i];
        }

        if (totalSupply() + totalToMint > TOTAL_SUPPLY_CAP) revert CapExceeded();

        for (uint256 i = 0; i < len; ++i) {
            _mint(tos[i], amounts[i]);
            emit Minted(tos[i], amounts[i]);
        }
    }

    /**
     * @notice Burn `amount` of caller's tokens.
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external whenNotPaused {
        _burn(_msgSender(), amount);
        emit Burned(_msgSender(), amount);
    }

    /**
     * @notice Burn `amount` tokens from `from`, using allowance.
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external whenNotPaused {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
        emit Burned(from, amount);
    }

    // ===== Pause =====

    /**
     * @notice Pause token transfers, minting and burning.
     * @dev Caller must have PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers, minting and burning.
     * @dev Caller must have PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ===== Overrides =====

    /**
     * @dev Override {_update} from ERC20Upgradeable to enforce pause checks on transfers, mints and burns.
     */
    function _update(address from, address to, uint256 amount) internal override {
        // Prevent operations while paused
        if (paused()) revert("ZPX: paused");
        super._update(from, to, amount);
    }

    // ===== Upgrade =====

    /**
     * @notice Authorize UUPS upgrades.
     * @dev Restricted to DEFAULT_ADMIN_ROLE (timelocked multisig).
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ===== Admin / Rescue =====

    /**
     * @notice Rescue ERC20 tokens mistakenly sent to this contract, except ZPX itself.
     * @dev Only DEFAULT_ADMIN_ROLE can call. Cannot rescue this token.
     * @param token Token address to rescue
     * @param to Recipient of rescued tokens
     * @param amount Amount to rescue
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(this)) revert();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ===== View Helpers / Constants =====

    /**
     * @notice Returns the fixed total supply cap.
     */
    function cap() external pure returns (uint256) {
        return TOTAL_SUPPLY_CAP;
    }

    // ===== Storage gap =====
    uint256[50] private __gap;
}
