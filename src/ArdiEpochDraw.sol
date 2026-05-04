// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IRandomnessSource, IRandomnessReceiver} from "./interfaces/IRandomnessSource.sol";
import {IAWPRegistry} from "./interfaces/IAWPRegistry.sol";

/// @title ArdiEpochDraw — fully on-chain commit-reveal + VRF lottery.
/// @notice Replaces the off-chain Coordinator-driven draw. Per (epoch, wordId):
///   1. Commit phase: agents submit `keccak256(guess || agent || nonce)` + bond.
///      Mempool only sees the hash; guess is sealed.
///   2. Coordinator publishes the canonical answer for that (epoch, wordId),
///      proven against the immutable VAULT_MERKLE_ROOT. After this point the
///      answer is public — but commits are already locked, so no front-run.
///   3. Reveal phase: agents who guessed correctly reveal `(guess, nonce)`.
///      Bond refunded on successful commit-match. Correct revealers are
///      collected.
///   4. Draw phase: anyone calls `requestDraw`, which pulls a random word
///      from `IRandomnessSource` (Chainlink VRF on mainnet, Mock on Anvil).
///      The VRF callback selects one address from the correct set as winner.
///   5. Winner is the only address that can mint the corresponding Ardinal
///      via ArdiNFT.inscribe.
///
/// This eliminates Coordinator-side grinding and the "trust me bro" lottery
/// pattern that the off-chain commit-reveal approach was vulnerable to.
contract ArdiEpochDraw is IRandomnessReceiver, Ownable2Step, ReentrancyGuard {
    // ============================== Constants ===============================

    /// @notice Bond required to commit. Refunded on successful reveal,
    ///         forfeited to treasury if agent never reveals (anti-grief).
    /// @dev Anti-spam bond locked at commit time, refunded on reveal.
    ///      Lowered to 0.00001 ETH on the testnet rehearsal so testers don't
    ///      need to keep refilling from faucets between epochs (5 commits ×
    ///      0.001 ≈ 0.005 ETH temporarily locked was draining drips). On
    ///      mainnet we'll restore a meaningfully larger value.
    uint256 public constant COMMIT_BOND = 0.00001 ether;

    /// @notice Maximum length of a guess string. Bounds calldata cost on
    ///         reveal. Real vault words are < 32 bytes.
    uint256 public constant MAX_GUESS_LEN = 64;

    /// @notice Minimum window between Coordinator publishing the answer and
    ///         the reveal deadline. If Coordinator publishes later than this
    ///         (i.e. less than MIN_REVEAL_AFTER_PUBLISH seconds before
    ///         revealDeadline), publishAnswer reverts. Closes audit H-1:
    ///         a Coordinator that publishes 1 second before the deadline
    ///         could otherwise compress the reveal window and harvest bonds.
    uint64 public constant MIN_REVEAL_AFTER_PUBLISH = 30;

    /// @notice Anyone can cancel a stuck VRF request after this many seconds
    ///         without a fulfillment. Resets drawRequested so the lottery is
    ///         re-requestable. Closes audit H-2: a stuck/orphaned VRF request
    ///         (Chainlink outage, source replaced) would otherwise brick the
    ///         (epoch, wordId) lottery permanently.
    uint64 public constant DRAW_FULFILLMENT_TIMEOUT = 1 days;

    /// @notice (v2 / MEV-1) Maximum delay between commit window close and
    ///         publishAnswer for any wordId in that epoch. Closes the
    ///         "publish-ordering grinding" MEV: with a wide publish window
    ///         the Coordinator can choose the order of publishes to compress
    ///         specific wordIds' reveal time and favor a colluding bot.
    ///         Forcing all publishes within MAX_PUBLISH_DELAY of commit close
    ///         removes the degree of freedom — order no longer affects per-
    ///         wordId reveal window length materially.
    ///         Combined with MIN_REVEAL_AFTER_PUBLISH, this defines a fixed
    ///         publish window of [commitDeadline, commitDeadline + MAX_PUBLISH_DELAY].
    uint64 public constant MAX_PUBLISH_DELAY = 30;

    /// @notice Hard cap on per-agent wins. Counts every VRF-selected win,
    ///         not mints — so winning and not minting still consumes a slot.
    ///         Once an agent's winCount hits this cap they cannot commit
    ///         on any new (epoch, wordId), preventing them from squatting
    ///         on more than this many wordIds.
    /// @dev    BondEscrow reads agentWinCount() to gate unlockBond().
    uint8 public constant MAX_WINS_PER_AGENT = 3;

    /// @notice (gas-bound) Hard cap on the candidate-walk iterations in
    ///         onRandomness. Without this, a correctList of 5K-50K
    ///         candidates × 6K gas/check would exceed Chainlink's
    ///         callback gas limit. With this, callback is bounded at
    ///         ~200 × 6K = 1.2M (well under 2.5M Chainlink limit).
    ///         If 200 iter all turn up ineligible (extreme sybil
    ///         scenario), onRandomness emits LotteryNeedsRetry and
    ///         resets drawRequested so a fresh VRF request can sample
    ///         a different segment.
    uint256 public constant MAX_LOTTERY_ITERATIONS = 200;

    // ============================== Storage =================================

    /// @notice Immutable Merkle root of the 21,000-entry vault.
    ///         Leaf format (v1.0, matches tools/vault_merkle.py):
    ///           keccak256(uint256 wordId || bytes32 wordHash || uint16 power || uint8 languageId)
    ///           where wordHash = keccak256(bytes(word))
    ///         The plaintext `word` is NOT in the leaf — only its hash. This
    ///         means publishAnswer can verify (wordId, hash, power, lang)
    ///         membership without ever putting the plaintext on chain.
    bytes32 public immutable VAULT_MERKLE_ROOT;

    IRandomnessSource public randomness;
    address public coordinator;
    address public treasury; // forfeited bonds + protocol fees

    // ─────────── AWP eligibility (replaces old BondEscrow / KYA bond) ───────────
    //
    // Each commit() reads AWPRegistry.getAgentInfo(agent, WN) and requires:
    //   info.isValid == true                      ← agent went through AWP register/bind
    //   AND (stake on ardiWorknetId  >= minStake
    //         OR stake on kyaWorknetId >= minStake)
    //
    // The whole BondEscrow + slash mechanism is gone — we don't escrow any
    // tokens here. Eligibility is a real-time read of AWP state. Agents who
    // de-allocate after committing still get to reveal that one slot
    // (bond is the per-commit ETH only), but cannot commit anywhere new.

    /// @notice AWPRegistry contract on this chain. Provides getAgentInfo.
    IAWPRegistry public immutable AWP_REGISTRY;
    /// @notice Ardi's own WorkNet ID (e.g. 8453 * 1e8 + N on Base).
    /// @dev    Owner-mutable so a future AWP WorkNet migration doesn't brick.
    uint256 public ardiWorknetId;
    /// @notice KYA's WorkNet ID. Stake on EITHER WN passes eligibility.
    uint256 public kyaWorknetId;
    /// @notice Minimum allocation (in AWP wei, 1e18 units) for any single WN.
    ///         Owner-tunable. Default 10_000 AWP at deploy.
    uint256 public minStake;

    event ArdiWorknetIdSet(uint256 newId);
    event KyaWorknetIdSet(uint256 newId);
    event MinStakeSet(uint256 newMinStake);

    error InsufficientStake();
    error AgentNotRegisteredInAWP();

    struct EpochCfg {
        uint64 startTs;
        uint64 commitDeadline;
        uint64 revealDeadline;
        bool exists;
    }
    mapping(uint256 => EpochCfg) public epochs;

    struct Commit {
        bytes32 hash;        // keccak256(guess || agent || nonce)
        bool revealed;
        bool correct;
        bool bondClaimed;    // true if either refunded or swept to treasury
    }
    /// @notice (epochId, wordId, agent) → commit
    mapping(uint256 => mapping(uint256 => mapping(address => Commit))) public commits;

    struct Answer {
        bytes32 wordHash;   // keccak256(bytes(word)) — published at commit close
        uint16 power;
        uint8 languageId;
        bool published;
        // NOTE: plaintext `word` is intentionally NOT stored. The winner
        // submits it at inscribe time and the NFT contract verifies
        // keccak256(word) == wordHash. Words for fully-unsolved (no correct
        // reveal) wordIds therefore never touch chain storage.
    }
    /// @notice Coordinator-published answer per (epoch, wordId), Merkle-verified.
    ///         Stores only the wordHash; plaintext is supplied by the winner at inscribe.
    mapping(uint256 => mapping(uint256 => Answer)) public answers;

    /// @notice wordId → answer leaked via at least one correct on-chain reveal.
    ///         A correct reveal puts the guess in tx calldata, so the answer
    ///         is publicly visible to anyone scraping the tx log. Once set,
    ///         the wordId is "consumed" for selection purposes — the
    ///         Coordinator must skip it forever, even if no NFT is minted.
    ///         This unifies "answered + minted", "answered + unminted",
    ///         and "answered + winner-squatted" into the same exclusion path.
    mapping(uint256 => bool) public wordCompromised;

    /// @notice Per-agent win count. Increments at VRF callback when the
    ///         agent is selected as winner. Capped at MAX_WINS_PER_AGENT;
    ///         further commits revert with WinCapReached.
    mapping(address => uint8) public agentWinCount;

    /// @notice (SD-2) Per-epoch per-agent commit count. Caps how many
    ///         wordIds a single agent can commit to within one epoch,
    ///         preventing a wealthy attacker from sweeping all riddles
    ///         in a single round to maximize lottery odds. The constraint
    ///         is on-chain so any commit beyond the cap reverts —
    ///         off-chain coordinator UI also enforces the same number.
    mapping(uint256 => mapping(address => uint8)) public agentCommitsInEpoch;
    /// @notice Max commits a single agent can submit per epoch. Owner-
    ///         mutable so we can tune across the 21K mining campaign
    ///         (e.g. tighten in late-game when fewer wordIds remain).
    ///         Production default 5 — matches `max_submissions_per_agent`
    ///         in the server config so the off-chain UI and on-chain
    ///         contract enforce the same limit.
    uint8 public maxCommitsPerEpoch = 5;
    event MaxCommitsPerEpochSet(uint8 newValue);

    /// @notice Emergency pause. When true, NEW epochs cannot be opened
    ///         and NEW commits are rejected. Reveal / forfeitBond /
    ///         requestDraw / fulfill / inscribe remain active so any
    ///         in-flight epoch can drain to its terminal state without
    ///         trapping bonds. Owner-toggleable.
    bool public paused;
    event Paused(bool paused);
    error PausedSystem();

    /// @notice Correct revealers per (epoch, wordId), pushed in reveal order.
    ///         Note: agents already at MAX_WINS_PER_AGENT are NOT pushed
    ///         here even if they reveal correctly — their reveal is
    ///         well-formed (bond refunded), but they don't enter the draw.
    mapping(uint256 => mapping(uint256 => address[])) public correctList;

    /// @notice Final winner per (epoch, wordId) after VRF callback
    mapping(uint256 => mapping(uint256 => address)) public winners;

    /// @notice VRF request id → packed (epochId, wordId)
    mapping(uint256 => uint256) public pendingRequests;

    /// @notice Whether a draw has already been requested for (epoch, wordId)
    mapping(uint256 => mapping(uint256 => bool)) public drawRequested;

    /// @notice Block timestamp at which `requestDraw` was called for (ep, wid).
    ///         Used by `cancelStuckDraw` to detect timeouts.
    mapping(uint256 => mapping(uint256 => uint64)) public drawRequestedAt;

    /// @notice Number of VRF requests in flight (requested but not yet
    ///         fulfilled or cancelled). Blocks `setRandomnessSource` while
    ///         non-zero so source-swap doesn't orphan callbacks (audit H-3).
    uint256 public pendingRequestsCount;

    // ============================== Events ==================================

    event EpochOpened(uint256 indexed epochId, uint64 startTs, uint64 commitDeadline, uint64 revealDeadline);
    event Committed(uint256 indexed epochId, uint256 indexed wordId, address indexed agent, bytes32 hash);
    event AnswerPublished(uint256 indexed epochId, uint256 indexed wordId, bytes32 wordHash, uint16 power, uint8 languageId);
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
    event StuckDrawCancelled(uint256 indexed epochId, uint256 indexed wordId, uint256 oldRequestId);
    event CoordinatorSet(address indexed coordinator);
    event TreasurySet(address indexed treasury);
    event RandomnessSet(address indexed randomness);

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
    error DrawAlreadyRequested();
    error DrawNotRequested();
    error NoCandidates();
    error AlreadyDrawn();
    error UnknownRequest();
    error BondAlreadyClaimed();
    error ZeroAddress();
    error PublishTooLate();
    error PublishWindowClosed();   // v2 / MEV-1
    error EmptyBatch();             // v2 / CH-1
    error DrawNotStuck();
    error PendingRequestsExist();
    error WinCapReached();
    error EpochCommitCapReached(); // SD-2

    // ============================ Constructor ===============================

    constructor(
        address initialOwner,
        bytes32 vaultMerkleRoot_,
        address randomness_,
        address coordinator_,
        address treasury_,
        address awpRegistry_,
        uint256 ardiWorknetId_,
        uint256 kyaWorknetId_,
        uint256 minStake_
    ) Ownable(initialOwner) {
        if (
            randomness_ == address(0) || coordinator_ == address(0)
                || treasury_ == address(0) || awpRegistry_ == address(0)
        ) revert ZeroAddress();
        if (ardiWorknetId_ == 0 || kyaWorknetId_ == 0) revert ZeroAddress();
        VAULT_MERKLE_ROOT = vaultMerkleRoot_;
        randomness = IRandomnessSource(randomness_);
        coordinator = coordinator_;
        treasury = treasury_;
        AWP_REGISTRY = IAWPRegistry(awpRegistry_);
        ardiWorknetId = ardiWorknetId_;
        kyaWorknetId = kyaWorknetId_;
        minStake = minStake_;
    }

    // ============================ Admin =====================================

    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setArdiWorknetId(uint256 v) external onlyOwner {
        if (v == 0) revert ZeroAddress();
        ardiWorknetId = v;
        emit ArdiWorknetIdSet(v);
    }

    function setKyaWorknetId(uint256 v) external onlyOwner {
        if (v == 0) revert ZeroAddress();
        kyaWorknetId = v;
        emit KyaWorknetIdSet(v);
    }

    function setMinStake(uint256 v) external onlyOwner {
        minStake = v;
        emit MinStakeSet(v);
    }

    /// @notice SD-2: tune the per-agent per-epoch commit cap. Setting to
    ///         0 effectively pauses commits. Recommended range 1-15.
    function setMaxCommitsPerEpoch(uint8 v) external onlyOwner {
        maxCommitsPerEpoch = v;
        emit MaxCommitsPerEpochSet(v);
    }

    /// @notice Emergency pause. Stops NEW activity (openEpoch + commit)
    ///         but does NOT block in-flight epochs from draining (reveal,
    ///         forfeitBond, requestDraw, VRF callback, inscribe all
    ///         continue to work). Use during incident response.
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    /// @notice Eligibility check: AWP-registered + at least `minStake` allocated
    ///         on either Ardi's or KYA's WorkNet. Read-only; reverts if not eligible.
    /// @dev    Cheap exit: query primary (Ardi) WN first; only read secondary if
    ///         primary is below threshold. ~5-15K gas typical.
    function _requireEligible(address agent) internal view {
        IAWPRegistry.AgentInfo memory ai = AWP_REGISTRY.getAgentInfo(agent, ardiWorknetId);
        if (!ai.isValid) revert AgentNotRegisteredInAWP();
        if (ai.stake >= minStake) return;
        // Fall back to KYA worknet.
        IAWPRegistry.AgentInfo memory ki = AWP_REGISTRY.getAgentInfo(agent, kyaWorknetId);
        if (!ki.isValid) revert AgentNotRegisteredInAWP();
        if (ki.stake >= minStake) return;
        revert InsufficientStake();
    }

    /// @notice Non-reverting variant of `_requireEligible`. Returns false if
    ///         agent doesn't satisfy the AWP eligibility predicate at the
    ///         current block. Used inside `onRandomness` to skip candidates
    ///         whose stake has been moved between commit and VRF callback.
    /// @dev    Sybil defense (SD-1): without this, an attacker could allocate
    ///         the same 10K AWP to a sequence of EOAs, have each commit /
    ///         reveal, then de-allocate to back the next EOA — using one
    ///         stake to back unbounded parallel agents. The commit-time
    ///         `_requireEligible` only proves "stake existed at commit
    ///         block"; this VRF-time re-check forces the attacker to keep
    ///         the allocation locked from commit through draw, which
    ///         serializes the attack at ~commit_window + reveal_window +
    ///         VRF latency per EOA (~5-10 min on Base) instead of being
    ///         instantly parallelizable.
    function _isEligibleView(address agent) internal view returns (bool) {
        IAWPRegistry.AgentInfo memory ai = AWP_REGISTRY.getAgentInfo(agent, ardiWorknetId);
        if (ai.isValid && ai.stake >= minStake) return true;
        IAWPRegistry.AgentInfo memory ki = AWP_REGISTRY.getAgentInfo(agent, kyaWorknetId);
        if (ki.isValid && ki.stake >= minStake) return true;
        return false;
    }

    function setRandomnessSource(address randomness_) external onlyOwner {
        if (randomness_ == address(0)) revert ZeroAddress();
        // H-3 mitigation: refuse to swap while there are unfulfilled requests,
        // which would orphan their callbacks (the new source's address won't
        // match the old reqId's expected `msg.sender == randomness` check).
        if (pendingRequestsCount > 0) revert PendingRequestsExist();
        randomness = IRandomnessSource(randomness_);
        emit RandomnessSet(randomness_);
    }

    // ============================ Lifecycle =================================

    /// @notice Coordinator opens a new epoch on-chain, declaring the timing
    ///         windows. The set of riddle wordIds is implicit — agents may
    ///         commit to any wordId they like; uninvolved wordIds simply have
    ///         empty correctList and are skipped at draw.
    function openEpoch(uint256 epochId, uint64 commitWindow, uint64 revealWindow) external {
        if (paused) revert PausedSystem();
        if (msg.sender != coordinator) revert NotCoordinator();
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

    /// @notice Submit a sealed commit + bond. Mempool sees only the hash.
    /// @dev    Win-cap guard: if the agent has already won MAX_WINS_PER_AGENT
    ///         times anywhere on the protocol, they cannot commit on any new
    ///         (epoch, wordId). Note this checks RESOLVED wins only — an agent
    ///         with several in-flight commits whose VRFs haven't fired yet may
    ///         still overshoot the cap (those overshoot wins land on chain but
    ///         can never be inscribed because the underlying wordCompromised
    ///         + winCount logic at draw time will skip them; see onRandomness).
    function commit(uint256 epochId, uint256 wordId, bytes32 hash) external payable nonReentrant {
        if (paused) revert PausedSystem();
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp >= cfg.commitDeadline) revert CommitWindowClosed();
        if (msg.value != COMMIT_BOND) revert WrongBond();
        if (agentWinCount[msg.sender] >= MAX_WINS_PER_AGENT) revert WinCapReached();
        // SD-2: per-epoch per-agent commit cap. Without this, a wealthy
        // attacker could commit on every published wordId to maximize
        // lottery hits, breaking the equal-odds property the design
        // assumes. The cap aligns chain enforcement with the off-chain
        // coordinator's `max_submissions_per_agent` server-side limit.
        if (agentCommitsInEpoch[epochId][msg.sender] >= maxCommitsPerEpoch) {
            revert EpochCommitCapReached();
        }

        // AWP eligibility — replaces the old BondEscrow KYA gate. Real-time
        // read against AWPRegistry. Reverts if agent isn't registered or
        // hasn't allocated at least minStake on either supported WorkNet.
        _requireEligible(msg.sender);

        Commit storage c = commits[epochId][wordId][msg.sender];
        if (c.hash != bytes32(0)) revert AlreadyCommitted();
        c.hash = hash;
        unchecked {
            ++agentCommitsInEpoch[epochId][msg.sender];
        }

        emit Committed(epochId, wordId, msg.sender, hash);
    }

    /// @notice (v2 / CH-1) Batch input for `publishAnswers`. One entry per wordId.
    struct AnswerData {
        uint256 wordId;
        bytes32 wordHash;
        uint16 power;
        uint8 languageId;
        bytes32[] vaultProof;
    }

    /// @notice (v2 / CH-1) Atomic batch publish for an epoch.
    /// @dev    Why batch: even with `MAX_PUBLISH_DELAY = 30s`, sequential
    ///         single-publishes left a 2x reveal-window gap between the
    ///         first and last wordId (60s vs 30s under default windows).
    ///         A colluding Coordinator could "publish-late" a specific
    ///         wordId to compress competitors' reveal time. Forcing the
    ///         entire epoch's set into one tx eliminates that ordering
    ///         degree of freedom — every wordId in the epoch gets the
    ///         same publishTimestamp, hence the same reveal runway.
    ///
    ///         Single-publishAnswer is kept (below) as a thin wrapper for
    ///         backwards compatibility with operator tooling; new
    ///         deployments should use this.
    function publishAnswers(uint256 epochId, AnswerData[] calldata data) external {
        if (data.length == 0) revert EmptyBatch();
        _assertPublishWindow(epochId);

        for (uint256 i; i < data.length;) {
            AnswerData calldata d = data[i];
            _publishOne(epochId, d.wordId, d.wordHash, d.power, d.languageId, d.vaultProof);
            unchecked { ++i; }
        }
    }

    /// @notice Single-publish wrapper. Kept for backwards compatibility +
    ///         emergency manual recovery. Subject to the same gates as
    ///         `publishAnswers`. Mainline path is the batch.
    function publishAnswer(
        uint256 epochId,
        uint256 wordId,
        bytes32 wordHash,
        uint16 power,
        uint8 languageId,
        bytes32[] calldata vaultProof
    ) external {
        _assertPublishWindow(epochId);
        _publishOne(epochId, wordId, wordHash, power, languageId, vaultProof);
    }

    /// @dev Shared publish-window gates for `publishAnswers` and
    ///      `publishAnswer`. Closes Opus NM-1 / Codex Info-2: previously
    ///      both externals duplicated 6 gate checks; future maintainers
    ///      could update one and miss the other. Single source of truth.
    function _assertPublishWindow(uint256 epochId) internal view {
        if (msg.sender != coordinator) revert NotCoordinator();
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.commitDeadline) revert CommitWindowNotClosed();
        if (block.timestamp >= cfg.revealDeadline) revert RevealWindowClosed();
        if (block.timestamp + MIN_REVEAL_AFTER_PUBLISH > cfg.revealDeadline) {
            revert PublishTooLate();
        }
        if (block.timestamp > cfg.commitDeadline + MAX_PUBLISH_DELAY) {
            revert PublishWindowClosed();
        }
    }

    function _publishOne(
        uint256 epochId,
        uint256 wordId,
        bytes32 wordHash,
        uint16 power,
        uint8 languageId,
        bytes32[] calldata vaultProof
    ) internal {
        Answer storage ans = answers[epochId][wordId];
        if (ans.published) revert AnswerAlreadyPublished();
        if (wordHash == bytes32(0)) revert InvalidVaultProof();
        if (power == 0 || power > 100) revert InvalidPower();
        if (languageId > 5) revert InvalidLanguage();

        bytes32 leaf = keccak256(abi.encodePacked(wordId, wordHash, power, languageId));
        if (!MerkleProof.verify(vaultProof, VAULT_MERKLE_ROOT, leaf)) revert InvalidVaultProof();

        ans.wordHash = wordHash;
        ans.power = power;
        ans.languageId = languageId;
        ans.published = true;

        emit AnswerPublished(epochId, wordId, wordHash, power, languageId);
    }

    /// @notice Reveal a guess. Must run during the reveal window AND after
    ///         the answer for this (epoch, wordId) has been published.
    ///         Bond is refunded on successful commit-match.
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

        // Determine correctness
        bool isCorrect = (keccak256(bytes(guess)) == ans.wordHash);
        if (isCorrect) {
            c.correct = true;
            // v1.0: a correct reveal always leaks the plaintext via tx
            // calldata, so the wordId is permanently "compromised" — the
            // Coordinator must never re-pick it, regardless of mint outcome.
            // First correct revealer also fires the WordCompromised event
            // (off-chain indexers consume this to update selection pools).
            if (!wordCompromised[wordId]) {
                wordCompromised[wordId] = true;
                emit WordCompromised(wordId, epochId, msg.sender);
            }
            // Win-cap guard: agents already at MAX_WINS_PER_AGENT are NOT
            // pushed into the candidate pool. Their reveal still succeeds
            // (bond refund) and isCorrect is true on the event, but they're
            // not eligible to win this slot. This prevents accidental
            // overshoot from in-flight commits made before earlier wins
            // resolved.
            if (agentWinCount[msg.sender] < MAX_WINS_PER_AGENT) {
                correctList[epochId][wordId].push(msg.sender);
            } else {
                emit RevealRejectedAtCap(epochId, wordId, msg.sender);
            }
        }

        // Refund bond (CEI: state already updated above)
        c.bondClaimed = true;
        (bool ok,) = msg.sender.call{value: COMMIT_BOND}("");
        require(ok, "bond refund failed");

        emit Revealed(epochId, wordId, msg.sender, isCorrect);
    }

    /// @notice Anyone can request the draw once the reveal window is over.
    ///         A previously requested draw cannot be re-requested.
    /// @dev    CEI: set drawRequested = true BEFORE the external call to
    ///         randomness.requestRandomness() so that even if the randomness
    ///         source is malicious and re-enters here, the duplicate-request
    ///         check trips.
    function requestDraw(uint256 epochId, uint256 wordId) external nonReentrant {
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.revealDeadline) revert RevealWindowNotClosed();
        if (drawRequested[epochId][wordId]) revert DrawAlreadyRequested();

        // Mark requested unconditionally — both branches below set it.
        drawRequested[epochId][wordId] = true;

        uint256 candidates = correctList[epochId][wordId].length;
        if (candidates == 0) {
            emit NoCorrectRevealers(epochId, wordId);
            return;
        }

        uint256 reqId = randomness.requestRandomness();
        // Pack (epoch, wordId) into 256 bits; both fit comfortably in 128 each.
        // We can only learn `reqId` after the external call returns, so this
        // write is necessarily post-call. A re-entrant call from a malicious
        // randomness source can't bypass drawRequested (already set above).
        pendingRequests[reqId] = (epochId << 128) | wordId;
        drawRequestedAt[epochId][wordId] = uint64(block.timestamp);
        unchecked { ++pendingRequestsCount; }

        emit DrawRequested(epochId, wordId, reqId, candidates);
    }

    /// @notice Anyone can cancel a stuck VRF request after DRAW_FULFILLMENT_TIMEOUT
    ///         seconds without a fulfillment. Resets `drawRequested` so that
    ///         `requestDraw` can be called again. Closes audit H-2.
    /// @dev    The original pendingRequests[reqId] mapping entry is left in
    ///         place — if the lost callback later does fulfill, `onRandomness`
    ///         will see `winners[ep][wid] != 0` (after re-draw success) and
    ///         revert with AlreadyDrawn. To make sure that happens, the
    ///         cancellation does NOT delete pendingRequests; future callbacks
    ///         to the cancelled request will safely revert.
    function cancelStuckDraw(uint256 epochId, uint256 wordId) external {
        if (!drawRequested[epochId][wordId]) revert DrawNotRequested();
        if (winners[epochId][wordId] != address(0)) revert AlreadyDrawn();
        uint64 reqTs = drawRequestedAt[epochId][wordId];
        if (reqTs == 0) revert DrawNotRequested();  // empty correctList path; nothing to cancel
        if (block.timestamp < reqTs + DRAW_FULFILLMENT_TIMEOUT) revert DrawNotStuck();

        // Reset so a fresh requestDraw can run
        drawRequested[epochId][wordId] = false;
        drawRequestedAt[epochId][wordId] = 0;
        if (pendingRequestsCount > 0) {
            unchecked { --pendingRequestsCount; }
        }
        emit StuckDrawCancelled(epochId, wordId, 0);
    }

    /// @notice VRF callback — picks the winner from the correct list.
    /// @dev    v1.0: walks candidates starting from `randomWord % n` and picks
    ///         the first one whose agentWinCount is below MAX_WINS_PER_AGENT.
    ///         The reveal-time cap-guard usually keeps cap-saturated agents
    ///         out of the list entirely, but if they hit cap between reveal
    ///         and draw (via another epoch's draw firing first), this
    ///         post-hoc filter prevents the overshoot. If ALL candidates are
    ///         saturated, no winner is selected (NoEligibleWinner event)
    ///         and the wordId stays unminted — wordCompromised flag still
    ///         applies (set at first correct reveal), so Coordinator excludes
    ///         it from future selection.
    /// @dev    SD-1 (sybil defense): also skip candidates whose AWP
    ///         allocation has been pulled between commit and now. See
    ///         `_isEligibleView` doc for the attack this blocks. Adds a
    ///         per-candidate ~5-15K gas (2 EXTCALL to AWPRegistry); n is
    ///         bounded in practice so callback gas budget holds.
    function onRandomness(uint256 requestId, uint256 randomWord) external override {
        if (msg.sender != address(randomness)) revert NotRandomnessSource();
        uint256 packed = pendingRequests[requestId];
        if (packed == 0) revert UnknownRequest();
        delete pendingRequests[requestId];

        uint256 epochId = packed >> 128;
        uint256 wordId = packed & ((uint256(1) << 128) - 1);

        if (winners[epochId][wordId] != address(0)) revert AlreadyDrawn();

        address[] storage cands = correctList[epochId][wordId];
        uint256 n = cands.length;
        if (n == 0) revert NoCandidates();

        // Find first eligible (winCount < MAX **and** still AWP-staked)
        // starting from random offset. Bounded at MAX_LOTTERY_ITERATIONS
        // so callback gas stays under Chainlink's 2.5M ceiling regardless
        // of correctList size. If 200 iter all ineligible (extreme sybil
        // scenario), we don't lock the slot — a fresh requestDraw can
        // re-roll with a different random offset and sample a different
        // segment. Probability of 200-in-a-row failure is < 1e-9 even at
        // 10% eligible population, so retry is a defense-in-depth, not a
        // common path.
        address winner = address(0);
        uint256 start = randomWord % n;
        uint256 maxIter = n < MAX_LOTTERY_ITERATIONS ? n : MAX_LOTTERY_ITERATIONS;
        for (uint256 i = 0; i < maxIter; i++) {
            address c = cands[(start + i) % n];
            if (agentWinCount[c] >= MAX_WINS_PER_AGENT) continue;
            // SD-1: candidate must STILL be AWP-eligible at draw time.
            if (!_isEligibleView(c)) continue;
            winner = c;
            break;
        }

        // Clear the timestamp regardless — this slot has been processed.
        drawRequestedAt[epochId][wordId] = 0;
        if (pendingRequestsCount > 0) {
            unchecked { --pendingRequestsCount; }
        }

        if (winner == address(0)) {
            // No eligible winner found in the bounded walk. Two cases:
            //   (a) cands.length <= MAX_LOTTERY_ITERATIONS and we walked
            //       everyone — all are saturated/ineligible. Hopeless;
            //       wordId stays unminted (existing semantics).
            //   (b) cands.length > MAX_LOTTERY_ITERATIONS and we sampled
            //       only a slice — the slice happened to be all bad.
            //       VERY unlikely (~1e-9 probability), but recoverable:
            //       reset drawRequested so anyone can call requestDraw
            //       again to fire a fresh VRF (different random offset
            //       → samples different slice).
            if (n > maxIter) {
                drawRequested[epochId][wordId] = false;
                emit LotteryNeedsRetry(epochId, wordId, n);
            } else {
                emit NoEligibleWinner(epochId, wordId, n);
            }
            return;
        }

        winners[epochId][wordId] = winner;
        unchecked { ++agentWinCount[winner]; }

        emit WinnerSelected(epochId, wordId, winner);
    }

    /// @notice After the reveal window closes, settle the bond of an unrevealed
    ///         commit. Two cases:
    ///           - Answer was published: the agent failed to reveal → bond is
    ///             forfeited to the treasury (anti-grief).
    ///           - Answer was NOT published: Coordinator failed → the agent
    ///             gets their bond back (no penalty for Coordinator's failure).
    ///         Anyone can call this — the destination is determined by state,
    ///         not by caller.
    function forfeitBond(uint256 epochId, uint256 wordId, address agent) external nonReentrant {
        EpochCfg memory cfg = epochs[epochId];
        if (!cfg.exists) revert EpochUnknown();
        if (block.timestamp < cfg.revealDeadline) revert RevealWindowNotClosed();

        Commit storage c = commits[epochId][wordId][agent];
        if (c.hash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (c.bondClaimed) revert BondAlreadyClaimed();

        c.bondClaimed = true;
        // Two-branch destination: either treasury (Coordinator-set, zero-checked
        // in setTreasury) or the original committer (msg.sender at commit time,
        // which is never zero because EVM rejects address(0) as a transaction
        // origin). Slither's "arbitrary-send-eth" warning here is a false
        // positive — neither destination is attacker-controlled.
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

    /// @notice Convenience getter for the published answer (used by ArdiNFT).
    /// @dev    v1.0: returns wordHash, NOT plaintext word. Plaintext is supplied
    ///         by the winner at inscribe time and verified against this hash.
    function getAnswer(uint256 epochId, uint256 wordId)
        external
        view
        returns (bytes32 wordHash, uint16 power, uint8 languageId, bool published)
    {
        Answer memory a = answers[epochId][wordId];
        return (a.wordHash, a.power, a.languageId, a.published);
    }

    /// @notice Number of correct revealers for (epoch, wordId). Used for
    ///         off-chain monitoring and the draw size prior to VRF.
    function correctCount(uint256 epochId, uint256 wordId) external view returns (uint256) {
        return correctList[epochId][wordId].length;
    }
}
