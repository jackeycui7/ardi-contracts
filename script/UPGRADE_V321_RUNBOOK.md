# v3.2 → v3.2.1 Upgrade Runbook (Base mainnet)

Generated 2026-05-05, post-fork-dryrun (6/6 passing).

## What's in v3.2.1

Two NFT-side changes, no distributor change:

1. **Dynamic repair pricing** — `repairFee = ratio/10_000 × dailyEmission × power × maxDur / totalActivePower`. Two new owner-tunable params:
   - `_maintenanceRatioBps` (default 5000 = 0.5×)
   - `_dailyEmissionWei` (default 24_000_000e18)
2. **Post-mortem-only repair** — `repair()` reverts `NotYetExpired` unless `effectiveDurability(tokenId) == 0`. No more preemptive top-up.

The v3.2 EmissionDistributor is unchanged; this upgrade touches **only the NFT proxy**.

## Pre-flight checklist

- [ ] Owner key `0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43` available; `DEPLOYER_PK` exported
- [ ] Owner key has ≥0.01 ETH on Base mainnet (single tx)
- [ ] Mainnet currently on v3.2 (`globalDecayRound > 0`, confirms v3.2 went live)
  ```bash
  cast call $NFT_PROXY "globalDecayRound()(uint64)" --rpc-url $RPC_URL  # → ≥1
  ```
- [ ] `forge build` clean in `/root/awp_code/ardi/contracts-v2/`
- [ ] Fork dry-run green:
  ```bash
  forge test --match-path "test/v321/MainnetForkUpgradeV321.t.sol" \
    --fork-url $RPC_URL  # → 6/6 passing
  ```
- [ ] Frontend (`ardinals-demo-next`) deployed with the v3.2.1 NFT_ABI additions (`repairFee`, `repair`) and the `<RepairPanel/>` component live in Vault. Without these the UI can't price or fire repairs.

## Environment

```bash
cd /root/awp_code/ardi/contracts-v2
export RPC_URL="https://mainnet.base.org"   # or QuickNode
export DEPLOYER_PK="0x..."                  # owner key
export ARDI_NFT_ADDR="0xf68425D0d451699d0d766150634E436Acd2F05A1"
# Optional overrides — defaults match the values fork-tested 2026-05-05.
# export MAINTENANCE_RATIO=5000               # bps, 0.5×
# export DAILY_EMISSION_WEI=24000000000000000000000000  # 24M ardi
```

## Phase 1 — Atomic upgrade + configure (1 tx)

This is the **only** on-chain step. The script bundles two operations into a single `upgradeToAndCall`:

1. Swap `ArdiNFT` impl from v3.2 → v3.2.1
2. Run `configureRepair(ratioBps, dailyWei)` via the post-upgrade delegatecall

Atomicity matters: between (1) and (2) the contract is in a "v3.2.1 code, unconfigured params" state where every `repairFee()` call reverts. Bundling removes that window — owner can't forget step (2), and no end-user `repair()` can land in between.

```bash
forge script script/UpgradeV321.s.sol:UpgradeV321 \
  --rpc-url $RPC_URL --broadcast --slow -vvv
```

Output:
```
ArdiNFTv321 impl:        0x<new impl>
Proxy (upgraded):        0xf68425D0d451699d0d766150634E436Acd2F05A1
maintenanceRatioBps:     5000
dailyEmissionWei:        24000000000000000000000000
```

## Verify (cast)

```bash
# 1. Pricing live (must NOT revert; returns wei).
TID=$(cast call $ARDI_NFT_ADDR "ownerOf(uint256)(address)" 4 --rpc-url $RPC_URL >/dev/null && echo 4)
cast call $ARDI_NFT_ADDR "repairFee(uint256)(uint256)" $TID --rpc-url $RPC_URL
# → e.g. 51234884644056966375896  (~51K $ardi for tid 4 at fork-test snapshot)

# 2. Pre-mortem gate live: a still-active NFT can't repair.
cast call $ARDI_NFT_ADDR "effectiveDurability(uint256)(uint8)" $TID --rpc-url $RPC_URL
# If ≥1, repair($TID) MUST revert NotYetExpired. Easy way to confirm:
cast call $ARDI_NFT_ADDR "repair(uint256)" $TID --from $OWNER --rpc-url $RPC_URL
# → execution reverted: NotYetExpired()
```

## Smoke test (frontend)

1. Open `https://ardinals-demo-delta.vercel.app/profile` with a wallet that owns at least one NFT.
2. If no NFT has `effectiveDurability == 0` yet, the Repair Panel renders nothing — that's expected. (At launch this list is empty; the first NFTs hit zero on day-`maxDurability` after their activation round.)
3. To force-test before any organic expiry: deploy a brand-new burner wallet, mint, then wait `maxDurability` rounds, OR use a Tenderly fork to advance state.

## Rollback

UUPS upgrades cannot be cleanly reverted (the impl pointer goes forward only). If v3.2.1 misbehaves:

- **If `repairFee` reverts unexpectedly** — check that `_maintenanceRatioBps` and `_dailyEmissionWei` are set:
  ```bash
  # Use storage slot inspection — the two slots live in the v32 storage gap.
  # Easier path: just re-call configureRepair with correct values.
  cast send $ARDI_NFT_ADDR "configureRepair(uint16,uint256)" 5000 24000000000000000000000000 \
    --private-key $DEPLOYER_PK --rpc-url $RPC_URL
  ```

- **If the repair gate is too aggressive** — owner can re-`upgradeToAndCall` to a new impl that overrides `_beforeRepair` to no-op. There is no kill-switch parameter; recovery requires another upgrade. Have a hot-fix impl ready before launch if you're worried.

- **If pricing is way off** — `configureRepair(0, 0)` does NOT disable; it makes `repairFee()` revert (NotYetExpired branch). To soften pricing, lower `_maintenanceRatioBps` (e.g. `1000` for 0.1×). To raise it, increase up to the 50_000-bps owner cap (5×).

## Total cost estimate (Base, ~0.1 gwei)

| Phase | tx | Total gas | Cost @ 0.1 gwei |
|---|---|---|---|
| 1 (deploy + atomic upgrade + configure) | 1 | ~3M | <$0.01 |
| **Total** | **1** | **~3M** | **<$0.01** |

Single-tx upgrade — much smaller surface than the v3.2 redeploy (which was 18 tx / ~135M gas). No pause needed because v3.2.1 only changes `repair()` semantics; `notifyReward`, `claim`, `inscribe`, and OTC are untouched.
