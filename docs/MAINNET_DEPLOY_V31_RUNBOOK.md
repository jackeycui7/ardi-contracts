# Ardi v3.1 — Base Mainnet Deploy Runbook

**Status**: this runbook covers **Stage 1 (internal validation)** AND
**Stage 2 (public release)**. Stage 1 sections are mandatory; Stage 2
sections are clearly marked and skipped during validation.

**Network**: Base mainnet (chainId 8453).
**Wordbank root**: `0x77b80d7e350c323fb9498e45dcb4b940041587971772ecb58b80d275475840d6`

## Stage 1 vs Stage 2

| | Stage 1 — internal validation (now) | Stage 2 — public release (later) |
|---|---|---|
| Goal | Run the full system on real mainnet, prove UX works with a small group of internal agents | Public launch with marketing |
| Wallet | jackeycui7-controlled EOA OK | Brand-new wallet, never touched stage 1, owner = multisig |
| GitHub | Current `jackeycui7/ardi-protocol` OK | New isolated account + org |
| Frontend | Running, internal URL only | Production domain |
| Skill | Local install for the test group | Official publish flow through AWP |
| Batch open epochs | DON'T run | Run via `BatchOpenEpochs.s.sol` |
| Ownership handoff | Optional | Required (transfer to multisig/timelock) |

For Stage 1 you do steps 0-8. For Stage 2 you redeploy from scratch on
fresh infra and do steps 0-10.

---

## 0. Prerequisites checklist

Before you start, every line must be a YES.

| # | Item | How to verify |
|---|------|---------------|
| 1 | New deployer wallet generated, private key safe | `cast wallet new` or hardware wallet. NEVER reuse the sepolia deployer. |
| 2 | Deployer funded with ≥ 0.1 ETH on Base mainnet | `cast balance $DEPLOYER --rpc-url https://mainnet.base.org` |
| 3 | New owner address (multisig recommended) | post-deploy `transferOwnership` target |
| 4 | New coordinator wallet funded with ≥ 0.05 ETH | runs 24/7 ops |
| 5 | New treasury / operator addresses chosen | passed to deploy script env |
| 6 | Chainlink VRF v2.5 subscription created on Base mainnet | https://vrf.chain.link → Base mainnet → New subscription |
| 7 | VRF subscription funded with ≥ 0.5 LINK or ≥ 0.05 ETH (native) | Same UI, "Add funds" |
| 8 | ARDI worknet 845300000014 active on AWPRegistry | `cast call $AWP_REGISTRY "isWorknetActive(uint256)(bool)" 845300000014 --rpc-url https://mainnet.base.org` → `true` |
| 9 | KYA worknet 845300000012 active | same → `true` |
| 10 | Wordbank file downloaded & root verified | see step 1 below |
| 11 | New GitHub account + org created (for code release) | non-blocking for chain deploy, but needed for skill release |
| 12 | All four mainnet audit fixes merged on `main` | git log: should include commits `acef365` (NFT ELEMENT_MAX) and `e246595` (element binding + gas guard) |

---

## 1. Wordbank: download + encrypt + verify

```bash
# Pull merged v3.1 wordbank
cd /var/lib/ardi
curl -sL -o vault_v3.json https://raw.githubusercontent.com/leslieshen1/ardinals-wordbankv3/main/data/vault_v3.json

# Verify Rust loader reproduces expected root
cd /opt/ardi/coord-rs   # or wherever coord-rs lives on prod
cargo run --release --bin coord -- vault-root /var/lib/ardi/vault_v3.json
# Expected: 0x77b80d7e350c323fb9498e45dcb4b940041587971772ecb58b80d275475840d6
```

If a `coord` `vault-root` subcommand doesn't exist yet, run the equivalent
3-line Python script with the wordbank repo's `tools/vault_merkle_v3.py`.

```bash
# Encrypt for prod
python3 -c "
from sys import argv
import sys, os
sys.path.insert(0, '/opt/ardi-skill/contracts-v2/tools')  # adjust path
# OR use coord-rs's vault encrypt subcommand
"
# Final encrypted file → /var/lib/ardi/vault.enc, chmod 640 root:ardi
```

