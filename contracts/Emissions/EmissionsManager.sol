// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {SupplyRegistry} from "../SupplyRegistry.sol";

interface IZPX is IERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * @title EmissionsManager
 * @notice Canonical chain emission epoch budgeting & controlled minting for ZPX.
 * @dev Holds MINTER_ROLE on the ZPX token. Epochs define a time-bounded budget. Mints
 *      can only occur inside an active epoch and cannot exceed its budget. Excess
 *      budget at epoch end simply expires (or can be reallocated via the next epoch).
 *
 * Responsibilities:
 *  - Schedule non-overlapping epochs (future-dated)
 *  - Increase budget of active/future epochs (never decrease mid-epoch to avoid games)
 *  - Mint directly to recipients OR a rewards distributor (pull model for users)
 *  - Record native minting to the SupplyRegistry for transparent supply accounting
 *
 * Separation of Concerns:
 *  - This contract performs budget enforcement only; it does not implement complex
 *    distribution math (delegated to RewardsDistributor / off-chain allocation)
 *  - Governance / scheduler creates epochs; operational emitter executes emissions
 */
contract EmissionsManager is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using Math for uint256;

    // ===== Roles =====
    bytes32 public constant SCHEDULER_ROLE = keccak256("SCHEDULER_ROLE");
    bytes32 public constant EMITTER_ROLE   = keccak256("EMITTER_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    // ===== Structs =====
    struct Epoch {
        uint64 start;      // inclusive
        uint64 end;        // exclusive
        uint128 budget;    // total allowable mint during epoch
        uint128 minted;    // amount minted so far
        bool finalized;    // governance finalization (optional; auto considered final after end)
    }

    // ===== State =====
    IZPX public token;              // ZPX token (upgradeable proxy address)
    SupplyRegistry public registry; // Supply accounting registry
    uint256 public lastEpochId;     // incremental id
    mapping(uint256 => Epoch) public epochs; // epochId => data

    // ===== Events =====
    event EpochScheduled(uint256 indexed id, uint64 start, uint64 end, uint128 budget);
    event EpochBudgetIncreased(uint256 indexed id, uint128 newBudget);
    event EpochEmission(uint256 indexed id, address indexed to, uint256 amount, uint128 epochMinted);
    event EpochEmissionBatch(uint256 indexed id, uint256 recipients, uint256 totalAmount, uint128 epochMinted);
    event EpochFinalized(uint256 indexed id, uint128 unusedBudget);
    event NativeMintRecorded(address indexed to, uint256 amount);

    // ===== Errors =====
    error InvalidTime();
    error Overlap();
    error EpochNotActive();
    error BudgetExceeded();
    error ZeroAddress();
    error NotEpoch();
    error AlreadyFinal();
    error NotStarted();
    error LengthMismatch();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address token_, address registry_) external initializer {
        if (admin == address(0) || token_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        token = IZPX(token_);
        registry = SupplyRegistry(registry_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SCHEDULER_ROLE, admin); // governance multisig initially
        _grantRole(PAUSER_ROLE, admin);
    }

    // ===== Epoch Scheduling =====

    /**
     * @notice Schedule a new future epoch with given window & budget.
     * @dev start must be >= now, end > start, non-overlapping with previous epoch.
     */
    function scheduleEpoch(uint64 start, uint64 end, uint128 budget) external onlyRole(SCHEDULER_ROLE) {
        if (end <= start || budget == 0) revert InvalidTime();
        if (start < block.timestamp) revert InvalidTime();

        // Ensure no overlap with previous (if any)
        if (lastEpochId > 0) {
            Epoch storage prev = epochs[lastEpochId];
            if (start < prev.end) revert Overlap();
        }

        uint256 newId = ++lastEpochId;
        epochs[newId] = Epoch({start: start, end: end, budget: budget, minted: 0, finalized: false});
        emit EpochScheduled(newId, start, end, budget);
    }

    /**
     * @notice Increase (never decrease) the budget of an existing future or active epoch.
     */
    function increaseEpochBudget(uint256 id, uint128 additional) external onlyRole(SCHEDULER_ROLE) {
        Epoch storage e = epochs[id];
        if (e.end == 0) revert NotEpoch();
        if (additional == 0) return; // no-op
        e.budget += additional; // overflow unrealistic w/ 128-bit and supply cap
        emit EpochBudgetIncreased(id, e.budget);
    }

    /**
     * @notice Explicitly finalize an epoch early (e.g., halt remaining budget).
     * @dev Can only finalize if epoch started. Remaining unused budget becomes inert.
     */
    function finalizeEpoch(uint256 id) external onlyRole(SCHEDULER_ROLE) {
        Epoch storage e = epochs[id];
        if (e.end == 0) revert NotEpoch();
        if (e.finalized) revert AlreadyFinal();
        if (block.timestamp < e.start) revert NotStarted();
        e.finalized = true;
        uint128 unused = 0;
        if (block.timestamp < e.end) {
            // Early finalization – compute unused
            unused = e.budget - e.minted;
        }
        emit EpochFinalized(id, unused);
    }

    // ===== Emission Execution =====

    function _activeEpoch() internal view returns (uint256 id, Epoch storage e) {
        id = lastEpochId;
        if (id == 0) revert EpochNotActive();
        e = epochs[id];
        if (block.timestamp < e.start || block.timestamp >= e.end || e.finalized) revert EpochNotActive();
    }

    /**
     * @notice Mint emission to a single recipient within the active epoch.
     */
    function emitTo(address to, uint256 amount) external whenNotPaused onlyRole(EMITTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        (uint256 id, Epoch storage e) = _activeEpoch();
        uint256 newMinted = uint256(e.minted) + amount;
        if (newMinted > e.budget) revert BudgetExceeded();
        e.minted = uint128(newMinted);
        token.mint(to, amount);
        registry.recordNativeMint(amount);
        emit EpochEmission(id, to, amount, e.minted);
        emit NativeMintRecorded(to, amount);
    }

    /**
     * @notice Batch mint to multiple recipients. Reverts on any zero address or if budget exceeded.
     */
    function emitBatch(address[] calldata tos, uint256[] calldata amounts) external whenNotPaused onlyRole(EMITTER_ROLE) {
        uint256 len = tos.length;
        if (len != amounts.length) revert LengthMismatch();
        (uint256 id, Epoch storage e) = _activeEpoch();

        uint256 total;
        for (uint256 i; i < len; ++i) {
            address to = tos[i];
            if (to == address(0)) revert ZeroAddress();
            total += amounts[i];
        }

        uint256 newMinted = uint256(e.minted) + total;
        if (newMinted > e.budget) revert BudgetExceeded();
        e.minted = uint128(newMinted);

        for (uint256 i; i < len; ++i) {
            token.mint(tos[i], amounts[i]);
            emit EpochEmission(id, tos[i], amounts[i], e.minted); // optional per-recipient granularity
        }
        registry.recordNativeMint(total);
        emit EpochEmissionBatch(id, len, total, e.minted);
    }

    /**
     * @notice Mint emissions directly to a RewardsDistributor (e.g., merkle root based).
     */
    function emitToDistributor(address distributor, uint256 amount) external whenNotPaused onlyRole(EMITTER_ROLE) {
        if (distributor == address(0)) revert ZeroAddress();
        (uint256 id, Epoch storage e) = _activeEpoch();
        uint256 newMinted = uint256(e.minted) + amount;
        if (newMinted > e.budget) revert BudgetExceeded();
        e.minted = uint128(newMinted);
        token.mint(distributor, amount);
        registry.recordNativeMint(amount);
        emit EpochEmission(id, distributor, amount, e.minted);
        emit NativeMintRecorded(distributor, amount);
    }

    // ===== Views =====

    function epochRemaining(uint256 id) external view returns (uint256) {
        Epoch storage e = epochs[id];
        if (e.end == 0) return 0;
        if (block.timestamp >= e.end || block.timestamp < e.start || e.finalized) return 0;
        return e.budget - e.minted;
    }

    function activeEpochId() external view returns (uint256) {
        uint256 id = lastEpochId;
        if (id == 0) return 0;
        Epoch storage e = epochs[id];
        if (block.timestamp < e.start || block.timestamp >= e.end || e.finalized) return 0;
        return id;
    }

    // ===== Admin =====

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ===== Upgrade auth =====
    function _authorizeUpgrade(address impl) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[45] private __gap; // storage gap
}
