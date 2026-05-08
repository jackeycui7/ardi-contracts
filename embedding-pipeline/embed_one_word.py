#!/usr/bin/env python3
"""
Single-word embedder: read word from stdin, output 192 hex chars (96 bytes
int8-quantized embedding) on stdout.

Args: artifacts_dir
  - reads pca_basis.json (or treats first-96-dims slice if synthetic)

Designed to be subprocess'ed by ardi-forge-oracle. Loads the model lazily
and caches it on disk via HuggingFace's standard cache. First call is slow
(~3-5s), subsequent calls quick (~150ms).
"""
import sys
import json
import numpy as np
from pathlib import Path
from sentence_transformers import SentenceTransformer

MODEL = "all-MiniLM-L6-v2"
TARGET_DIMS = 96
INT8_MAX = 127

def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: embed_one_word.py <artifacts_dir>\nword on stdin\n")
        sys.exit(2)
    artifacts = Path(sys.argv[1])
    word = sys.stdin.read().strip()
    if not word:
        sys.stderr.write("empty word\n"); sys.exit(2)

    pca_doc = json.loads((artifacts / "pca_basis.json").read_text())
    components = np.array(pca_doc["components"], dtype=np.float32)  # (96, 384)
    mean = np.array(pca_doc["mean"], dtype=np.float32)              # (384,)

    # Load model — cached after first call.
    model = SentenceTransformer(MODEL)
    emb_384 = model.encode([word], normalize_embeddings=True)  # (1, 384) float32

    # Project: subtract mean, project via components.
    centered = emb_384 - mean
    emb_96 = centered @ components.T  # (1, 96)

    # Re-normalize to unit length.
    norms = np.linalg.norm(emb_96, axis=1, keepdims=True)
    emb_96 = emb_96 / np.clip(norms, 1e-12, None)

    # Quantize.
    emb_int = np.clip(np.round(emb_96 * INT8_MAX), -INT8_MAX, INT8_MAX).astype(np.int8)

    sys.stdout.write(emb_int[0].tobytes().hex())
    sys.stdout.flush()

if __name__ == "__main__":
    main()