---

## 2. Fill `/etc/ardi/secrets.env`

Copy `coord-rs/deploy/mainnet-secrets.env.template` to `/etc/ardi/secrets.env`,
then fill EVERY `=` line. Critical:

- `DEPLOYER_PK`, `OWNER_ADDR`, `COORDINATOR_PK`, `COORDINATOR_ADDR`, `TREASURY_ADDR`, `OPERATOR_ADDR`
- `VRF_SUB_ID` (the Chainlink sub created in step 0.6)
- `VAULT_MERKLE_ROOT_V3` already pre-filled to v3.1 root
- `AWP_ALLOCATOR_ADDR` already pre-filled to mainnet allocator

```bash
chmod 640 /etc/ardi/secrets.env
chown root:ardi /etc/ardi/secrets.env
```

---

## 3. Dry-run deploy

```bash
cd /opt/ardi/contracts-v2
source /etc/ardi/secrets.env
forge script script/DeployV3Mainnet.s.sol \
  --rpc-url https://mainnet.base.org
```

**Verify in dry-run output**:
- `chainid: 8453`
- All env addresses non-zero
- Estimated total gas ~5-7M, total cost ~0.005 ETH
- "post-deploy steps" message lists the 5 follow-ups

If output looks wrong, **fix env first**, do not broadcast.

---

## 4. Broadcast deploy

```bash
forge script script/DeployV3Mainnet.s.sol \
  --rpc-url https://mainnet.base.org \
  --broadcast \
  --verify --etherscan-api-key $BASESCAN_API_KEY
```

After completion, `deployments/base-mainnet-v3.json` is written with all
proxy addresses. **Save this file**, commit it to the monorepo.

---

## 5. Post-deploy wiring

```bash
# 1. Add both VRF adapters as Consumers on Chainlink sub (manual UI step)
#    https://vrf.chain.link → your sub → "Add consumer" → paste vrfAdapterEpoch
#    Repeat for vrfAdapterNFT.

# 2. Verify on-chain config
cast call $EPOCH_DRAW "vaultMerkleRoot()(bytes32)" --rpc-url https://mainnet.base.org
# → 0x77b80d7e...

cast call $EPOCH_DRAW "ardiWorknetId()(uint256)" --rpc-url https://mainnet.base.org
# → 845300000014

cast call $EPOCH_DRAW "kyaWorknetId()(uint256)" --rpc-url https://mainnet.base.org
# → 845300000012

cast call $EPOCH_DRAW "minStake()(uint256)" --rpc-url https://mainnet.base.org
# → 10000000000000000000000

cast call $NFT "ELEMENT_MAX()(uint8)" --rpc-url https://mainnet.base.org
# → 6   (god element supported)

cast call $NFT "epochDraw()(address)" --rpc-url https://mainnet.base.org
# → matches $EPOCH_DRAW
```

---

## 6. Bump VRF callback gas (1.5M)

```bash
# v3.1 lottery walk uses ~80K gas per candidate live re-check. Default
# Chainlink callback gas (200K) is too low. Bump to 1.5M on both adapters.
cast send $VRF_ADAPTER_EPOCH "setConfig(uint32)" 1500000 \
  --private-key $DEPLOYER_PK --rpc-url https://mainnet.base.org

cast send $VRF_ADAPTER_NFT "setConfig(uint32)" 1500000 \
  --private-key $DEPLOYER_PK --rpc-url https://mainnet.base.org
```

---

## 7. Coord-rs config

```bash
# Copy template, fill in the 3 deploy-derived fields
cp /opt/ardi/coord-rs/deploy/mainnet.toml.template /etc/ardi/coord.toml

# Edit /etc/ardi/coord.toml:
#   contracts.ardi_nft       = $NFT
#   contracts.epoch_draw     = $EPOCH_DRAW
#   indexer.start_block      = <earliest block from base-mainnet-v3.json deploy>

systemctl restart ardi-coord
journalctl -u ardi-coord -f
# Expected: "vault root verified: 0x77b80d7e..."
#           "subscribed to Allocated events at block X"
```

---

