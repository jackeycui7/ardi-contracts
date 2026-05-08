// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {EmbeddingStore} from "./EmbeddingStore.sol";
import {ForgeMath} from "./lib/ForgeMath.sol";
import {IRandomnessSource, IRandomnessReceiver} from "../interfaces/IRandomnessSource.sol";
import {IEmissionDistributor} from "../v3/interfaces/IEmissionDistributor.sol";

/// @notice Minimal interface to ArdiNFTv4Mainnet — just the admin entry
///         points + a couple of reads needed for forge.
interface IArdiNFTv4Mainnet {
    function ownerOf(uint256 tokenId) external view returns (address);
    function inscriptions(uint256 tokenId) external view returns (
        string memory word, uint16 power, uint8 languageId, uint8 generation,
        address inscriber, uint64 mintTimestamp, uint8 element,
        uint8 maxDurability, uint8 currentDurability, uint64 lastDecayCheckpoint,
        bool broken, bool activeTracked
    );
    function adminBurnPair(uint256 tokenIdA, uint256 tokenIdB, address holder) external;
    function adminMintForged(
        address holder,
        uint256[2] calldata parents,
        string calldata word,
        uint16 power,
        uint8 dur,
        uint8 element,
        bytes calldata embedding
    ) external returns (uint256);
    function forgedEmbeddingByWordId(uint16 wid) external view returns (bytes memory);
}

