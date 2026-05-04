# contracts-v2 — code review

Reviewed against `coord-rs` (Rust coordinator) at the same workspace.
Goal: cross-check that off-chain callers and on-chain logic agree, and
flag any audit-grade concerns before testnet/mainnet deploy. Findings are
labelled by severity:

- **C** Critical (must fix before mainnet)
- **H** High (should fix before mainnet, defence-in-depth)
- **M** Medium (worth fixing in a follow-up PR)
- **L** Low / informational
- **OK** verified correct

Nothing in this review is **C** — the v2 changes are coherent and the
prior v1 review (`SECURITY.md`) was honest about what remained. We add
checks specific to the v2 changes (MEV-1, MEV-2, V3 fuse) and the Rust
coord's contract-call surface.

---

## 1. ArdiEpochDraw

### MEV-1 fix interplay — **OK**

`MAX_PUBLISH_DELAY = 30s` plus `MIN_REVEAL_AFTER_PUBLISH = 30s` plus
default `revealWindow = 60s` means both publish gates fire at exactly
`commitDeadline + 30s`. Either revert is the right answer, so the
overlap is benign. With a 45s revealWindow `PublishTooLate` fires
earlier; with a 90s one `PublishWindowClosed` fires earlier — but the
**collapse of publish ordering discretion is unconditional**, which is
the goal.

### Win-cap overshoot guard — **OK**

`commit()` checks `agentWinCount[msg.sender] >= MAX_WINS_PER_AGENT`,
but only resolved wins count. An agent with two wins in flight could
still commit on a fourth wordId. The defence is at `reveal()`:
`agentWinCount[msg.sender] < MAX_WINS_PER_AGENT` gates pushing into the
candidate list (`correctList`). Bond is still refunded because that's
guarded by `c.revealed`, not by candidate inclusion. The `RevealRejectedAtCap`
event flags it for off-chain bookkeeping. Net effect: agent can grief
themselves (commit + reveal + skipped from VRF) but cannot exceed cap.

### `pendingRequestsCount` book-keeping — **OK**

