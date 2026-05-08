#!/usr/bin/env python3
import os
"""
Upload 21K embeddings to a fresh EmbeddingStore.

Reads artifacts/embeddings.json (wordId → 0x-prefixed 96-byte hex), submits
in batches of N via cast send. Tracks tx nonce locally to avoid races.
After upload, calls setBatch + setPcaBasisHash + setModelHash + seal.

Usage:
  python3 upload_21k.py <store_addr>
"""
import json
import os
import subprocess
import sys
from pathlib import Path

PK = os.environ["PRIVATE_KEY"]  # sepolia testnet deployer
RPC = "https://sepolia.base.org"
ARTIFACTS = Path("/root/awp_code/ardi/contracts-v2/embedding-pipeline/artifacts")
BATCH_SIZE = 150  # ~10.7M gas/batch — Base Sepolia caps tx gas tighter than mainnet

def cast(args, capture=True):
    out = subprocess.run(["cast"] + args, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {out.stderr}")
    return out.stdout.strip() if capture else None

def get_nonce(addr):
    return int(cast(["nonce", addr, "--rpc-url", RPC]))

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    store = sys.argv[1]
    deployer = cast(["wallet", "address", "--private-key", PK])
    print(f"deployer: {deployer}")
    print(f"store:    {store}")

    embs = json.loads((ARTIFACTS / "embeddings.json").read_text())
    ids_sorted = sorted(int(k) for k in embs.keys())
    print(f"loaded {len(ids_sorted)} embeddings")

    # Set hashes first.
    pca_hash = "0x" + __import__("hashlib").sha256((ARTIFACTS / "pca_basis.json").read_bytes()).hexdigest()
    model_hash = cast(["keccak", "all-MiniLM-L6-v2/sentence-transformers"])
    print(f"pca_hash: {pca_hash}")
    print(f"model_hash: {model_hash}")

    nonce = get_nonce(deployer)
    print(f"starting nonce: {nonce}")

    print("→ setPcaBasisHash")
    cast(["send", store, "setPcaBasisHash(bytes32)", pca_hash,
          "--private-key", PK, "--rpc-url", RPC, "--nonce", str(nonce), "--gas-limit", "100000"])
    nonce += 1
    print("→ setModelHash")
    cast(["send", store, "setModelHash(bytes32)", model_hash,
          "--private-key", PK, "--rpc-url", RPC, "--nonce", str(nonce), "--gas-limit", "100000"])
    nonce += 1

    # Upload in batches.
    total_batches = (len(ids_sorted) + BATCH_SIZE - 1) // BATCH_SIZE
    for batch_i in range(total_batches):
        start = batch_i * BATCH_SIZE
        end = min(start + BATCH_SIZE, len(ids_sorted))
        chunk = ids_sorted[start:end]
        ids_arg = "[" + ",".join(str(i) for i in chunk) + "]"
        embs_arg = "[" + ",".join(embs[str(i)] for i in chunk) + "]"

        attempt = 0
        while True:
            try:
                cast(["send", store, "setBatch(uint16[],bytes[])", ids_arg, embs_arg,
                      "--private-key", PK, "--rpc-url", RPC, "--nonce", str(nonce),
                      "--gas-limit", "15000000"])
                break
            except RuntimeError as e:
                attempt += 1
                if attempt > 3:
                    raise
                err = str(e).lower()
                if "nonce too low" in err:
                    # Bump nonce and retry — RPC saw later state.
                    nonce = get_nonce(deployer)
                    print(f"  nonce bumped to {nonce}")
                elif "underpriced" in err or "replacement" in err:
                    import time; time.sleep(3)
                else:
                    raise
        print(f"  batch {batch_i+1}/{total_batches} ({end}/{len(ids_sorted)}) nonce={nonce}")
        nonce += 1

    print("→ seal()")
    cast(["send", store, "seal()",
          "--private-key", PK, "--rpc-url", RPC, "--nonce", str(nonce), "--gas-limit", "100000"])
    print("done.")
    print(f"final nonce: {nonce}")
    # Verify
    count = cast(["call", store, "storedCount()(uint32)", "--rpc-url", RPC]).split()[0]
    sealed = cast(["call", store, "sealed_()(bool)", "--rpc-url", RPC]).split()[0]
    print(f"  storedCount: {count}")
    print(f"  sealed:      {sealed}")

if __name__ == "__main__":
    main()
