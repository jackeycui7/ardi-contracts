# Ardi Contracts — Security Checklist

Pre-audit / pre-mainnet review checklist. Each item should be ✅ before deploying to Base mainnet.

## Static analysis

- [ ] `slither .` runs clean (or all findings reviewed + dismissed with rationale)
- [ ] `forge build --sizes` shows all contracts under 24KB EIP-170 limit
- [ ] No `pragma experimental` features used
- [ ] All `unchecked` blocks justified in comments
- [ ] Solc version pinned to 0.8.24

## Access control

- [ ] `ArdiToken.mint` is callable only by the immutable `minter` (after lock)
- [ ] `ArdiToken.mintLp` is **one-shot** — gated by `lpMinted` storage flag,
      cannot be called twice, even by owner
- [ ] `ArdiNFT.inscribe` requires Coordinator signature + `isMiner` from BondEscrow
- [ ] `ArdiNFT.fuse` requires Coordinator signature **bound to msg.sender (V2)** + ownership of both tokens
- [ ] `ArdiNFT.setCoordinator` / `setBondEscrow` only callable by Owner (multisig recommended)
- [ ] `ArdiBondEscrow.slashOnSybil` only callable by KYA contract or Owner
- [ ] `ArdiBondEscrow.setArdiNFT` only callable by Owner
- [ ] `ArdiBondEscrow.setSealed` callable only by ArdiNFT (no owner backdoor)
- [ ] `ArdiBondEscrow.setFusionPool` rejects `address(this)` to prevent re-introducing the locked-funds footgun
- [ ] `ArdiMintController.settleDay` only callable by Coordinator
- [ ] `ArdiMintController.claim` validates Merkle proof against the day's root,
      caps proof length at `MAX_PROOF_LEN = 32`

## Reentrancy

- [ ] All external state-changing functions wrapped in `nonReentrant`
- [ ] `inscribe`, `fuse`, `unlockBond`, `registerMiner`, `slashOnSybil`, `claim`, `buy`: all guarded
- [ ] Effect-then-interaction pattern used in slash flow (state updated before AWP.transfer)

## Signature security

- [ ] All Coordinator-signed digests include:
    - chainId (prevents cross-chain replay)
    - contract address (prevents cross-contract replay)
    - versioned prefix (`ARDI_INSCRIBE_V1`, `ARDI_FUSE_V1`)
    - per-action nonce (epochId for inscribe, fusionNonce for fuse)
- [ ] Signature recovery uses `MessageHashUtils.toEthSignedMessageHash` (EIP-191)
- [ ] Coordinator can be rotated via `setCoordinator` (with multisig)

## Integer safety

- [ ] All `uint128`/`uint64`/`uint16`/`uint8` casts checked or proven safe
- [ ] `power * multiplier` fusion math cannot overflow uint16 (MAX 65535; max practical ~30000)
- [ ] `compoundDecay` loop bounded by 200 iterations; product safely fits uint256

## Token economics

- [ ] `MAX_SUPPLY = 10B * 1e18` enforced in `_update`
- [ ] Initial 1B LP mint accounted for in 9B emission target
- [ ] `dailyEmission(day)` matches off-chain Coordinator's emission formula EXACTLY (verified by parity test)
- [ ] `totalScheduledEmission()` summed over days 1-180 ≈ 9B (rounding tolerance ±10M)

## Vault integrity

- [ ] `VAULT_MERKLE_ROOT` is `immutable` — cannot be changed post-deploy
- [ ] Each `wordId` mintable exactly once via `wordMinted` mapping
- [ ] `wordId` bounded `< 21,000` (`InvalidWordId` revert)
- [ ] `tokenId` for originals = `wordId + 1` (1..21000); for fusions = `21000 + fusionCount` (21001..)
- [ ] No collision possible between original and fusion tokenIds

## Economic edge cases

- [ ] Slash with `bps = 0` reverts (`InvalidBps`)
- [ ] Slash with `bps > 10000` reverts (`InvalidBps`)
- [ ] Slash fully drains bond + refunds remainder to agent if any
- [ ] Burned $AWP either via `burn()` if supported, or routed to dead address
- [ ] Bond unlocks immediately when agent caps at 3 mints (no waiting)
- [ ] OTC `buy()` validates seller still owns token (defense vs stale listing)
- [ ] OTC refunds excess ETH to buyer

## Invariants (Foundry)

- [ ] `forge test --match-contract InvariantTest` passes
- [ ] $ardi totalSupply ≤ MAX_SUPPLY across all calls
- [ ] totalInscribed ≤ 21,000 across all calls
- [ ] sealed implies totalInscribed == 21,000
- [ ] BondEscrow $AWP balance ≥ sum of active bonds (ghost state)

## Deployment hygiene

- [ ] Deploy script is idempotent (re-runnable from clean state)
- [ ] All external addresses set via env vars (no hardcoded testnet addresses)
- [ ] Vault Merkle root regenerated via `vault_merkle.py` from canonical `riddles.json`
- [ ] Verified contracts published on Basescan
- [ ] Owner = multisig (Safe)
- [ ] Coordinator = dedicated EOA with HSM/KMS-backed key

## External dependencies

- [ ] OpenZeppelin contracts at v5.1.0 (audited by OZ team)
- [ ] No untrusted libraries imported
- [ ] forge-std test utilities only used in test/

## Pre-mainnet steps

- [ ] **External audit** by reputable firm (OpenZeppelin / Trail of Bits / Spearbit etc.)
- [ ] **Public testnet** deployment for ≥ 2 weeks before mainnet
- [ ] **Bug bounty** program live before launch (Immunefi)
- [ ] **Incident response** plan documented; multisig signers on call

