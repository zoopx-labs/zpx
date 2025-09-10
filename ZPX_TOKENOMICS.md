🪙 ZPX Tokenomics & Emissions
=============================

Token Details
-------------

| Field                 | Value                                                                 |
|----------------------:|:----------------------------------------------------------------------|
| Name / Symbol         | ZoopX (ZPX)                                                           |
| Decimals              | 18                                                                    |
| Total Supply          | 100,000,000 ZPX (fixed cap)                                           |
| Chain at TGE          | Base (OP Stack L2)                                                    |
| Standard at TGE       | ERC-20 (upgradeable proxy via UUPSUpgradeable)                        |
| Upgrade Intent        | In-place upgrade to SuperchainERC20 (ERC-7802) when interop is live   |
| Minting Model         | Mint-on-launch → vesting contracts + emissions manager (no inflation beyond 100M) |
| Permit Support        | EIP-2612 (gasless approvals for CEX/DEX/MM)                           |
| AccessControl Roles   | DEFAULT_ADMIN_ROLE → timelocked multisig; MINTER_ROLE → EmissionsManager, future Vaults; PAUSER_ROLE (optional) → ops multisig |
| Vesting Contracts     | Bucket-based escrows (cliff + linear)                                 |
| Governance Transfer   | Treasury moves to DAO timelock after 6 months                         |

Allocation
----------

| Category              | %   | Tokens       | Vesting / Notes                                         |
|:----------------------|:----|-------------:|:-------------------------------------------------------|
| Staking / Rewards     | 50%  | 50,000,000   | 60m emissions, front-loaded first 6–12m, then decays   |
| Pre-IEO + IEO         | 15%  | 15,000,000   | Pre-IEO: 6m cliff + 18m linear; IEO: 20% TGE + 5-day linear |
| MM & Liquidity Ops    | 5%   | 5,000,000    | Market making & CEX/DEX liquidity                       |
| Team & Advisory       | 15%  | 15,000,000   | 24m cliff + 36m linear                                 |
| Treasury              | 5%   | 5,000,000    | 6m cliff → DAO-governed treasury                       |
| Marketing & Ops       | 5%   | 5,000,000    | 3m cliff + 36m linear                                  |
| Ecosystem / Reserve   | 5%   | 5,000,000    | Partnerships, listings, emergencies (timelocked)        |
| **Total**             | 100% |100,000,000   |                                                        |

Emission Schedule (Staking / Rewards — 50M ZPX over 5 years)
----------------------------------------------------------------

Rewards are distributed in 10 epochs (6 months each) with a 20% decay per epoch.
This ensures high APY early on, tapering as protocol matures.

| Epoch | Months | Emission (ZPX) | Cumulative      |
|:-----:|:------:|---------------:|----------------:|
| 1     | 0–6    | 11,200,000     | 11,200,000      |
| 2     | 6–12   | 8,960,000      | 20,160,000      |
| 3     | 12–18  | 7,168,000      | 27,328,000      |
| 4     | 18–24  | 5,734,400      | 33,062,400      |
| 5     | 24–30  | 4,587,500      | 37,649,900      |
| 6     | 30–36  | 3,670,000      | 41,319,900      |
| 7     | 36–42  | 2,936,000      | 44,255,900      |
| 8     | 42–48  | 2,349,000      | 46,604,900      |
| 9     | 48–54  | 1,879,000      | 48,483,900      |
| 10    | 54–60  | 1,503,000      | 49,986,900      |

➡️ ~50,000,000 ZPX distributed over 5 years.

Upgrade Path: Base ERC-20 → SuperchainERC20
-----------------------------------------

What is SuperchainERC20?

A new OP-Stack token standard (ERC-7802) enabling canonical, wrap-free cross-chain “teleportation” via the SuperchainTokenBridge.

Plan (High Level)
------------------

- Today (TGE): Deploy ZPXV1 on Base as ERC-20 (UUPS proxy).
- Future: Upgrade proxy to ZPXV2 implementing SuperchainERC20 / IERC7802.
- Grant the SuperchainTokenBridge predeploy mint/burn rights.
- Opt-in via OP docs, preserving proxy storage layout so the token address remains the same.

Dev Checklist
-------------

ZPXV1 (now):

- ERC20Upgradeable + ERC20PermitUpgradeable + AccessControlUpgradeable + UUPSUpgradeable
- Hard cap enforcement, MINTER_ROLE, __gap[50] for future storage.

ZPXV2 (future):

- Same inheritance order, add SuperchainERC20 interface (IERC7802)
- Functions: crosschainMint, crosschainBurn (restricted to bridge)
- Events: CrosschainMint, CrosschainBurn
- One-time initializer upgradeToSuperchainERC20(address bridge)

Governance
----------

- ProxyAdmin + Timelock (48–72h delay).
- Testing: Stage on Base Sepolia + Interop devnets before mainnet.

