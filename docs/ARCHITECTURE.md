# Architecture

This repository contains the upgradeable ZPX token stack, multi‑chain supply accounting, and emissions & distribution layer.

## Core Components

### ZPXV1 (Upgradeable ERC20)
* UUPS upgradeable token with a fixed cap enforced in `mint` / `mintBatch`.
* Roles:
	* `DEFAULT_ADMIN_ROLE` – governance multisig.
	* `MINTER_ROLE` – entities allowed to mint (EmissionsManager, bridge proxy).
	* `PAUSER_ROLE` – can pause token level operations (minting) for emergency.
* EIP-2612 Permit support (see `PermitFuzz` test & invariants for assurance).

### ZPXV2 (Bridge Extension)
* Adds cross‑chain aware mint/burn entry points for canonical ↔ remote supply movement.
* Bridge agent receives `BRIDGE_ROLE` and records pending burns in `SupplyRegistry`.
* Upgrade path preserves storage layout of V1 (see comments in contract for gap usage).

### SupplyRegistry
Tracks canonical & remote recognized supply plus in‑flight bridge amounts.
* `nativeCirculating` – net canonical minted (minus reconciled burns).
* `remoteRecognized` – emissions executed on remote chains and later acknowledged.
* `vestingLocked` – retained for external reporting only (vesting contract removed).
* `bridgePending` – amount burned locally, awaiting remote mint settlement.
* Access controlled by `RECORDER_ROLE` (granted to EmissionsManager, bridge agent, governance automation bot(s)).

### EmissionsManager
* Epoch based budgeting: non‑overlapping epochs with start/end timestamps & budgets.
* Supports: single recipient emission, batch emission, distributor funding.
* Records every native mint via `SupplyRegistry.recordNativeMint` for transparent accounting.
* Roles:
	* `SCHEDULER_ROLE` – schedule / increase / finalize epochs.
	* `EMITTER_ROLE` – perform emissions within active epoch budget.
	* `PAUSER_ROLE` – emergency halt of emission functions (does not touch registry).

### RewardsDistributor
* Cumulative Merkle root model: each root encodes total claimable so far per address.
* Users claim deltas (newCum - previouslyClaimed).
* Root publication gated by `ROOT_SETTER_ROLE`; recovery (skim) by `RECOVER_ROLE`.
* Custom lightweight nonReentrant guard.

## Removed Vesting Module
`TokenVesting.sol` and related ignition & tests were removed to reduce audit surface. The `vestingLocked` field in `SupplyRegistry` remains for off‑chain curated reporting (e.g., if vesting schedules managed by a separate, audited system or multisig snapshots). No on‑chain enforcement currently ties to this value.

## Upgrade Path & Forward Plan
1. Current live implementation: ZPXV1 proxy with potential upgrade to ZPXV2 for bridge features.
2. Planned migration: adopt an OP Stack / Superchain standard ("SuperchainERC20") once finalized:
	 * Expect interface additions (e.g., `l2BridgeMint`, `l2BridgeBurn` semantics) and potential event name normalization.
	 * Storage: ensure sufficient `__gap` slots retained; review any new state required before upgrade.
3. EmissionsManager and RewardsDistributor are upgradeable themselves (UUPS). Governance should time‑lock upgrades and potentially introduce an on‑chain guardian review step.

## Security Considerations
* Role separation: scheduling vs emitting prevents accidental large mint execution if emitter compromised before epoch start.
* Budget enforcement: cannot exceed epoch budget; early finalize halts remaining allowance.
* Distribution: cumulative Merkle prevents claim malleability and simplifies double‑claim prevention.
* Supply accounting: every manager/distributor mint updates `SupplyRegistry` ensuring external observers can reconstruct circulating supply deterministically from emitted events.
* Invariants: Foundry invariant tests cover cap adherence & balance non‑overflow under fuzzed mint/burn actions.

## Testing Overview
* Unit tests target each contract's role & error paths.
* Fuzz tests for permit logic & invariants for supply cap.
* Emissions tests validate epoch lifecycle and registry integration.
* Planned additions: bridge pause/unauthorized, batch emission & distributor funding coverage, reentrancy simulation for `RewardsDistributor`.

## Gaps / TODO
* Expand coverage on batch emissions & distributor skim edge cases.
* Document Superchain migration steps in `DEPLOYMENT.md` once standard final.
* Introduce formal verification targets (budget monotonicity, non‑overlap) if required pre‑audit.

