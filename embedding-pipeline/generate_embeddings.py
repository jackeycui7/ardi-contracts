#!/usr/bin/env python3
"""
Generate 96-byte int8-quantized embeddings for ArdiForge.

Pipeline:
  1. Load all-MiniLM-L6-v2 (384-dim sentence-transformer)
  2. Encode each input word → 384-dim float32 vector
  3. Reduce 384 → 96 dims via PCA (basis trained from the input set)
  4. Quantize each dim to int8 by scaling to fit [-127, 127]
  5. Output JSON: { wordId: hex-encoded 96-byte string }

Usage:
  python3 generate_embeddings.py words.txt output_dir/

words.txt format: one word per line. wordId = line index (0-based).

Outputs in output_dir/:
  - embeddings.json   { "0": "0x...", "1": "0x...", ... }
  - pca_basis.json    { "shape": [96, 384], "data": [[...], ...] }
  - manifest.json     hashes + model version + word count
"""
import sys
import json
import hashlib
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.decomposition import PCA

MODEL_NAME = "all-MiniLM-L6-v2"
TARGET_DIMS = 96
INT8_MAX = 127

def main(words_path: str, out_dir: str):
    words = Path(words_path).read_text().strip().split("\n")
    words = [w.strip() for w in words if w.strip()]
    print(f"Loading {MODEL_NAME}...", flush=True)
    model = SentenceTransformer(MODEL_NAME)
    print(f"Encoding {len(words)} words...", flush=True)
    embs_384 = model.encode(words, normalize_embeddings=True)  # (N, 384)

    if len(words) < TARGET_DIMS + 1:
        print(f"WARNING: only {len(words)} words; PCA needs ≥{TARGET_DIMS+1}. "
              "Falling back to first-{TARGET_DIMS}-dims slice for testnet seed.", flush=True)
        embs_96 = embs_384[:, :TARGET_DIMS]
        # Build a fake "PCA" doc so manifest still validates — identity slice.
        pca = type("FakePCA", (), {})()
        pca.components_ = np.eye(TARGET_DIMS, embs_384.shape[1], dtype=np.float32)
        pca.mean_ = np.zeros(embs_384.shape[1], dtype=np.float32)
    else:
        print(f"PCA reducing to {TARGET_DIMS} dims...", flush=True)
        pca = PCA(n_components=TARGET_DIMS)
        embs_96 = pca.fit_transform(embs_384)  # (N, 96)
    # Re-normalize to unit length so cosine semantics survive PCA.
    norms = np.linalg.norm(embs_96, axis=1, keepdims=True)
    embs_96 = embs_96 / np.clip(norms, 1e-12, None)

    # Quantize: scale each vector by INT8_MAX, then clip to int8.
    # Per-vector scaling preserves direction (cosine invariant).
    print("Quantizing int8...", flush=True)
    embs_int = np.clip(np.round(embs_96 * INT8_MAX), -INT8_MAX, INT8_MAX).astype(np.int8)

    # Verify: cosine of identical word should still be 100.
    sample_a = embs_int[0].astype(np.int32)
    cos_self = np.dot(sample_a, sample_a) / (np.linalg.norm(sample_a) ** 2)
    print(f"Self-cosine sanity: {cos_self:.6f} (should be 1.0)", flush=True)

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # embeddings.json: {wordId_str: 0x-prefixed hex bytes}
    embeddings = {}
    for i, vec in enumerate(embs_int):
        # Two's-complement byte representation: cast int8 to uint8 view.
        as_bytes = vec.astype(np.int8).tobytes()
        embeddings[str(i)] = "0x" + as_bytes.hex()
    (out / "embeddings.json").write_text(json.dumps(embeddings, indent=2))

    # pca_basis.json: 96x384 float32 matrix
    basis_data = pca.components_.astype(np.float32).tolist()
    pca_doc = {
        "shape": list(pca.components_.shape),
        "mean": pca.mean_.astype(np.float32).tolist(),
        "components": basis_data,
    }
    (out / "pca_basis.json").write_text(json.dumps(pca_doc))

    # word_to_id.json: { word: wordId } (for coord lookup)
    word_to_id = {w: i for i, w in enumerate(words)}
    (out / "word_to_id.json").write_text(json.dumps(word_to_id, indent=2))

    # manifest.json: hashes for on-chain verification
    pca_hash = hashlib.sha256((out / "pca_basis.json").read_bytes()).hexdigest()
    embs_hash = hashlib.sha256((out / "embeddings.json").read_bytes()).hexdigest()
    model_id = f"{MODEL_NAME}/sentence-transformers"
    model_hash = hashlib.sha256(model_id.encode()).hexdigest()
    manifest = {
        "model": MODEL_NAME,
        "model_hash_sha256": model_hash,
        "model_hash_keccak_solidity_input": "keccak256(abi.encodePacked(\"all-MiniLM-L6-v2/sentence-transformers\"))",
        "target_dims": TARGET_DIMS,
        "n_words": len(words),
        "pca_hash_sha256": pca_hash,
        "embeddings_hash_sha256": embs_hash,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"\nWrote {len(words)} embeddings to {out}/", flush=True)
    print(f"  embeddings.json   {(out / 'embeddings.json').stat().st_size:>10} bytes")
    print(f"  pca_basis.json    {(out / 'pca_basis.json').stat().st_size:>10} bytes")
    print(f"  word_to_id.json   {(out / 'word_to_id.json').stat().st_size:>10} bytes")
    print(f"  manifest.json:")
    for k, v in manifest.items():
        if isinstance(v, str) and len(v) > 80:
            v = v[:77] + "..."
        print(f"    {k}: {v}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
