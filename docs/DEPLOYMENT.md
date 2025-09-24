# Deployment

This guide outlines deploying the ZPX upgradeable token stack (canonical chain) plus Emissions & Supply Registry components. Vesting contract has been removed; any vesting reporting is off‑chain and optionally reflected via `updateVestingLocked` on `SupplyRegistry` by governance automation.

## Prerequisites
* Foundry toolchain installed (`forge`, `cast`).
* Deployer wallet with governance multisig address prepared.
* Cap value & initial allocations finalized.

## Contracts & Order
1. Deploy `ZPXV1` implementation.
2. Deploy `LocalERC1967Proxy` pointing to `ZPXV1` with `initialize(admin, initialMinters, pauser)` calldata.
3. Deploy `SupplyRegistry` implementation & proxy, initializing with `(admin, recorder)` – typically recorder = governance initially.
4. Deploy `EmissionsManager` implementation & proxy, initializing with `(admin, zpxProxy, supplyRegistryProxy)`.
5. Grant roles:
	* ZPX: `MINTER_ROLE` to EmissionsManager and bridge agent (once available).
	* Registry: `RECORDER_ROLE` to EmissionsManager + bridge agent + automation bots.
	* EmissionsManager: `SCHEDULER_ROLE` to governance, `EMITTER_ROLE` to operations hot wallet, `PAUSER_ROLE` to security council.
6. (Optional now / future) Upgrade token to `ZPXV2` (bridge extension) after bridge agent readiness.

## Scheduling Emissions
1. Governance schedules an epoch: `scheduleEpoch(start, end, budget)` (must be future & non‑overlapping).
2. Operations emits with `emitTo`, `emitBatch`, or funds distributor `emitToDistributor` after epoch start.
3. Governance can increase budget (`increaseEpochBudget`) or early finalize (`finalizeEpoch`) if halting remaining allowance is needed.

## Rewards Distribution (Optional Flow)
1. Deploy `RewardsDistributor` proxy: init `(admin)`.
2. Grant `ROOT_SETTER_ROLE` to emissions governance or designated publisher.
3. EmissionsManager mints directly to distributor via `emitToDistributor`.
4. Off‑chain service publishes cumulative merkle root; users claim deltas.
5. Periodic `skim` recovers dust to governance treasury.

## Supply Accounting
Every emission calls `recordNativeMint(amount)` so observers reconstruct supply from events:
* Circulating = `nativeCirculating + remoteRecognized - bridgePending` (bridge pending excluded from immediate accessible supply).
* Fully Diluted (conceptual) = above + `vestingLocked` (if externally maintained).

## Upgrades
* Use UUPS upgrade with governance multisig executing `upgradeTo` / `upgradeToAndCall` via timelock.
* Prior to Superchain (future) upgrade, audit storage layout and keep `__gap` buffers.

## Post-Deployment Hardening Checklist
* Transfer admin ownership to timelock governance.
* Set operations & security role separation (different keys).
* Run invariant & fuzz test suite against deployed artifacts (dry-run on fork).
* Publish merkle distribution spec & hashing domain for user verification.

## Future: SuperchainERC20 Migration
When adopting the Superchain standard:
* Deploy new implementation referencing standard interface.
* Ensure bridging role semantics align (e.g., dedicated system contracts in OP Stack).
* Run storage layout diff before upgrade.

