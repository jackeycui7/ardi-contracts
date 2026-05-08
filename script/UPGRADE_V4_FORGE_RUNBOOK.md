# Mainnet v322 → v4 Forge Upgrade Runbook

**Status**: dry-run target. Do NOT run on mainnet without sky/leslie sign-off + this whole list ticked.

## Architecture

```
Existing (v322):                          After upgrade (v4):
                                          
ArdiNFT proxy                             ArdiNFT proxy (same proxy)
  └─ v322 impl                              └─ v4Mainnet impl  ←── UUPS upgrade
                                              ↓ (admin-call only)
                                            ArdiForgeModule  ──→ ChainlinkVRFAdapter (NEW)
                                              ↓
                                            EmbeddingStore   ── 21K embeddings, sealed
```

The NFT proxy stays at `0xf68425D0d451699d0d766150634E436Acd2F05A1`. All 16K
NFTs' state preserved (verified via `test/v4/MainnetForkUpgrade.t.sol`).

## Pre-flight checks (all must be ✓)

| # | Check | How |
|---|---|---|
| 1 | Storage layout v322 vs v4 compatible | `forge inspect ArdiNFTv322 storageLayout > /tmp/v322.txt && forge inspect ArdiNFTv4Mainnet storageLayout > /tmp/v4.txt && diff` (slots 0-166 must match byte-for-byte) |
| 2 | Mainnet fork test passes | `forge test --match-path test/v4/MainnetForkUpgrade.t.sol -vv` |
| 3 | Module unit tests pass | `forge test --match-path test/v4/ForgeModule.t.sol -vv` (7/7) |
| 4 | v4 + Module byte sizes under EIP-170 | check `out/ArdiNFTv4Mainnet.sol/ArdiNFTv4Mainnet.json deployedBytecode.object` length / 2 |
| 5 | sky + leslie reviewed final tier/mult/fee numbers | manual sign-off |
| 6 | Chainlink VRF subscription created on Base mainnet, funded with ≥ 5 LINK | https://vrf.chain.link |
| 7 | Owner key (`0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43`) accessible + tested with `cast wallet sign` once | confirm signer matches proxy owner |
| 8 | Frontend ardinals-demo-next forge module ready (or kept on testnet path) | up to ops cadence |

## Phase 1: Deploy forge stack (no mainnet impact)

These three contracts are independent — they don't touch the existing NFT proxy.

```bash
cd /root/awp_code/ardi/contracts-v2
PK=$(ssh vm-ardi 'bash -c ". /etc/ardi/mainnet-secrets.env >/dev/null && printf %s \"\$DEPLOYER_PK\""')

# Chainlink VRF v2.5 on Base mainnet — confirmed values 2026-05-08
# Same coordinator + subscription as existing repair / epoch VRF adapters.
# New ForgeVRFAdapter must be ADDED as a consumer to this subscription via
# https://vrf.chain.link/base after deploy.
COORDINATOR=0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
KEYHASH=0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab
SUB_ID=16930718806815128775765336163266985442054823555235005973058454548001250832594

PRIVATE_KEY=$PK \
CHAINLINK_COORDINATOR=$COORDINATOR \
CHAINLINK_KEYHASH=$KEYHASH \
CHAINLINK_SUB_ID=$SUB_ID \
  forge script script/DeployForgeMainnet.s.sol:DeployForgeMainnet \
    --rpc-url https://mainnet.base.org --broadcast
```

Output: addresses of EmbeddingStore, ArdiForgeModule, ForgeVRFAdapter.
**Save these into `deployments/base-mainnet-v3.json`** under new keys
(`embeddingStoreV4`, `forgeModuleV4`, `forgeVrfAdapterV4`).

## Phase 2: Add VRF adapter to Chainlink subscription

Off-chain:
1. Go to https://vrf.chain.link/base
2. Open your subscription
3. "Add consumer" → paste ForgeVRFAdapter address
4. Confirm at least 5 LINK balance

## Phase 3: Upload 21K embeddings + seal

```bash
ts-node embedding-pipeline/upload_embeddings.ts <EmbeddingStore_addr>
# ~50 batches of 500 each, ~50 tx total. ~$2 total at Base gas.

cast send <EmbeddingStore> 'seal()' --private-key $PK --rpc-url https://mainnet.base.org
# After this, store is permanent. Verify storedCount == 21000 first.
```

Pre-seal sanity:
```bash
cast call <EmbeddingStore> 'storedCount()(uint32)' --rpc-url https://mainnet.base.org
# expected: 21000
cast call <EmbeddingStore> 'sealed_()(bool)' --rpc-url https://mainnet.base.org
# expected: false (still open)
```

## Phase 4: Upgrade NFT proxy → v4

