// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IArdiEpochDraw {
    function winners(uint256 epochId, uint256 wordId) external view returns (address);
    /// @dev v1.0: returns wordHash (not plaintext); inscribe verifies user-supplied word against it.
    function getAnswer(uint256 epochId, uint256 wordId)
        external
        view
        returns (bytes32 wordHash, uint16 power, uint8 languageId, bool published);
    function agentWinCount(address agent) external view returns (uint8);
}

/// @title ArdiNFT — the Ardinal inscription token (ERC-721)
/// @notice 21,000 originals (tokenIds 1..21,000), each tied to a unique vault wordId
///         (0..20,999). Plus fusion products (tokenIds 21,001+).
/// @dev    All minting and fusing requires a Coordinator signature. The Coordinator
///         is the off-chain service that runs riddle epochs, validates submissions,
///         runs the verifiable random draw, and invokes the LLM oracle for fusions.
///         Vault Merkle root is set at deployment and immutable thereafter.
contract ArdiNFT is ERC721, ERC721Burnable, Ownable2Step, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // --- Constants ---

    uint256 public constant ORIGINAL_CAP = 21_000;
    /// @notice Per-agent cap. Enforced upstream in ArdiEpochDraw via
    ///         agentWinCount; kept here as a constant for off-chain UIs.
    uint8 public constant MAX_MINTS_PER_AGENT = 3;
    uint8 public constant LANG_EN = 0;
    uint8 public constant LANG_ZH = 1;
    uint8 public constant LANG_JA = 2;
    uint8 public constant LANG_KO = 3;
    uint8 public constant LANG_FR = 4;
    uint8 public constant LANG_DE = 5;

    // --- Inscription data ---

    struct Inscription {
        string word; // revealed only on mint
        uint16 power; // 1-100 originals; up to ~10000 after fusion compounding
        uint8 languageId; // 0..5 enum above
        uint8 generation; // 0 = original, 1+ = fusion product
        address inscriber;
        uint64 timestamp;
        uint256[] parents; // empty for originals, length 2 for fusions
    }

    /// @notice tokenId → Inscription struct
    mapping(uint256 => Inscription) public inscriptions;

    /// @notice wordId (0..20,999) → minted yet? Prevents double-minting same word.
    mapping(uint256 => bool) public wordMinted;

    /// @notice agent address → number of originals minted. Tracks how many
    ///         NFTs this agent has actually inscribed; the per-agent cap is
    ///         enforced UPSTREAM in ArdiEpochDraw via agentWinCount (winning
    ///         counts toward the cap, not just minting). This counter is
    ///         retained as a public view for indexers / UIs that want to show
    ///         "minted N of M" alongside "won N of M".
    mapping(address => uint8) public agentMintCount;

    /// @notice Total originals minted (0..21,000). When this hits 21,000, isSealed = true.
    uint256 public totalInscribed;

    /// @notice Total fusion products minted (used to derive fusion tokenIds: 21,000 + fusionCount).
    uint256 public fusionCount;

    /// @notice Once 21,000 originals minted, no more inscribe() allowed.
    bool public isSealed;

    /// @notice Vault Merkle root committed at deployment. Used by off-chain proof
    ///         verification (does not affect on-chain inscribe path, which trusts
    ///         Coordinator signature). Logged for transparency / auditability.
    bytes32 public immutable VAULT_MERKLE_ROOT;

    // --- Coordinator authority ---

    address public coordinator;
    /// @notice (v2) Per-holder fuse nonce.
    ///         Replaces the v1 single global counter, which had a UX hazard:
    ///         any successful fuse() in the world bumped the global counter,
    ///         invalidating every previously-signed-but-not-yet-submitted
    ///         authorization for every other holder. A griefer could spam
    ///         cheap fuses to repeatedly invalidate a target user's pending
    ///         signature. Per-holder nonces decouple users entirely.
    /// @dev    Read by Coordinator at sign time; bumped on each fuse() of a
    ///         given holder. Signature digest binds (holder, holderNonce).
    mapping(address => uint256) public fusionNonceOf;

    // --- On-chain draw authority ---

    /// @notice ArdiEpochDraw contract. The single source of truth for "who won
    ///         the lottery for (epoch, wordId)". Inscribe enforces that
    ///         msg.sender == winners[epoch][wordId]. Set once at deploy by owner;
    ///         can be updated by owner (multisig) only if the draw contract is
    ///         migrated. There is no Coordinator signature path — winners are
    ///         determined fully on-chain via commit-reveal + VRF.
    IArdiEpochDraw public epochDraw;

    // --- Events ---

    event Inscribed(
        address indexed agent,
        uint256 indexed tokenId,
        uint256 indexed wordId,
        string word,
        uint16 power,
        uint8 languageId
    );

    event Fused(
        address indexed holder,
        uint256 indexed tokenIdA,
        uint256 indexed tokenIdB,
        uint256 newTokenId,
        string newWord,
        uint16 newPower,
        uint8 newLanguageId,
        uint8 generation
    );

    event FusionFailed(
        address indexed holder, uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 burnedId
    );

    event Sealed(uint256 timestamp);
    event CoordinatorSet(address indexed coordinator);
    event EpochDrawSet(address indexed epochDraw);

    // --- Errors ---

    error AlreadySealed();
    error AgentCapReached();
    error WordAlreadyMinted();
    error InvalidSignature();
    error InvalidLanguage();
    error InvalidWordId();
    error NotTokenOwner();
    error SameTokenId();
    error InvalidPower();
    error ZeroAddress();
    error NotWinner();
    error AnswerNotPublished();
    error EpochDrawNotSet();
    error MintParamsMismatch();
    error WordMismatch();

    // --- Constructor ---

    constructor(address initialOwner, address coordinator_, bytes32 vaultMerkleRoot_)
        ERC721("Ardinal", "ARDI")
        Ownable(initialOwner)
    {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        VAULT_MERKLE_ROOT = vaultMerkleRoot_;
        emit CoordinatorSet(coordinator_);
    }

    // --- Admin ---

    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    function setEpochDraw(address epochDraw_) external onlyOwner {
        if (epochDraw_ == address(0)) revert ZeroAddress();
        epochDraw = IArdiEpochDraw(epochDraw_);
        emit EpochDrawSet(epochDraw_);
    }

    // --- Inscribe (mint original) ---

    /// @notice Mint an original Ardinal. The caller MUST be the on-chain
    ///         lottery winner for (epochId, wordId), as determined by the
    ///         ArdiEpochDraw contract via commit-reveal + Chainlink VRF.
    ///         No Coordinator signature is needed or accepted — the lottery
    ///         is fully verifiable on-chain.
    /// @dev    v1.0: caller supplies the plaintext `word`. The contract:
    ///           1. Verifies they're the on-chain winner.
    ///           2. Reads (wordHash, power, lang) from EpochDraw.getAnswer.
    ///           3. Verifies keccak256(word) == wordHash.
    ///         The wordHash itself was Merkle-proven against VAULT_MERKLE_ROOT
    ///         at publishAnswer time, so a hash-match means the supplied word
    ///         is the canonical vault entry.
    ///
    ///         The mint cap is enforced UPSTREAM by ArdiEpochDraw (agents who
    ///         have hit MAX_WINS_PER_AGENT can't commit, so can't end up
    ///         here). The agentMintCount check below is belt-and-suspenders.
    /// @param  epochId  The epoch in which this win occurred.
    /// @param  wordId   0..20,999
    /// @param  word     Plaintext canonical word. Must satisfy
    ///                  keccak256(bytes(word)) == answer.wordHash.
    function inscribe(uint64 epochId, uint256 wordId, string calldata word) external nonReentrant {
        if (address(epochDraw) == address(0)) revert EpochDrawNotSet();
        if (isSealed) revert AlreadySealed();
        // BondEscrow check removed in v2: eligibility (AWP allocation ≥ minStake
        // on Ardi or KYA WorkNet) is now enforced at commit() time in
        // ArdiEpochDraw. By the time we reach inscribe, the agent already
        // passed the gate and won the VRF — we don't re-check de-allocations.
        if (agentMintCount[msg.sender] >= MAX_MINTS_PER_AGENT) revert AgentCapReached();
        if (wordMinted[wordId]) revert WordAlreadyMinted();
        if (wordId >= ORIGINAL_CAP) revert InvalidWordId();

        // Single source of truth: ArdiEpochDraw says who won.
        if (epochDraw.winners(epochId, wordId) != msg.sender) revert NotWinner();

        // Pull the published hash + power/lang. Plaintext is supplied by the
        // caller and verified against the hash here (defense against the
        // "winner submits arbitrary metadata" attack).
        (bytes32 wordHash, uint16 power, uint8 languageId, bool published) =
            epochDraw.getAnswer(epochId, wordId);
        if (!published) revert AnswerNotPublished();
        if (keccak256(bytes(word)) != wordHash) revert WordMismatch();
        if (languageId > LANG_DE) revert InvalidLanguage();
        if (power == 0 || power > 100) revert InvalidPower();

        // Effects
        wordMinted[wordId] = true;
        unchecked {
            ++agentMintCount[msg.sender];
            ++totalInscribed;
        }

        uint256 tokenId = wordId + 1; // tokenId 1..21000 maps to wordId 0..20999

        Inscription storage ins = inscriptions[tokenId];
        ins.word = word;
        ins.power = power;
        ins.languageId = languageId;
        ins.generation = 0;
        ins.inscriber = msg.sender;
        ins.timestamp = uint64(block.timestamp);
        // ins.parents stays empty

        _safeMint(msg.sender, tokenId);

        emit Inscribed(msg.sender, tokenId, wordId, word, power, languageId);

        // No more onMinted hook — BondEscrow reads agentWinCount() from
        // EpochDraw directly. Win counts (not mint counts) drive bond unlock,
        // since winning + squatting still consumes a cap slot.

        if (totalInscribed >= ORIGINAL_CAP) {
            isSealed = true;
            emit Sealed(block.timestamp);
        }
    }

    // --- Fuse ---

    /// @notice Fuse two Ardinals owned by the caller. Coordinator's LLM oracle
    ///         determines compatibility, suggested new word, and success/fail.
    /// @param  tokenIdA  First Ardinal (must be owned by caller)
    /// @param  tokenIdB  Second Ardinal (must be owned by caller)
    /// @param  newWord   LLM-suggested word for the new Ardinal (only used on success)
    /// @param  newPower  Computed (powerA + powerB) × multiplier (only used on success)
    /// @param  newLangId Output language id (only used on success)
    /// @param  success   Whether the fusion succeeded per oracle's success_rate roll
    /// @param  signature Coordinator's ECDSA signature over the FuseAuth payload
    function fuse(
        uint256 tokenIdA,
        uint256 tokenIdB,
        string calldata newWord,
        uint16 newPower,
        uint8 newLangId,
        bool success,
        bytes calldata signature
    ) external nonReentrant {
        if (tokenIdA == tokenIdB) revert SameTokenId();
        if (ownerOf(tokenIdA) != msg.sender) revert NotTokenOwner();
        if (ownerOf(tokenIdB) != msg.sender) revert NotTokenOwner();
        if (newLangId > LANG_DE) revert InvalidLanguage();

        // v2: per-holder nonce (was global single counter — see fusionNonceOf doc).
        // Bump the version tag because the digest layout changed; a V2 signature
        // would not validate under the V3 layout (and vice versa).
        uint256 _nonce = fusionNonceOf[msg.sender];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "ARDI_FUSE_V3",
                block.chainid,
                address(this),
                msg.sender,
                tokenIdA,
                tokenIdB,
                newWord,
                newPower,
                newLangId,
                success,
                _nonce
            )
        ).toEthSignedMessageHash();
        if (digest.recover(signature) != coordinator) revert InvalidSignature();
        unchecked {
            ++fusionNonceOf[msg.sender];
        }

        if (success) {
            // Burn both, mint new
            uint8 genA = inscriptions[tokenIdA].generation;
            uint8 genB = inscriptions[tokenIdB].generation;
            uint8 newGen = (genA > genB ? genA : genB) + 1;

            _burn(tokenIdA);
            _burn(tokenIdB);

            unchecked {
                ++fusionCount;
            }
            uint256 newTokenId = ORIGINAL_CAP + fusionCount;

            uint256[] memory parents = new uint256[](2);
            parents[0] = tokenIdA;
            parents[1] = tokenIdB;

            Inscription storage ins = inscriptions[newTokenId];
            ins.word = newWord;
            ins.power = newPower;
            ins.languageId = newLangId;
            ins.generation = newGen;
            ins.inscriber = msg.sender;
            ins.timestamp = uint64(block.timestamp);
            ins.parents = parents;

            _safeMint(msg.sender, newTokenId);

            emit Fused(
                msg.sender, tokenIdA, tokenIdB, newTokenId, newWord, newPower, newLangId, newGen
            );
        } else {
            // Burn lower-power
            uint16 pA = inscriptions[tokenIdA].power;
            uint16 pB = inscriptions[tokenIdB].power;
            uint256 burnId = pA <= pB ? tokenIdA : tokenIdB;
            _burn(burnId);
            emit FusionFailed(msg.sender, tokenIdA, tokenIdB, burnId);
        }
    }

    // --- Views ---

    /// @notice Returns the Inscription struct for a given tokenId.
    /// @dev    Convenience view — public mapping getter doesn't return the parents array.
    function getInscription(uint256 tokenId) external view returns (Inscription memory) {
        _requireOwned(tokenId);
        return inscriptions[tokenId];
    }

    /// @notice Returns the Power of a single token. Off-chain indexers aggregate
    ///         per-holder Power totals via the Inscribed / Fused / FusionFailed event
    ///         stream + ERC-721 Transfer events. Aggregation is intentionally
    ///         off-chain to keep the on-chain path cheap.
    function powerOf(uint256 tokenId) external view returns (uint16) {
        _requireOwned(tokenId);
        return inscriptions[tokenId].power;
    }
}
