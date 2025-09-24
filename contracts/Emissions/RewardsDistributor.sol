// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SupplyRegistry} from "../SupplyRegistry.sol";

/**
 * @title RewardsDistributor
 * @notice Merkle-root based distribution of previously minted emission allocations.
 * @dev EmissionsManager mints tokens to this contract. Governance (or authorized role)
 *      publishes a merkle root mapping (account, amount) => claimable for an epoch.
 */
contract RewardsDistributor is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ===== Roles =====
    bytes32 public constant ROOT_SETTER_ROLE = keccak256("ROOT_SETTER_ROLE");
    bytes32 public constant RECOVER_ROLE     = keccak256("RECOVER_ROLE");

    // ===== Types =====
    struct RootInfo {
        bytes32 root;      // merkle root of (account, amount)
        uint256 total;     // total tokens allocated by root (informational)
        uint256 claimed;   // claimed so far against this root
    }

    IERC20 public token;            // reward token (ZPX)
    SupplyRegistry public registry; // optional reference for future accounting snapshots

    uint256 public lastRootId;      // incremental root id
    mapping(uint256 => RootInfo) public roots; // id => info
    mapping(uint256 => mapping(address => uint256)) public claimed; // id => account => amount claimed

    // ===== Events =====
    event RootPublished(uint256 indexed id, bytes32 root, uint256 total);
    event Claimed(uint256 indexed id, address indexed account, uint256 amount, uint256 cumulative, uint256 rootClaimed);
    event Skimmed(address indexed to, uint256 amount);

    // ===== Errors =====
    error ZeroAddress();
    error InvalidAmount();
    error InvalidProof();
    error NothingToClaim();
    error RootNotFound();

    constructor() {
        _disableInitializers();
    }

    // Reentrancy guard storage (simple custom implementation since upgradeable variant not present)
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status; // default zero until initialized

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    function initialize(address admin, address token_, address registry_) external initializer {
        if (admin == address(0) || token_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _status = _NOT_ENTERED;
        token = IERC20(token_);
        if (registry_ != address(0)) registry = SupplyRegistry(registry_); // optional
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROOT_SETTER_ROLE, admin);
        _grantRole(RECOVER_ROLE, admin);
    }

    // ===== Root Publication =====

    /**
     * @notice Publish a new merkle root representing cumulative claimable amounts.
     * @dev Each leaf encodes (account, cumulativeAmount). Users can claim the delta since last claimed.
     */
    function publishRoot(bytes32 root, uint256 total) external onlyRole(ROOT_SETTER_ROLE) {
        if (root == bytes32(0) || total == 0) revert InvalidAmount();
        uint256 id = ++lastRootId;
        roots[id] = RootInfo({root: root, total: total, claimed: 0});
        emit RootPublished(id, root, total);
    }

    // ===== Claims =====

    /**
     * @notice Claim rewards for a given root id using a merkle proof of cumulative amount.
     * @param id Root id
     * @param account Account to claim for
     * @param cumulativeAmount Total cumulative entitlement encoded in merkle tree
     * @param proof Merkle proof
     */
    function claim(uint256 id, address account, uint256 cumulativeAmount, bytes32[] calldata proof) external nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        RootInfo storage info = roots[id];
    if (info.root == bytes32(0)) revert RootNotFound();
    bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
    if (!MerkleProof.verify(proof, info.root, leaf)) revert InvalidProof();

        uint256 alreadyClaimed = claimed[id][account];
        if (cumulativeAmount <= alreadyClaimed) revert NothingToClaim();
        uint256 amount = cumulativeAmount - alreadyClaimed;

        claimed[id][account] = cumulativeAmount;
        info.claimed += amount;

        token.safeTransfer(account, amount);
        emit Claimed(id, account, amount, cumulativeAmount, info.claimed);
    }

    // ===== Admin Utilities =====

    /**
     * @notice Skim unallocated tokens (e.g., after migrating to new distributor). Governance only.
     */
    function skim(address to, uint256 amount) external onlyRole(RECOVER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Skimmed(to, amount);
    }

    // ===== Views =====
    function unclaimedInRoot(uint256 id) external view returns (uint256) {
        RootInfo storage info = roots[id];
        if (info.root == bytes32(0)) return 0;
        return info.total - info.claimed; // may not reflect per-user availability precisely
    }

    // ===== Upgrade auth =====
    function _authorizeUpgrade(address impl) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[44] private __gap; // storage gap
}
