#!/usr/bin/env python3
"""
Upload 21K embeddings to a fresh Base mainnet EmbeddingStore + seal.

Adapted from upload_21k.py (sepolia version):
  * RPC + PRIVATE_KEY come from env (not hardcoded)
  * Larger batch size (Base mainnet has higher gas-per-block cap)
  * Verifies storedCount before sealing

Inputs
------
  STORE_ADDR     env  EmbeddingStore proxy address (from DeployForgeMainnet)
  PRIVATE_KEY    env  Owner of the store (== deployer wallet)
  RPC            env  https://mainnet.base.org or QuickNode
  ARTIFACTS_DIR  env  defaults to /root/awp_code/ardi/contracts-v2/embedding-pipeline/artifacts

Outputs
-------
  Logs each batch tx hash + final seal tx hash.
  Resumable: skips wordIds already stored (queries hasWord per id; ~3.5 min check
  before any upload, but lets you restart after a crash without re-uploading).

Usage
-----
  STORE_ADDR=0x... \
  PRIVATE_KEY=0x... \
  RPC=https://mainnet.base.org \
    python3 upload_21k_mainnet.py
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

STORE = os.environ.get("STORE_ADDR")
PK    = os.environ.get("PRIVATE_KEY")
RPC   = os.environ.get("RPC", "https://mainnet.base.org")
ARTIFACTS = Path(os.environ.get(
    "ARTIFACTS_DIR",
    "/root/awp_code/ardi/contracts-v2/embedding-pipeline/artifacts"
))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "500"))   # mainnet allows bigger batches

if not STORE or not PK:
    print(__doc__)
    sys.exit(2)


def cast(args, capture=True):
    out = subprocess.run(["cast"] + args, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {out.stderr.strip()}")
    return out.stdout.strip() if capture else None


def get_nonce(addr):
    return int(cast(["nonce", addr, "--rpc-url", RPC]))


def get_count():
    return int(cast(["call", STORE, "storedCount()(uint32)", "--rpc-url", RPC]))


def is_sealed():
    return cast(["call", STORE, "sealed_()(bool)", "--rpc-url", RPC]) == "true"


def has_word(wid):
    out = cast(["call", STORE, "hasWord(uint16)(bool)", str(wid), "--rpc-url", RPC])
    return out == "true"


def encode_setbatch(ids, embs_hex):
    """
    Encode setBatch(uint16[],bytes[]) calldata.
    Returns the hex string for cast send --calldata.
    """
    types = "uint16[],bytes[]"
    ids_arr = "[" + ",".join(str(i) for i in ids) + "]"
    embs_arr = "[" + ",".join(embs_hex) + "]"
    return cast(["abi-encode", f"setBatch({types})", ids_arr, embs_arr])


def main():
    deployer = cast(["wallet", "address", "--private-key", PK])
    print(f"deployer: {deployer}")
    print(f"store:    {STORE}")
    print(f"rpc:      {RPC}")
    print(f"batch:    {BATCH_SIZE}")
    print()

    if is_sealed():
        print("✗ store is already sealed. Aborting.")
        sys.exit(1)

    embs = json.loads((ARTIFACTS / "embeddings.json").read_text())
    all_ids = sorted(int(k) for k in embs.keys())
    print(f"loaded {len(all_ids)} embeddings from artifacts", flush=True)

    # Optional resumability: skip hasWord scan when storedCount == 0
    # (fresh deploy — we know nothing is stored yet, scan would be 8h+ wasted).
    initial_count = get_count()
    skip_offset = int(os.environ.get("SKIP_FIRST_N", "0"))
    if skip_offset > 0:
        print(f"SKIP_FIRST_N={skip_offset} — resuming from offset {skip_offset}", flush=True)
        pending = all_ids[skip_offset:]
    elif initial_count == 0 or os.environ.get("SKIP_HASWORD_SCAN") == "1":
        print(f"storedCount=0 — skipping hasWord scan, uploading all {len(all_ids)} ids", flush=True)
        pending = all_ids
    else:
        print(f"checking which ids are already stored ({len(all_ids)} hasWord calls)…", flush=True)
        pending = []
        for i, wid in enumerate(all_ids):
            if has_word(wid):
                continue
            pending.append(wid)
            if (i + 1) % 1000 == 0:
                print(f"  scanned {i+1}/{len(all_ids)}, {len(pending)} pending so far", flush=True)
        print(f"need to upload {len(pending)} embeddings (already stored: {len(all_ids) - len(pending)})", flush=True)
    if not pending:
        print("nothing to upload, jumping to seal")
    else:
        nonce = get_nonce(deployer)
        for batch_start in range(0, len(pending), BATCH_SIZE):
            batch = pending[batch_start : batch_start + BATCH_SIZE]
            ids_arr = "[" + ",".join(str(i) for i in batch) + "]"
            embs_arr = "[" + ",".join(embs[str(i)] for i in batch) + "]"
            ts = time.time()
            tx = cast([
                "send", STORE,
                "setBatch(uint16[],bytes[])",
                ids_arr, embs_arr,
                "--private-key", PK,
                "--rpc-url", RPC,
                "--nonce", str(nonce),
                # Base mainnet caps individual tx gas at ~30M (block 60M).
                # 200-id batch ≈ 20M gas (3 SSTOREs × 96-byte writes + bookkeeping
                # per entry). 25M leaves ~25% headroom under the per-tx cap.
                "--gas-limit", "25000000",
                "--json",
            ])
            tx_hash = json.loads(tx).get("transactionHash")
            took = time.time() - ts
            print(f"  batch {batch_start//BATCH_SIZE + 1} ({len(batch)} ids, nonce {nonce}) → {tx_hash}  [{took:.1f}s]", flush=True)
            nonce += 1

    final_count = get_count()
    print(f"\nstoredCount: {final_count} / 21000")
    if final_count != 21000:
        print(f"✗ count mismatch — DO NOT seal. Aborting.")
        sys.exit(1)

    # Sanity: model hash + pca hash should be set already (ctor or setHash).
    model_hash = cast(["call", STORE, "modelHash()(bytes32)", "--rpc-url", RPC])
    pca_hash   = cast(["call", STORE, "pcaBasisHash()(bytes32)", "--rpc-url", RPC])
    print(f"modelHash:  {model_hash}")
    print(f"pcaHash:    {pca_hash}")
    if model_hash == "0x" + "0" * 64 or pca_hash == "0x" + "0" * 64:
        print("✗ model/pca hash unset. Run setModelHash + setPcaBasisHash first.")
        sys.exit(1)

    # Final seal.
    print("\nsealing…")
    seal_tx = cast([
        "send", STORE, "seal()",
        "--private-key", PK,
        "--rpc-url", RPC,
        "--json",
    ])
    print(f"seal tx: {json.loads(seal_tx).get('transactionHash')}")
    print("\n✓ DONE — store is permanent.")


if __name__ == "__main__":
    main()
