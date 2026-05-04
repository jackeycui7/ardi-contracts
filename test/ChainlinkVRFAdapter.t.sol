// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkVRFAdapter, IVRFCoordinatorV2Plus} from "../src/ChainlinkVRFAdapter.sol";
import {IRandomnessReceiver} from "../src/interfaces/IRandomnessSource.sol";

/// @notice Mock Chainlink VRF Coordinator for unit testing the adapter
///         without depending on chainlink-contracts at compile time.
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 public nextId = 1;
    mapping(uint256 => address) public consumerOf;

    function requestRandomWords(RandomWordsRequest calldata req)
        external
        override
        returns (uint256 requestId)
    {
        // Sanity: req fields exist (compiler would prune unused param warning)
        require(req.numWords == 1, "test expects numWords=1");
        requestId = nextId++;
        consumerOf[requestId] = msg.sender;
    }

    /// @dev Test helper — fulfill a pending request by calling the consumer's
    ///      rawFulfillRandomWords entry, which is what the real coordinator does.
    function fulfill(uint256 requestId, uint256 randomWord) external {
        address consumer = consumerOf[requestId];
        require(consumer != address(0), "no such request");
        delete consumerOf[requestId];
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        // Static-call signature used by Chainlink: rawFulfillRandomWords(uint256, uint256[])
        (bool ok, ) = consumer.call(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words)
        );
        require(ok, "fulfill failed");
    }
}

/// @notice Mock receiver that records what it gets from onRandomness.
contract MockReceiver is IRandomnessReceiver {
    uint256 public lastRequestId;
    uint256 public lastRandomness;
    uint256 public callCount;

    function onRandomness(uint256 requestId, uint256 randomness) external override {
        lastRequestId = requestId;
        lastRandomness = randomness;
        ++callCount;
    }
}


contract ChainlinkVRFAdapterTest is Test {
    ChainlinkVRFAdapter adapter;
    MockVRFCoordinator coord;
    MockReceiver receiver;

    address owner = address(0xA11CE);
    bytes32 keyHash = bytes32(uint256(0xDEADBEEF));
    uint256 subId = 42;

    function setUp() public {
        coord = new MockVRFCoordinator();
        receiver = new MockReceiver();
        vm.prank(owner);
        adapter = new ChainlinkVRFAdapter(
            owner, address(coord), keyHash, subId, address(receiver)
        );
    }

    // ============================ Auth =====================================

    function test_requestRandomness_onlyConsumer() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ChainlinkVRFAdapter.NotConsumer.selector);
        adapter.requestRandomness();
    }

    function test_setConsumer_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.setConsumer(address(0xCAFE));
    }

    function test_setConfig_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.setConfig(bytes32(uint256(1)), 99, 5, 300_000);
    }

    // ============================ Happy path ==============================

    function test_request_then_fulfill_roundtrip() public {
        // Receiver requests randomness through the adapter (only it can)
        vm.prank(address(receiver));
        uint256 reqId = adapter.requestRandomness();
        assertEq(reqId, 1);

        // Coordinator fulfills — adapter forwards to receiver via onRandomness
        coord.fulfill(reqId, uint256(0xCAFEBABE));
        assertEq(receiver.lastRequestId(), reqId);
        assertEq(receiver.lastRandomness(), uint256(0xCAFEBABE));
        assertEq(receiver.callCount(), 1);
    }

    function test_fulfill_rejected_from_non_coordinator() public {
        vm.prank(address(receiver));
        adapter.requestRandomness();

        // Anyone-but-the-coordinator calling rawFulfillRandomWords must be rejected.
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(address(0xBAD));
        vm.expectRevert();  // OnlyVRFCoordinatorCanFulfill custom error
        adapter.rawFulfillRandomWords(1, words);
    }

    // ============================ Config update ===========================

    function test_setConfig_appliesNewValues() public {
        bytes32 newHash = bytes32(uint256(0xC0FFEE));
        vm.prank(owner);
        adapter.setConfig(newHash, 99, 7, 350_000);
        assertEq(adapter.keyHash(), newHash);
        assertEq(adapter.subscriptionId(), 99);
        assertEq(adapter.requestConfirmations(), 7);
        assertEq(adapter.callbackGasLimit(), 350_000);
    }

    function test_setConsumer_redirectsFutureRequests() public {
        MockReceiver r2 = new MockReceiver();
        vm.prank(owner);
        adapter.setConsumer(address(r2));

        // Old receiver can no longer request
        vm.prank(address(receiver));
        vm.expectRevert(ChainlinkVRFAdapter.NotConsumer.selector);
        adapter.requestRandomness();

        // New consumer can
        vm.prank(address(r2));
        uint256 reqId = adapter.requestRandomness();
        coord.fulfill(reqId, uint256(0x1234));
        assertEq(r2.lastRandomness(), uint256(0x1234));
        assertEq(receiver.callCount(), 0);  // old never received
    }
}
