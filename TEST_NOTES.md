# contracts-v2 — test status

## Compile

`forge build` ✅ — all sources + tests compile.

## `forge test` results

| State | Count | Note |
|---|---:|---|
| pass | 122+ | unaffected + v2-touched suites |
| fail | 5 | **pre-existing v1 bugs** unrelated to v2 changes (see below) |
| skipped (`Invariants`, `Timelock`) | n/a | rely on infra not bundled here |

Run: `forge test --no-match-contract "Invariants|Timelock"`.

## Pre-existing failures left as-is

These are bugs in the v1 test suite against the v1.0 hash-only + win-cap
contract refactor. They predate contracts-v2 and are out of scope for the
MEV / fusion-nonce work.

| Test | Reason |
|---|---|
| `ArdiBondEscrow.t::test_onMinted_byArdiNFT` | v1.0 removed the `onMinted` mint counter; bond unlock now reads `agentWinCount` from `ArdiEpochDraw` (`IEpochDrawWinView`). Test still calls the deprecated hook + asserts internal `miners[agent].mintCount`. |
| `ArdiBondEscrow.t::test_unlock_afterCapReached` | Calls `escrow.onMinted` 3× to "simulate" cap, then `unlockBond`. Production unlock reads `epochDraw.agentWinCount`; test never wires an `epochDraw`, so `unlockBond` reverts `EpochDrawNotSet`. Fix requires deploying a `MockEpochDraw`, setting it on the escrow, and stubbing `agentWinCount(agent) = 3`. |
| `ArdiBondEscrow.t::test_unlock_revertsBeforeCapAndBeforeSeal` | Same — `epochDraw` not set, unlock reverts on the wrong selector. |
| `ArdiBondEscrow.t::test_unlock_afterSealAndCooldown` | Same. |
| `Adversary.t::test_attack_unlockBeforeUnlocked` | Same. |

To fix all five, add to `ArdiBondEscrow.t::setUp()`:

```solidity
import {MockEpochDraw} from "./Mocks.sol";
MockEpochDraw mockDraw;

function setUp() public {
    // ...existing setup...
    mockDraw = new MockEpochDraw();
    vm.prank(owner);
    escrow.setEpochDraw(address(mockDraw));
}
```

Then in each `test_unlock_*`, instead of `escrow.onMinted(agent)`, call
`mockDraw.setAgentWinCount(agent, n)` (the helper added in
`Mocks.sol::MockEpochDraw`).

`test_onMinted_byArdiNFT` should be deleted — the `onMinted` hook is
intentionally inert in v1.0+.

These are mechanical refactors with no signal value for v2; left for a
follow-up cleanup PR alongside any other test-suite hygiene work.

## v2-related test changes

| Test | Updated for v2 |
|---|---|
| `ArdiNFT.t::_signFuse` | `ARDI_FUSE_V2` → `ARDI_FUSE_V3` |
| `ArdiNFT.t::test_fuse_nonceIncrementsBlocksReplay` | `nft.fusionNonce()` → `nft.fusionNonceOf(agent)` |
| `ArdiNFT.t` (all `inscribe` callsites) | 2-arg → 3-arg (plaintext word now required) |
| `ArdiNFT.t::test_inscribe_capPerAgent` | expected revert `NotMiner` → `AgentCapReached` (production check order) |
| `Adversary.t` (all `inscribe`) | 2-arg → 3-arg |
| `Adversary.t::test_attack_inscribeAfterCap` | revert order fix as above |
| `ArdiOTC.t::setUp` | 2-arg → 3-arg `inscribe(1, 0, "x")` |
| `ArdiEpochDraw.t::_redeployWithLeafRoot` | leaf format hash-only |
| `ArdiEpochDraw.t::publishAnswer` callsites | now pass `keccak256(bytes(word))` |
| `ArdiEpochDraw.t::getAnswer` destructure | returns `bytes32 wordHash` (not `string word`) |
| `ArdiEpochDraw.t` bond values | `0.001 ether` → `0.00001 ether` (matches `COMMIT_BOND` testnet rehearsal value) |
| `Mocks.sol::MockEpochDraw` | stores `bytes32 wordHash`; adds `setAgentWinCount`, `setAnswerHash`, `agentWinCount` view |
