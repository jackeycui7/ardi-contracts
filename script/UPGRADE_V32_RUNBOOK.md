# v3 → v3.2 Upgrade Runbook (Base mainnet)

Generated 2026-05-04, post-fork-dryrun.

## Pre-flight checklist

- [ ] ke confirms MERKLE_ROLE granted to `0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65`
- [ ] Owner key `0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43` available on the
      machine you're running scripts from (export `DEPLOYER_PK`)
- [ ] Owner key has ≥0.05 ETH on Base mainnet (gas budget for 18 tx total)
- [ ] `/tmp/migrate_batches/batch_*.csv` exists (run `python3 /tmp/gen_migrate_batches.py`)
- [ ] `forge build` succeeds in `/root/awp_code/ardi/contracts-v2/`

## Environment

```bash
cd /root/awp_code/ardi/contracts-v2
export RPC_URL="https://mainnet.base.org"  # or QuickNode for reliability
export DEPLOYER_PK="0x..."                  # owner key
export NFT_PROXY="0xf68425D0d451699d0d766150634E436Acd2F05A1"
export DIST_PROXY="0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65"
export WORKNET_MANAGER="0x22cB0f31FCa7d43B42f4eA4bDf9D0d0CFC69E03b"
```

## Phase 1 — Deploy v32 implementations (safe, idempotent)

Deploys two impls. NO proxy upgrade. Mainnet behavior unchanged.

```bash
forge script script/UpgradeV32Phase1.s.sol \
  --rpc-url $RPC_URL --broadcast -vv
```

Output prints two addresses. Save them:

```bash
export NFT_V32_IMPL=0x...  # ArdiNFTv32 impl
export ED_V32_IMPL=0x...   # EmissionDistributorV2 impl
```

## Phase 2a — Pause + upgrade + wire (atomic, 7 tx in one broadcast)

This is the high-stakes step. After this runs, `effectiveDurability`
reads 0 for all NFTs until Phase 2b completes.

```bash
forge script script/UpgradeV32Phase2.s.sol \
  --rpc-url $RPC_URL --broadcast -vv
```

Verify after:

```bash
cast call $DIST_PROXY "paused()(bool)"            --rpc-url $RPC_URL  # → true
cast call $DIST_PROXY "ardiNFTv32()(address)"     --rpc-url $RPC_URL  # → $NFT_PROXY
cast call $DIST_PROXY "rewardMinter()(address)"   --rpc-url $RPC_URL  # → $WORKNET_MANAGER
cast call $DIST_PROXY "maxMintPerClaim()(uint256)" --rpc-url $RPC_URL # → 75e24
cast call $DIST_PROXY "maxNotifyAmount()(uint256)" --rpc-url $RPC_URL # → 36e24
```

## Phase 2b — Migrate all active tokenIds (14 tx, ~10 min)

Runs migrateExisting for each batch CSV in `/tmp/migrate_batches/`.

```bash
for f in /tmp/migrate_batches/batch_*.csv; do
  echo "Migrating $f..."
  export MIGRATE_TIDS="$(cat $f)"
  forge script script/UpgradeV32Phase2Migrate.s.sol \
    --rpc-url $RPC_URL --broadcast -vv
done
```

Verify the last batch's first tokenId post-migrate:

```bash
TID=$(head -c -1 /tmp/migrate_batches/batch_13.csv | cut -d, -f1)
cast call $NFT_PROXY "v32Migrated(uint256)(bool)" $TID --rpc-url $RPC_URL  # → true
cast call $NFT_PROXY "expirationRoundOf(uint256)(uint64)" $TID --rpc-url $RPC_URL  # → > 0
```

## Phase 2c — Unpause (1 tx)

After all migrations confirm:

```bash
cast send $DIST_PROXY "unpause()" \
  --private-key $DEPLOYER_PK --rpc-url $RPC_URL
```

Verify:

```bash
cast call $DIST_PROXY "paused()(bool)" --rpc-url $RPC_URL  # → false
```

## Phase 3 — First notifyReward (12:00 UTC, separate session)

Pre-condition: ke has confirmed MERKLE_ROLE granted.

Verify on chain:

```bash
ROLE=$(cast call $WORKNET_MANAGER "MERKLE_ROLE()(bytes32)" --rpc-url $RPC_URL)
cast call $WORKNET_MANAGER "hasRole(bytes32,address)(bool)" \
  $ROLE $DIST_PROXY --rpc-url $RPC_URL  # MUST be true
```

Then operator runs:

```bash
cast send $DIST_PROXY "notifyReward(uint256)" \
  24000000000000000000000000 \
  --private-key $DEPLOYER_PK --rpc-url $RPC_URL
```

This is the moment the first day's emissions go live. After this,
holders can `claim`.

## Rollback / aborted phases

- After Phase 1 only: nothing to undo (impls just sit there).
- After Phase 2a but before 2b: the system works but `effectiveDurability`
  reads 0 for everyone. Resume by running 2b. If you need to abort,
  there is no clean rollback to v3 (UUPS forwards the upgrade); the
  mitigation is to run migrateExisting and unpause, leaving the system
  v32 with all NFTs alive — equivalent to a successful upgrade.
- After Phase 2b/2c but before notifyReward: state is fine, just don't
  call notifyReward until ke's role grant is confirmed.
- After notifyReward: cannot un-distribute; if amount was wrong, owner
  can `adminRewindDecayRound(1)` immediately (CAVEAT: see V32_CHANGES.md
  M-3, owner must also re-activate any bump-evicted NFTs).

## Total cost estimate (Base, ~0.1 gwei)

| Phase | tx | Total gas | Cost @ 0.1 gwei |
|---|---|---|---|
| 1 (deploy 2 impls) | 1 | ~9M | <$0.01 |
| 2a (pause + 2× upgrade + wire) | 1 | ~1M | <$0.01 |
| 2b (14× migrateExisting) | 14 | ~125M | ~$0.10 |
| 2c (unpause) | 1 | ~30K | <$0.01 |
| 3 (first notify) | 1 | ~200K | <$0.01 |
| **Total** | **18** | **~135M** | **~$0.15** |
