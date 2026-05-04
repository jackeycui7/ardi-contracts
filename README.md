# Ardi Contracts

Production Solidity contracts for the Ardi WorkNet (Base mainnet, chainId 8453).

## Repo layout

```
src/
  v3/                  Currently deployed (production redeploy 2026-05-03)
    ArdiNFTv3.sol           — NFT, durability, repair, fuse, emission tracking
    ArdiEpochDrawV3.sol     — epoch lifecycle, commit/reveal/lottery
    EmissionDistributor.sol — accPerShare $ardi reward distribution
  v32/                 Proposed UUPS upgrade — round-based decay (THIS PR)
    ArdiNFTv32.sol          — round-based dura + repair re-activate fix + admin
    EmissionDistributorV2.sol — round-aware notifyReward + cap snapshots
  ArdiOTC.sol          — peer-to-peer marketplace
  ChainlinkVRFAdapter.sol — VRF wrapper for both NFT + EpochDraw
script/
  Deploy*.s.sol        — initial deployment scripts
  UpgradeV32.s.sol     — proposed v3 → v3.2 upgrade
test/
  v3/, v32/            — invariant + smoke tests
  *                    — adversarial / security / unit
docs/                  — design notes (vault, fees, MEV mitigations)
deployments/           — chain-id keyed address books
```

## Build + test

```bash
forge install                         # pulls openzeppelin + forge-std
forge build
forge test                            # all suites
forge test --match-path "test/v32/*"  # just v3.2 invariants
```

## Live deployment (Base mainnet)

| Contract | Proxy address |
|---|---|
| ArdiNFTv3        | `0xf68425D0d451699d0d766150634E436Acd2F05A1` |
| ArdiEpochDrawV3  | `0xA57d8E6646E063FFd6eae579d4f327b689dA5DC3` |
| EmissionDistributor | `0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65` |
| ArdiOTC          | `0xEd4A2B66756fB3aB0f7a4fC9d442dccF3162B68F` |
| ChainlinkVRFAdapter (epoch) | `0xB628881E2C735ebeE20B51A3098f0Af6d8D012c2` |
| ChainlinkVRFAdapter (nft)   | `0xf5a21CE09daEf088edc60b6511570717640c4036` |

Deployer / Owner: `0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43`
Coordinator EOA:  `0x99AB1D66aF35ea4C16c6407e94D75b2f6a31338e`

## Audit scope (v3.2 PR)

See `V32_CHANGES.md` for the full change set, storage-layout argument,
migration steps, and test invariants. The v3 baseline (already deployed,
audited prior) is included for diff context — the audit ask is the
incremental v3.2 surface.
