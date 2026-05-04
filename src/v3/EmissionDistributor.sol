// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IEmissionDistributor} from "./interfaces/IEmissionDistributor.sol";

/// @title  EmissionDistributor — accPerShare $ardi reward distribution.
/// @notice MasterChef-style. ArdiNFT calls onActivate / onDeactivate / onTransfer
///         hooks; operator pushes reward via notifyReward (Q1: operator receives
///         the daily mint from WorknetToken and forwards into here).
///
/// Per-NFT power is mirrored locally (Q9 default: cache, don't cross-call ArdiNFT
/// on every claim) — set on activate, cleared on deactivate, never mutated mid-life
/// (NFT power is mint-time fixed).
///
/// Pause behavior: when paused, notifyReward + claim revert; activation hooks
/// still run (so an in-flight ArdiNFT inscribe/repair-success is never blocked
/// by pausing the distributor — it still tracks state, just can't pay out).
contract EmissionDistributor is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IEmissionDistributor
{
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e18;

    IERC20 public ardi;
    address public ardiNFT; // hook caller
    address public operator; // notifyReward caller

    /// @notice Accumulated reward per power unit, scaled by ACC_PRECISION.
    uint256 public accRewardPerPower;
    /// @notice Sum of power across all activeTracked NFTs.
    uint256 public totalActivePower;
    /// @notice Lifetime $ardi pushed via notifyReward.
    uint256 public totalEmittedToDate;

    struct TokenSlot {
        uint128 power; // 0 when inactive
        uint128 rewardDebt; // power * accRewardPerPower / ACC_PRECISION at last settle
        address holder; // Q9 cache: source-of-truth ownership for claim() auth.
            // Set on onActivate; rotated on onTransfer; zeroed on onDeactivate.
    }

    mapping(uint256 => TokenSlot) public tokens;
    /// @notice Holder claim balance — accumulated unsettled rewards for them.
    mapping(address => uint256) public pendingOf;

    /// @notice C-2: rewards pushed when totalActivePower == 0 are queued
    ///         here instead of reverting; folded into accRewardPerPower the
    ///         next time notifyReward fires with a non-zero pool.
    uint256 public pendingPool;

    /// @notice (H-6 guardrail) Cap on a single notifyReward call. Defends
    ///         against operator typo / compromised cron pushing 1000x the
    ///         daily emission. Owner (Timelock) sets after launch based on
    ///         the actual day-1 emission target. Default 0 = disabled, so
    ///         deployment doesn't accidentally brick day-1 emissions; owner
    ///         must call setMaxNotifyAmount before risk grows.
    uint256 public maxNotifyAmount;

    event RewardNotified(uint256 amount, uint256 newAcc, uint256 totalPower);
    event Activated(uint256 indexed tokenId, address indexed holder, uint256 power);
    event Deactivated(uint256 indexed tokenId, address indexed holder, uint256 settled);
    event Transferred(uint256 indexed tokenId, address indexed from, address indexed to);
    event Claimed(address indexed holder, uint256 amount);
    event ArdiNFTSet(address indexed ardiNFT);
    event OperatorSet(address indexed operator);
    event MaxNotifyAmountSet(uint256 cap);

    error NotArdiNFT();
    error NotOperator();
    error ZeroAddress();
    error AlreadyActive();
    error NotActive();
    error NoSupply();
    error NotHolder();
    error AmountAboveCap();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address ardi_, address operator_)
        external
        initializer
    {
        if (initialOwner == address(0) || ardi_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(initialOwner);
        __Pausable_init();
        ardi = IERC20(ardi_);
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setArdiNFT(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        ardiNFT = a;
        emit ArdiNFTSet(a);
    }

    function setOperator(address o) external onlyOwner {
        if (o == address(0)) revert ZeroAddress();
        operator = o;
        emit OperatorSet(o);
    }

    /// @notice (H-6 guardrail) Set the maximum amount notifyReward can push
    ///         in a single tx. 0 disables the cap. Recommended: ~1.5x the
    ///         expected day-1 daily emission so operational variance still
    ///         lands but a 100x typo aborts.
    function setMaxNotifyAmount(uint256 v) external onlyOwner {
        maxNotifyAmount = v;
        emit MaxNotifyAmountSet(v);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================ Hooks ============================

    modifier onlyArdiNFT() {
        if (msg.sender != ardiNFT) revert NotArdiNFT();
        _;
    }

    function onActivate(uint256 tokenId, address holder, uint256 power) external virtual onlyArdiNFT {
        TokenSlot storage s = tokens[tokenId];
        if (s.power != 0) revert AlreadyActive();
        if (power == 0) revert ZeroAddress(); // reuse — power=0 invalid
        if (holder == address(0)) revert ZeroAddress();

        s.power = uint128(power);
        s.rewardDebt = uint128((power * accRewardPerPower) / ACC_PRECISION);
        s.holder = holder;
        totalActivePower += power;

        emit Activated(tokenId, holder, power);
    }

    function onDeactivate(uint256 tokenId, address holder) external virtual onlyArdiNFT {
        TokenSlot storage s = tokens[tokenId];
        if (s.power == 0) revert NotActive();

        uint256 power = s.power;
        uint256 accrued = (power * accRewardPerPower) / ACC_PRECISION;
        uint256 owed = accrued > s.rewardDebt ? accrued - s.rewardDebt : 0;
        if (owed > 0) {
            pendingOf[holder] += owed;
        }

        totalActivePower -= power;
        s.power = 0;
        s.rewardDebt = 0;
        s.holder = address(0);

        emit Deactivated(tokenId, holder, owed);
    }

    function onTransfer(uint256 tokenId, address from, address to) external virtual onlyArdiNFT {
        TokenSlot storage s = tokens[tokenId];
        if (s.power == 0) revert NotActive();
        uint256 power = s.power;
        uint256 accrued = (power * accRewardPerPower) / ACC_PRECISION;
        uint256 owed = accrued > s.rewardDebt ? accrued - s.rewardDebt : 0;
        if (owed > 0) {
            pendingOf[from] += owed;
        }
        // Reset debt under the new holder so future accrual lands with `to`.
        s.rewardDebt = uint128(accrued);
        s.holder = to;
        emit Transferred(tokenId, from, to);
    }

    // ============================ Reward ============================

    function notifyReward(uint256 amount) external virtual whenNotPaused nonReentrant {
        if (msg.sender != operator) revert NotOperator();
        if (amount == 0) return;
        if (maxNotifyAmount != 0 && amount > maxNotifyAmount) revert AmountAboveCap();
        // C-2: never revert on zero supply. If no NFT is active yet, queue
        // the amount into pendingPool so the operator's daily cron isn't
        // wedged on launch day or during a cascading mass-broken event.
        // The pool is folded in on the next non-zero notify.
        ardi.safeTransferFrom(msg.sender, address(this), amount);
        if (totalActivePower == 0) {
            pendingPool += amount;
            emit RewardNotified(amount, accRewardPerPower, 0);
            return;
        }
        // C3-2 hardening: cap the per-call distribution at maxNotifyAmount
        // (when set). If the queued pendingPool plus this amount exceeds the
        // cap, drain ONLY up to the cap and leave the remainder in the pool
        // for subsequent notifies. Without the cap (default), the full pool
        // drains in one call (legacy behavior).
        uint256 toDistribute = amount + pendingPool;
        uint256 cap = maxNotifyAmount;
        uint256 leftover = 0;
        if (cap != 0 && toDistribute > cap) {
            leftover = toDistribute - cap;
            toDistribute = cap;
        }
        pendingPool = leftover;
        accRewardPerPower += (toDistribute * ACC_PRECISION) / totalActivePower;
        totalEmittedToDate += toDistribute;
        emit RewardNotified(toDistribute, accRewardPerPower, totalActivePower);
    }

    // ============================ Claim ============================

    function pendingFor(address holder, uint256[] calldata tokenIds)
        external
        view
        virtual
        returns (uint256 total)
    {
        total = pendingOf[holder];
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            TokenSlot storage s = tokens[tokenIds[i]];
            if (s.power == 0) continue;
            uint256 accrued = (uint256(s.power) * accRewardPerPower) / ACC_PRECISION;
            if (accrued > s.rewardDebt) total += accrued - s.rewardDebt;
        }
    }

    /// @notice Settle a list of active tokenIds (each MUST be held by
    ///         msg.sender) and pay out together with any pending balance.
    /// @dev    C-1 fix: ownership is verified against the cached `holder`
    ///         field in TokenSlot. The cache is set on activate, rotated on
    ///         transfer, and cleared on deactivate via hooks from ArdiNFT.
    ///         Without this guard, anyone could settle anyone else's accrual
    ///         (move it from `s.rewardDebt` into their own pending balance).
    function claim(uint256[] calldata tokenIds) external virtual whenNotPaused nonReentrant {
        uint256 total = pendingOf[msg.sender];
        pendingOf[msg.sender] = 0;

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            TokenSlot storage s = tokens[tokenIds[i]];
            if (s.power == 0) continue;
            if (s.holder != msg.sender) revert NotHolder();
            uint256 accrued = (uint256(s.power) * accRewardPerPower) / ACC_PRECISION;
            if (accrued > s.rewardDebt) {
                total += accrued - s.rewardDebt;
                s.rewardDebt = uint128(accrued);
            }
        }

        if (total > 0) {
            ardi.safeTransfer(msg.sender, total);
        }
        emit Claimed(msg.sender, total);
    }

    uint256[50] private __gap;
}