⚠️ **FINAL POINT OF NO RETURN** — after this, fuse() reverts permanently
(was never called on mainnet anyway, but make sure no in-flight expectations).

Pre-check `pendingFuseOf` mapping is empty for any active token:
```bash
# Spot-check 5 tokens
for t in 1 1000 5000 10000 16000; do
  echo -n "tid $t pendingFuseOf: "
  cast call <PROXY> 'pendingFuseOf(uint256)(uint256)' $t --rpc-url https://mainnet.base.org
done
# All should print "0"
```

Then deploy + upgrade:
```bash
PRIVATE_KEY=$PK \
PROXY=0xf68425D0d451699d0d766150634E436Acd2F05A1 \
  forge script script/UpgradeNFTToV4.s.sol:UpgradeNFTToV4 \
    --rpc-url https://mainnet.base.org --broadcast
```

Save the new impl address into `deployments/base-mainnet-v3.json` as `ardiNFTv4_impl`.

## Phase 5: Wire ForgeModule into NFT

```bash
cast send <PROXY> 'setForgeModule(address)' <FORGE_MODULE> \
  --private-key $PK --rpc-url https://mainnet.base.org

# Verify
cast call <PROXY> 'forgeModule()(address)' --rpc-url https://mainnet.base.org
cast call <PROXY> 'nextForgedWordId()(uint16)' --rpc-url https://mainnet.base.org  # 21001
```

## Phase 6: Configure ForgeModule

```bash
NFT=0xf68425D0d451699d0d766150634E436Acd2F05A1
ARDI=0xA1008d4F7aA3Aec3C3F529A71dd241Ff9553CAFE
EMBED=<from Phase 1>
RAND=<ForgeVRFAdapter from Phase 1>
EMI=0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65   # EmissionDistributor
ORACLE=0xe573...                                  # forge oracle signer addr
TREASURY=0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43  # owner

cast send <FORGE_MODULE> \
  'setConfig(address,address,address,address,address,address,address,uint16,uint256,uint16)' \
  $NFT $ARDI $EMBED $RAND $EMI $ORACLE $TREASURY \
  7 24000000000000000000000000 10000 \
  --private-key $PK --rpc-url https://mainnet.base.org
```

Params:
- `forgeFeeK = 7` (sky 2026-05-08 拍板)
- `dailyEmissionWei = 24M ether` (current notifyReward amount)
- `forgeBurnBps = 10000` (100% burn)

## Phase 7: Smoke test on mainnet

Pick a wallet you control with 2 NFTs that are FRESH (eff dura ≥ 8 ideally).
Don't use a cherished NFT — you might burn it on T1 tier.

1. Approve aARDI: `cast send $ARDI 'approve(address,uint256)' <FORGE_MODULE> uint256.max`
2. Get oracle to sign forge intent (use ardi-forge-oracle prod instance)
3. Call `module.forge(...)` → wait for VRF callback (~30-60s on Base)
4. Watch ForgeRolled event (success / fail / mult / specials)
5. If success: get oracle to sign newWord + embedding, call `module.completeForge(...)`
6. Verify new NFT minted at id 21001

Expected gas: ~1M for forge() entry, ~150K for VRF callback, ~600K for completeForge.

## Phase 8: Post-launch monitoring

- Bot: add forge-related metrics to `/root/.ardi-alertbot/config.toml`:
  - alerts on stuck forges (rolled but not completed > 2h)
  - oracle signer balance
  - LINK balance on forge VRF subscription
- Frontend: enable forge UI on `ardinals-demo-next` prod (gated rollout)

## Rollback plan (any phase)

Each phase is independent. If trouble:
- Phase 1-3: just don't proceed; deployed contracts are dormant.
- Phase 4: UUPS upgrade back to v322 impl `0x8d044036c45896AAE7e2C879Df38cB61156172B0`. NFT data unaffected by either direction.
- Phase 5-6: `setForgeModule(address(0))` to disable forge entry.

## Cost estimate

| Step | Gas | $ at Base 0.005 gwei + ETH $3K |
|---|---|---|
| EmbeddingStore deploy | ~1.5M | $0.02 |
| ForgeModule deploy | ~3M | $0.05 |
| ForgeVRFAdapter deploy | ~1.5M | $0.02 |
| 21K embeddings upload (50 batches) | ~50M | $0.75 |
| seal() | ~30K | $0.0005 |
| v4 impl deploy | ~5M | $0.075 |
| upgradeToAndCall | ~50K | $0.001 |
| setForgeModule | ~50K | $0.001 |
| setConfig | ~150K | $0.002 |
| **Total** | ~62M gas | **~$0.92** |

Plus LINK funding for Chainlink subscription (~5 LINK = $30).
