// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SupplyRegistry
 * @notice Tracks aggregated market supply state for ZPX across chains & vesting.
 * @dev This contract does NOT mint or burn; it is an accounting & event surface
 *      updated by off-chain orchestrators / emission controllers holding RECORDER_ROLE.
 *
 *  Tracked dimensions:
 *   - nativeCirculating: Recognized supply minted on canonical chain (net of canonical burns used for reconciliation)
 *   - remoteRecognized: Sum of emissions / minted amounts that have been reconciled from non-native chains
 *   - vestingLocked: Current amount still locked in vesting schedules (informational; not enforced)
 *   - bridgePending: Amount burned on a source chain pending mint on a destination (in-flight bridging)
 *
 *  The grand total market supply (excluding in-flight) is:
 *      totalMarketSupply() = nativeCirculating + remoteRecognized
 *
 *  Fully diluted including locked vesting (excluding pending bridge) is:
 *      fdvSupply() = totalMarketSupply() + vestingLocked
 */
contract SupplyRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    uint256 public nativeCirculating;   // canonical recognized circulating supply
    uint256 public remoteRecognized;    // reconciled remote emissions
    uint256 public vestingLocked;       // currently locked in vesting
    uint256 public bridgePending;       // burned awaiting mint elsewhere

    event NativeMintRecorded(uint256 amount, uint256 newNativeCirculating);
    event NativeBurnReconciliation(uint256 amount, string reason, uint256 newNativeCirculating);
    event RemoteEmissionRecorded(uint256 amount, uint256 newRemoteRecognized);
    event VestingLockedUpdated(uint256 lockedAmount);
    event BridgeBurnPending(uint256 amount, uint256 newBridgePending);
    event BridgeMintSettled(uint256 amount, uint256 newBridgePending);
    event MarketSnapshot(uint256 nativeCirculating, uint256 remoteRecognized, uint256 vestingLocked, uint256 bridgePending, uint256 totalMarketSupply, uint256 fdvSupply);

    error NotPositive();
    error InsufficientPending();
    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address recorder) external initializer {
        if (admin == address(0) || recorder == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECORDER_ROLE, recorder);
    }

    // ============ Recording Functions (Restricted) ============

    function recordNativeMint(uint256 amount) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert NotPositive();
        nativeCirculating += amount;
        emit NativeMintRecorded(amount, nativeCirculating);
    }

    // Called when burning on native chain to reflect supply moved elsewhere or retired.
    function recordNativeBurnReconciliation(uint256 amount, string calldata reason) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert NotPositive();
        nativeCirculating -= amount; // underflow will revert automatically if inconsistent
        emit NativeBurnReconciliation(amount, reason, nativeCirculating);
    }

    function recordRemoteEmission(uint256 amount) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert NotPositive();
        remoteRecognized += amount;
        emit RemoteEmissionRecorded(amount, remoteRecognized);
    }

    function updateVestingLocked(uint256 lockedAmount) external onlyRole(RECORDER_ROLE) {
        vestingLocked = lockedAmount; // lockedAmount may go up or down as schedules unlock
        emit VestingLockedUpdated(lockedAmount);
    }

    function recordBridgeBurn(uint256 amount) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert NotPositive();
        bridgePending += amount;
        emit BridgeBurnPending(amount, bridgePending);
    }

    function recordBridgeMint(uint256 amount) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert NotPositive();
        if (bridgePending < amount) revert InsufficientPending();
        bridgePending -= amount;
        emit BridgeMintSettled(amount, bridgePending);
    }

    function snapshot() external onlyRole(RECORDER_ROLE) {
        emit MarketSnapshot(
            nativeCirculating,
            remoteRecognized,
            vestingLocked,
            bridgePending,
            totalMarketSupply(),
            fdvSupply()
        );
    }

    // ============ Views ============

    function totalMarketSupply() public view returns (uint256) {
        return nativeCirculating + remoteRecognized; // excludes in-flight & locked
    }

    function fdvSupply() public view returns (uint256) {
        return totalMarketSupply() + vestingLocked; // conceptual fully diluted (locked + circulating)
    }

    // ============ Upgrade Auth ============
    function _authorizeUpgrade(address impl) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[42] private __gap; // reserve storage for future expansion
}
