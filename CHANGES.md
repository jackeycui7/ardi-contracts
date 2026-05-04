# contracts-v2 — changes vs ardi-skill/contracts

This is the v2 contract baseline. Forked from `ardi-skill/contracts @ 07279bf`.

Two structural fixes target MEV / griefing surfaces identified in design review.
Engine, vault, settlement, and OTC contracts are unchanged.

---

## 1. ArdiEpochDraw — MEV-1: bound the publishAnswer window

### Problem (v1)

`publishAnswer` accepted any `block.timestamp` in
`[commitDeadline, revealDeadline - MIN_REVEAL_AFTER_PUBLISH]`. With
default `revealWindow = 60s` and `MIN_REVEAL_AFTER_PUBLISH = 30s`, the
Coordinator had a ~30-second window to choose the publish ordering of
the ~15 wordIds in an epoch.

A colluding (Coordinator, bot) pair could:
1. Identify which wordIds the bot has committed.
2. Publish those wordIds **last**, leaving competitors only ~31s to
   construct, sign, send, and confirm a reveal tx.
3. The bot, primed and ready, lands its reveal first; competitors
   stuck behind RPC backpressure miss the window and don't enter the
   correct-set, raising the bot's VRF win probability.

The exploit doesn't require a malicious Coordinator — even an honest
operator that prefers low gas may publish out-of-order in ways that
incidentally favor specific wordIds.

### Fix

Added `MAX_PUBLISH_DELAY = 30 seconds` and a hard upper bound:

```solidity
if (block.timestamp > cfg.commitDeadline + MAX_PUBLISH_DELAY) {
    revert PublishWindowClosed();
}
```

The publish window collapses to `[commitDeadline, commitDeadline + 30s]`.
Combined with `MIN_REVEAL_AFTER_PUBLISH = 30s`, every wordId in an epoch
gets reveal time of at least `revealWindow - MAX_PUBLISH_DELAY = 30s`,
and the coordinator has no meaningful ordering discretion.

### Operational impact

- The Coordinator MUST publish all 15 wordIds within 30s of commit
  close. With current `gas_default = 350_000` per `publishAnswer` and
  Base Sepolia ~2s blocks, this is comfortably achievable when txs are
  pipelined (concurrent signing, sequential nonce, no per-tx receipt
  wait).
- If the Coordinator misses the window for a wordId, that wordId
  becomes "unpublished" — `forfeitBond` refunds committers; no win is
  possible. This is a self-correcting failure mode.
- The Rust coord (coord-rs) implements pipelined publishAnswer to make
  hitting this window a non-event; the Python coord must be tuned.

### New error

`error PublishWindowClosed();`

---

## 2. ArdiNFT — per-holder fusion nonce

### Problem (v1)

`uint256 public fusionNonce` was a single global counter. Every
successful `fuse()` bumped it. Coordinator-signed `FuseAuth`
authorizations bind to the current nonce. So **any successful fuse
anywhere in the system invalidates every other holder's pending
unsubmitted authorization**.

UX hazard: a holder runs `forge_sign`, gets a signature, but before
their `fuse()` tx lands, another holder's `fuse()` lands first; the
first holder's signature is now invalid and they must re-call
`forge_sign` (re-running the LLM oracle, paying the latency).

Grief vector: a malicious actor can `fuse()` cheap pairs in a loop to
bump the nonce, invalidating a target user's signature repeatedly.
Cost to attacker is gas + cheap NFTs; cost to victim is delayed UX
plus potential cache misses on Coordinator side.

### Fix

```solidity
mapping(address => uint256) public fusionNonceOf;
```

Each holder has their own counter. The signed digest now binds the
holder explicitly:

```
keccak256("ARDI_FUSE_V3" ‖ chainId ‖ contract ‖ holder ‖
          tokenIdA ‖ tokenIdB ‖ newWord ‖ newPower ‖ newLangId ‖
          success ‖ holderNonce)
```

Two unrelated holders' fuses never affect each other's nonces.

### Compatibility

Bumped digest version `ARDI_FUSE_V2 → ARDI_FUSE_V3`. v2 signatures will
not verify under v3 contracts. The Coordinator (forge.sign) MUST be
updated to read `fusionNonceOf(holder)` instead of `fusionNonce()` and
sign under the V3 layout.

`ICoordinator.FuseAuth` updated; `holder` field added, `fusionNonce`
renamed to `holderNonce`.

### Tests

`ArdiNFT.t.sol::test_fuse_nonceIncrementsBlocksReplay` updated to use
`fusionNonceOf(agent)`.

---

## 3. Out of scope for this v2

These were discussed but deferred:

- **Fusion success bit via on-chain VRF** — would remove the last
  Coordinator-controlled randomness. Requires a second VRF subscription
  and changes to the fuse flow (sign LLM eval; success decided on-chain
  during fuse() via a follow-up VRF callback). Significant change;
  defer to v3.
- **`requestDraw` keeper incentive** — small bounty from forfeited
  bonds for non-Coordinator callers. Defer; the Rust coord handles draw
  triggering reliably enough for now.
- **Atomic block-pinned daily snapshot** — primarily an off-chain
  (Rust indexer + settlement) change; no contract change needed beyond
  optionally accepting `snapshotBlock` in `settleDay` for verifiability.
  Coordinated with coord-rs work.
- **`cancelStuckEpoch`** — operator can recover via manual ops;
  contract change unnecessary.

---

## 4. Deploy

Same scripts as v1 (`script/Deploy*.s.sol`). The v2 changes are
ABI-compatible aside from the renamed `fusionNonce` getter and the
bumped digest version. Off-chain code (the Rust coord and any client
SDKs) must update to:

1. Read `fusionNonceOf(holder)` instead of `fusionNonce()`.
2. Sign with `"ARDI_FUSE_V3"` and include `holder` in the digest.
3. Pipeline `publishAnswer` calls within 30s of commit close.

A redeployed v2 produces a new Merkle root environment; existing v1
state does not migrate.
