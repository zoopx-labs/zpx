# Superchain / Future ERC-20 Standard Upgrade Plan

This document describes the forward-looking plan to migrate the ZPX token (currently `ZPXV1` / optionally `ZPXV2`) to a future Superchain / Optimism ecosystem standard token implementation (referred to here as `SuperchainERC20`). It focuses on: storage layout safety, role / permission alignment, bridging semantics, deployment choreography, and risk mitigation.

> NOTE: The exact canonical specification (event names / hook signatures) may still evolve. Treat this as a living runbook to be amended once the standard is finalized.

---
## 1. Current State Summary

Contract | Proxy? | Upgradeable? | Key Storage (ordered)
---------|--------|--------------|-----------------------
`ZPXV1`  | Yes    | UUPS         | (1) OZ slots (ERC20 name/symbol/etc.), (2) AccessControl role admin mapping, (3) Pausable state, (4) TOTAL_SUPPLY via ERC20 storage, (5) custom: none, (6) `__gap[50]`.
`ZPXV2`  | Yes    | UUPS         | Inherits V1 storage exactly; adds: (a) `BRIDGE_ROLE` constant (no storage), (b) `_bridge` (address), (c) events, (d) `__gapV2[49]`.

Other upgradeable components (EmissionsManager, SupplyRegistry, RewardsDistributor) are orthogonal to the token’s storage and only rely on the public minting / role APIs.

### Storage Layout Invariants
* V2 appended `_bridge` before introducing a new gap array, preserving all existing slot indices from V1.
* Custom errors and events DO NOT introduce storage.
* No in-line struct or mapping re-ordering has occurred since initial deployment.

To re-validate before any future upgrade:
```
forge inspect contracts/ZPXV1.sol:ZPXV1 storage-layout > layout_v1.json
forge inspect contracts/ZPXV2.sol:ZPXV2 storage-layout > layout_v2.json
# (future) forge inspect contracts/ZPXSuperchain.sol:ZPXSuperchain storage-layout > layout_future.json
```
Diff `layout_v2.json` vs `layout_future.json` and ensure all existing slot / offset pairs are identical for inherited vars.

---
## 2. Anticipated Superchain Additions

Probable additions (based on emerging OP Stack token patterns):
1. Bridge hook normalization (e.g. `bridgeMint(address to, uint256 amount, bytes calldata data)` / `bridgeBurn(address from, uint256 amount, bytes calldata data)`).
2. Standardized events (e.g. `event BridgeMint(address indexed to, uint256 amount);`).
3. Optional metadata or L2 origin tracking (e.g. chainId stamping or message hash caching).
4. Fee / burn accounting hooks (if ecosystem introduces global fee capture at token layer).

### Storage Impact Planning
Reserve additional space BEFORE final spec if necessary. Current gaps:
* `ZPXV1` left `__gap[50]`
* `ZPXV2` consumed 1 slot (`_bridge`) and replaced gap with `__gapV2[49]`.

If future spec requires N new storage slots, ensure `N <= 49`. If larger, create an intermediate upgrade whose sole purpose is to inject another gap expansion (still safe because only appending) BEFORE adding logic.

---
## 3. Migration Path Scenarios

### Scenario A: Upgrading Directly From V1 → SuperchainERC20
1. (If still on V1) Author new implementation `ZPXSuperchain` inheriting from `ZPXV1` (NOT `ZPXV2`) and append required storage.
2. Include compatibility shims for prior `crosschainMint/crosschainBurn` if ecosystems used them off-chain (or emit deprecated events for one release cycle).
3. Execute `upgradeTo` via governance timelock.
4. (Optional) Call a one-time reinitializer to set bridge system contracts.

### Scenario B: Already Upgraded V1 → V2, Then V2 → SuperchainERC20
1. Author `ZPXSuperchain` inheriting from `ZPXV2` to retain `_bridge` usage or migrate semantics.
2. If the new standard renames events, keep old events for one epoch (dual emission) OR emit only new ones and update indexers simultaneously.
3. Execute `upgradeTo` (or `upgradeToAndCall`) to run the new initializer that sets any additional configuration.
4. Revoke deprecated roles (`BRIDGE_ROLE`) if replaced by system predeploy address checks.

---
## 4. Role / Permission Alignment

Current Roles:
* `DEFAULT_ADMIN_ROLE` – governance timelock.
* `MINTER_ROLE` – EmissionsManager, bridge agent.
* `PAUSER_ROLE` – security council.
* `BRIDGE_ROLE` (V2 only) – OP Stack bridge contract.

