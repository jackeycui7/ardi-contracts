// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRandomnessSource, IRandomnessReceiver} from "./interfaces/IRandomnessSource.sol";

/// @notice Minimal Chainlink VRF v2.5 (Plus) interfaces — inlined to avoid
///         pulling in the full chainlink-contracts package as a dependency.
///         Verify these signatures against Chainlink docs at:
///           https://docs.chain.link/vrf/v2-5/billing
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs; // VRFV2PlusClient.ExtraArgsV1 abi-encoded
    }

    function requestRandomWords(RandomWordsRequest calldata req)
        external
        returns (uint256 requestId);
}

/// @notice Chainlink-side parent class for receiving VRF callbacks.
///         The real `VRFConsumerBaseV2Plus` from chainlink-contracts is
///         abstract + has a constructor wired to the coordinator. Here we
///         re-implement the necessary surface ourselves, keeping the same
///         method name (`rawFulfillRandomWords`) the coordinator expects.
abstract contract VRFConsumerCompat {
    address private immutable s_vrfCoordinator;

    error OnlyVRFCoordinatorCanFulfill(address have, address want);

    constructor(address vrfCoordinator) {
        s_vrfCoordinator = vrfCoordinator;
    }

    /// @dev Coordinator entry point; routes to the implementation.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        external
    {
        if (msg.sender != s_vrfCoordinator) {
            revert OnlyVRFCoordinatorCanFulfill(msg.sender, s_vrfCoordinator);
        }
        _fulfillRandomWords(requestId, randomWords);
    }

    function _fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        virtual;
}

/// @title ChainlinkVRFAdapter — production randomness source for ArdiEpochDraw.
/// @notice Implements `IRandomnessSource` (the interface ArdiEpochDraw consumes)
///         on top of Chainlink VRF v2.5 subscription billing.
///
/// Deployment runbook:
///   1. Operator creates a Chainlink VRF v2.5 Subscription via the Chainlink UI
///      and funds it with LINK or native ETH.
///   2. Deploy this contract with:
///        - `coordinator_` = the Chainlink VRF Coordinator address on Base mainnet
///        - `keyHash_`     = the gas lane key hash (chain-specific, see Chainlink docs)
///        - `subId_`       = the subscription id from step 1
///        - `consumer_`    = the ArdiEpochDraw contract address (after it's deployed)
///   3. Add this adapter as a Consumer on the Subscription.
///   4. Call `ArdiEpochDraw.setRandomnessSource(<this address>)`.
///
/// Operational notes:
///   - Subscription must stay funded; running dry → all `requestRandomness()`
///     calls revert. Monitor LINK/ETH balance and top up before depletion.
///   - `requestConfirmations` defaults to 3 — Chainlink's recommended minimum
///     for Base. Increase for higher reorg tolerance, decrease for faster draws
///     (within Chainlink's 3..200 bounds).
contract ChainlinkVRFAdapter is IRandomnessSource, VRFConsumerCompat, Ownable2Step {
    /// @notice The ArdiEpochDraw contract that consumes our randomness.
    ///         Single consumer model — only one contract can request.
    address public consumer;

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public requestConfirmations = 3;
    uint32 public callbackGasLimit = 200_000;
    /// @notice If true, VRF requests are paid from the subscription's
    ///         native (ETH) balance; otherwise from LINK. Owner-mutable.
    ///         Default true — native is one-token-fewer for operators
    ///         and Base / mainnet have native subscriptions natively.
    bool public nativePayment = true;

    IVRFCoordinatorV2Plus public immutable coordinator;

    event ConsumerSet(address indexed consumer);
    event ConfigUpdated(bytes32 keyHash, uint256 subId, uint16 confirms, uint32 gasLimit);
    event RandomnessRequested(uint256 indexed requestId, address indexed consumer);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomWord);

    error NotConsumer();
    error ZeroAddress();

    constructor(
        address initialOwner,
        address coordinator_,
        bytes32 keyHash_,
        uint256 subId_,
        address consumer_
    ) VRFConsumerCompat(coordinator_) Ownable(initialOwner) {
        if (coordinator_ == address(0) || consumer_ == address(0)) revert ZeroAddress();
        coordinator = IVRFCoordinatorV2Plus(coordinator_);
        keyHash = keyHash_;
        subscriptionId = subId_;
        consumer = consumer_;
        emit ConsumerSet(consumer_);
    }

    // ============================ Admin =====================================

    function setConsumer(address consumer_) external onlyOwner {
        if (consumer_ == address(0)) revert ZeroAddress();
        consumer = consumer_;
        emit ConsumerSet(consumer_);
    }

    function setConfig(
        bytes32 keyHash_,
        uint256 subId_,
        uint16 confirmations_,
        uint32 gasLimit_
    ) external onlyOwner {
        keyHash = keyHash_;
        subscriptionId = subId_;
        requestConfirmations = confirmations_;
        callbackGasLimit = gasLimit_;
        emit ConfigUpdated(keyHash_, subId_, confirmations_, gasLimit_);
    }

    /// @notice Toggle between LINK (false) and native ETH (true) payment.
    ///         Subscription must have a positive balance of the chosen
    ///         token; check `Balance` on vrf.chain.link before flipping.
    function setNativePayment(bool v) external onlyOwner {
        nativePayment = v;
    }

    // ============================ IRandomnessSource =========================

    /// @notice Request 1 random word from Chainlink VRF v2.5.
    /// @dev    `extraArgs = abi.encodeWithSelector(VRFV2PlusClient.EXTRA_ARGS_V1_TAG,
    ///         VRFV2PlusClient.ExtraArgsV1{nativePayment: false})`. We inline the
    ///         constants so we don't depend on the chainlink lib.
    ///         For native ETH payment instead of LINK, set nativePayment=true.
    bytes4 private constant EXTRA_ARGS_V1_TAG = 0x92fd1338;

    function requestRandomness() external override returns (uint256 requestId) {
        if (msg.sender != consumer) revert NotConsumer();

        bytes memory extraArgs = abi.encodeWithSelector(
            EXTRA_ARGS_V1_TAG,
            ExtraArgsV1({nativePayment: nativePayment})
        );

        IVRFCoordinatorV2Plus.RandomWordsRequest memory req = IVRFCoordinatorV2Plus.RandomWordsRequest({
            keyHash: keyHash,
            subId: subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 1,
            extraArgs: extraArgs
        });

        requestId = coordinator.requestRandomWords(req);
        emit RandomnessRequested(requestId, consumer);
    }

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    // ============================ VRF callback ==============================

    /// @dev Forwarded from rawFulfillRandomWords (parent does the auth check).
    function _fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        require(randomWords.length >= 1, "no words");
        uint256 rnd = randomWords[0];
        emit RandomnessFulfilled(requestId, rnd);
        // Forward to the consumer (ArdiEpochDraw) using its IRandomnessReceiver hook.
        // The consumer checks `msg.sender == address(randomness)` against this
        // adapter's address — that's why the call must come from THIS contract.
        IRandomnessReceiver(consumer).onRandomness(requestId, rnd);
    }
}
