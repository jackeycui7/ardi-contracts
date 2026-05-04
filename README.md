# Ardi WorkNet Contracts

Smart contracts for the [Ardi WorkNet](../docs/design-spec.md). Solidity 0.8.24, Foundry, OpenZeppelin v5.

## Modules

| Contract | Purpose |
|---|---|
| `ArdiToken` | ERC-20 `$ardi` with 10B hard cap and a single locked-once minter. |
| `ArdiNFT` | ERC-721 inscriptions. Mint via Coordinator signature; fuse via Coordinator+LLM signature. |
| `ArdiBondEscrow` | KYA-gated registration + 10K $AWP Mining Bond, refundable on graceful exit, slashable on sybil. |
| `ArdiOTC` | Zero-fee peer-to-peer NFT marketplace (Ardinal trading). |
| `ArdiMintController` | Daily $ardi emission per two-phase halving + Merkle-rooted holder airdrops. |
| `interfaces/IKYA` | External KYA WorkNet interface (consumed only). |
| `interfaces/ICoordinator` | Documents the off-chain Coordinator's signed payload formats. |

## Build & test

```bash
# Install Foundry once
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Build
forge build

# Test (50 tests)
forge test -vv

# Coverage
forge coverage
```

## Vault Merkle root

The vault file (`../wordbank-builder/riddles.json` — 21,000 entries) is hashed into
a Merkle tree pre-deployment. Generate with:

```bash
python3 ../tools/vault_merkle.py \
  --vault ../path/to/riddles.json \
  --out ../tools/vault_tree.json \
  --prove 0   # prints sample proof for wordId 0
```

The resulting `root` (bytes32) goes into `VAULT_MERKLE_ROOT` env var for deployment.

Leaf format (matches OpenZeppelin's `MerkleProof` library):
```
keccak256(abi.encodePacked(
    uint256(wordId),
    bytes(word),         // UTF-8
    uint8(power),
    uint8(languageId)    // 0=en, 1=zh, 2=ja, 3=ko, 4=fr, 5=de
))
```

Sorted-pair internal hashing.

## Deployment

```bash
# Required env
export OWNER_ADDR=0x...           # multisig recommended
export COORDINATOR_ADDR=0x...     # off-chain signer
export AWP_TOKEN_ADDR=0x...       # $AWP on Base
export KYA_ADDR=0x...             # KYA registry
export VAULT_MERKLE_ROOT=0x...    # from vault_merkle.py
export LP_ESCROW_ADDR=0x...       # destination of 1B initial $ardi LP mint
export GENESIS_TS=1735603200      # unix timestamp of day-1 launch (UTC 00:00)
export RPC_URL=https://...
export PRIVATE_KEY=0x...          # deployer (should equal OWNER_ADDR)

# Dry-run
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# Broadcast
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

The script:
1. Deploys all 5 contracts in dependency order
2. Wires `nft.setBondEscrow`, `escrow.setArdiNFT`
3. Mints initial 1B $ardi to `LP_ESCROW_ADDR` (for Uniswap V4 LP setup)
4. Hands `$ardi` minting authority to `ArdiMintController` and **permanently locks it**
5. Logs all addresses

## Security notes

- **`via_ir = true`** in `foundry.toml` — required because fuse() has many local variables.
- **All Coordinator-signed paths use a versioned EIP-191 message** (`ARDI_INSCRIBE_V1` / `ARDI_FUSE_V1`) bound to chainId + contract address + replay-blocking nonce.
- **`MAX_MINTS_PER_AGENT = 3`** is enforced on-chain.
- **`MAX_SUPPLY = 10B`** is enforced on-chain.
- **Slash flow**: 50% burned, 50% to fusion pool (default). Configurable via `setFusionPool`.
- **`isSealed`**: once 21,000 originals minted, no further `inscribe()` accepted.
- **No re-entrancy entry points**: all external state-change functions wrapped in `nonReentrant`.

This code is **not yet audited**. Do not deploy to mainnet without an external security audit.

## Layout

```
contracts/
├── foundry.toml
├── README.md
├── lib/
│   ├── forge-std/
│   └── openzeppelin-contracts/
├── src/
│   ├── ArdiToken.sol
│   ├── ArdiNFT.sol
│   ├── ArdiBondEscrow.sol
│   ├── ArdiOTC.sol
│   ├── ArdiMintController.sol
│   └── interfaces/
│       ├── IKYA.sol
│       └── ICoordinator.sol
├── test/
│   ├── Mocks.sol
│   ├── ArdiToken.t.sol
│   ├── ArdiNFT.t.sol
│   ├── ArdiBondEscrow.t.sol
│   ├── ArdiOTC.t.sol
│   └── ArdiMintController.t.sol
└── script/
    └── Deploy.s.sol
```