Future Standard Adjustments:
* MAY remove explicit `BRIDGE_ROLE` and instead hardcode recognized bridge system address(es).
* Preserve `MINTER_ROLE` for emissions logic unless Superchain spec mandates specialized mint gating.
* Governance should review and revoke obsolete roles post-upgrade.

---
## 5. Upgrade Execution Checklist

Pre-Upgrade:
1. Freeze non-critical emissions (optional) and snapshot totalSupply & registry metrics.
2. Run storage layout diff (see commands above).
3. Dry-run `forge script` upgrade on a fork with the exact calldata (record transaction traces).
4. Run invariant & fuzz suites against the forked, upgraded state (simulate upgrade inside test harness). 

Execution (Timelocked):
1. Queue `upgradeTo` (or `upgradeToAndCall`) to new implementation.
2. After delay, execute transaction.
3. (If needed) Call reinitializer to set new bridge/system addresses.
4. Emit an on-chain event or post verification commit with the final implementation bytecode hash.

Post-Upgrade Validation:
1. Confirm `implementation()` address changed (EIP-1967 slot read).
2. Verify `totalSupply` unchanged and random holder balances invariant.
3. Exercise new bridge mint/burn on a test path with small amount.
4. Re-run partial test subset (emissions + bridge) against live state (fork tests).

Rollback Considerations:
* If a critical issue is found immediately post-upgrade, governance can upgrade again to a minimal emergency implementation that blocks new minting but preserves balances.

---
## 6. Risk Register

Risk | Mitigation
-----|-----------
Storage collision | Automated `forge inspect` diff + peer review.
Role misconfiguration | Post-upgrade script asserts expected role memberships & reverts if mismatch.
Paused state inconsistency | Pre-upgrade script records `paused()`; reinitializer logic refrains from unpausing.
Event schema change breaks indexers | Deploy dual-event emission for one release OR provide migration notice & off-chain mapping.
Bridge address drift (L2 network upgrade) | Abstract bridge access behind a function that can be upgraded vs direct role if spec unstable.

---
## 7. Operational Scripts (Outline)

Expected new script (pseudo-code) once spec final:
```solidity
function run() external broadcast timelock {
    address proxy = 0x...; // ZPX proxy
    address impl  = deploy("ZPXSuperchain");
    bytes memory data = abi.encodeCall(ZPXSuperchain.upgradeToSuperchainStandard, (bridgePredeploy, extraConfig));
    UUPSLike(proxy).upgradeToAndCall(impl, data);
}
```
Include assertions post-call:
* `IERC20(proxy).totalSupply()` unchanged.
* `ZPXSuperchain(proxy).superchainBridge() == bridgePredeploy`.

---
## 8. Observability & Monitoring

Add new Grafana / Dune dashboard panels:
* Implementation address (EIP-1967) trend.
* Bridge mint / burn totals per day.
* Emissions vs budget after upgrade (should remain unaffected).

---
## 9. Timeline (Tentative)

Phase | Duration | Exit Criteria
------|----------|--------------
Spec finalization | External | Formal interface published.
Implementation draft | 1 week | Internal review + storage diff passes.
Audit delta | 1–2 weeks | External auditor sign-off on diff scope.
Governance proposal | 3–5 days | Community review window.
Upgrade execution | 1 day | On-chain tx confirmed.
Monitoring & bake-in | 1–2 weeks | No anomalies detected.

---
## 10. Appendix: Quick Storage Snapshot (Current)

Slot ordering (abridged – rely on `forge inspect` for authoritative detail):
1. ERC20Upgradeable: `_balances` (mapping), `_allowances`, `_totalSupply`, `_name`, `_symbol`.
2. AccessControl: `_roles` mapping.
3. Pausable: `_paused` bool.
4. (ZPX custom) constants (compile-time, no storage).
5. V1 gap: `__gap[50]`.
6. V2 addition: `_bridge` (slot after prior gap start) + `__gapV2[49]`.

This leaves ample contiguous gap slots for future state.

---
## 11. Action Items Before Finalizing This Doc

- [ ] Replace this placeholder with final interface names once OP / Superchain standard ratified.
- [ ] Add concrete fork test script identifiers.
- [ ] Attach storage diff artifacts (`layout_v2.json`, `layout_superchain.json`).

---
Maintainers should treat this document as the canonical runbook for future token standard migrations.
