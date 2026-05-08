// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  EmbeddingStore — read-only registry of 96-byte word embeddings
/// @notice Standalone contract that holds the int8-quantized embeddings for
///         all 21K original words. Separated from ArdiNFTv4 because the
///         main NFT contract is already 4 bytes from EIP-170 (24,576) and
///         the 21K SSTOREs would otherwise need to land on a contract that
///         can't grow further.
///
///         **Lifecycle**:
///           1. owner deploys this contract
///           2. owner calls setBatch() in ~60 batches to upload 21K entries
///           3. owner calls seal() — locks the store forever
///           4. ArdiNFTv4.forge() reads `embeddings(wordId)` (single SLOAD)
///
///         After seal(), the contract is immutable. Verifiability is
///         backed by `pcaBasisHash` — the hash of the off-chain PCA
///         projection matrix used to reduce 384-dim → 96-dim embeddings.
///         Anyone with the published basis (artifacts/pca_basis_96x384.json)
///         can re-derive every byte stored here from the original 21K
///         words via the locked `all-MiniLM-L6-v2` model.
contract EmbeddingStore is Ownable2Step {
    /// @notice Hash of the PCA projection matrix (keccak256 of the canonical
    ///         JSON serialization of the 96×384 float32 basis). Set once at
    ///         deploy via setPcaBasisHash; locked at seal().
    bytes32 public pcaBasisHash;

    /// @notice Hash of the embedding model + version + tokenizer config.
    ///         keccak256(abi.encodePacked("all-MiniLM-L6-v2", "1.0", "bert"))
    ///         or similar — locks WHICH model produced these embeddings.
    bytes32 public modelHash;

    /// @notice Sealed flag. Once true, no more setBatch / setPcaBasisHash
    ///         allowed. ArdiNFTv4.forge() refuses to run if !sealed.
    bool public sealed_;

    /// @notice wordId → 96-byte int8-quantized embedding.
    ///         wordId is a uint16: 21,000 words fits in 14 bits.
    mapping(uint16 => bytes) private _embeddings;

    /// @notice Count of distinct wordIds with a non-empty embedding.
    ///         Sanity check: should equal 21,000 at seal time.
    uint32 public storedCount;

    // ─────────── events ───────────
    event BatchSet(uint16 firstId, uint16 lastId, uint32 count);
    event PcaBasisHashSet(bytes32 indexed hash);
    event ModelHashSet(bytes32 indexed hash);
    event Sealed(uint32 finalCount, bytes32 pcaBasisHash, bytes32 modelHash);

    // ─────────── errors ───────────
    error AlreadySealed();
    error NotSealed();
    error LengthMismatch();
    error InvalidEmbeddingLength();
    error UnknownWord();

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────── owner mutators (pre-seal) ───────────

    function setPcaBasisHash(bytes32 h) external onlyOwner {
        if (sealed_) revert AlreadySealed();
        pcaBasisHash = h;
        emit PcaBasisHashSet(h);
    }

    function setModelHash(bytes32 h) external onlyOwner {
        if (sealed_) revert AlreadySealed();
        modelHash = h;
        emit ModelHashSet(h);
    }

    /// @notice Upload one batch of (wordId, embedding) pairs.
    /// @dev    Per-call gas budget on Base is ~30M; ~350 entries per batch
    ///         is comfortable. Each entry costs ~71K gas (3 cold SSTOREs +
    ///         dispatch). 21K / 350 ≈ 60 batches.
    ///
    ///         Idempotency: setting the same wordId twice overwrites silently
    ///         (storedCount only increments on first-set).
    function setBatch(uint16[] calldata ids, bytes[] calldata embs)
        external
        onlyOwner
    {
        if (sealed_) revert AlreadySealed();
        if (ids.length != embs.length) revert LengthMismatch();

        uint32 newCount = storedCount;
        uint16 first = ids.length > 0 ? ids[0] : 0;
        uint16 last  = ids.length > 0 ? ids[ids.length - 1] : 0;

        for (uint256 i = 0; i < ids.length; i++) {
            if (embs[i].length != 96) revert InvalidEmbeddingLength();
            if (_embeddings[ids[i]].length == 0) {
                unchecked { newCount++; }
            }
            _embeddings[ids[i]] = embs[i];
        }
        storedCount = newCount;
        emit BatchSet(first, last, uint32(ids.length));
    }

    /// @notice Lock the store. After this:
    ///   - setBatch / setPcaBasisHash / setModelHash all revert
    ///   - sealed_ = true permanently
    ///   - ArdiNFTv4 can be wired up
    function seal() external onlyOwner {
        if (sealed_) revert AlreadySealed();
        sealed_ = true;
        emit Sealed(storedCount, pcaBasisHash, modelHash);
    }

    // ─────────── reads ───────────

    /// @notice Get embedding for wordId. Reverts if no entry exists.
    ///         ArdiNFTv4 should only call this for inscribed wordIds, so
    ///         a missing entry indicates a bug or unmigrated word.
    function embeddings(uint16 wordId) external view returns (bytes memory) {
        bytes memory e = _embeddings[wordId];
        if (e.length == 0) revert UnknownWord();
        return e;
    }

    /// @notice Boolean check without revert; used by callers that need to
    ///         pre-check (e.g. forge UI before submitting tx).
    function hasWord(uint16 wordId) external view returns (bool) {
        return _embeddings[wordId].length == 96;
    }
}