/// @title  ArdiForgeModule — privileged forge logic for ArdiNFTv4Mainnet.
/// @notice All forge mechanics live here. Calls back into the NFT
///         contract via two admin entry points (adminBurnPair,
///         adminMintForged). Owns its own VRF receiver hook + LLM oracle
///         signature verifier + dynamic fee math.
contract ArdiForgeModule is Ownable, ReentrancyGuardTransient, IRandomnessReceiver {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // ─────────────── Constants ───────────────

    uint16 internal constant FORGE_BPS_DENOM = 10_000;
    uint8  internal constant DUR_CAP = 30;
    uint16 internal constant MYTHIC_BONUS_BPS = 12_000;  // 1.2× power
    uint8  internal constant ELEM_GOD = 6;
    uint256 internal constant ORIGINAL_CAP = 21_000;

    // ─────────────── Wires ───────────────

    IArdiNFTv4Mainnet public nft;
    IERC20 public ardi;
    EmbeddingStore public embeddingStore;
    IRandomnessSource public randomness;
    IEmissionDistributor public emissionDist;
    address public oracle;
    address public treasury;

    // ─────────────── Tunable params ───────────────

    /// @notice forgeFee = K * dailyEmissionWei * (Pa+Pb) / totalActivePower
    uint16  public forgeFeeK;        // 7 → "7 days of yield" per sky 2026-05-08
    uint256 public dailyEmissionWei; // 24M ether mainnet
    uint16  public forgeBurnBps;     // 10000 = 100% burn, treasury takes the rest

    // ─────────────── State ───────────────

    struct ForgeReq {
        uint8   tier;
        uint8   element;
        bool    rolled;
        bool    success;
        bool    isCritical;
        bool    isMythic;
        bool    isGodTouch;
        uint32  multBps;       // post-crit ≤ 110000 for T1, fits uint32
        address holder;
        uint256 tokenIdA;
        uint256 tokenIdB;
        uint256 paid;
    }

    mapping(uint256 => ForgeReq) public pendingForge;
    mapping(uint256 => uint256) public pendingForgeOf;     // tokenId → reqId lock
    mapping(address => uint256) public forgeNonceOf;       // holder → next nonce

    // ─────────────── Events ───────────────

    event ConfigSet(
        address nft, address ardi, address embeddingStore,
        address randomness, address emissionDist,
        address oracle, address treasury,
        uint16 feeK, uint256 dailyEmissionWei, uint16 burnBps
    );
    event ForgeRequested(
        address indexed holder,
        uint256 indexed reqId,
        uint256 tokenIdA,
        uint256 tokenIdB,
        uint8 tier,
        uint8 score,
        uint256 fee
    );
    event ForgeRolled(
        uint256 indexed reqId,
        bool success,
        uint32 multBps,
        bool isCritical,
        bool isMythic,
        bool isGodTouch,
        uint8 element,
        uint256 burnedOnFail
    );
    event Forged(
        uint256 indexed reqId,
        address indexed holder,
        uint256 newTokenId,
        string newWord,
        uint16 newPower,
        uint8 newDur,
        uint8 element
    );
    event ForgeCancelled(uint256 indexed reqId, address indexed holder);

    // ─────────────── Errors ───────────────

    error ForgeNotConfigured();
    error SameTokenId();
    error NotTokenOwner();
    error AlreadyPending();
    error InvalidOracleSig();
    error ForgeNotPending();
    error AlreadyRolled();
    error NotSucceeded();
    error EmbeddingLengthBad();
    error WordTooLong();
    error FeeFormulaUnready();
    error NotRandomness();

    constructor(address _owner) Ownable(_owner) {}

    // ─────────────── Owner setup ───────────────

    function setConfig(
        address _nft,
        address _ardi,
        address _embeddingStore,
        address _randomness,
        address _emissionDist,
        address _oracle,
        address _treasury,
        uint16  _feeK,
        uint256 _dailyEmissionWei,
        uint16  _burnBps
    ) external onlyOwner {
        require(_burnBps <= FORGE_BPS_DENOM, "burn bps");
        nft = IArdiNFTv4Mainnet(_nft);
        ardi = IERC20(_ardi);
        embeddingStore = EmbeddingStore(_embeddingStore);
        randomness = IRandomnessSource(_randomness);
        emissionDist = IEmissionDistributor(_emissionDist);
        oracle = _oracle;
        treasury = _treasury;
        forgeFeeK = _feeK;
        dailyEmissionWei = _dailyEmissionWei;
        forgeBurnBps = _burnBps;
        emit ConfigSet(
            _nft, _ardi, _embeddingStore, _randomness, _emissionDist,
            _oracle, _treasury, _feeK, _dailyEmissionWei, _burnBps
        );
    }

    // ─────────────── Read helpers ───────────────

    /// @notice Live forge fee for the given pair.
    function quoteForgeFee(uint256 tokenIdA, uint256 tokenIdB) public view returns (uint256) {
        if (forgeFeeK == 0 || dailyEmissionWei == 0) revert FeeFormulaUnready();
        uint256 totalPow = emissionDist.totalActivePower();
        if (totalPow == 0) revert FeeFormulaUnready();
        (, uint16 powA, , , , , , , , , , ) = nft.inscriptions(tokenIdA);
        (, uint16 powB, , , , , , , , , , ) = nft.inscriptions(tokenIdB);
        uint256 sumPow = uint256(powA) + uint256(powB);
        return (uint256(forgeFeeK) * dailyEmissionWei * sumPow) / totalPow;
    }

    function _resolveEmbedding(uint16 wid) internal view returns (bytes memory) {
        if (wid <= ORIGINAL_CAP - 1) {
            return embeddingStore.embeddings(wid);
        }
        bytes memory emb = nft.forgedEmbeddingByWordId(wid);
        require(emb.length == 96, "no forged emb");
        return emb;
    }

    // ─────────────── forge() ───────────────

    function forge(
        uint256 tokenIdA,
        uint256 tokenIdB,
        uint16 wordIdA,
        uint16 wordIdB,
        bytes calldata signature
    ) external nonReentrant returns (uint256 reqId) {
        if (address(nft) == address(0) || forgeFeeK == 0
            || address(randomness) == address(0) || oracle == address(0)) {
            revert ForgeNotConfigured();
        }
        if (tokenIdA == tokenIdB) revert SameTokenId();
        if (nft.ownerOf(tokenIdA) != msg.sender) revert NotTokenOwner();
        if (nft.ownerOf(tokenIdB) != msg.sender) revert NotTokenOwner();
        if (pendingForgeOf[tokenIdA] != 0 || pendingForgeOf[tokenIdB] != 0) revert AlreadyPending();

        uint256 _nonce = forgeNonceOf[msg.sender];
        bytes32 digest = keccak256(abi.encodePacked(
            "ARDI_FORGE_V4", block.chainid, address(this), msg.sender,
            tokenIdA, tokenIdB, wordIdA, wordIdB, _nonce
        )).toEthSignedMessageHash();
        if (digest.recover(signature) != oracle) revert InvalidOracleSig();
        unchecked { forgeNonceOf[msg.sender] = _nonce + 1; }

        uint8 score = ForgeMath.cosineSimilarity(
            _resolveEmbedding(wordIdA),
            _resolveEmbedding(wordIdB)
        );
        ForgeMath.Tier tier = ForgeMath.matchScoreToTier(score);

        uint256 fee = quoteForgeFee(tokenIdA, tokenIdB);
        ardi.safeTransferFrom(msg.sender, address(this), fee);

        reqId = randomness.requestRandomness();
        pendingForgeOf[tokenIdA] = reqId;
        pendingForgeOf[tokenIdB] = reqId;

        ForgeReq storage f = pendingForge[reqId];
        f.tier      = uint8(tier);
        f.holder    = msg.sender;
        f.tokenIdA  = tokenIdA;
        f.tokenIdB  = tokenIdB;
        f.paid      = fee;

        emit ForgeRequested(msg.sender, reqId, tokenIdA, tokenIdB, uint8(tier), score, fee);
    }

    // ─────────────── VRF callback ───────────────

    function onRandomness(uint256 reqId, uint256 r) external override nonReentrant {
        if (msg.sender != address(randomness)) revert NotRandomness();
        ForgeReq storage f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        if (f.rolled) revert AlreadyRolled();

        ForgeMath.ForgeOutcome memory out = ForgeMath.deriveOutcome(ForgeMath.Tier(f.tier), r);
        f.rolled     = true;
        f.success    = out.success;
        f.multBps    = out.multiplierBps;
        f.isCritical = out.isCritical;
        f.isMythic   = out.isMythic;
        f.isGodTouch = out.isGodTouch;
        f.element    = out.element;

        uint256 burnedOnFail = 0;
        if (!out.success) {
            (, uint16 pA, , , , , , , , , , ) = nft.inscriptions(f.tokenIdA);
            (, uint16 pB, , , , , , , , , , ) = nft.inscriptions(f.tokenIdB);
            uint256 burnId = pA < pB ? f.tokenIdA
                : pB < pA ? f.tokenIdB
                : (f.tokenIdA < f.tokenIdB ? f.tokenIdA : f.tokenIdB);
            burnedOnFail = burnId;
            nft.adminBurnPair(burnId, 0, f.holder);
            delete pendingForgeOf[f.tokenIdA];
            delete pendingForgeOf[f.tokenIdB];
            _flushSink(f.paid);
            f.paid = 0;
        }

        emit ForgeRolled(
            reqId, out.success, out.multiplierBps,
            out.isCritical, out.isMythic, out.isGodTouch,
            out.element, burnedOnFail
        );
    }

    // ─────────────── completeForge ───────────────

    function completeForge(
        uint256 reqId,
        string calldata newWord,
        bytes calldata embedding,
        bytes calldata oracleSig
    ) external nonReentrant {
        ForgeReq storage f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        if (!f.rolled || !f.success) revert NotSucceeded();
        if (embedding.length != 96) revert EmbeddingLengthBad();
        if (bytes(newWord).length == 0 || bytes(newWord).length > 64) revert WordTooLong();

        bytes32 digest = keccak256(abi.encodePacked(
            "ARDI_FORGE_COMPLETE_V4", block.chainid, address(this),
            reqId, newWord, embedding
        )).toEthSignedMessageHash();
        if (digest.recover(oracleSig) != oracle) revert InvalidOracleSig();

        // Read parent stats once for the derivation.
        (, uint16 pA, , , , , , uint8 mdA, , , , ) = nft.inscriptions(f.tokenIdA);
        (, uint16 pB, , , , , , uint8 mdB, , , , ) = nft.inscriptions(f.tokenIdB);

        uint256 newPower = (uint256(pA) + uint256(pB)) * f.multBps / FORGE_BPS_DENOM;
        if (f.isMythic) newPower = newPower * MYTHIC_BONUS_BPS / FORGE_BPS_DENOM;
        if (newPower > type(uint16).max) newPower = type(uint16).max;

        uint16 sumDur = uint16(mdA) + uint16(mdB);
        uint8 newDur = sumDur > DUR_CAP ? DUR_CAP : uint8(sumDur);
        if (newDur == 0) newDur = 1;

        // Burn both inputs first, then mint output. Order matters so the
        // EmissionDistributor sees the deactivations before the new mint.
        nft.adminBurnPair(f.tokenIdA, f.tokenIdB, f.holder);
        delete pendingForgeOf[f.tokenIdA];
        delete pendingForgeOf[f.tokenIdB];

        uint256[2] memory parents;
        parents[0] = f.tokenIdA;
        parents[1] = f.tokenIdB;
        uint256 newTokenId = nft.adminMintForged(
            f.holder, parents, newWord, uint16(newPower), newDur, f.element, embedding
        );

        _flushSink(f.paid);
        f.paid = 0;

        emit Forged(reqId, f.holder, newTokenId, newWord, uint16(newPower), newDur, f.element);
    }

    // ─────────────── adminCancelForge — escape hatch ───────────────

    /// @notice Owner-only escape hatch for stuck forges. Refunds the
    ///         escrowed fee to the holder and unlocks both NFTs (which
    ///         are still owned by the holder, just locked via
    ///         pendingForgeOf). Use only when:
    ///           - VRF subscription drained / adapter dead and won't fulfil
    ///           - Oracle key lost / completeForge unreachable on success roll
    ///           - reqId stuck for more than ~24h with no fulfilment
    ///         Owner is trusted not to yank legitimate in-flight forges.
    /// @dev    Idempotent — safe to call twice (second call no-op since
    ///         pendingForge[reqId] cleared).
    function adminCancelForge(uint256 reqId) external onlyOwner nonReentrant {
        ForgeReq storage f = pendingForge[reqId];
        if (f.holder == address(0)) revert ForgeNotPending();
        // Refund escrowed fee (if any still held).
        if (f.paid > 0) {
            ardi.safeTransfer(f.holder, f.paid);
            f.paid = 0;
        }
        // Unlock NFTs. Tokens themselves are unaffected — holder still owns them.
        delete pendingForgeOf[f.tokenIdA];
        delete pendingForgeOf[f.tokenIdB];
        delete pendingForge[reqId];
        emit ForgeCancelled(reqId, f.holder);
    }

    // ─────────────── Sink ───────────────

    function _flushSink(uint256 amount) internal {
        if (amount == 0) return;
        uint256 burnAmt = amount * uint256(forgeBurnBps) / FORGE_BPS_DENOM;
        uint256 rest = amount - burnAmt;
        if (burnAmt > 0) ardi.safeTransfer(address(0xdead), burnAmt);
        if (rest > 0 && treasury != address(0)) ardi.safeTransfer(treasury, rest);
    }
}
