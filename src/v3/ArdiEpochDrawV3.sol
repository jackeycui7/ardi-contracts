// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IRandomnessSource, IRandomnessReceiver} from "../interfaces/IRandomnessSource.sol";
import {IAWPAllocator} from "./interfaces/IAWPAllocator.sol";

/// @title ArdiEpochDraw v3 — commit-reveal-VRF lottery with staker-aware eligibility.
/// @notice Differences vs v2:
///   1. commit() takes `staker` param. staker == address(0) → msg.sender (self-stake).
///   2. _requireEligible uses AWPAllocator.getAgentStake(staker, agent, worknetId)
///      — works with KYA delegated path that does not bind agent to provider.
///   3. Commit struct stores the staker address; SD-1 VRF-time re-check uses
///      the SAME staker so an agent can't swap providers between commit and draw.
///   4. publishAnswer/Answers carry maxDurability (1..14) and element (1..6).
///      v3.1 leaf binds (wordId, wordHash, power, languageId, maxDurability,
///      themeHash, elementHash) — themeHash/elementHash supplied by coordinator
///      to match Leslie's wordbank vault_merkle_v3.py spec.
///   5. UUPS upgradeable + Pausable.
contract ArdiEpochDrawV3 is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IRandomnessReceiver
{
    // ============================== Constants ===============================

    uint256 public constant COMMIT_BOND = 0.00001 ether;
    uint256 public constant MAX_GUESS_LEN = 64;
    uint64 public constant MIN_REVEAL_AFTER_PUBLISH = 30;
    uint64 public constant DRAW_FULFILLMENT_TIMEOUT = 1 days;
    uint64 public constant MAX_PUBLISH_DELAY = 30;
    // 2026-05-03: bumped from 3 → 5 for the production deploy. Aligns
    // with maxCommitsPerEpoch (also 5) so every commit can become a
    // mint without leaving lottery entries that can never resolve.
    // Constant (not storage) — bumping requires a redeploy, which we're
    // doing tonight anyway.
    uint8 public constant MAX_WINS_PER_AGENT = 5;
    uint256 public constant MAX_LOTTERY_ITERATIONS = 200;
    /// @notice Bail out of the candidate walk when remaining gas drops below
    ///         this. Each iteration does a live multi-staker stake re-check
    ///         (~80K gas / candidate at MAX_STAKERS_PER_COMMIT=8). On bail,
    ///         the cursor + seed are saved and `continueDraw` can be invoked
    ///         by anyone to resume — no new VRF needed, the original random
    ///         word is reused as the Latin-square offset start.
    uint256 public constant LOTTERY_GAS_FLOOR = 200_000;

    // ============================== Storage =================================

    bytes32 public vaultMerkleRoot;
    IRandomnessSource public randomness;
    address public coordinator;
    address public treasury;

    IAWPAllocator public awpAllocator;
    uint256 public ardiWorknetId;
    uint256 public kyaWorknetId;
    uint256 public minStake;

    struct EpochCfg {
        uint64 startTs;
        uint64 commitDeadline;
        uint64 revealDeadline;
        bool exists;
    }
    mapping(uint256 => EpochCfg) public epochs;

    /// @notice Max stakers a single commit can list. Caps gas + dedup work.
    uint8 public constant MAX_STAKERS_PER_COMMIT = 8;

    struct Commit {
        bytes32 hash;
        // Multi-staker (v3.1): the agent's stake on Ardi may be split across
        // several stakers (e.g. some self-stake + several KYA sponsors). The
        // contract sums their allocations across BOTH worknets at commit and
        // again at settlement. Stored on chain (not just in event) so the
        // settlement path can re-read without trusting calldata.
        // Strict ascending order (enforced at commit) guarantees uniqueness.
        address[] stakers;
        // H-1: total stake snapshot at commit time. SD-1 fast-filter at draw
        // uses this so a malicious staker can't withdraw between commit and
        // draw to skew the candidate walk. The on-chain stakers list is also
        // re-summed lazily when needed for explicit verification.
        uint128 stakeSnapshot;
        // R2-HIGH-02: minStake threshold snapshot. Owner can't retroactively
        // disqualify candidates by raising minStake post-commit.
        uint128 minStakeAtCommit;
        bool revealed;
        bool correct;
        bool bondClaimed;
    }
    mapping(uint256 => mapping(uint256 => mapping(address => Commit))) public commits;

    struct Answer {
        bytes32 wordHash;
        uint16 power;
        uint8 languageId;
        uint8 maxDurability; // v3: 1..14
        uint8 element; // v3.1: 1..6 (5 五行 + 6=god)
        bool published;
    }
    mapping(uint256 => mapping(uint256 => Answer)) public answers;

    mapping(uint256 => bool) public wordCompromised;
    mapping(address => uint8) public agentWinCount;
    mapping(uint256 => mapping(address => uint8)) public agentCommitsInEpoch;
    uint8 public maxCommitsPerEpoch;

    mapping(uint256 => mapping(uint256 => address[])) public correctList;
    mapping(uint256 => mapping(uint256 => address)) public winners;
    mapping(uint256 => uint256) public pendingRequests;
    mapping(uint256 => mapping(uint256 => bool)) public drawRequested;
    mapping(uint256 => mapping(uint256 => uint64)) public drawRequestedAt;
    /// @notice (C2-1) Reverse map: (epochId, wordId) -> in-flight VRF requestId.
    ///         Lets cancelStuckDraw delete pendingRequests[reqId] cleanly so a
    ///         late-arriving callback can't fire a zombie second winner. Without
    ///         this we knew (ep, wid) but not the orphan reqId.
    mapping(uint256 => mapping(uint256 => uint256)) public drawReqId;
    uint256 public pendingRequestsCount;

    /// @notice (v3.1 multi-staker live re-check) Lottery walk state per
    ///         (epoch, wordId). On gas-out the walk pauses; anyone may call
    ///         `continueDraw` to resume from the saved cursor without a new
    ///         VRF request. The seed is the original VRF random word.
    struct DrawState {
        uint256 seed;
        uint128 cursor;       // next attempt index in the Latin-square walk
        bool active;          // true while the walk is unresolved
    }
    mapping(uint256 => mapping(uint256 => DrawState)) public drawState;

    // ============================== Events ==================================

    event EpochOpened(uint256 indexed epochId, uint64 startTs, uint64 commitDeadline, uint64 revealDeadline);
    event Committed(
        uint256 indexed epochId,
        uint256 indexed wordId,
        address indexed agent,
        bytes32 hash,
        address[] stakers
    );
    event AnswerPublished(
        uint256 indexed epochId,
        uint256 indexed wordId,
        bytes32 wordHash,
        uint16 power,
        uint8 languageId,
        uint8 maxDurability,
        uint8 element
    );
    event Revealed(uint256 indexed epochId, uint256 indexed wordId, address indexed agent, bool correct);
    event DrawRequested(uint256 indexed epochId, uint256 indexed wordId, uint256 requestId, uint256 candidates);
    event WinnerSelected(uint256 indexed epochId, uint256 indexed wordId, address indexed winner);
    event NoCorrectRevealers(uint256 indexed epochId, uint256 indexed wordId);
    event WordCompromised(uint256 indexed wordId, uint256 indexed epochId, address indexed firstCorrectAgent);
    event RevealRejectedAtCap(uint256 indexed epochId, uint256 indexed wordId, address indexed agent);
    event NoEligibleWinner(uint256 indexed epochId, uint256 indexed wordId, uint256 candidates);
    event LotteryNeedsRetry(uint256 indexed epochId, uint256 indexed wordId, uint256 candidates);
    event BondForfeited(uint256 indexed epochId, uint256 indexed wordId, address indexed agent, uint256 amount);
    event BondRefundedNoAnswer(uint256 indexed epochId, uint256 indexed wordId, address indexed agent, uint256 amount);
    event StuckDrawCancelled(uint256 indexed epochId, uint256 indexed wordId);
    event LotteryPausedGas(uint256 indexed epochId, uint256 indexed wordId, uint128 cursor);
    event LotteryResumed(uint256 indexed epochId, uint256 indexed wordId, uint128 fromCursor);
    event CoordinatorSet(address indexed coordinator);
    event TreasurySet(address indexed treasury);
    event RandomnessSet(address indexed randomness);
    event AllocatorSet(address indexed allocator);
    event WorknetIdsSet(uint256 ardi, uint256 kya);
    event MinStakeSet(uint256 minStake);
    event MaxCommitsPerEpochSet(uint8 v);
    event VaultMerkleRootSet(bytes32 root);

    // ============================== Errors ==================================

    error NotCoordinator();
    error NotRandomnessSource();
    error EpochUnknown();
    error EpochAlreadyOpen();
    error CommitWindowClosed();
    error CommitWindowNotClosed();
    error RevealWindowClosed();
    error RevealWindowNotClosed();
    error AlreadyCommitted();
    error WrongBond();
    error NoCommit();
    error AlreadyRevealed();
    error CommitMismatch();
    error AnswerNotPublished();
    error AnswerAlreadyPublished();
    error InvalidVaultProof();
    error GuessTooLong();
    error InvalidPower();
    error InvalidLanguage();
    error InvalidDurability();
    error InvalidElement();
    error DrawAlreadyRequested();
    error DrawNotRequested();
    error NoCandidates();
    error AlreadyDrawn();
    error UnknownRequest();
    error BondAlreadyClaimed();
    error ZeroAddress();
    error PublishTooLate();
    error PublishWindowClosed();
    error EmptyBatch();
    error DrawNotStuck();
    error PendingRequestsExist();
    error WinCapReached();
    error EpochCommitCapReached();
    error InsufficientStake();
    error StakeTooLarge();
    error VaultRootAlreadySet();
    error VaultRootNotSet();
    error TooManyStakers();
    error StakersNotSortedOrDuped();
    error DrawNotResumable();
    error ContinueDrawNeedsMoreGas();

    // ============================ Init ======================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        bytes32 vaultMerkleRoot_,
        address randomness_,
        address coordinator_,
        address treasury_,
        address awpAllocator_,
        uint256 ardiWorknetId_,
        uint256 kyaWorknetId_,
        uint256 minStake_
    ) external initializer {
        if (
            initialOwner == address(0) || randomness_ == address(0) || coordinator_ == address(0)
                || treasury_ == address(0) || awpAllocator_ == address(0)
        ) revert ZeroAddress();
        if (ardiWorknetId_ == 0 || kyaWorknetId_ == 0) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __Pausable_init();
        vaultMerkleRoot = vaultMerkleRoot_;
        randomness = IRandomnessSource(randomness_);
        coordinator = coordinator_;
        treasury = treasury_;
        awpAllocator = IAWPAllocator(awpAllocator_);
        ardiWorknetId = ardiWorknetId_;
        kyaWorknetId = kyaWorknetId_;
        minStake = minStake_;
        maxCommitsPerEpoch = 5;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============================ Admin =====================================

    function setCoordinator(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        coordinator = v;
        emit CoordinatorSet(v);
    }

    function setTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        treasury = v;
        emit TreasurySet(v);
    }

    function setAllocator(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        awpAllocator = IAWPAllocator(v);
        emit AllocatorSet(v);
    }

    function setWorknetIds(uint256 ardi, uint256 kya) external onlyOwner {
        if (ardi == 0 || kya == 0) revert ZeroAddress();
        ardiWorknetId = ardi;
        kyaWorknetId = kya;
        emit WorknetIdsSet(ardi, kya);
    }

    function setMinStake(uint256 v) external onlyOwner {
        // R5-3: same uint128 bound as M2-2 in _checkAndSnapshotStake — a
        // typo > uint128 max would silently truncate at commit time
        // (Commit.minStakeAtCommit = uint128(minStake)) and weaken eligibility.
        if (v > type(uint128).max) revert StakeTooLarge();
        minStake = v;
        emit MinStakeSet(v);
    }

    /// @notice One-shot setter for the vault Merkle root. Deploy-time
    ///         convenience so we can ship the contracts before the wordbank
    ///         finalizes the 21K entries: deploy with `bytes32(0)`, then
    ///         call this exactly once with the real root. After it's set
    ///         to non-zero, it's locked forever (no second call accepted).
    /// @dev    `openEpoch` is gated on a non-zero root (see below) so the
    ///         placeholder state can't accidentally accept commits.
    function setVaultMerkleRoot(bytes32 root) external onlyOwner {
        if (vaultMerkleRoot != bytes32(0)) revert VaultRootAlreadySet();
        if (root == bytes32(0)) revert ZeroAddress();
        vaultMerkleRoot = root;
        emit VaultMerkleRootSet(root);
    }

    /// @notice One-shot v3.1 leaf-format migration. The deployed v3.0 root
    ///         was computed against a 6-field leaf; v3.1 adds maxDurability
    ///         and switches to themeHash/elementHash (Sky's audit). Callable
    ///         only before any epoch is opened to prevent in-flight commits
    ///         from being invalidated by a root swap mid-game.
    function migrateVaultMerkleRootV31(bytes32 newRoot) external onlyOwner {
        if (newRoot == bytes32(0)) revert ZeroAddress();
        if (vaultMerkleRoot == bytes32(0)) revert VaultRootNotSet();
        if (pendingRequestsCount > 0) revert PendingRequestsExist();
        vaultMerkleRoot = newRoot;
        emit VaultMerkleRootSet(newRoot);
    }

    function setMaxCommitsPerEpoch(uint8 v) external onlyOwner {
        maxCommitsPerEpoch = v;
        emit MaxCommitsPerEpochSet(v);
    }

    function setRandomnessSource(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (pendingRequestsCount > 0) revert PendingRequestsExist();
        randomness = IRandomnessSource(v);
        emit RandomnessSet(v);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================ Eligibility ===============================

    /// @notice Reverts if neither worknet meets minStake; otherwise returns
    ///         the larger of the two allocations as the snapshot to lock in
    ///         the Commit struct.
    /// @notice Sum allocations across all stakers and BOTH worknets, then
    ///         enforce minStake. Caller already validated stakers length +
    ///         strict-ascending order (so iteration is safe + duplicate-free).
    function _checkAndSnapshotStake(address agent, address[] calldata stakers)
        internal
        view
        returns (uint128 snapshot)
    {
        uint256 sum = 0;
        for (uint256 i = 0; i < stakers.length; ++i) {
            sum += awpAllocator.getAgentStake(stakers[i], agent, ardiWorknetId);
            sum += awpAllocator.getAgentStake(stakers[i], agent, kyaWorknetId);
        }
        if (sum < minStake) revert InsufficientStake();
        // M2-2: explicit bound check vs silent uint128 truncation.
        if (sum > type(uint128).max) revert StakeTooLarge();
        snapshot = uint128(sum);
    }

    /// @notice (settlement helper) re-sum stakers' on-chain allocations from
    ///         a stored Commit. Used for explicit "still eligible?" checks at
    ///         draw / settlement. View-only; never reverts.
    function liveStakeForCommit(uint256 epochId, uint256 wordId, address agent)
        external
        view
        returns (uint256 sum)
    {
        Commit storage c = commits[epochId][wordId][agent];
        for (uint256 i = 0; i < c.stakers.length; ++i) {
            sum += awpAllocator.getAgentStake(c.stakers[i], agent, ardiWorknetId);
            sum += awpAllocator.getAgentStake(c.stakers[i], agent, kyaWorknetId);
        }
    }

    /// @notice Read the stored stakers list for a commit. The auto-generated
    ///         `commits()` public getter skips dynamic-array fields, so this
    ///         is the only way external callers see who's backing this commit.
    function getCommitStakers(uint256 epochId, uint256 wordId, address agent)
        external
        view
        returns (address[] memory)
    {
        return commits[epochId][wordId][agent].stakers;
    }

    // ============================ Lifecycle =================================

    function openEpoch(uint256 epochId, uint64 commitWindow, uint64 revealWindow)
        external
        whenNotPaused
    {
        if (msg.sender != coordinator) revert NotCoordinator();
        // Block the placeholder window: deploy ships with vaultMerkleRoot=0,
        // so coordinator cannot accidentally open a real epoch before the
        // wordbank-derived root is locked in via setVaultMerkleRoot.
        if (vaultMerkleRoot == bytes32(0)) revert VaultRootNotSet();
        if (epochs[epochId].exists) revert EpochAlreadyOpen();
        uint64 now64 = uint64(block.timestamp);
        epochs[epochId] = EpochCfg({
            startTs: now64,
            commitDeadline: now64 + commitWindow,
            revealDeadline: now64 + commitWindow + revealWindow,
            exists: true
        });
        emit EpochOpened(epochId, now64, now64 + commitWindow, now64 + commitWindow + revealWindow);
    }

    /// @notice v3.1: pass the FULL list of stakers backing your stake. Sums
    ///         their allocations across BOTH worknets and accepts if total
    ///         >= minStake. Skill auto-detects via AWP RPC; UI lets users
    ///         override.
    /// @dev    `stakers` MUST be strictly ascending — that's how dedup is
    ///         enforced cheaply (no second pass / no extra storage). Length
    ///         capped at MAX_STAKERS_PER_COMMIT (8) to bound gas at draw.
    function commit(
        uint256 epochId,
        uint256 wordId,
        bytes32 hash,
        address[] calldata stakers
    )
        external
        payable
        whenNotPaused
        nonReentrant
    {
        // Default: self-stake (single staker = msg.sender).
        address[] calldata effective = stakers;
        address[] memory selfArr;
        if (stakers.length == 0) {
            selfArr = new address[](1);
            selfArr[0] = msg.sender;
        }

        // Length + dedup validation (strict ascending). Skip if we're using
        // the self-fallback (a single address has no ordering).
        if (effective.length > 0) {
            if (effective.length > MAX_STAKERS_PER_COMMIT) revert TooManyStakers();
            for (uint256 i = 1; i < effective.length; ++i) {
                if (effective[i] <= effective[i - 1]) revert StakersNotSortedOrDuped();
            }
            if (effective[0] == address(0)) revert ZeroAddress();
        }

        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp >= cfg.commitDeadline) revert CommitWindowClosed();
        if (msg.value != COMMIT_BOND) revert WrongBond();
        if (agentWinCount[msg.sender] >= MAX_WINS_PER_AGENT) revert WinCapReached();
        if (agentCommitsInEpoch[epochId][msg.sender] >= maxCommitsPerEpoch) {
            revert EpochCommitCapReached();
        }

        // Sum + threshold check + uint128 bound.
        uint128 snapshot = effective.length == 0
            ? _checkAndSnapshotStakeMem(msg.sender, selfArr)
            : _checkAndSnapshotStake(msg.sender, effective);

        Commit storage c = commits[epochId][wordId][msg.sender];
        if (c.hash != bytes32(0)) revert AlreadyCommitted();
        c.hash = hash;
        // Persist the staker list — settlement reads it for live re-check.
        if (effective.length == 0) {
            c.stakers.push(msg.sender);
        } else {
            for (uint256 i = 0; i < effective.length; ++i) {
                c.stakers.push(effective[i]);
            }
        }
        c.stakeSnapshot = snapshot;
        c.minStakeAtCommit = uint128(minStake);
        unchecked {
            ++agentCommitsInEpoch[epochId][msg.sender];
        }

        emit Committed(epochId, wordId, msg.sender, hash, c.stakers);
    }

    /// @dev Memory variant of _checkAndSnapshotStake — used only on the
    ///      single-element self-stake fallback path so we don't need to
    ///      duplicate calldata-only logic.
    function _checkAndSnapshotStakeMem(address agent, address[] memory stakers)
        internal
        view
        returns (uint128 snapshot)
    {
        uint256 sum = 0;
        for (uint256 i = 0; i < stakers.length; ++i) {
            sum += awpAllocator.getAgentStake(stakers[i], agent, ardiWorknetId);
            sum += awpAllocator.getAgentStake(stakers[i], agent, kyaWorknetId);
        }
        if (sum < minStake) revert InsufficientStake();
        if (sum > type(uint128).max) revert StakeTooLarge();
        snapshot = uint128(sum);
    }

    struct AnswerData {
        uint256 wordId;
        bytes32 wordHash;
        uint16 power;
        uint8 languageId;
        uint8 maxDurability;
        uint8 element;
        bytes32 themeHash;
        bytes32 elementHash;
        bytes32[] vaultProof;
    }

    function publishAnswers(uint256 epochId, AnswerData[] calldata data) external {
        if (data.length == 0) revert EmptyBatch();
        _assertPublishWindow(epochId);
        for (uint256 i; i < data.length;) {
            AnswerData calldata d = data[i];
            _publishOne(
                epochId, d.wordId, d.wordHash, d.power, d.languageId, d.maxDurability, d.element,
                d.themeHash, d.elementHash, d.vaultProof
            );
            unchecked {
                ++i;
            }
        }
    }

    function publishAnswer(
        uint256 epochId,
        uint256 wordId,
        bytes32 wordHash,
        uint16 power,
        uint8 languageId,
        uint8 maxDurability,
        uint8 element,
        bytes32 themeHash,
        bytes32 elementHash,
        bytes32[] calldata vaultProof
    ) external {
        _assertPublishWindow(epochId);
        _publishOne(epochId, wordId, wordHash, power, languageId, maxDurability, element,
            themeHash, elementHash, vaultProof);
    }

    function _assertPublishWindow(uint256 epochId) internal view {
        if (msg.sender != coordinator) revert NotCoordinator();
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.commitDeadline) revert CommitWindowNotClosed();
        if (block.timestamp >= cfg.revealDeadline) revert RevealWindowClosed();
        if (block.timestamp + MIN_REVEAL_AFTER_PUBLISH > cfg.revealDeadline) revert PublishTooLate();
        if (block.timestamp > cfg.commitDeadline + MAX_PUBLISH_DELAY) revert PublishWindowClosed();
    }

    function _publishOne(
        uint256 epochId,
        uint256 wordId,
        bytes32 wordHash,
        uint16 power,
        uint8 languageId,
        uint8 maxDurability,
        uint8 element,
        bytes32 themeHash,
        bytes32 elementHash,
        bytes32[] calldata vaultProof
    ) internal {
        Answer storage ans = answers[epochId][wordId];
        if (ans.published) revert AnswerAlreadyPublished();
        if (wordHash == bytes32(0)) revert InvalidVaultProof();
        if (themeHash == bytes32(0) || elementHash == bytes32(0)) revert InvalidVaultProof();
        if (power == 0 || power > 100) revert InvalidPower();
        if (languageId > 5) revert InvalidLanguage();
        if (maxDurability == 0 || maxDurability > 14) revert InvalidDurability();
        // v3.1: element 1..6 (5 五行 + 6=god for 22 hand-picked legendary entries)
        if (element == 0 || element > 6) revert InvalidElement();
        // v3.1 audit fix: elementHash IS bound into the Merkle leaf, but
        // `element` (uint8) was previously trusted from coordinator without
        // verifying it matches elementHash. A compromised/malicious
        // coordinator could publish (element=6, elementHash=keccak("metal"))
        // and mint a wood word as god-tier in the NFT inscription. Bind them
        // here via the canonical mapping so the on-chain element field
        // inherits the Merkle root's tamper-evidence.
        if (elementHash != _elementHashForId(element)) revert InvalidElement();

        // v3.1 leaf: matches Leslie's wordbank vault_merkle_v3.py.
        //   keccak256(abi.encode(wordId, wordHash, power, languageId,
        //                        maxDurability, themeHash, elementHash))
        // Per Sky's audit: use abi.encode (each field padded to 32 bytes) over
        // abi.encodePacked. No collision risk here either way (all fixed-width
        // types, no adjacent dynamic types) but encode is the auditor-preferred
        // canonical form. themeHash/elementHash come from coordinator so adding
        // new themes/elements doesn't need a contract bump.
        bytes32 leaf = keccak256(
            abi.encode(wordId, wordHash, power, languageId, maxDurability, themeHash, elementHash)
        );
        if (!MerkleProof.verify(vaultProof, vaultMerkleRoot, leaf)) revert InvalidVaultProof();

        ans.wordHash = wordHash;
        ans.power = power;
        ans.languageId = languageId;
        ans.maxDurability = maxDurability;
        ans.element = element;
        ans.published = true;

        emit AnswerPublished(epochId, wordId, wordHash, power, languageId, maxDurability, element);
    }

    /// @notice Canonical mapping uint8 element id → keccak256(bytes(name)).
    /// @dev Mirrors `element_id` / `element_name` in coord-rs/ardi-core/vault.rs
    ///      and the ELEMENTS list in tools/build_v3_vault.py.
    ///      Order: 1=metal, 2=wood, 3=water, 4=fire, 5=earth, 6=god (v3.1).
    ///      Used by `_publishOne` to bind the on-chain `element` uint8 to the
    ///      `elementHash` that goes into the Merkle leaf — without this check
    ///      a coordinator could decouple the two and mint inflated rarities.
    function _elementHashForId(uint8 elemId) internal pure returns (bytes32) {
        if (elemId == 1) return keccak256(bytes("metal"));
        if (elemId == 2) return keccak256(bytes("wood"));
        if (elemId == 3) return keccak256(bytes("water"));
        if (elemId == 4) return keccak256(bytes("fire"));
        if (elemId == 5) return keccak256(bytes("earth"));
        if (elemId == 6) return keccak256(bytes("god"));
        revert InvalidElement();
    }

    function reveal(uint256 epochId, uint256 wordId, string calldata guess, bytes32 nonce)
        external
        nonReentrant
    {
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.commitDeadline) revert CommitWindowNotClosed();
        if (block.timestamp >= cfg.revealDeadline) revert RevealWindowClosed();
        if (bytes(guess).length > MAX_GUESS_LEN) revert GuessTooLong();

        Answer memory ans = answers[epochId][wordId];
        if (!ans.published) revert AnswerNotPublished();

        Commit storage c = commits[epochId][wordId][msg.sender];
        if (c.hash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(guess, msg.sender, nonce));
        if (expected != c.hash) revert CommitMismatch();
        c.revealed = true;

        bool isCorrect = (keccak256(bytes(guess)) == ans.wordHash);
        if (isCorrect) {
            c.correct = true;
            if (!wordCompromised[wordId]) {
                wordCompromised[wordId] = true;
                emit WordCompromised(wordId, epochId, msg.sender);
            }
            if (agentWinCount[msg.sender] < MAX_WINS_PER_AGENT) {
                correctList[epochId][wordId].push(msg.sender);
            } else {
                emit RevealRejectedAtCap(epochId, wordId, msg.sender);
            }
        }

        c.bondClaimed = true;
        (bool ok,) = msg.sender.call{value: COMMIT_BOND}("");
        require(ok, "bond refund failed");

        emit Revealed(epochId, wordId, msg.sender, isCorrect);
    }

    function requestDraw(uint256 epochId, uint256 wordId) external nonReentrant {
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.revealDeadline) revert RevealWindowNotClosed();
        if (drawRequested[epochId][wordId]) revert DrawAlreadyRequested();

        drawRequested[epochId][wordId] = true;

        uint256 candidates = correctList[epochId][wordId].length;
        if (candidates == 0) {
            emit NoCorrectRevealers(epochId, wordId);
            return;
        }

        uint256 reqId = randomness.requestRandomness();
        pendingRequests[reqId] = (epochId << 128) | wordId;
        drawReqId[epochId][wordId] = reqId;
        drawRequestedAt[epochId][wordId] = uint64(block.timestamp);
        unchecked {
            ++pendingRequestsCount;
        }
        emit DrawRequested(epochId, wordId, reqId, candidates);
    }

    function cancelStuckDraw(uint256 epochId, uint256 wordId) external {
        if (!drawRequested[epochId][wordId]) revert DrawNotRequested();
        if (winners[epochId][wordId] != address(0)) revert AlreadyDrawn();
        uint64 reqTs = drawRequestedAt[epochId][wordId];
        if (reqTs == 0) revert DrawNotRequested();
        if (block.timestamp < reqTs + DRAW_FULFILLMENT_TIMEOUT) revert DrawNotStuck();

        // C2-1: wipe pendingRequests[reqId] so a late VRF callback no longer
        // resolves; combined with drawRequested=false reset, the slot is
        // re-requestable. Counter underflow guard removed (H2-2): if invariants
        // hold this is unreachable; if violated revert reveals the bug.
        uint256 reqId = drawReqId[epochId][wordId];
        if (reqId != 0) {
            delete pendingRequests[reqId];
            delete drawReqId[epochId][wordId];
        }
        drawRequested[epochId][wordId] = false;
        drawRequestedAt[epochId][wordId] = 0;
        --pendingRequestsCount;
        emit StuckDrawCancelled(epochId, wordId);
    }

    function onRandomness(uint256 requestId, uint256 randomWord) external override {
        if (msg.sender != address(randomness)) revert NotRandomnessSource();
        uint256 packed = pendingRequests[requestId];
        if (packed == 0) revert UnknownRequest();
        delete pendingRequests[requestId];

        uint256 epochId = packed >> 128;
        uint256 wordId = packed & ((uint256(1) << 128) - 1);

        if (winners[epochId][wordId] != address(0)) revert AlreadyDrawn();

        // VRF callback is done from VRF's POV — drop the in-flight counter
        // even if the lottery walk pauses. drawRequested stays true so
        // continueDraw can be invoked permissionlessly while the walk is
        // mid-flight; cancelStuckDraw will only fire if the original VRF
        // never arrived (timeout), which is no longer possible past here.
        drawRequestedAt[epochId][wordId] = 0;
        delete drawReqId[epochId][wordId];
        --pendingRequestsCount;

        // Initialise the lottery walk state and start consuming gas.
        drawState[epochId][wordId] = DrawState({seed: randomWord, cursor: 0, active: true});
        _walkLottery(epochId, wordId);
    }

    /// @notice Continue a paused lottery walk WITHOUT requesting new VRF.
    ///         Reuses the VRF random word saved in `drawState[ep][wid].seed`
    ///         and resumes from the saved cursor. Permissionless — anyone
    ///         can pay the gas to push the walk forward.
    function continueDraw(uint256 epochId, uint256 wordId) external nonReentrant {
        DrawState storage ds = drawState[epochId][wordId];
        if (!ds.active) revert DrawNotResumable();
        if (winners[epochId][wordId] != address(0)) revert AlreadyDrawn();
        // v3.1 audit fix (MEV/HIGH): require enough gas at entry so a caller
        // cannot precision-grief by supplying gas budget = bail-at-cursor-K.
        // The walk itself bails when gasleft < LOTTERY_GAS_FLOOR (200K) per
        // iteration; require at least 4× that here so the caller cannot
        // bail before completing several candidates worth of work, removing
        // single-iteration cursor manipulation as a practical attack.
        if (gasleft() < LOTTERY_GAS_FLOOR * 4) revert ContinueDrawNeedsMoreGas();
        emit LotteryResumed(epochId, wordId, ds.cursor);
        _walkLottery(epochId, wordId);
    }

    /// @dev Latin-square iteration starting from `seed % n`, advancing
    ///      cursor by 1 each attempt. Each candidate gets a LIVE multi-staker
    ///      stake re-check (sums all stakers across both worknets via
    ///      AWPAllocator). Bails when gasleft < LOTTERY_GAS_FLOOR; cursor
    ///      saved so continueDraw can pick up later.
    function _walkLottery(uint256 epochId, uint256 wordId) internal {
        DrawState storage ds = drawState[epochId][wordId];
        address[] storage cands = correctList[epochId][wordId];
        uint256 n = cands.length;
        if (n == 0) {
            ds.active = false;
            emit NoCorrectRevealers(epochId, wordId);
            return;
        }
        uint256 start = ds.seed % n;
        uint256 maxIter = n < MAX_LOTTERY_ITERATIONS ? n : MAX_LOTTERY_ITERATIONS;
        uint128 i = ds.cursor;
        address winner = address(0);

        while (i < maxIter) {
            // Bail BEFORE doing the per-candidate work so we don't half-
            // consume gas in the middle of an iteration. Save cursor first.
            if (gasleft() < LOTTERY_GAS_FLOOR) {
                ds.cursor = i;
                emit LotteryPausedGas(epochId, wordId, i);
                return;
            }
            address c = cands[(start + uint256(i)) % n];
            unchecked { ++i; }

            if (agentWinCount[c] >= MAX_WINS_PER_AGENT) continue;
            Commit storage cc = commits[epochId][wordId][c];
            // Owner-raise guard (R2-HIGH-02): commit-time threshold sticks.
            if (cc.minStakeAtCommit < minStake) {
                // owner LOWERED minStake → still eligible. Use the lower
                // threshold (= current minStake) for the live check.
                // owner RAISED minStake → keep commit-time threshold (this branch).
                // Either way the threshold for THIS candidate is the lower of
                // (commit-time, current). Compare via cc.minStakeAtCommit.
            }
            uint256 threshold = cc.minStakeAtCommit;

            // Live multi-staker stake re-check.
            uint256 live = 0;
            uint256 sCount = cc.stakers.length;
            for (uint256 j = 0; j < sCount; ++j) {
                address sk = cc.stakers[j];
                live += awpAllocator.getAgentStake(sk, c, ardiWorknetId);
                live += awpAllocator.getAgentStake(sk, c, kyaWorknetId);
            }
            if (live < threshold) continue;

            winner = c;
            break;
        }

        // Persist cursor either way (so a future continueDraw is a no-op
        // pass-through if we already exhausted the walk).
        ds.cursor = i;

        if (winner != address(0)) {
            ds.active = false;
            winners[epochId][wordId] = winner;
            unchecked { ++agentWinCount[winner]; }
            emit WinnerSelected(epochId, wordId, winner);
            return;
        }

        // No winner yet, but did we exhaust the walk?
        if (i >= maxIter) {
            ds.active = false;
            if (n > maxIter) {
                // We sampled only a slice (n large, MAX_LOTTERY_ITERATIONS
                // hit). Reset drawRequested so a fresh requestDraw can
                // re-fire VRF and walk a different slice.
                drawRequested[epochId][wordId] = false;
                emit LotteryNeedsRetry(epochId, wordId, n);
            } else {
                // We walked everyone — none eligible.
                emit NoEligibleWinner(epochId, wordId, n);
            }
        }
        // else: gas-out path already emitted LotteryPausedGas above.
    }

    function forfeitBond(uint256 epochId, uint256 wordId, address agent) external nonReentrant {
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.revealDeadline) revert RevealWindowNotClosed();

        Commit storage c = commits[epochId][wordId][agent];
        if (c.hash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (c.bondClaimed) revert BondAlreadyClaimed();

        c.bondClaimed = true;
        if (answers[epochId][wordId].published) {
            (bool ok,) = treasury.call{value: COMMIT_BOND}("");
            require(ok, "treasury transfer failed");
            emit BondForfeited(epochId, wordId, agent, COMMIT_BOND);
        } else {
            (bool ok,) = agent.call{value: COMMIT_BOND}("");
            require(ok, "agent refund failed");
            emit BondRefundedNoAnswer(epochId, wordId, agent, COMMIT_BOND);
        }
    }

    // ============================ Views =====================================

    /// @notice v3: returns the full answer payload including maxDurability + element.
    function getAnswer(uint256 epochId, uint256 wordId)
        external
        view
        returns (
            bytes32 wordHash,
            uint16 power,
            uint8 languageId,
            uint8 maxDurability,
            uint8 element,
            bool published
        )
    {
        Answer memory a = answers[epochId][wordId];
        return (a.wordHash, a.power, a.languageId, a.maxDurability, a.element, a.published);
    }

    function correctCount(uint256 epochId, uint256 wordId) external view returns (uint256) {
        return correctList[epochId][wordId].length;
    }

    /// @dev Reduced from 50 → 49 when `drawState` mapping was appended (v3.1).
    uint256[49] private __gap;
}
