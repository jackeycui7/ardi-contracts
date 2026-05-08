// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721BurnableUpgradeable}
    from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient}
    from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRandomnessSource, IRandomnessReceiver} from "../interfaces/IRandomnessSource.sol";
import {ForgeMath} from "./lib/ForgeMath.sol";
import {EmbeddingStore} from "./EmbeddingStore.sol";

/// @title  ArdiNFTv4Testnet — Forge mechanic, standalone test deploy
/// @notice Minimal NFT contract for validating forge business logic on
///         Base Sepolia. Drops repair / inscribe / emission / wordbank
///         flows present in v322 — those are stubbed for testnet only.
///         The forge pathway is identical to what mainnet will use; only
///         storage layout differs (this is a fresh deploy, not a v322
///         upgrade).
///
///         For mainnet, a v322-storage-compatible v4 will be written
///         separately (the "surgical clone") preserving inheritance from
///         v3 → v32 → v322.
///
/// Lifecycle:
///   adminMint(holder, ...)  → seed test NFTs (testnet only)
///   forge(A, B, ...)         → cosine score, tier, VRF
///   _onForgeVRF              → success / fail
///   completeForge            → oracle delivers word, mint new NFT
///   adminRescueForge         → owner refund stuck forges
contract ArdiNFTv4Testnet is
    Initializable,
    ERC721Upgradeable,
    ERC721BurnableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IRandomnessReceiver
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // ─────────── Constants ───────────

    uint256 public constant ORIGINAL_CAP = 21_000;
    uint16 internal constant FORGE_BPS_DENOM = 10_000;
    uint8 internal constant DUR_CAP = 30;
    uint16 internal constant MYTHIC_BONUS_BPS = 12_000;
    uint8 internal constant ELEM_GOD = 6;

    // ─────────── Storage ───────────

    struct Inscription {
        string word;
        uint16 power;
        uint8 languageId;
        uint8 generation;
        address inscriber;
        uint64 mintTimestamp;
        uint8 element;
        uint8 maxDurability;
        uint8 currentDurability;
        uint64 lastDecayCheckpoint;
        bool broken;
        bool activeTracked;
        uint256[] parents;
    }

    mapping(uint256 => Inscription) public inscriptions;
    uint256 public fusionCount;            // forged NFT id offset

    IERC20 public ardi;                    // test aARDI
    address public treasury;
    EmbeddingStore public embeddingStore;
    IRandomnessSource public randomness;
    address public forgeOracle;

    uint256 public forgeBaseFee;
    uint16 public forgeBurnBps;            // bps of fee that goes to 0xdead

    mapping(uint256 => ForgeReq) public pendingForge;
    mapping(uint256 => uint256) public pendingForgeOf;       // tokenId → reqId
    mapping(bytes32 => bool) public wordExists;
    mapping(address => uint256) public forgeNonceOf;

    /// Last-minted "wordId" for forged NFTs. Used as the embedding-store key
    /// for forged words (originals use their wordbank id).
    uint16 public nextForgedWordId;        // starts at 21001, monotonic

    // ── Forged-NFT embedding storage (added 2026-05-07) ──
    //
    // EmbeddingStore is sealed at deploy time; we can't write to it for
    // newly-forged words. Store them locally so re-forging a forge product
    // (or two of them) can compute cosine on chain just like an original.

    /// tokenId (>= ORIGINAL_CAP+1) → wordId assigned at mint. Originals use
    /// implicit `wordId = tokenId - 1`, so this only stores the forged set.
    mapping(uint256 => uint16) public forgedTokenWordId;
    /// wordId (>= ORIGINAL_CAP+1) → 96-byte int8-quantized embedding.
    mapping(uint16 => bytes) public forgedEmbeddingByWordId;

    struct ForgeReq {
        uint8 tier;
        uint8 element;
        bool rolled;
        bool success;
        bool isCritical;
        bool isMythic;
        bool isGodTouch;
        uint32 multBps;       // widened to match ForgeMath fix (audit L-7)
        // Cached at request time so callbacks don't re-derive:
        address holder;
        uint256 tokenIdA;
        uint256 tokenIdB;
        uint256 paid;
    }

    // ─────────── Events ───────────

    event AdminMinted(address indexed holder, uint256 indexed tokenId, string word, uint16 power, uint8 element, uint8 maxDur);
    event ForgeRequested(address indexed holder, uint256 indexed reqId, uint256 tokenIdA, uint256 tokenIdB, uint8 tier, uint8 score);
    event ForgeRolled(uint256 indexed reqId, bool success, uint32 multBps, bool isCritical, bool isMythic, bool isGodTouch, uint8 element, uint256 burnedOnFail);
    event Forged(uint256 indexed reqId, address indexed holder, uint256 newTokenId, string newWord, uint16 newPower, uint8 newDur, uint8 element);
    event ForgeRescued(uint256 indexed reqId, address holder);
    event ForgeOracleSet(address oracle);
    event ForgeParamsSet(uint256 baseFee, uint16 burnBps);
    event EmbeddingStoreSet(address store);
    event RandomnessSet(address randomness);

    // ─────────── Errors ───────────

    error ZeroAddress();
    error SameTokenId();
    error NotTokenOwner();
    error AlreadyPending();
    error ForgeNotConfigured();
    error InvalidOracleSig();
    error ForgeNotPending();
    error NotRolledYet();
    error AlreadyRolled();
    error NotSuccessful();
    error WordCollision();
    error EmbeddingBadLength();
    error NotRandomness();

    // ─────────── Init ───────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address initialOwner,
        address ardi_,
        address treasury_,
        address forgeOracle_
    ) external initializer {
        if (initialOwner == address(0) || ardi_ == address(0) || treasury_ == address(0) || forgeOracle_ == address(0))
            revert ZeroAddress();
        __ERC721_init("ArdinalForgeTest", "ARDI4T");
        __ERC721Burnable_init();
        __Ownable_init(initialOwner);

        ardi = IERC20(ardi_);
        treasury = treasury_;
        forgeOracle = forgeOracle_;
        forgeBaseFee = 20_000 ether;       // 20K aARDI default
        forgeBurnBps = 10_000;             // 100% burn
        nextForgedWordId = uint16(ORIGINAL_CAP + 1);

        emit ForgeOracleSet(forgeOracle_);
        emit ForgeParamsSet(forgeBaseFee, forgeBurnBps);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─────────── Admin ───────────

    function setEmbeddingStore(address store) external onlyOwner {
        if (store == address(0)) revert ZeroAddress();
        require(EmbeddingStore(store).sealed_(), "store !sealed");
        embeddingStore = EmbeddingStore(store);
        emit EmbeddingStoreSet(store);
    }

    function setRandomness(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        randomness = IRandomnessSource(r);
        emit RandomnessSet(r);
    }

    function setForgeOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        forgeOracle = oracle;
        emit ForgeOracleSet(oracle);
    }

    function setForgeParams(uint256 baseFee, uint16 burnBps) external onlyOwner {
        require(burnBps <= FORGE_BPS_DENOM, "bps");
        forgeBaseFee = baseFee;
        forgeBurnBps = burnBps;
        emit ForgeParamsSet(baseFee, burnBps);
    }

    function migrateWordHashes(bytes32[] calldata hashes) external onlyOwner {
        for (uint256 i = 0; i < hashes.length; i++) {
            wordExists[hashes[i]] = true;
        }
    }

    /// @notice Testnet-only seeding entrypoint. Mints an NFT directly with
    ///         supplied stats. tokenId = wordId + 1 to mirror v3 semantics.
    function adminMint(
        address holder,
        uint16 wordId,
        string calldata word,
        uint16 power,
        uint8 element,
        uint8 maxDur,
        uint8 languageId
    ) external onlyOwner returns (uint256 tokenId) {
        require(wordId < ORIGINAL_CAP, "wordId range");
        require(power > 0 && power <= 100, "power range");
        require(maxDur > 0 && maxDur <= 14, "dur range");
        require(element >= 1 && element <= 6, "elem range");
        // wordExists check removed for adminMint — once 21K word hashes are
        // migrated for collision protection, that mapping is uniformly true,
        // so admin would be locked out. tokenId uniqueness (below) is a
        // sufficient guard against double-mint per wordId on testnet.
        tokenId = uint256(wordId) + 1;
        require(_ownerOf(tokenId) == address(0), "tokenId taken");

        Inscription storage ins = inscriptions[tokenId];
        ins.word = word;
        ins.power = power;
        ins.languageId = languageId;
        ins.generation = 0;
        ins.inscriber = holder;
        ins.mintTimestamp = uint64(block.timestamp);
        ins.element = element;
        ins.maxDurability = maxDur;
        ins.currentDurability = maxDur;
        ins.lastDecayCheckpoint = uint64(block.timestamp);
        ins.activeTracked = true;

        // Mark wordExists so completeForge LLM doesn't generate a colliding word.
        wordExists[keccak256(bytes(word))] = true;
        _safeMint(holder, tokenId);

        emit AdminMinted(holder, tokenId, word, power, element, maxDur);
    }

    // ─────────── forge() entry ───────────

    function forge(
        uint256 tokenIdA,
        uint256 tokenIdB,
        uint16 wordIdA,
        uint16 wordIdB,
        bytes calldata signature
    ) external nonReentrant returns (uint256 reqId) {
        if (address(embeddingStore) == address(0) || forgeBaseFee == 0
            || address(randomness) == address(0)) revert ForgeNotConfigured();
        if (tokenIdA == tokenIdB) revert SameTokenId();
        if (ownerOf(tokenIdA) != msg.sender) revert NotTokenOwner();
        if (ownerOf(tokenIdB) != msg.sender) revert NotTokenOwner();
        if (pendingForgeOf[tokenIdA] != 0 || pendingForgeOf[tokenIdB] != 0) revert AlreadyPending();

        uint256 _nonce = forgeNonceOf[msg.sender];
        bytes32 digest = keccak256(abi.encodePacked(
            "ARDI_FORGE_V4", block.chainid, address(this), msg.sender,
            tokenIdA, tokenIdB, wordIdA, wordIdB, _nonce
        )).toEthSignedMessageHash();
        if (digest.recover(signature) != forgeOracle) revert InvalidOracleSig();
        unchecked { forgeNonceOf[msg.sender] = _nonce + 1; }

        uint8 score = ForgeMath.cosineSimilarity(
            _resolveEmbedding(wordIdA),
            _resolveEmbedding(wordIdB)
        );
        ForgeMath.Tier tier = ForgeMath.matchScoreToTier(score);

        ardi.safeTransferFrom(msg.sender, address(this), forgeBaseFee);

        reqId = randomness.requestRandomness();
        pendingForgeOf[tokenIdA] = reqId;
        pendingForgeOf[tokenIdB] = reqId;
        ForgeReq storage f = pendingForge[reqId];
        f.tier = uint8(tier);
        f.holder = msg.sender;
        f.tokenIdA = tokenIdA;
        f.tokenIdB = tokenIdB;
        f.paid = forgeBaseFee;

        emit ForgeRequested(msg.sender, reqId, tokenIdA, tokenIdB, uint8(tier), score);
    }

    // ─────────── VRF callback ───────────

    function onRandomness(uint256 reqId, uint256 r) external override nonReentrant {
        if (msg.sender != address(randomness)) revert NotRandomness();
        ForgeReq storage f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        if (f.rolled) revert AlreadyRolled();

        ForgeMath.ForgeOutcome memory out = ForgeMath.deriveOutcome(ForgeMath.Tier(f.tier), r);

        f.rolled = true;
        f.success = out.success;
        f.multBps = out.multiplierBps;
        f.isCritical = out.isCritical;
        f.isMythic = out.isMythic;
        f.isGodTouch = out.isGodTouch;
        f.element = out.element;

        uint256 burnedOnFail;
        if (!out.success) {
            uint16 pA = inscriptions[f.tokenIdA].power;
            uint16 pB = inscriptions[f.tokenIdB].power;
            uint256 burnId = pA < pB ? f.tokenIdA
                : pB < pA ? f.tokenIdB
                : (f.tokenIdA < f.tokenIdB ? f.tokenIdA : f.tokenIdB);
            burnedOnFail = burnId;
            uint256 survId = burnId == f.tokenIdA ? f.tokenIdB : f.tokenIdA;

            _burn(burnId);
            delete pendingForgeOf[burnId];
            delete pendingForgeOf[survId];

            _flushSinkForge(f.paid);
            uint256 paidTmp = f.paid;
            delete pendingForge[reqId];

            emit ForgeRolled(reqId, false, out.multiplierBps, false, false, false, 0, burnedOnFail);
            paidTmp; // silence unused
            return;
        }

        emit ForgeRolled(reqId, true, out.multiplierBps,
            out.isCritical, out.isMythic, out.isGodTouch, out.element, 0);
    }

    // ─────────── completeForge ───────────

    function completeForge(
        uint256 reqId,
        string calldata newWord,
        bytes calldata embedding,
        bytes calldata oracleSig
    ) external nonReentrant {
        ForgeReq memory f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        if (!f.rolled) revert NotRolledYet();
        if (!f.success) revert NotSuccessful();
        if (embedding.length != 96) revert EmbeddingBadLength();

        bytes32 digest = keccak256(abi.encodePacked(
            "ARDI_FORGE_COMPLETE_V4", block.chainid, address(this),
            reqId, bytes(newWord), embedding
        )).toEthSignedMessageHash();
        if (digest.recover(oracleSig) != forgeOracle) revert InvalidOracleSig();

        bytes32 wh = keccak256(bytes(newWord));
        if (wordExists[wh]) revert WordCollision();
        wordExists[wh] = true;

        _settleSuccess(reqId, f, newWord, embedding);
    }

    function _settleSuccess(
        uint256 reqId,
        ForgeReq memory f,
        string memory newWord,
        bytes calldata embedding
    ) internal {
        Inscription storage inA = inscriptions[f.tokenIdA];
        Inscription storage inB = inscriptions[f.tokenIdB];

        uint256 newPower = (uint256(inA.power) + uint256(inB.power)) * f.multBps / FORGE_BPS_DENOM;
        if (f.isMythic) newPower = newPower * MYTHIC_BONUS_BPS / FORGE_BPS_DENOM;
        require(newPower <= type(uint16).max, "pow ovf");

        uint16 sumDur = uint16(inA.maxDurability) + uint16(inB.maxDurability);
        uint8 newDur = sumDur > DUR_CAP ? DUR_CAP : uint8(sumDur);
        if (newDur == 0) newDur = 1;

        uint8 newGen = (inA.generation > inB.generation ? inA.generation : inB.generation) + 1;
        address holder = f.holder;

        _burn(f.tokenIdA);
        _burn(f.tokenIdB);

        unchecked { ++fusionCount; }
        uint256 newTokenId = ORIGINAL_CAP + fusionCount;
        uint256[] memory parents = new uint256[](2);
        parents[0] = f.tokenIdA;
        parents[1] = f.tokenIdB;

        Inscription storage ins = inscriptions[newTokenId];
        ins.word = newWord;
        ins.power = uint16(newPower);
        ins.generation = newGen;
        ins.inscriber = holder;
        ins.mintTimestamp = uint64(block.timestamp);
        ins.element = f.element;
        ins.maxDurability = newDur;
        ins.currentDurability = newDur;
        ins.lastDecayCheckpoint = uint64(block.timestamp);
        ins.activeTracked = true;
        ins.parents = parents;

        // Assign + persist a wordId for this forged token, plus its
        // embedding. EmbeddingStore is sealed; we keep a parallel local
        // map so re-forging forge products works without an upgrade to
        // the store contract.
        uint16 newWid;
        unchecked { newWid = nextForgedWordId++; }
        require(newWid >= uint16(ORIGINAL_CAP) + 1, "wid range");
        forgedTokenWordId[newTokenId] = newWid;
        // Copy calldata bytes into storage. Solidity 0.8 supports direct
        // assignment from calldata bytes to storage mapping.
        forgedEmbeddingByWordId[newWid] = embedding;

        delete pendingForgeOf[f.tokenIdA];
        delete pendingForgeOf[f.tokenIdB];
        delete pendingForge[reqId];

        _safeMint(holder, newTokenId);
        _flushSinkForge(f.paid);

        emit Forged(reqId, holder, newTokenId, newWord, uint16(newPower), newDur, f.element);
    }

    function adminRescueForge(uint256 reqId) external onlyOwner nonReentrant {
        ForgeReq memory f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        if (!f.rolled || !f.success) revert NotSuccessful();
        delete pendingForgeOf[f.tokenIdA];
        delete pendingForgeOf[f.tokenIdB];
        delete pendingForge[reqId];
        if (f.paid > 0) ardi.safeTransfer(f.holder, f.paid);
        emit ForgeRescued(reqId, f.holder);
    }

    /// Read the 96-byte int8 embedding for a wordId from whichever store
    /// holds it. Originals (wordId < ORIGINAL_CAP+1) live in the sealed
    /// EmbeddingStore; forged words live in this contract's local map.
    function _resolveEmbedding(uint16 wordId) internal view returns (bytes memory) {
        if (uint256(wordId) <= ORIGINAL_CAP) {
            return embeddingStore.embeddings(wordId);
        }
        bytes memory e = forgedEmbeddingByWordId[wordId];
        require(e.length == 96, "no forged emb");
        return e;
    }

    /// Public helper for off-chain (oracle, UI) to resolve a tokenId to
    /// its wordId without keeping a duplicate map. Originals: implicit
    /// `wordId = tokenId - 1`. Forged: stored at mint time.
    function wordIdOf(uint256 tokenId) external view returns (uint16) {
        if (tokenId <= ORIGINAL_CAP) return uint16(tokenId - 1);
        uint16 wid = forgedTokenWordId[tokenId];
        require(wid != 0, "unknown tokenId");
        return wid;
    }

    function _flushSinkForge(uint256 amount) internal {
        if (amount == 0) return;
        uint256 burnAmt = amount * forgeBurnBps / FORGE_BPS_DENOM;
        if (burnAmt > 0) ardi.safeTransfer(address(0xdead), burnAmt);
        uint256 rest = amount - burnAmt;
        if (rest > 0) ardi.safeTransfer(treasury, rest);
    }

    // Lock NFTs against transfer while a forge is in flight.
    function _update(address to, uint256 tokenId, address auth)
        internal override(ERC721Upgradeable) returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && from != to) {
            if (pendingForgeOf[tokenId] != 0) revert AlreadyPending();
        }
        return super._update(to, tokenId, auth);
    }

    function getInscription(uint256 tokenId) external view returns (Inscription memory) {
        require(_ownerOf(tokenId) != address(0) || inscriptions[tokenId].mintTimestamp > 0, "no token");
        return inscriptions[tokenId];
    }
}
