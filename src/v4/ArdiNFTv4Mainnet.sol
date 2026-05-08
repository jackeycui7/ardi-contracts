// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArdiNFTv322} from "../v32/ArdiNFTv322.sol";

/// @title  ArdiNFTv4Mainnet — minimal host for the ForgeModule pattern.
/// @notice Inherits ArdiNFTv322 — preserves storage layout of the live
///         16K NFTs on the existing UUPS proxy. Adds ONLY the admin
///         entry points that an external `ArdiForgeModule` needs to
///         carry out the forge mechanic. All forge logic — embedding
///         resolution, VRF callback, completion, fee math, LLM oracle
///         signature checks — lives in `ArdiForgeModule` (separate
///         deployment). This keeps v4 well under EIP-170 and lets us
///         iterate forge mechanics by redeploying the module without
///         touching the NFT proxy.
///
/// Storage adds (consumes v322Gap):
///   - `forgeModule`            address of the privileged module
///   - `_forgedTokenWordId`     forged-tokenId → wordId
///   - `_forgedEmbeddingByWid`  wordId → 96-byte embedding
///   - `nextForgedWordId`       monotonic counter, init at 21001
///
/// Admin entry points (only callable by `forgeModule`):
///   - adminBurnPair(tidA, tidB, holder)
///   - adminMintForged(holder, props, embedding) → newTokenId
///
/// Lifecycle:
///   1. Owner deploys ArdiForgeModule, sets its NFT pointer to this proxy.
///   2. Owner upgrades the proxy to this v4 impl.
///   3. Owner calls `setForgeModule(<module addr>)`.
///   4. From now on, users interact with ArdiForgeModule for forge.
///      Module calls back into this contract via the admin entry points.
contract ArdiNFTv4Mainnet is ArdiNFTv322 {
    // ─────────────── Constants ───────────────

    uint8 internal constant DUR_CAP = 30;

    // ─────────────── New v4 storage (consumes v322Gap) ───────────────
    // APPEND-ONLY. Never reorder. Layout must remain compatible with the
    // live UUPS proxy at upgrade time.

    /// @notice Privileged ForgeModule contract; gates the admin entries.
    address public forgeModule;

    /// @notice Per-tokenId → forged wordId. Originals (≤ ORIGINAL_CAP)
    ///         use tokenId-1 implicitly; this is set only for forge outputs.
    mapping(uint256 => uint16) public forgedTokenWordId;

    /// @notice 96-byte int8-quantized embedding for forge-issued words.
    ///         Originals' embeddings live in a sealed EmbeddingStore; we
    ///         keep forge ones here so re-forging works.
    mapping(uint16 => bytes) public forgedEmbeddingByWordId;

    /// @notice Next forged-wordId. Initialized lazily to ORIGINAL_CAP+1
    ///         the first time setForgeModule runs.
    uint16 public nextForgedWordId;

    // ─────────────── Events ───────────────

    event ForgeModuleSet(address indexed module);
    event AdminBurnedPair(uint256 indexed tokenIdA, uint256 indexed tokenIdB, address indexed holder);
    event AdminForgedMinted(
        address indexed holder,
        uint256 indexed newTokenId,
        uint16 wid,
        string word,
        uint16 power,
        uint8 dur,
        uint8 element
    );

    // ─────────────── Errors ───────────────

    error NotForgeModule();
    error ModuleNotSet();

    // ─────────────── Modifiers ───────────────

    modifier onlyForgeModule() {
        if (msg.sender != forgeModule) revert NotForgeModule();
        _;
    }

    // ─────────────── Owner setter ───────────────

    /// @notice Owner: install the ForgeModule. Setting to address(0)
    ///         disables forge entirely. First non-zero install also
    ///         lazily initialises nextForgedWordId to ORIGINAL_CAP+1.
    function setForgeModule(address module) external onlyOwner {
        forgeModule = module;
        if (module != address(0) && nextForgedWordId == 0) {
            nextForgedWordId = uint16(ORIGINAL_CAP + 1);
        }
        emit ForgeModuleSet(module);
    }

    // ─────────────── Read helper used by oracle / module ───────────────

    /// @notice For originals: tokenId-1 (implicit). For forged: looks up
    ///         the local map. Used off-chain by the forge oracle to drive
    ///         the cosine call before submitting forge intent.
    function wordIdOf(uint256 tokenId) external view returns (uint16) {
        if (tokenId <= ORIGINAL_CAP) return uint16(tokenId - 1);
        uint16 wid = forgedTokenWordId[tokenId];
        require(wid != 0, "unknown tokenId");
        return wid;
    }

    // ─────────────── Admin entry points (forgeModule only) ───────────────

    /// @notice Burn one or both inputs of a forge attempt. Used on the
    ///         FAILURE path (single id, lower-power) and the SUCCESS path
    ///         (both, then mint). Module is responsible for ownership +
    ///         pending-state checks before calling.
    function adminBurnPair(uint256 tokenIdA, uint256 tokenIdB, address holder)
        external
        onlyForgeModule
    {
        if (tokenIdA != 0) {
            if (inscriptions[tokenIdA].activeTracked) _deactivate(tokenIdA, holder);
            _burn(tokenIdA);
        }
        if (tokenIdB != 0) {
            if (inscriptions[tokenIdB].activeTracked) _deactivate(tokenIdB, holder);
            _burn(tokenIdB);
        }
        emit AdminBurnedPair(tokenIdA, tokenIdB, holder);
    }

    /// @notice Mint a freshly-forged NFT. Module supplies all derived
    ///         attributes; this contract only enforces structural caps
    ///         (ID range, dur cap, simple validity). Returns the new id.
    /// @param holder   recipient
    /// @param parents  source tokenIds (for the `parents` field; A then B)
    /// @param word     LLM-picked new word
    /// @param power    derived power (uint16)
    /// @param dur      derived dura (clamped to DUR_CAP off-chain too)
    /// @param element  1..6 (6 = god, T1 godTouch path)
    /// @param embedding 96 bytes int8 quantized — stored locally
    function adminMintForged(
        address holder,
        uint256[2] calldata parents,
        string calldata word,
        uint16 power,
        uint8 dur,
        uint8 element,
        bytes calldata embedding
    ) external onlyForgeModule returns (uint256 newTokenId) {
        require(holder != address(0), "zero holder");
        require(power > 0, "zero power");
        require(dur > 0 && dur <= DUR_CAP, "dur range");
        require(element >= 1 && element <= 6, "elem range");
        require(embedding.length == 96, "emb len");

        unchecked { ++fusionCount; }
        newTokenId = ORIGINAL_CAP + fusionCount;

        // Lineage gen = max(parent gens) + 1; module guarantees parents
        // are valid at call time but defensively read from storage.
        uint8 genA = inscriptions[parents[0]].generation;
        uint8 genB = inscriptions[parents[1]].generation;
        uint8 newGen = (genA > genB ? genA : genB) + 1;

        uint256[] memory ps = new uint256[](2);
        ps[0] = parents[0];
        ps[1] = parents[1];

        Inscription storage ins = inscriptions[newTokenId];
        ins.word                = word;
        ins.power               = power;
        ins.generation          = newGen;
        ins.inscriber           = holder;
        ins.mintTimestamp       = uint64(block.timestamp);
        ins.element             = element;
        ins.maxDurability       = dur;
        ins.currentDurability   = dur;
        ins.lastDecayCheckpoint = uint64(block.timestamp);
        ins.activeTracked       = true;
        ins.parents             = ps;

        uint16 newWid = nextForgedWordId++;
        forgedTokenWordId[newTokenId]    = newWid;
        forgedEmbeddingByWordId[newWid]  = embedding;

        _safeMint(holder, newTokenId);
        _activate(newTokenId, holder);

        emit AdminForgedMinted(holder, newTokenId, newWid, word, power, dur, element);
    }

    // ─────────────── Storage gap ───────────────
    // Conservative — ForgeModule pattern means future expansions of v4
    // itself should be rare; new state goes into the module instead.
    uint256[39] private __v4Gap;
}
