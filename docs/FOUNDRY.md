# Foundry Integration

This project now supports Foundry alongside Hardhat.

## Layout
- `foundry.toml` – Foundry config (mirrors Hardhat compiler settings)
- `test-foundry/` – Solidity-based tests
  - `BaseZPXTest.t.sol` – shared deployment & upgrade helpers
  - `ZPXV1.t.sol` – unit tests for core token behavior
  - `ZPXV2Upgrade.t.sol` – upgrade path & bridge hooks
  - `PermitFuzz.t.sol` – fuzzing EIP-2612 permit inputs
  - `Invariants.t.sol` – invariant tests (supply cap, balances)

## Commands
```bash
# Build
forge build

# Run all tests (unit + fuzz seeds)
forge test -vv

# Focus on a single test contract
forge test --match-contract ZPXV2Upgrade -vv

# Run only functions matching pattern
forge test --match-test upgrade -vv

# Fuzzing: (already on by default for test* functions)
forge test --match-contract PermitFuzz -vv

# Invariant testing (StdInvariant)
forge test --match-contract ZPXInvariants -vv

# Coverage
forge coverage

# Gas snapshot
forge snapshot
```

## Fuzzing Notes
- Foundry automatically fuzzes public/external test functions prefixed with `test`.
- Bounds applied via `bound()` to keep values within cap constraints.
- EIP-2612 `permit` digest built manually; using `vm.sign` for private key simulation.

## Invariants
Current invariants:
1. `totalSupply() <= cap`
2. Handler balance never exceeds cap.

Extend by adding more handler methods & invariants (e.g., pause state consistency, role escalation prevention) and calling `targetSelector(FuzzSelector({...}))` for specific distributions.

## Upgrade Flow in Tests
- Deploy V1 implementation
- Deploy proxy with initializer calldata
- Deploy V2, call `upgradeToAndCall` to run `upgradeToSuperchainERC20` in the same transaction

## Formal Verification (Next Steps)
Foundry does not natively include full formal verification (SMT-based) but you can:
- Use Certora / Slither / Echidna pipelines.
- Translate invariants to Echidna config if deeper state space exploration is required.

Suggested add-ons:
- Slither static analysis: `slither . --exclude-informational` (after adding a proper Python environment)
- Echidna: generate wrapper harness from `Handler` to explore additional edge cases.

## Future Enhancements
- Add invariant: Permit nonces monotonically increase (track with a mapping snapshot)
- Add role-based fuzz: random role revocations & grants (maintain admin set snapshot)
- Add bridging invariants once multi-bridge logic added

