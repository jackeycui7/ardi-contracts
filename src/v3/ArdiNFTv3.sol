// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRandomnessSource, IRandomnessReceiver} from "../interfaces/IRandomnessSource.sol";
import {IArdiEpochDrawV3} from "./interfaces/IArdiEpochDrawV3.sol";
import {IEmissionDistributor} from "./interfaces/IEmissionDistributor.sol";

/// @title  ArdiNFT v3 — Power + Durability + Element edition.
/// @notice Originals (tokenId = wordId+1, 1..21000), fusion products (>21000).
///         Each NFT has Power (1-100, mint-time VRF-picked off chain via vault leaf),
///         maxDurability (1-14 weighted, same), Element (1-5: metal/wood/water/fire/earth).
///         Durability decays 1/day; repair restores it but rolls a 1% failure via VRF.
///         Failed repair → broken; broken NFT can only be revived by fuse.
///
/// Lifecycle:
///   inscribe         → activate (joins emission pool)
///   decay+repair OK  → stays active, durability refreshed
///   decay+repair FAIL → broken=true, deactivate, requires fuse to revive
///   durability hits 0 (no repair) → expireToZero(): deactivate (anyone may call, 50 ardi keeper bounty)
///   fuse success     → burn 2, mint 1 (fresh durability)
///   fuse fail        → burn lower-power
contract ArdiNFTv3 is
    Initializable,
    ERC721Upgradeable,
    ERC721BurnableUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IRandomnessReceiver
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // =============================== Constants =================================

    uint256 public constant ORIGINAL_CAP = 21_000;
    // 2026-05-03: bumped from 3 → 5 for the production deploy. Mirrors
    // ArdiEpochDrawV3.MAX_WINS_PER_AGENT (also 5). Constant — needs
    // a redeploy if this changes again.
    uint8 public constant MAX_MINTS_PER_AGENT = 5;
    uint8 public constant LANG_DE = 5;
    // v3.1: 1..6 (5 五行 + 6=god for 22 hand-picked legendary entries in
    // Leslie's wordbank — bitcoin/ethereum/satoshi/etc). Was 5 in v3.0; the
    // bump must ship together with ArdiEpochDrawV3 v3.1 which raised its own
    // element validation from 5 to 6 — otherwise winners of god-tier words
    // pass publishAnswer but revert at inscribe time.
    uint8 public constant ELEMENT_MAX = 6;

    /// @notice 1% repair-failure threshold. randomness % 100 < this → fail.
    uint256 public constant REPAIR_FAIL_BPS = 100; // out of 10_000
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice VRF stale timeout: keeper-callable forceFailStaleRepair only
    ///         fires after this. Bumped from 1h to 6h (H-2): on Base during
    ///         Chainlink incidents 1h was within normal jitter and would
    ///         cause legit repairs to be force-broken by keepers.
    uint256 public constant REPAIR_STALE_AFTER = 6 hours;
    /// @notice After this, even the holder gives up on the request and may
    ///         cancel themselves to recover the fee. Always longer than
    ///         REPAIR_STALE_AFTER so keepers get first crack at the bounty.
    uint256 public constant REPAIR_HOLDER_CANCEL_AFTER = 12 hours;

    /// @notice Keeper bounty paid out of treasury for clean-up calls
    ///         (forceFailStaleRepair, expireToZero). Q4/Q11 default 50 $ardi.
    uint256 public constant KEEPER_BOUNTY = 50 ether;

    // =============================== Storage =================================

    struct Inscription {
        string word;
        uint16 power; // 1-100 originals; up to ~10000 after fusion compounding
        uint8 languageId; // 0..5
        uint8 generation; // 0 = original
        address inscriber;
        uint64 mintTimestamp;
        uint8 element; // 1..5; 0 invalid
        uint8 maxDurability; // 1..14
        uint8 currentDurability;
        uint64 lastDecayCheckpoint;
        bool broken;
        bool activeTracked; // mirrored to EmissionDistributor active set
        uint256[] parents;
    }

    mapping(uint256 => Inscription) public inscriptions;
    mapping(uint256 => bool) public wordMinted;
    mapping(address => uint8) public agentMintCount;
    uint256 public totalInscribed;
    uint256 public fusionCount;
    bool public isSealed;
    bytes32 public vaultMerkleRoot;

    address public coordinator;
    mapping(address => uint256) public fusionNonceOf;
    IArdiEpochDrawV3 public epochDraw;
    IEmissionDistributor public emissionDist;

    // --- VRF + repair state ---

    IRandomnessSource public randomness;

    enum ReqKind {
        None,
        Repair,
        Fuse
    }

    struct PendingRequest {
        ReqKind kind;
        uint256 tokenId; // for repair = the NFT being repaired
        uint256 tokenIdB; // for fuse = second NFT
        address holder; // who initiated, for callback validation
        uint64 requestedAt;
        // Fuse-only payload, locked at request time so coordinator signed
        // intent can't be swapped by a re-request:
        string newWord;
        uint16 newPower;
        uint8 newLangId;
        uint8 newElement;
        // Repair-only:
        uint256 paid; // ardi paid into the contract (refunded on stale-fail bounty)
    }

    mapping(uint256 => PendingRequest) public pending; // requestId -> request
    /// @notice tokenId -> requestId of in-flight repair, 0 if none.
    mapping(uint256 => uint256) public pendingRepairOf;
    /// @notice tokenId -> requestId of in-flight fuse (locks both sides), 0 if none.
    mapping(uint256 => uint256) public pendingFuseOf;
    /// @notice (H-8) Outstanding VRF requests blocking adapter swap.
    ///         Mirrors EpochDraw's H-3 mitigation: `setRandomness` would
    ///         orphan in-flight requests' callbacks (msg.sender check would
    ///         start failing under the new adapter address), so we refuse
    ///         the swap until in-flight count drains to zero.
    uint256 public pendingRequestsCount;

    // --- Sink params (Q5: static, Timelock-set) ---

    /// @notice $ardi token (AWP WorknetToken). Used for repair fees, treasury, keeper bounty.
    IERC20 public ardi;
    /// @notice Treasury holds repair sink + funds keeper bounties + fuse fee share.
    address public treasury;

    /// @notice Per-power per-durability-day base price for repair, in $ardi wei.
    ///         repairFee = repairBaseUnitPrice × power × maxDurability.
    uint256 public repairBaseUnitPrice;
    /// @notice Repair sink burn share (rest to treasury). bps of 10_000.
    uint16 public repairBurnBps;

    /// @notice Base fuse fee in $ardi wei (Q14: same for fresh + broken).
    uint256 public fuseBaseFee;
    /// @notice Fuse sink burn share. bps of 10_000.
    uint16 public fuseBurnBps;

    // =============================== Events =================================

    event Inscribed(
        address indexed agent,
        uint256 indexed tokenId,
        uint256 indexed wordId,
        string word,
        uint16 power,
        uint8 languageId,
        uint8 element,
        uint8 maxDurability
    );
    event RepairRequested(
        uint256 indexed tokenId, address indexed holder, uint256 requestId, uint256 fee
    );
    event RepairFulfilled(uint256 indexed tokenId, uint256 requestId, bool failed);
    event RepairForceFailed(uint256 indexed tokenId, uint256 requestId, address keeper);
    event RepairCancelled(uint256 indexed tokenId, uint256 requestId, address holder);
    event FuseCancelled(
        uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 requestId, address holder
    );
    event FuseForceFailed(
        uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 requestId, address keeper
    );
    event KeeperBountyUnpaid(address indexed keeper, uint256 amount);
    event FuseRequested(
        address indexed holder,
        uint256 indexed tokenIdA,
        uint256 indexed tokenIdB,
        uint256 requestId
    );
    event Fused(
        address indexed holder,
        uint256 tokenIdA,
        uint256 tokenIdB,
        uint256 newTokenId,
        string newWord,
        uint16 newPower,
        uint8 newLangId,
        uint8 newElement,
        uint8 generation
    );
    event FusionFailed(address indexed holder, uint256 tokenIdA, uint256 tokenIdB, uint256 burnedId);
    event Expired(uint256 indexed tokenId, address keeper);
    event Sealed(uint256 timestamp);
    event CoordinatorSet(address indexed coordinator);
    event EpochDrawSet(address indexed epochDraw);
    event EmissionDistributorSet(address indexed dist);
    event RandomnessSet(address indexed randomness);
    event SinkParamsUpdated(
        uint256 repairBaseUnitPrice, uint16 repairBurnBps, uint256 fuseBaseFee, uint16 fuseBurnBps
    );
    event TreasurySet(address indexed treasury);

    // =============================== Errors =================================

    error AlreadySealed();
    error AgentCapReached();
    error WordAlreadyMinted();
    error InvalidLanguage();
    error InvalidElement();
    error InvalidWordId();
    error NotTokenOwner();
    error SameTokenId();
    error InvalidPower();
    error InvalidDurability();
    error ZeroAddress();
    error NotWinner();
    error AnswerNotPublished();
    error EpochDrawNotSet();
    error WordMismatch();
    error Broken();
    error NotBroken();
    error AlreadyRepairing();
    error AlreadyFusing();
    error NoPendingRequest();
    error NotStale();
    error NotZero();
    error NotRandomness();
    error InvalidSignature();
    error InsufficientPayment();
    error PendingRequestsExist();
    error NotSelf();
    error TokenLocked();

    // =============================== Init =================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address coordinator_,
        bytes32 vaultMerkleRoot_,
        address ardi_,
        address treasury_
    ) external initializer {
        if (
            initialOwner == address(0) || coordinator_ == address(0) || ardi_ == address(0)
                || treasury_ == address(0)
        ) revert ZeroAddress();
        __ERC721_init("Ardinal", "ARDI");
        __ERC721Burnable_init();
        __Ownable_init(initialOwner);
        __Pausable_init();

        coordinator = coordinator_;
        vaultMerkleRoot = vaultMerkleRoot_;
        ardi = IERC20(ardi_);
        treasury = treasury_;
        // Q5: placeholder unit price. Timelock will reset post-deploy.
        repairBaseUnitPrice = 1000;
        repairBurnBps = 5_000; // 50/50 burn/treasury
        fuseBaseFee = 20_000 ether;
        fuseBurnBps = 5_000;

        emit CoordinatorSet(coordinator_);
        emit TreasurySet(treasury_);
        emit SinkParamsUpdated(repairBaseUnitPrice, repairBurnBps, fuseBaseFee, fuseBurnBps);
    }

    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}

    // =============================== Admin =================================

    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    function setEpochDraw(address epochDraw_) external onlyOwner {
        if (epochDraw_ == address(0)) revert ZeroAddress();
        epochDraw = IArdiEpochDrawV3(epochDraw_);
        emit EpochDrawSet(epochDraw_);
    }

    function setEmissionDistributor(address d) external onlyOwner {
        if (d == address(0)) revert ZeroAddress();
        emissionDist = IEmissionDistributor(d);
        emit EmissionDistributorSet(d);
    }

    function setRandomness(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        // H-8: refuse adapter swap while requests are mid-flight, otherwise
        // their callbacks orphan (the new adapter's address won't pass the
        // `msg.sender == randomness` check the old reqId expects).
        if (pendingRequestsCount > 0) revert PendingRequestsExist();
        randomness = IRandomnessSource(r);
        emit RandomnessSet(r);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function setSinkParams(
        uint256 repairBaseUnitPrice_,
        uint16 repairBurnBps_,
        uint256 fuseBaseFee_,
        uint16 fuseBurnBps_
    ) external onlyOwner {
        require(repairBurnBps_ <= BPS_DENOM && fuseBurnBps_ <= BPS_DENOM, "bps");
        repairBaseUnitPrice = repairBaseUnitPrice_;
        repairBurnBps = repairBurnBps_;
        fuseBaseFee = fuseBaseFee_;
        fuseBurnBps = fuseBurnBps_;
        emit SinkParamsUpdated(repairBaseUnitPrice_, repairBurnBps_, fuseBaseFee_, fuseBurnBps_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================== Inscribe =================================

    function inscribe(uint64 epochId, uint256 wordId, string calldata word)
        external
        whenNotPaused
        nonReentrant
    {
        if (address(epochDraw) == address(0)) revert EpochDrawNotSet();
        if (isSealed) revert AlreadySealed();
        if (agentMintCount[msg.sender] >= MAX_MINTS_PER_AGENT) revert AgentCapReached();
        if (wordMinted[wordId]) revert WordAlreadyMinted();
        if (wordId >= ORIGINAL_CAP) revert InvalidWordId();
        if (epochDraw.winners(epochId, wordId) != msg.sender) revert NotWinner();

        (
            bytes32 wordHash,
            uint16 power,
            uint8 languageId,
            uint8 maxDurability,
            uint8 element,
            bool published
        ) = epochDraw.getAnswer(epochId, wordId);
        if (!published) revert AnswerNotPublished();
        if (keccak256(bytes(word)) != wordHash) revert WordMismatch();
        if (languageId > LANG_DE) revert InvalidLanguage();
        if (power == 0 || power > 100) revert InvalidPower();
        if (maxDurability == 0 || maxDurability > 14) revert InvalidDurability();
        if (element == 0 || element > ELEMENT_MAX) revert InvalidElement();

        wordMinted[wordId] = true;
        unchecked {
            ++agentMintCount[msg.sender];
            ++totalInscribed;
        }
        uint256 tokenId = wordId + 1;

        Inscription storage ins = inscriptions[tokenId];
        ins.word = word;
        ins.power = power;
        ins.languageId = languageId;
        ins.generation = 0;
        ins.inscriber = msg.sender;
        ins.mintTimestamp = uint64(block.timestamp);
        ins.element = element;
        ins.maxDurability = maxDurability;
        ins.currentDurability = maxDurability;
        ins.lastDecayCheckpoint = uint64(block.timestamp);
        // broken=false, activeTracked set below by _activate

        _safeMint(msg.sender, tokenId);
        _activate(tokenId, msg.sender);

        emit Inscribed(msg.sender, tokenId, wordId, word, power, languageId, element, maxDurability);

        if (totalInscribed >= ORIGINAL_CAP) {
            isSealed = true;
            emit Sealed(block.timestamp);
        }
    }

    // =============================== Repair =================================

    /// @notice Compute the current effective durability accounting for unsynced decay.
    function effectiveDurability(uint256 tokenId) public view virtual returns (uint8) {
        Inscription storage ins = inscriptions[tokenId];
        if (ins.broken) return 0;
        uint256 elapsed = block.timestamp - ins.lastDecayCheckpoint;
        uint256 daysGone = elapsed / 1 days;
        if (daysGone >= ins.currentDurability) return 0;
        return uint8(ins.currentDurability - daysGone);
    }

    /// @notice v3.2.1 hook: subclass can require-revert to gate `repair()`
    ///         on additional preconditions (e.g. effectiveDurability == 0).
    ///         Default no-op preserves v3 behavior.
    function _beforeRepair(uint256 /* tokenId */) internal virtual {}

    function repairFee(uint256 tokenId) public view virtual returns (uint256) {
        Inscription storage ins = inscriptions[tokenId];
        return repairBaseUnitPrice * ins.power * ins.maxDurability;
    }

    /// @notice Pay repair fee + request VRF. NFT stays in active set (durability
    ///         restored optimistically); on failure callback we deactivate +
    ///         flag broken. The async VRF shape is what blocks the
    ///         "call repair, revert if broken" attack: the caller cannot know
    ///         the result in the same tx.
    function repair(uint256 tokenId) external virtual whenNotPaused nonReentrant returns (uint256 reqId) {
        _beforeRepair(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        Inscription storage ins = inscriptions[tokenId];
        if (ins.broken) revert Broken();
        if (pendingRepairOf[tokenId] != 0) revert AlreadyRepairing();
        if (pendingFuseOf[tokenId] != 0) revert AlreadyFusing();

        uint256 fee = repairFee(tokenId);
        ardi.safeTransferFrom(msg.sender, address(this), fee);

        // Restore durability optimistically. If VRF fails the NFT is broken
        // anyway (no longer earning), so the optimistic refresh costs nothing.
        ins.currentDurability = ins.maxDurability;
        ins.lastDecayCheckpoint = uint64(block.timestamp);

        reqId = randomness.requestRandomness();
        pendingRepairOf[tokenId] = reqId;
        pending[reqId] = PendingRequest({
            kind: ReqKind.Repair,
            tokenId: tokenId,
            tokenIdB: 0,
            holder: msg.sender,
            requestedAt: uint64(block.timestamp),
            newWord: "",
            newPower: 0,
            newLangId: 0,
            newElement: 0,
            paid: fee
        });
        unchecked {
            ++pendingRequestsCount;
        }

        emit RepairRequested(tokenId, msg.sender, reqId, fee);
    }

    /// @notice Permissionless: if a repair VRF request never gets fulfilled
    ///         within REPAIR_STALE_AFTER, anyone may call to mark the NFT
    ///         broken and collect the keeper bounty.
    function forceFailStaleRepair(uint256 tokenId) external nonReentrant {
        uint256 reqId = pendingRepairOf[tokenId];
        if (reqId == 0) revert NoPendingRequest();
        PendingRequest memory req = pending[reqId];
        if (block.timestamp < req.requestedAt + REPAIR_STALE_AFTER) revert NotStale();

        _settleRepairFailure(tokenId, reqId, req);
        bool paid = _tryPayKeeper(msg.sender);
        emit RepairForceFailed(tokenId, reqId, msg.sender);
        if (!paid) emit KeeperBountyUnpaid(msg.sender, KEEPER_BOUNTY);
    }

    /// @notice (H-2) Holder-only escape hatch: after REPAIR_HOLDER_CANCEL_AFTER
    ///         (12h, longer than the keeper window) the holder can cancel
    ///         their own stuck repair, get the fee back, and keep the NFT.
    ///         The optimistic durability refresh from the original repair() call
    ///         stays in place (treated as a free repair) — the alternative was
    ///         to forfeit, and we already optimistically charged + restored
    ///         durability at request time. This window is rarely hit in
    ///         practice; mostly it exists so users aren't trapped paying a fee
    ///         for a permanent-broken NFT during VRF outages.
    function cancelMyRepair(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        uint256 reqId = pendingRepairOf[tokenId];
        if (reqId == 0) revert NoPendingRequest();
        PendingRequest memory req = pending[reqId];
        // H2-3: requester must match. Without this, an NFT transferred AFTER
        // the original holder paid + requested could let the new owner cancel
        // and pocket the original holder's refunded fee.
        if (req.holder != msg.sender) revert NotTokenOwner();
        if (block.timestamp < req.requestedAt + REPAIR_HOLDER_CANCEL_AFTER) revert NotStale();

        delete pendingRepairOf[tokenId];
        delete pending[reqId];
        // H2-2: guard removed; revert on underflow exposes invariant break.
        --pendingRequestsCount;
        if (req.paid > 0) {
            ardi.safeTransfer(msg.sender, req.paid);
        }
        emit RepairCancelled(tokenId, reqId, msg.sender);
    }

    /// @notice cancelMyFuse / forceFailStaleFuse — fuse() is deprecated;
    ///         these guard rails are kept as 1-line reverts to free
    ///         EIP-170 budget. No fuse can become pending in v4+ since
    ///         the entry function reverts, so these are unreachable in
    ///         practice anyway.
    function cancelMyFuse(uint256) external virtual nonReentrant {
        revert("FuseDeprecated");
    }

    function forceFailStaleFuse(uint256) external virtual nonReentrant {
        revert("FuseDeprecated");
    }

    /// @notice Permissionless: if an NFT's effective durability has hit 0 and
    ///         it's still in the active set, kick it out so the
    ///         EmissionDistributor accounting stays accurate. 50 ardi bounty.
    ///         Owner can repair within REPAIR_STALE timer to revive (broken=false
    ///         remains, just out-of-pool).
    function expireToZero(uint256 tokenId) external nonReentrant {
        Inscription storage ins = inscriptions[tokenId];
        if (!ins.activeTracked) revert NotZero();
        if (effectiveDurability(tokenId) != 0) revert NotZero();

        // Persist the zero state.
        ins.currentDurability = 0;
        ins.lastDecayCheckpoint = uint64(block.timestamp);
        _deactivate(tokenId, ownerOf(tokenId));

        bool paid = _tryPayKeeper(msg.sender);
        emit Expired(tokenId, msg.sender);
        if (!paid) emit KeeperBountyUnpaid(msg.sender, KEEPER_BOUNTY);
    }

    /// @notice (H-3) Try to pay the keeper bounty WITHOUT reverting on failure.
    ///         Eviction logic MUST always succeed even when treasury is empty
    ///         / hasn't approved this contract; otherwise stuck NFTs accumulate
    ///         in totalActivePower forever and break emission accounting.
    /// @dev    Uses raw transfer/transferFrom returning bool with try/catch on
    ///         the entire call (handles ERC20s that revert AND those that
    ///         return false). Trimmed to fit EIP-170 contract size limit.
    function _tryPayKeeper(address to) internal returns (bool) {
        if (treasury == address(this)) {
            try ardi.transfer(to, KEEPER_BOUNTY) returns (bool ok) { return ok; }
            catch { return false; }
        } else {
            try ardi.transferFrom(treasury, to, KEEPER_BOUNTY) returns (bool ok) { return ok; }
            catch { return false; }
        }
    }

    function _settleRepairFailure(uint256 tokenId, uint256 reqId, PendingRequest memory req)
        internal
    {
        Inscription storage ins = inscriptions[tokenId];
        ins.broken = true;
        ins.currentDurability = 0;
        if (ins.activeTracked) _deactivate(tokenId, ownerOf(tokenId));

        delete pendingRepairOf[tokenId];
        delete pending[reqId];
        // H2-2: guard removed; revert on underflow exposes invariant break.
        --pendingRequestsCount;
        // The fee already paid stays in the contract; on next sweep it gets
        // distributed by _flushSink at the next successful repair, OR an
        // operator can call sweepSink() to push to burn/treasury. Keep simple
        // here: send to treasury since the agent's NFT broke anyway.
        if (req.paid > 0) {
            ardi.safeTransfer(treasury, req.paid);
        }
    }

    // =============================== Fuse =================================

    /// @notice Same authorisation flow as v2 (coordinator EIP-191 sig over
    ///         intent), but the dice roll itself is now VRF, not coordinator-
    ///         supplied. Coordinator only signs (newWord, newPower, newLang,
    ///         newElement) — success/fail comes from chain.
    /// @notice fuse() was deprecated pre-launch and never called on
    ///         mainnet. Stripped to a 1-line revert to free EIP-170 budget
    ///         for v4 forge. Storage slots (`pendingFuseOf`, `fuseBaseFee`,
    ///         etc.) preserved so v4Mainnet inherits compatible layout.
    function fuse(
        uint256, uint256, string calldata, uint16, uint8, uint8, bytes calldata
    ) external virtual whenNotPaused nonReentrant returns (uint256) {
        revert("FuseDeprecated");
    }

    // =============================== VRF callback =================================

    function onRandomness(uint256 requestId, uint256 randomWord) external virtual override nonReentrant {
        if (msg.sender != address(randomness)) revert NotRandomness();
        PendingRequest memory req = pending[requestId];
        if (req.kind == ReqKind.None) revert NoPendingRequest();

        if (req.kind == ReqKind.Repair) {
            _onRepairRandomness(requestId, req, randomWord);
        } else {
            _onFuseRandomness(requestId, req, randomWord);
        }
    }

    function _onRepairRandomness(uint256 reqId, PendingRequest memory req, uint256 r) internal virtual {
        bool failed = (r % BPS_DENOM) < REPAIR_FAIL_BPS;
        if (failed) {
            _settleRepairFailure(req.tokenId, reqId, req);
            emit RepairFulfilled(req.tokenId, reqId, true);
        } else {
            // Success path: NFT already optimistically refreshed at request
            // time; just route the fee and clean up.
            _flushSinkRepair(req.paid);
            delete pendingRepairOf[req.tokenId];
            delete pending[reqId];
            // H2-2: guard removed; revert on underflow exposes invariant break.
            --pendingRequestsCount;
            emit RepairFulfilled(req.tokenId, reqId, false);
        }
    }

    /// @notice _onFuseRandomness — fuse() entry reverts so this is
    ///         unreachable in practice. Kept as a 1-line revert to free
    ///         EIP-170 budget. v4Mainnet's onRandomness override never
    ///         routes here; v3-base would only reach here if someone
    ///         crafted a phantom Fuse pending request, which the entry
    ///         guards prevent.
    function _onFuseRandomness(uint256, PendingRequest memory, uint256) internal virtual {
        revert("FuseDeprecated");
    }

    function _flushSinkRepair(uint256 amount) internal {
        if (amount == 0) return;
        uint256 burnAmt = (amount * repairBurnBps) / BPS_DENOM;
        if (burnAmt > 0) ardi.safeTransfer(address(0xdead), burnAmt);
        uint256 rest = amount - burnAmt;
        if (rest > 0) ardi.safeTransfer(treasury, rest);
    }

    /// @notice _flushSinkFuse — fuse path is dead, function kept as no-op
    ///         (callable only by `_onFuseRandomness` which itself reverts).
    function _flushSinkFuse(uint256) internal {
        // unreachable in v4+; kept for inheritance + EIP-170 trim.
    }

    // =============================== Hooks to distributor =================================

    function _activate(uint256 tokenId, address holder) internal virtual {
        Inscription storage ins = inscriptions[tokenId];
        if (ins.activeTracked) return;
        ins.activeTracked = true;
        if (address(emissionDist) != address(0)) {
            emissionDist.onActivate(tokenId, holder, ins.power);
        }
    }

    function _deactivate(uint256 tokenId, address holder) internal virtual {
        Inscription storage ins = inscriptions[tokenId];
        if (!ins.activeTracked) return;
        ins.activeTracked = false;
        if (address(emissionDist) != address(0)) {
            emissionDist.onDeactivate(tokenId, holder);
        }
    }

    /// @dev Override transfer hook so the EmissionDistributor sees holder
    ///      changes for actively-earning NFTs. _update is OZ v5's unified hook.
    /// @dev (M-4) ALSO catches direct ERC721Burnable.burn() — without this,
    ///      a holder calling burn() bypasses our _deactivate flow and the
    ///      emission distributor's totalActivePower drifts upward forever.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        // C3-1 / H3-1: lock NFT against external transfer while a VRF request
        // (repair or fuse) is in flight. Otherwise the original holder could
        // request → transfer → callback fires → victim's NFT gets burned (fuse)
        // or marked broken (repair). We allow our own internal mint (from=0)
        // and burn (to=0, used by fuse settle), but reject EOA-driven transfers.
        if (from != address(0) && to != address(0) && from != to) {
            if (pendingFuseOf[tokenId] != 0 || pendingRepairOf[tokenId] != 0) {
                revert TokenLocked();
            }
        }
        // M-4: handle burn before super so _deactivate fires while ownerOf
        // still resolves; otherwise the emission accounting goes stale.
        if (to == address(0) && from != address(0)) {
            Inscription storage ins = inscriptions[tokenId];
            if (ins.activeTracked) {
                _deactivate(tokenId, from);
            }
        }
        address result = super._update(to, tokenId, auth);
        // Only fire transfer hook on real transfers (from != 0 && to != 0 && from != to);
        // mints (from=0) call _activate; burns now handled above.
        if (from != address(0) && to != address(0) && from != to) {
            Inscription storage ins = inscriptions[tokenId];
            if (ins.activeTracked && address(emissionDist) != address(0)) {
                emissionDist.onTransfer(tokenId, from, to);
            }
        }
        return result;
    }

    // =============================== Views =================================

    function getInscription(uint256 tokenId) external view returns (Inscription memory) {
        _requireOwned(tokenId);
        return inscriptions[tokenId];
    }

    function powerOf(uint256 tokenId) external view returns (uint16) {
        _requireOwned(tokenId);
        return inscriptions[tokenId].power;
    }

    // Storage gap for upgradeability.
    uint256[50] private __gap;
}
