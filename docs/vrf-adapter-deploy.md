# ChainlinkVRFAdapter — deploy & wire runbook

How to swap from `MockRandomness` to a live Chainlink VRF v2.5 source on
Base Sepolia (testnet) or Base mainnet.

## Prereqs

1. ArdiEpochDraw already deployed (via `Deploy.s.sol` or `DeployTestnet.s.sol`).
   Its initial `randomness` is `MockRandomness`. Take note of the EpochDraw address.
2. A funded EOA you control on the target chain. This EOA MUST be the
   current owner of `ArdiEpochDraw` (because `setRandomnessSource` is
   `onlyOwner`).
3. LINK token balance OR native-ETH for VRF payment.

## Step 1 — Create + fund a VRF Subscription

Go to <https://vrf.chain.link>, connect your wallet on the right chain,
click **Create Subscription**.

Note the **Subscription ID** (a uint64 / uint256 number).

Fund it:
- Minimum to test: ~5 LINK (or ~0.05 ETH if you go native-payment).
- For ongoing production: monitor balance; ~1 LINK per ~50 fulfilments.

## Step 2 — Get the chain-specific constants

Source: <https://docs.chain.link/vrf/v2-5/supported-networks>

| Chain | VRF Coordinator | 200 gwei keyHash |
|---|---|---|
| Base mainnet | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` | (look up) |
| Base Sepolia | `0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE` | `0x9e9e...e6` |

**Verify these in the Chainlink docs at deploy time** — VRF infrastructure
does migrate.

## Step 3 — Run the deploy script

```bash
export DEPLOYER_PK=0x...                 # owner of EpochDraw
export EPOCH_DRAW_ADDR=0x...             # from the main deploy
export VRF_COORDINATOR=0x5C210eF4...
export VRF_KEY_HASH=0x9e9e...
export VRF_SUB_ID=123                    # your subscription ID

cd contracts-v2
forge script script/DeployVRFAdapter.s.sol \
    --rpc-url $BASE_SEPOLIA_RPC \
    --broadcast \
    --private-key $DEPLOYER_PK \
    -vvv
```

The script:
1. Deploys `ChainlinkVRFAdapter`.
2. Sets the chosen confirmations / callback gas.
3. Calls `epochDraw.setRandomnessSource(<adapter>)` — only succeeds if
   the deployer key equals EpochDraw's owner. If you've handed
   ownership off to a multisig, the call will revert; the script logs
   that and you finish wiring from the multisig.

Note the printed **Adapter** address.

## Step 4 — Add adapter as a Consumer on the Subscription

Back to <https://vrf.chain.link> → your subscription → **Add consumer** →
paste the adapter address. Confirm the transaction.

Without this step, `requestRandomness` reverts at the Chainlink Coordinator.

## Step 5 — End-to-end verification

The cleanest verification is a real epoch on testnet:

```bash
# 1. Coordinator opens an epoch.
# 2. An agent commits to a wordId.
# 3. Coordinator publishes the answer batch.
# 4. Agent reveals (correct).
# 5. Wait reveal_window. Coord-rs (or anyone) calls requestDraw.
# 6. Watch for the VRF Coordinator's `RandomWordsRequested` event in the
#    block scan within ~5 seconds, then `RandomWordsFulfilled` in
#    ~30 seconds (Chainlink's Base nodes are fast).
# 7. ArdiEpochDraw.WinnerSelected fires immediately after.
```

Cast trace for VRF events on the adapter:
```bash
cast logs --address $ADAPTER \
  --rpc-url $BASE_SEPOLIA_RPC \
  --from-block <tx_block> \
  'RandomnessRequested(uint256,address)' \
  'RandomnessFulfilled(uint256,uint256)'
```

## Operational checklist

- [ ] Subscription balance monitored (Prometheus alert at <2 LINK).
- [ ] Adapter address recorded in OPERATIONS.md alongside EpochDraw.
- [ ] Multisig has the ability to call `epochDraw.setRandomnessSource`
      to roll back to MockRandomness or a v3 adapter if Chainlink
      requires migration.
- [ ] `cancelStuckDraw` path tested — if VRF subscription runs dry
      mid-epoch, anyone can cancel after `DRAW_FULFILLMENT_TIMEOUT = 1 day`
      and re-request once funding is restored.