## 8. End-to-end validation (Stage 1 — REQUIRED)

The whole point of Stage 1 is to put 3-5 internal people on real agent
wallets and walk them through commit → reveal → draw → inscribe on real
Base mainnet, end-to-end. ~$0.50/agent/cycle. See companion guide
`AGENT_VALIDATION_GUIDE.md` for the per-agent install + test instructions.

Operator side (you, running coord-rs):

```bash
# 8a. Open a few epochs with comfortable windows (5-min commit, 5-min reveal)
#     so participants have time to react during the test session.
for ID in 1 2 3; do
  cast send $EPOCH_DRAW "openEpoch(uint256,uint64,uint64)" $ID 300 300 \
    --private-key $COORDINATOR_PK --rpc-url https://mainnet.base.org
done

# 8b. coord-rs auto-publishAnswers when commit window closes.
#     Watch:
journalctl -u ardi-coord -f | grep -E "publishAnswers|requestDraw"

# 8c. Optional: manually requestDraw if coord-rs doesn't (it's permissionless)
cast send $EPOCH_DRAW "requestDraw(uint256,uint256)" 1 <wordId> \
  --private-key $COORDINATOR_PK --rpc-url https://mainnet.base.org

# 8d. Verify winner picked
cast call $EPOCH_DRAW "winners(uint256,uint256)(address)" 1 <wordId> \
  --rpc-url https://mainnet.base.org
```

**Validation checklist** (each row should be observed at least once across
the test cycles):

- [ ] Agent's `ardi-agent stake` shows correct delegated stake from AWP RPC
- [ ] Multi-staker commit (agent with KYA delegation) succeeds
- [ ] Self-stake commit succeeds
- [ ] reveal returns the commit bond to the agent
- [ ] requestDraw fires VRF, callback returns within ~30s on Base
- [ ] A winner is picked when there's ≥1 correct revealer
- [ ] Inscribe with a normal element word (e.g. metal) mints an NFT
- [ ] **Inscribe with a god element word (e.g. wordId=0 "bitcoin") mints
      an NFT** — this is the ELEMENT_MAX fix in production
- [ ] Stake withdrawal between commit and draw triggers live re-check
      skip (advanced; optional but valuable)
- [ ] Front-end displays the NFT with correct element name (incl. "god")

If everything in the checklist holds, Stage 1 is complete.

---

## 9. Batch initial mint — STAGE 2 ONLY

See `script/BatchOpenEpochs.s.sol`. Opens N consecutive epochs in one
broadcast for the public launch wave. **Do NOT run during Stage 1
validation** — Stage 1 uses manually-opened individual epochs from step 8a.

---

## 10. Hand off ownership — STAGE 2 ONLY (skip in Stage 1)

```bash
cast send $EPOCH_DRAW "transferOwnership(address)" $TIMELOCK_OR_MULTISIG \
  --private-key $DEPLOYER_PK --rpc-url https://mainnet.base.org
cast send $NFT          "transferOwnership(address)" $TIMELOCK_OR_MULTISIG ...
cast send $EMISSION_DIST "transferOwnership(address)" $TIMELOCK_OR_MULTISIG ...
cast send $VRF_ADAPTER_EPOCH "transferOwnership(address)" $TIMELOCK_OR_MULTISIG ...
cast send $VRF_ADAPTER_NFT   "transferOwnership(address)" $TIMELOCK_OR_MULTISIG ...
```

---

## Rollback / panic plan

If something looks wrong after broadcast but BEFORE any user activity:

```bash
# Pause both contracts immediately
cast send $EPOCH_DRAW "pause()" --private-key $DEPLOYER_PK --rpc-url https://mainnet.base.org
cast send $NFT        "pause()" --private-key $DEPLOYER_PK --rpc-url https://mainnet.base.org
```

Then debug. UUPS upgrade is available via:

```bash
EPOCH_PROXY_ADDR=$EPOCH_DRAW DEPLOYER_PK=$DEPLOYER_PK SKIP_MIGRATE=1 \
  forge script script/UpgradeEpochDrawV31.s.sol \
  --rpc-url https://mainnet.base.org --broadcast
```