`requestDraw` only increments after the no-candidates branch returns.
`onRandomness` and `cancelStuckDraw` both decrement. The empty-candidates
path (no increment) cannot reach `cancelStuckDraw` because the path
sets `drawRequestedAt = 0` (the function reverts `DrawNotRequested` when
that's true).

### `setRandomnessSource` swap-with-pending — **OK**

`if (pendingRequestsCount > 0) revert PendingRequestsExist();` correctly
guards. The `cancelStuckDraw` path decrements the count, allowing a swap
after stuck cancellation. Good.

### Bond refund re-entrancy — **OK**

`reveal()` and `forfeitBond()` both transfer ETH via `.call{value: ...}("")`.
Both are `nonReentrant`. State mutation precedes the call (`c.revealed = true`,
`c.bondClaimed = true`). CEI respected.

### Cross-contract drift — **L**

`coordinator` here is the EOA that calls `openEpoch` / `publishAnswer` /
`requestDraw`. In `ArdiMintController` it's the EOA that holds
`MERKLE_ROLE`. There is no on-chain enforcement that they're the same
address; only off-chain config + admin discipline. coord-rs ships a
single `coordinator.private_key` env var assumed to satisfy both. This
is **fine** for testnet; on mainnet, document that "the same EOA must
be coordinator on both contracts, OR each contract's
setCoordinator/setMerkleRole must be invoked separately and tracked".

### `coordinator` single-key risk — **L (deployment)**

A compromised coordinator key can:
- Publish wrong answers (constrained by Merkle proof — must be a real
  vault leaf; cannot fabricate)
- Stall the epoch loop (cannot publish — bonds refundable via
  forfeitBond)
- Bias settlement Merkle (can over-credit themselves up to the
  on-chain `dailyEmission(day)` cap and AWP balance)

Mitigations: Timelock multisig in admin role can rotate via
`setCoordinator` / `_revokeRole(MERKLE_ROLE, ...)`. **Deployment
runbook should require multisig wrapping.**

---

## 2. ArdiNFT

### V3 fuse digest — **OK**

Layout matches `ardi-chain::FuseV3Signer::build_digest` byte-for-byte.
Unit test `fuse_v3_digest_layout` pins this. Per-holder
`fusionNonceOf(holder)` decouples replay risk across holders (closes
v1's grief vector).

### `inscribe` word verification — **OK**

`keccak256(bytes(word)) != wordHash` revert closes the
"winner-submits-arbitrary-metadata" attack. Plaintext only ever lands
on-chain when the winner inscribes; un-won words stay sealed.

### Re-entrancy on `_safeMint` — **OK**

`fuse()` and `inscribe()` use `_safeMint`, which calls
`onERC721Received`. Both functions are `nonReentrant` and have already
set state (incremented `agentMintCount`, set `wordMinted`, etc.) before
the mint, so a re-entrant inscribe / fuse would fail the duplicate
check. CEI respected.

### Generation overflow — **L**

`uint8 generation` can reach 255 only after 255 fusions. Practical floor
of multiplier ~1.31× × power requires ~exponential token consumption
to reach gen 255. Not a real issue.

---

## 3. ArdiMintController

### `settleDay` sequential ordering — **OK**

`if (day > lastSettledDay + 1 && lastSettledDay != 0) revert PrematureSettlement();`
prevents skip-day attacks. The `lastSettledDay != 0` exception lets the
first settlement land at any past day (e.g. day 5 if no one settled
days 1-4); subsequent settlements must be strictly +1 from there. coord-rs
already iterates from `last_settled + 1` to `target_day` so this matches.

### `claim` proof length cap — **OK**

`MAX_PROOF_LEN = 32` allows up to 2^32 leaves — far more than the
holder count we'll ever see. The cap is purely a calldata DoS guard.

### `cumulativeMinted` vs `MAX_SUPPLY` — **OK**

`cumulativeMinted` tracks Merkle-root-allocated $aArdi (potential to
mint via claim). The actual cap is enforced by `ArdiToken._update`:
`totalSupply() + amount > MAX_SUPPLY` revert. Belt-and-suspenders.

### AWP race between settlement read and tx — **L**

coord-rs reads `awpReservedForClaims + ownerAwpReserve + balanceOf` at
block N to compute today's split, then sends `settleDay`. If between
read and tx-land:
- AWP arrives → still passes `awpLockedAfter <= awpAvailable`
- AWP drained by `claim` (only path that lowers controller balance) →
  `awpReservedForClaims` drops too, so `awpLockedAfter` correspondingly
  drops; net difference roughly cancels.
- AWP drained by `withdrawOwnerAwp` → `ownerAwpReserve` drops; same.

Conclusion: the on-chain check is consistent with the off-chain
computation as long as coord-rs reads all three values atomically (it
does — single block-call). No fix needed; documented for clarity.

### Operator share rotation — **OK**

`setOwnerOpsBps` capped at `MAX_OWNER_OPS_BPS = 2000` (20%). Hard cap.
`setOwnerOpsAddr` rotates `OWNER_OPS_ROLE` atomically.

---

## 4. ArdiBondEscrow

### `onMinted` is now a no-op — **OK** (intentional)

v1.0 redirected mint-cap enforcement to `ArdiEpochDraw.agentWinCount`.
The hook is left in place for ABI compatibility but does nothing.
`isMiner` returns active && !slashed only — no win-count gating, since
that would brick a winner who has just earned their 3rd win
(winCount → 3 before they call inscribe). `unlockBond` reads
`agentWinCount` directly. Documented in code, correct logic.

### `slashOnSybil` callable by KYA or owner — **OK**

`if (msg.sender != address(KYA) && msg.sender != owner()) revert NotKYAOrOwner();`
The owner branch is the manual escape hatch; KYA is the automated
trigger. `bps` capped at 10000. Tokens split 50% burn / 50% to
fusionPool. Remainder refunded to agent. CEI: state zeroed before
external calls.

### Self-burn fallback — **OK**

`try IBurnableToken(address(AWP)).burn(toBurn)` falls back to dead-address
transfer if AWP doesn't expose `burn()`. Defensive against AWP rev-up
not exposing burn.

### `setFusionPool` self-pointer guard — **OK**

`if (pool_ == address(this)) revert ZeroAddress();` prevents the C-2
footgun (locking tokens forever).

---

## 5. ArdiOTC

### Stale-listing defence — **OK**

`buy()` re-checks `ARDI_NFT.ownerOf(tokenId) != l.seller` and clears
the listing if seller no longer owns. Excess ETH refund on success.
`nonReentrant`.

### MEV: cancel-front-running — **L** (acceptable)

If a seller realises they listed too cheap and races to call `unlist`,
a buyer's `buy` tx in the mempool can land first. Classic OTC dynamic;
no fix in scope. Sellers should price carefully.

---

## 6. ArdiToken

### Cap enforcement — **OK**

`MAX_SUPPLY = 10B`. `mintLp` is one-shot (`lpMinted` flag). `mint`
gated to `minter`; both check `totalSupply() + amount > MAX_SUPPLY`.
`lockMinter()` is permanent.

### LP one-shot — **OK**

`if (lpMinted) revert LpAlreadyMinted();` set BEFORE `_mint`. Cannot
double-spend.

---

## 7. ChainlinkVRFAdapter

### Inlined Chainlink interfaces — **L**

Avoiding the full `chainlink-contracts` dep. Verify the
`requestRandomWords` selector and `RandomWordsRequest` layout against
the deployed Chainlink VRF Coordinator on Base mainnet at deploy time.
The `EXTRA_ARGS_V1_TAG = 0x92fd1338` and `nativePayment: false` selector
match the v2.5 spec at the time of writing; if Chainlink updates the
selector, tx will revert until the constant is bumped.

### Single-consumer model — **OK**

`if (msg.sender != consumer) revert NotConsumer();` and
`setConsumer(...)` only by owner. Adapter cannot be rugged into routing
randomness elsewhere.

### Subscription drain — **L (operational)**

VRF subscription must stay funded; running dry → all `requestRandomness`
calls revert silently in the consumer. coord-rs has no automatic
funding logic; **monitor LINK/ETH balance via Prometheus alert**.

---

## 8. Cross-stack coherence vs `coord-rs`

### Indexer event coverage — **L**

The Rust indexer subscribes to:
- ArdiNFT: Inscribed, Fused, FusionFailed, Transfer
- ArdiEpochDraw: WordCompromised

Other emitted events (`Committed`, `AnswerPublished`, `Revealed`,
`WinnerSelected`, `BondSlashed`, `MinerRegistered`, `Listed/Sold`,
`Claimed`) are **not** consumed. All purely informational for the
shadow-deploy phase: settlement uses tokens-table aggregates; KYA
bridge polls; agent state reads `mints`. Adding subscriptions for
`MinerRegistered` would tighten the KYA bridge's scan scope (current
implementation polls all token holders; should poll registered miners
only). Not blocking.

### MEV-1 enforcement at off-chain side — **M**

The Rust epoch loop pipelines all `publishAnswer` txs and warns AFTER the
fact if total elapsed > `MAX_PUBLISH_DELAY`. Recommend adding a **pre-
submit time guard**: after pipeline starts, if elapsed > 25s on the
last tx, abort the rest (better to publish 14 of 15 wordIds and have
forfeitBond refund committers on the unpublished one than to send a tx
that will revert `PublishWindowClosed` and leave coord-rs uncertain).

### MEV-2 closure — **OK**

`tokens.last_modified_block` stamping in indexer + `last_modified_block <= snapshot_block`
filter in settlement makes the snapshot deterministic vs a fixed block.
The "approximation" caveat in `snapshot.rs` only fires when a token is
mutated AFTER snapshot_block — those rows are excluded (logged as
warning). The indexer + settlement use the same `head - 5` confirmation
buffer, so the warning should fire only on the rare case of a holder
transferring between snapshot read and settlement.

### V3 fuse signer — **OK**

`ardi-chain::FuseV3Signer::build_digest` produces the exact
`abi.encodePacked` layout that `ArdiNFT.fuse` recomputes:

```
"ARDI_FUSE_V3" ‖ chainId(u256) ‖ contract(20) ‖ holder(20)
                ‖ tokenA(u256) ‖ tokenB(u256) ‖ newWord(utf8)
                ‖ newPower(u16 BE) ‖ newLangId(u8) ‖ success(u8) ‖ holderNonce(u256)
```

Unit test `fuse_v3_digest_layout` pins this. Round-trip test
`fuse_v3_signature_recovers_signer_address` verifies the produced
65-byte (r,s,v=27/28) signature recovers the signer's address through
EIP-191 prefix.

### vault Merkle leaf — **OK**

`ardi-core::vault::vault_leaf` produces:
```
keccak256(abi.encodePacked(uint256 wordId, bytes32 wordHash, uint16 power, uint8 lang))
```
which matches the Solidity:
```solidity
keccak256(abi.encodePacked(wordId, wordHash, power, languageId))
```
in `ArdiEpochDraw.publishAnswer` line 349. End-to-end OZ-style proof
verification tested.

### Airdrop Merkle leaf — **OK**

`ardi-api::merkle::Leaf::hash` produces:
```
keccak256(addr ‖ uint256(ardi) ‖ uint256(awp))
```
which matches `ArdiMintController.claim`:
```solidity
keccak256(abi.encodePacked(msg.sender, ardiAmount, awpAmount))
```

The integration test `airdrop_proof_returns_merkle_proof_for_known_holder`
re-runs OZ-style verification on the served proof against the served
root; passes.

---

## Summary

| Severity | Count |
|---|---|
| C / Critical | 0 |
| H / High | 0 |
| M / Medium | 1 (epoch pre-submit time guard, off-chain only) |
| L / Low | 8 (mostly operational + documentation) |
| OK | 18 verified correct |

**Sign-off**: contracts-v2 is mainnet-quality at the structural level
(MEV-1, V3 fuse nonce, hash-only vault leaf are all coherent with the
Rust coord). The one **M** item is off-chain (coord-rs MEV-1 pre-submit
time guard) and can be patched in coord-rs without redeploying contracts.

Operational callouts to bake into the deploy runbook:
1. Multisig wrap the `coordinator` and `DEFAULT_ADMIN_ROLE` keys.
2. Verify Chainlink VRF v2.5 selector at deploy time.
3. Monitor VRF subscription balance.
4. Document that `coord` and `MERKLE_ROLE` rotation must be coordinated.

Pre-existing v1 issues called out in `TEST_NOTES.md` (BondEscrow tests
needing EpochDraw mock wiring) are unrelated to v2 logic and don't
block deploy.
