// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IArdiTokenMint} from "./interfaces/IArdiTokenMint.sol";

/// @title ArdiMintController — daily $aArdi emission + dual-token Merkle airdrop (AWP-aligned)
///
/// Aligns Ardi with the AWP WorkNet manager interface:
///   - $aArdi emission (worknet token): 100% to NFT holders by power weight
///   - AWP receipt   (from AWP protocol DAO-voted share):
///       OWNER_OPS_BPS to operator (10% by default, Timelock-adjustable up
///         to MAX_OWNER_OPS_BPS = 20%); withdrawable any time by the
///         OWNER_OPS_ROLE holder
///       remainder to NFT holders, by the same power weight, in the same
///         daily Merkle as $aArdi
///
/// A single `claim(day, ardiAmount, awpAmount, proof)` call distributes
/// both tokens.
///
/// Access roles:
///   DEFAULT_ADMIN_ROLE — protocol governance (production: Timelock multisig).
///                         Can rotate Coordinator, change owner-ops bps + addr.
///   MERKLE_ROLE        — Coordinator's signing key. Calls settleDay each epoch.
///   OWNER_OPS_ROLE     — operator EOA. Withdraws accrued AWP ops cut.
///
/// Emission schedule (180 days, 9B $aArdi total, on-chain enforceable):
///   Phase 1 (Day 1-14):  954M × 0.8706^(d-1)   5-day half-life, 70% supply
///   Phase 2 (Day 15-180): 63M × 0.9772^(d-15)  30-day half-life, 30% supply
contract ArdiMintController is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---

    bytes32 public constant MERKLE_ROLE = keccak256("MERKLE_ROLE");
    bytes32 public constant OWNER_OPS_ROLE = keccak256("OWNER_OPS_ROLE");

    // --- Schedule constants ---

    uint256 public constant PHASE1_DAYS = 14;
    uint256 public constant PHASE2_DAYS = 166; // total 180

    /// @notice Day-1 emission for Phase 1, in 1e18 wei units. Approx 954M $aArdi.
    uint256 public constant PHASE1_DAY1 = 954_277_300 ether;
    uint256 public constant PHASE1_NUMERATOR = 8706; // 0.8706
    uint256 public constant PHASE1_DENOMINATOR = 10000;

    /// @notice Day-15 emission for Phase 2 in 1e18 wei units. Approx 63M $aArdi.
    uint256 public constant PHASE2_DAY1 = 63_375_500 ether;
    uint256 public constant PHASE2_NUMERATOR = 9772; // 0.9772
    uint256 public constant PHASE2_DENOMINATOR = 10000;

    /// @notice Hard upper bound on the operator's AWP ops cut. Even Timelock
    ///         cannot exceed this. 20% is generous; default starts at 10%.
    uint16 public constant MAX_OWNER_OPS_BPS = 2000;

    /// @notice Hard cap on Merkle proof length to prevent calldata griefing.
    uint256 public constant MAX_PROOF_LEN = 32;

    // --- Externals ---

    IArdiTokenMint public immutable ARDI_TOKEN;
    IERC20 public immutable AWP;

    /// @notice The Coordinator's reference address — used by sibling contracts
    ///         (ArdiNFT, ArdiBondEscrow) for cross-contract identification.
    ///         Distinct from MERKLE_ROLE (which gates settleDay) — typically the
    ///         same key, but split for finer-grained ops.
    address public coordinator;

    /// @notice Single EOA that receives the AWP ops cut on withdraw. Set
    ///         (and rotated) by DEFAULT_ADMIN_ROLE (Timelock).
    address public ownerOpsAddr;

    /// @notice Operator's share of received AWP, in basis points.
    ///         Adjustable by DEFAULT_ADMIN_ROLE; capped at MAX_OWNER_OPS_BPS.
    uint16 public ownerOpsBps = 1000; // 10% default

    /// @notice (v2 / CH-2) Max share of any single day's distribution that
    ///         a single holder can claim. Defense in depth against a
    ///         compromised MERKLE_ROLE submitting a root that allocates
    ///         the whole pot to a single attacker leaf.
    ///
    ///         Default 5000 (50%) — loose enough to never block legitimate
    ///         distribution (max realistic single-holder share is ~5-30%
    ///         depending on early-game NFT distribution), tight enough
    ///         that a rug requires multiple compromised claim leaves.
    ///         DEFAULT_ADMIN_ROLE (Timelock multisig) can lower this once
    ///         distribution stabilizes, or raise temporarily during
    ///         genesis-day scenarios where a single holder owns everything.
    ///         Capped on the upside at 10000 (100%); 0 disables claims.
    uint16 public maxPerHolderBps = 5000;

    /// @notice Genesis timestamp marking day 1 (00:00 UTC of mining start).
    uint256 public immutable GENESIS_TS;

    // --- Per-day state ---

    /// @dev DailyRoot stores the dual-token Merkle root + totals for one day.
    struct DailyRoot {
        bytes32 root;             // keccak(account, ardiAmount, awpAmount)
        uint256 ardiTotal;        // $aArdi distributed to holders this day
        uint256 awpTotalToHolders; // AWP distributed to holders this day (90% by default)
        uint256 awpOwnerCut;       // AWP added to ownerAwpReserve this day (10% by default)
        uint256 publishedAt;
        /// @notice (v2 / CH-3) Block number at which the holder snapshot
        ///         was taken. Off-chain settlement workers commit to a
        ///         specific block before computing leaves; recording it
        ///         on-chain lets any party independently re-derive the
        ///         distribution and verify it matches the root.
        ///         Must be ≤ block.number at settleDay time and strictly
        ///         monotone increasing across days.
        uint64 snapshotBlock;
    }

    mapping(uint256 => DailyRoot) public dailyRoots;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public lastSettledDay;
    uint256 public cumulativeMinted;        // cumulative $aArdi minted via claims
    uint256 public ownerAwpReserve;          // AWP accrued for ops, withdrawable anytime
    uint256 public awpReservedForClaims;     // AWP earmarked for unclaimed holder rewards

    // --- Events ---

    event DailySettled(
        uint256 indexed day,
        bytes32 root,
        uint256 ardiTotal,
        uint256 awpToHolders,
        uint256 awpOwnerCut,
        uint64 snapshotBlock
    );
    event MaxPerHolderBpsSet(uint16 newBps);
    event Claimed(
        uint256 indexed day,
        address indexed account,
        uint256 ardiAmount,
        uint256 awpAmount
    );
    event CoordinatorSet(address indexed coordinator);
    event OwnerOpsAddrSet(address indexed addr);
    event OwnerOpsBpsSet(uint16 newBps);
    event OwnerAwpWithdrawn(address indexed to, uint256 amount);

    // --- Errors ---

    error AlreadySettled();
    error DayInFuture();
    error AlreadyClaimed();
    error InvalidProof();
    error EmissionExhausted();
    error PrematureSettlement();
    error InsufficientAwpHeld();
    error ExceedsReserve();
    error ExceedsBpsCap();
    error ExceedsPerHolderCap();        // v2 / CH-2
    error InvalidSnapshotBlock();        // v2 / CH-3
    error ZeroAddress();

    // --- Constructor ---

    /// @param admin            the DEFAULT_ADMIN_ROLE holder — set this to the
    ///                          Timelock address in production
    /// @param ardiToken_       address of the worknet token (auto-deployed by
    ///                          AWP at activation)
    /// @param awpToken_        address of $AWP on the target chain
    /// @param coordinator_     Coordinator service signing key (also gets MERKLE_ROLE)
    /// @param ownerOpsAddr_    EOA receiving the AWP ops cut on withdraw
    /// @param genesisTs_       unix timestamp marking day 1
    constructor(
        address admin,
        address ardiToken_,
        address awpToken_,
        address coordinator_,
        address ownerOpsAddr_,
        uint256 genesisTs_
    ) {
        if (
            admin == address(0) || ardiToken_ == address(0) || awpToken_ == address(0)
                || coordinator_ == address(0) || ownerOpsAddr_ == address(0)
        ) {
            revert ZeroAddress();
        }
        ARDI_TOKEN = IArdiTokenMint(ardiToken_);
        AWP = IERC20(awpToken_);
        coordinator = coordinator_;
        ownerOpsAddr = ownerOpsAddr_;
        GENESIS_TS = genesisTs_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MERKLE_ROLE, coordinator_);
        _grantRole(OWNER_OPS_ROLE, ownerOpsAddr_);

        emit CoordinatorSet(coordinator_);
        emit OwnerOpsAddrSet(ownerOpsAddr_);
    }

    // --- Admin ---

    function setCoordinator(address coordinator_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (coordinator_ == address(0)) revert ZeroAddress();
        // Rotate roles + reference address atomically. NEW coordinator gets
        // MERKLE_ROLE; OLD loses it. Caller (admin / Timelock) is responsible
        // for ensuring the in-flight settlement is quiesced before rotating.
        _revokeRole(MERKLE_ROLE, coordinator);
        coordinator = coordinator_;
        _grantRole(MERKLE_ROLE, coordinator_);
        emit CoordinatorSet(coordinator_);
    }

    function setOwnerOpsAddr(address newAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAddr == address(0)) revert ZeroAddress();
        _revokeRole(OWNER_OPS_ROLE, ownerOpsAddr);
        ownerOpsAddr = newAddr;
        _grantRole(OWNER_OPS_ROLE, newAddr);
        emit OwnerOpsAddrSet(newAddr);
    }

    function setOwnerOpsBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_OWNER_OPS_BPS) revert ExceedsBpsCap();
        ownerOpsBps = newBps;
        emit OwnerOpsBpsSet(newBps);
    }

    /// @notice (v2 / CH-2) Tune the per-holder daily claim cap.
    /// @dev    Hard-bounded at 10000 bps (100%); 0 effectively pauses claims.
    function setMaxPerHolderBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > 10_000) revert ExceedsBpsCap();
        maxPerHolderBps = newBps;
        emit MaxPerHolderBpsSet(newBps);
    }

    // --- Emission schedule (deterministic, on-chain enforceable) ---

    function dailyEmission(uint256 day) public pure returns (uint256) {
        if (day == 0) return 0;
        if (day > PHASE1_DAYS + PHASE2_DAYS) return 0;
        if (day <= PHASE1_DAYS) {
            return _compoundDecay(PHASE1_DAY1, day - 1, PHASE1_NUMERATOR, PHASE1_DENOMINATOR);
        }
        uint256 phase2Day = day - PHASE1_DAYS - 1;
        return _compoundDecay(PHASE2_DAY1, phase2Day, PHASE2_NUMERATOR, PHASE2_DENOMINATOR);
    }

    function _compoundDecay(uint256 principal, uint256 exp, uint256 num, uint256 den)
        internal
        pure
        returns (uint256)
    {
        uint256 result = principal;
        for (uint256 i; i < exp;) {
            result = (result * num) / den;
            unchecked { ++i; }
        }
        return result;
    }

    // --- Daily settlement ---

    /// @notice Coordinator submits the day's Merkle root + totals.
    /// @dev    Single Merkle covers BOTH $aArdi and AWP for each holder:
    ///           leaf = keccak256(abi.encodePacked(account, ardiAmount, awpAmount))
    ///         The Coordinator computes the AWP split off-chain (10/90 by
    ///         default) and passes the per-holder portion as `awpToHolders`.
    ///         The contract additionally accrues `awpOwnerCut` to ownerAwpReserve.
    /// @param  day                  1-indexed day number
    /// @param  root                 dual-token Merkle root
    /// @param  ardiTotal            total $aArdi to be distributed via this Merkle
    /// @param  awpToHolders         total AWP earmarked for holder claims via this Merkle
    /// @param  awpOwnerCut          AWP credited to ownerAwpReserve (separate from holder cut)
    function settleDay(
        uint256 day,
        bytes32 root,
        uint256 ardiTotal,
        uint256 awpToHolders,
        uint256 awpOwnerCut,
        uint64 snapshotBlock
    ) external onlyRole(MERKLE_ROLE) nonReentrant {
        if (dailyRoots[day].root != bytes32(0)) revert AlreadySettled();
        if (day == 0 || day > _currentDay()) revert DayInFuture();
        if (day > lastSettledDay + 1 && lastSettledDay != 0) revert PrematureSettlement();

        // CH-3: snapshot block constraints.
        //   (a) Strictly nonzero — every settled day must commit to a
        //       specific block. Closes Codex L: a zero snapshot would
        //       disable the next-day monotonic check.
        //   (b) At or before the current block.
        //   (c) Strictly newer than the previous day's snapshot.
        // Together with off-chain selection of "block at or before
        // end-of-day", this lets any third party reproduce the leaves
        // and verify the root.
        if (snapshotBlock == 0) revert InvalidSnapshotBlock();
        if (snapshotBlock > block.number) revert InvalidSnapshotBlock();
        if (lastSettledDay != 0) {
            uint64 prevBlock = dailyRoots[lastSettledDay].snapshotBlock;
            // Invariant from (a): prevBlock is always nonzero past the
            // first settled day. Unconditional strict-greater check.
            if (snapshotBlock <= prevBlock) revert InvalidSnapshotBlock();
        }

        uint256 expectedArdi = dailyEmission(day);
        if (ardiTotal > expectedArdi) revert EmissionExhausted();

        // AWP must be on this contract before settlement. Coordinator should
        // wait for the AWP protocol's daily push to land before calling this.
        uint256 awpAvailable = AWP.balanceOf(address(this));
        uint256 awpLockedAfter = awpReservedForClaims + ownerAwpReserve + awpToHolders + awpOwnerCut;
        if (awpLockedAfter > awpAvailable) revert InsufficientAwpHeld();

        dailyRoots[day] = DailyRoot({
            root: root,
            ardiTotal: ardiTotal,
            awpTotalToHolders: awpToHolders,
            awpOwnerCut: awpOwnerCut,
            publishedAt: block.timestamp,
            snapshotBlock: snapshotBlock
        });
        if (day > lastSettledDay) lastSettledDay = day;

        cumulativeMinted += ardiTotal;
        awpReservedForClaims += awpToHolders;
        ownerAwpReserve += awpOwnerCut;

        emit DailySettled(day, root, ardiTotal, awpToHolders, awpOwnerCut, snapshotBlock);
    }

    // --- Claim ---

    /// @notice Claim a single day's holder airdrop — both $aArdi and AWP in one tx.
    /// @dev    Leaf format: keccak256(abi.encodePacked(account, ardiAmount, awpAmount))
    function claim(
        uint256 day,
        uint256 ardiAmount,
        uint256 awpAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (proof.length > MAX_PROOF_LEN) revert InvalidProof();
        if (claimed[day][msg.sender]) revert AlreadyClaimed();

        DailyRoot storage dr = dailyRoots[day];
        bytes32 root = dr.root;
        if (root == bytes32(0)) revert InvalidProof();

        // CH-2: per-holder cap. Even with a valid Merkle proof, a single
        // claimer cannot drain more than `maxPerHolderBps` of the day's
        // distribution. Defense in depth against compromised MERKLE_ROLE.
        uint256 ardiCap = (dr.ardiTotal * maxPerHolderBps) / 10_000;
        uint256 awpCap = (dr.awpTotalToHolders * maxPerHolderBps) / 10_000;
        if (ardiAmount > ardiCap) revert ExceedsPerHolderCap();
        if (awpAmount > awpCap) revert ExceedsPerHolderCap();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, ardiAmount, awpAmount));
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

        claimed[day][msg.sender] = true;

        if (ardiAmount > 0) {
            // Lazy-mint: $aArdi only inflates supply when actually claimed
            ARDI_TOKEN.mint(msg.sender, ardiAmount);
        }
        if (awpAmount > 0) {
            // AWP was reserved at settleDay; release it now
            awpReservedForClaims -= awpAmount;
            AWP.safeTransfer(msg.sender, awpAmount);
        }

        emit Claimed(day, msg.sender, ardiAmount, awpAmount);
    }

    // --- Owner ops withdrawal ---

    /// @notice Pull `amount` AWP from the ops reserve to the configured `ownerOpsAddr`.
    ///         Caller must hold OWNER_OPS_ROLE; recipient is the configured EOA
    ///         (NOT msg.sender), so a hot-key compromise cannot redirect funds.
    function withdrawOwnerAwp(uint256 amount) external onlyRole(OWNER_OPS_ROLE) nonReentrant {
        if (amount > ownerAwpReserve) revert ExceedsReserve();
        ownerAwpReserve -= amount;
        AWP.safeTransfer(ownerOpsAddr, amount);
        emit OwnerAwpWithdrawn(ownerOpsAddr, amount);
    }

    /// @notice Convenience helper: withdraw the entire reserve.
    function withdrawAllOwnerAwp() external onlyRole(OWNER_OPS_ROLE) nonReentrant {
        uint256 amount = ownerAwpReserve;
        if (amount == 0) return;
        ownerAwpReserve = 0;
        AWP.safeTransfer(ownerOpsAddr, amount);
        emit OwnerAwpWithdrawn(ownerOpsAddr, amount);
    }

    // --- Views ---

    function _currentDay() internal view returns (uint256) {
        if (block.timestamp <= GENESIS_TS) return 0;
        return ((block.timestamp - GENESIS_TS) / 1 days) + 1;
    }

    function totalScheduledEmission() external pure returns (uint256 total) {
        for (uint256 d = 1; d <= PHASE1_DAYS + PHASE2_DAYS; d++) {
            total += dailyEmission(d);
        }
    }
}
