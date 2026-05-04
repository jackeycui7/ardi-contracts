# Ardi v3.1 — Agent Validation Guide (Stage 1)

For internal testers participating in the Stage 1 mainnet validation.
Each session: ~30 min, ~$1 USD ETH burned per agent.

---

## 0. Prerequisites

- Linux or macOS dev box
- Rust toolchain (`rustup default stable`)
- `cast` from foundry (`curl -L https://foundry.paradigm.xyz | bash; foundryup`)
- A fresh wallet for testing (NOT your main wallet) with:
  - **Base mainnet ETH**: 0.005 ETH (~$2). Bridge from L1 if needed:
    https://bridge.base.org
  - **AWP allocation in ARDI worknet (id 845300000014)** — talk to ops to
    get sponsored stake, OR self-stake ≥ 10,000 AWP via the AWP UI

---

## 1. Install the skill

```bash
git clone https://github.com/jackeycui7/ardi-skill.git
cd ardi-skill
cargo build --release --bin ardi-agent
export PATH="$PWD/target/release:$PATH"

# Sanity check
ardi-agent --help
```

---

## 2. Configure for mainnet

Create `~/.ardi-agent/config.toml`:

```toml
# Test wallet (NOT your main wallet)
agent_pk = "0x_your_test_wallet_private_key"

# Base mainnet
rpc_url = "https://mainnet.base.org"
chain_id = 8453

# Mainnet contracts (operator will share these in the test channel)
epoch_draw    = "0x__FILL_FROM_OPS__"
ardi_nft      = "0x__FILL_FROM_OPS__"
awp_allocator = "0x0000D6BB5e040E35081b3AaF59DD71b21C9800AA"

# Worknet IDs (do NOT change)
ardi_worknet_id = 845300000014  # ARDI
kya_worknet_id  = 845300000012  # KYA delegation

# AWP rootnet RPC (used to discover your stakers)
awp_rpc_url = "https://api.awp.sh/v2"
```

---

## 3. Verify your stake is visible

```bash
ardi-agent stake
```

Expected output:

```
Agent address: 0x...
ARDI worknet (845300000014): 10000 AWP from 0x... (self)
KYA  worknet (845300000012): 5000 AWP from 0xSPONSOR (delegated)
Total stake: 15000 AWP
Eligible (>= 10000 minStake): YES
```

If stake = 0 → talk to ops about getting allocation. Cannot proceed
otherwise (commit will revert with InsufficientStake).

---

## 4. Pick an epoch + word

Operator will announce in the test channel:

```
Epoch 1 is open.
Riddle for wordId 0: "Digital gold forged in computational fire..."
Riddle for wordId 1: "A world computer that never sleeps..."
...
Commit closes at: 18:00 UTC
Reveal closes at: 18:05 UTC
```

The riddle hints at an answer. Pick one and try to solve it.

---

## 5. Commit your guess

```bash
ardi-agent commit \
  --epoch 1 \
  --word-id 0 \
  --answer "bitcoin"
```

What this does internally:

1. Calls AWP RPC to discover your stakers list (sorted, deduped, ≤8)
2. Computes `keccak256(answer, your_address, random_nonce)` as commit hash
3. Sends `commit(epoch, wordId, hash, [staker1, staker2, ...])` with 0.00001 ETH bond
4. Saves `(answer, nonce)` locally so you can reveal later

Output:

```
✓ commit submitted
  tx: 0x...
  bond: 0.00001 ETH (refunded on reveal)
  saved nonce → ~/.ardi-agent/state/epoch-1-word-0.json
```

---

## 6. Wait for the publishAnswer + reveal window

Operator's coord-rs will publish the canonical answer when commit window
closes. After that, the reveal window opens (5 min in test).

```bash
# Optional: tail the operator's status feed
cast logs --address $EPOCH_DRAW \
  --from-block latest \
  --rpc-url https://mainnet.base.org
# Watch for AnswerPublished events
```

---

## 7. Reveal

```bash
ardi-agent reveal --epoch 1 --word-id 0
```

This reads your saved nonce, sends `reveal(epoch, wordId, answer, nonce)`.

- If answer matches the canonical answer → bond refunded, you're added to
  `correctList[epoch][wordId]`, eligible to win
- If answer wrong → bond stays as forfeit

---

## 8. Wait for the draw

After reveal window closes, anyone can call `requestDraw`. Operator will
do this. VRF callback (~30s) selects a winner.

```bash
# Check if you won
cast call $EPOCH_DRAW "winners(uint256,uint256)(address)" 1 0 \
  --rpc-url https://mainnet.base.org
# If returns YOUR address → 🎉
```

---

## 9. Inscribe your NFT (only if you won)

```bash
ardi-agent inscribe --epoch 1 --word-id 0 --word "bitcoin"
```

What this does:
1. Calls `inscribe(epoch, wordId, "bitcoin")` on ArdiNFT
2. Mints NFT with all properties (power, lang, element, durability) from
   the published answer
3. Sets you as the NFT holder

Output:

```
✓ inscribed
  tokenId: 1
  word: bitcoin
  power: 100
  element: god        ← if word=bitcoin (element=6)
  durability: 9 / 9
  tx: 0x...
```

---

## 10. Validation checklist

Report back to ops if any of these fail:

- [ ] `ardi-agent stake` showed your full stake (across both worknets)
- [ ] Commit succeeded
- [ ] Bond was refunded after reveal
- [ ] If you won, inscribe minted the NFT
- [ ] **If you won a god-tier word (bitcoin/ethereum/satoshi/etc.),
      inscribe still succeeded** — this is the ELEMENT_MAX fix
- [ ] Frontend showed the right element name (especially "god" if you got
      a god-tier NFT)
- [ ] Total ETH burned was within expectations (~$0.50 per cycle)

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `InsufficientStake` | Your stake < minStake (10,000 AWP) | Get allocation, retry |
| `CommitWindowClosed` | Too late to commit | Wait for next epoch |
| `WrongBond` | Sent ≠ 0.00001 ETH | Use the CLI which sets it correctly |
| `AnswerNotPublished` (on reveal) | Operator hasn't published yet | Wait ~30s |
| `InvalidGuess` (on reveal) | Your answer ≠ canonical answer | Bond forfeited; better luck next time |
| `RevealWindowClosed` | Too late to reveal | Bond forfeited |
| `WinnersAlreadyPicked` | Someone else won this word | Try a different wordId next epoch |
| `InvalidElement` (on inscribe) | Should NOT happen in v3.1; report immediately | — |
| MetaMask "transfer error" | Insufficient ETH for gas | Top up your test wallet |

---

## Cleanup (post-test)

If you have leftover test ETH on your test wallet, you can leave it for
the next test session or send it back to the team treasury.