## Slither static analysis (run pre-audit)

Last run: slither-analyzer 0.11.5 against the full src/ tree.

### Findings addressed

| Detector             | Severity | Status |
|----------------------|----------|--------|
| reentrancy-no-eth    | Medium   | Fixed — `slashOnSybil` now zeroes all bond state before any external call |
| reentrancy-benign    | Low      | Fixed — `settleDay` now updates `cumulativeMinted` and emits the event before the fusion mint call |
| missing-zero-check   | Low (×10)| Fixed — every `set*` and constructor address parameter rejects `address(0)` with `ZeroAddress()` |
| missing-inheritance  | Info (×2)| Fixed — `ArdiBondEscrow` now `is IArdiBondEscrow`; `ArdiToken` now `is IArdiTokenMint`; interfaces moved to `src/interfaces/` |

### Findings reviewed and accepted

| Detector              | Where                        | Why accepted |
|-----------------------|------------------------------|--------------|
| timestamp (×6)        | Daily-window comparisons     | `block.timestamp` is the correct primitive for human-day boundaries; 12-second miner skew is negligible at the day grain |
| low-level-calls (×1)  | `ArdiOTC.buy` ETH refund     | Standard pattern — return value is checked with `require(ok)`; this is the only safe way to forward ETH while avoiding 2300-gas stipend issues |
| naming-convention (×6)| `AWP`, `KYA`, `ARDI_TOKEN`, `GENESIS_TS`, `VAULT_MERKLE_ROOT`, `ARDI_NFT` | Intentional ALL_CAPS for `immutable` references; this matches OpenZeppelin convention |

After the fixes above, `slither .` reports **0 medium-or-high findings** and **0 unaddressed lows**.

To reproduce:
```bash
python3 -m venv .slither_venv
.slither_venv/bin/pip install slither-analyzer
.slither_venv/bin/slither contracts --filter-paths "lib|test|script"
```

## Tokenomics & deployment correctness

### Daily emission split

The on-chain `settleDay(day, root, holderTotal, fusionTotal)` interface is
generic — it lets the Coordinator drive the split. Default Coordinator config
(`config.example.toml`):

| Slice | bps | Destination |
|---|---:|---|
| `holder_bps` | **10000** | Power-weighted Merkle airdrop to NFT holders |
| `fusion_bps` | **0** | On-chain `fusionPool` slot (treasury) — currently unused |

→ With defaults, **100% of daily emission flows to NFT holders**. The
`fusionPool` slot exists so governance can later route a slice to a
treasury / fusion-rewards contract without redeploying.

### `fusionPool` deployment requirement

Both `ArdiBondEscrow` and `ArdiMintController` carry a `fusionPool` address.
Tokens routed there from:

- `BondEscrow.slashOnSybil` — 50% of forfeited Mining Bonds in $AWP
- `MintController.settleDay` — `fusionTotal` in $ardi (currently 0)

**Critical**: this address must NEVER point at `address(escrow)`. BondEscrow has
no withdraw path — anything sent to it is permanently locked. The deploy
scripts (`Deploy.s.sol`, `DeployLocal.s.sol`):

- Require `TREASURY_ADDR` env (mandatory on mainnet, defaults to deployer locally)
- Pass it to both constructors
- Assert `fusionPool != address(escrow)` post-deploy

### Mainnet deploy checklist (critical)

- [ ] `TREASURY_ADDR` set to a multisig / dedicated treasury contract
- [ ] Treasury is NOT the `BondEscrow` address
- [ ] `LP_ESCROW_ADDR` set to a multisig (separate from treasury preferable for accounting)
- [ ] `OWNER_ADDR` set to a multisig — NOT a single-key EOA
- [ ] `holder_bps + fusion_bps == 10000` in coordinator config
- [ ] If raising `fusion_bps > 0` later, treasury must have a $ardi distribution mechanism

## Deferred audit findings (architectural decisions, NOT shipped fixes)

These were identified by independent audits but require governance / deployment
decisions before implementation. Tracked here so they aren't forgotten:

- **Owner-key compromise blast radius (audit C-2)**: `setKYA`, `setCoordinator`
  on both ArdiNFT and ArdiMintController, and `setFusionPool` are all plain
  `onlyOwner` with no Timelock. A compromised owner key can swap KYA →
  bypass sybil checks → drain bond mechanics. Mitigation must be either:
  (a) make `KYA` immutable post-deploy, OR (b) gate setters behind a
  Timelock contract controlled by a separate multisig. Decision deferred to
  governance design phase. **For mainnet**: `OWNER_ADDR` MUST be a multisig
  (≥2-of-3) and the owner-rotation procedure MUST be documented.

- **Reverse-proxy IP rate-limit (audit F5)**: `request.client.host` becomes
  the proxy IP under any production deployment (nginx / CloudFront / ALB).
  All traffic shares one bucket → false positives + trivial bypass via proxy
  chaining. Fix is `X-Forwarded-For` extraction with a configurable trusted
  proxy CIDR list. Decision deferred — depends on chosen deployment topology.

- **Renouncing ownership of BondEscrow / MintController is a footgun**: the
  `setFusionPool` setter becomes uncallable forever, so a wrong TREASURY_ADDR
  cannot be corrected. **DO NOT renounce** ownership of these two contracts.
  Only `ArdiToken` ownership is safe to renounce after `lockMinter`.

## Known limitations (out of MVP, future AIPs)

- Random draw uses `blockhash` from a single block — multi-block VRF would be stronger
- LLM oracle is a single-provider trust — multi-oracle / verifiable inference is future work
- Slash detection is centralized to KYA — decentralized sybil detection is future research
- No cross-chain plans in V1 (single Base deployment)
