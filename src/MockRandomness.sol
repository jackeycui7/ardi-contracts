// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRandomnessSource, IRandomnessReceiver} from "./interfaces/IRandomnessSource.sol";

/// @title Deterministic mock randomness source for tests + Anvil.
/// @notice DO NOT USE IN PRODUCTION. Replays a configurable random word back
///         to the caller via the IRandomnessReceiver callback.
///
/// On mainnet, replace with a Chainlink VRF v2.5 adapter that:
///   - inherits VRFConsumerBaseV2Plus
///   - calls vrfCoordinator.requestRandomWords(...) in requestRandomness()
///   - implements fulfillRandomWords by calling IRandomnessReceiver.onRandomness
contract MockRandomness is IRandomnessSource {
    uint256 public nextRequestId = 1;
    uint256 public mockSeed = uint256(keccak256("ardi-mock-seed-v1"));

    /// @notice Pending requests: requestId → consumer
    mapping(uint256 => address) public consumerOf;

    function setMockSeed(uint256 newSeed) external {
        mockSeed = newSeed;
    }

    function requestRandomness() external returns (uint256) {
        uint256 reqId = nextRequestId++;
        consumerOf[reqId] = msg.sender;
        return reqId;
    }

    /// @notice Test helper — anyone can fulfill a pending request.
    /// @dev    On real VRF, the coordinator does this asynchronously.
    function fulfill(uint256 requestId) external {
        address consumer = consumerOf[requestId];
        require(consumer != address(0), "no such request");
        delete consumerOf[requestId];
        // Derive a per-request pseudorandom word from the configured seed
        uint256 rnd = uint256(keccak256(abi.encodePacked(mockSeed, requestId)));
        IRandomnessReceiver(consumer).onRandomness(requestId, rnd);
    }
}
