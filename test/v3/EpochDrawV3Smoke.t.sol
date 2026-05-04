// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ArdiEpochDrawV3} from "../../src/v3/ArdiEpochDrawV3.sol";
import {IRandomnessSource, IRandomnessReceiver} from "../../src/interfaces/IRandomnessSource.sol";

/// Mock AWPAllocator that maps (staker, agent, worknetId) -> amount in storage
/// so we can drive _requireEligible decisions deterministically from tests.
contract MockAllocator {
    mapping(bytes32 => uint256) public stake;

    function set(address staker, address agent, uint256 worknetId, uint256 amount) external {
        stake[keccak256(abi.encode(staker, agent, worknetId))] = amount;
    }

    function getAgentStake(address staker, address agent, uint256 worknetId)
        external
        view
        returns (uint256)
    {
        return stake[keccak256(abi.encode(staker, agent, worknetId))];
    }
}

/// Mock VRF that returns increasing requestIds and never auto-fulfils
/// (tests that need a callback can manually call onRandomness on the consumer).
contract MockRandomness is IRandomnessSource {
    uint256 public next = 1;
    function requestRandomness() external override returns (uint256) {
        uint256 id = next;
        next = id + 1;
        return id;
    }
}

contract EpochDrawV3Smoke is Test {
    ArdiEpochDrawV3 epoch;
    MockAllocator allocator;
    MockRandomness rng;

    address owner = address(0xa11ce);
    address coordinator = address(0xc0c0);
    address treasury = address(0xfee5);
    address agent = address(0xa6e7);
    address provider = address(0x9d09); // KYA-style provider; not the agent
    uint256 constant ARDI_WN = 845300000012;
    uint256 constant KYA_WN = 845300000014;
    uint256 constant MIN_STAKE = 10_000 ether;

    function setUp() public {
        allocator = new MockAllocator();
        rng = new MockRandomness();

        ArdiEpochDrawV3 impl = new ArdiEpochDrawV3();
        bytes memory init = abi.encodeCall(
            ArdiEpochDrawV3.initialize,
            (
                owner,
                bytes32(uint256(1)), // sentinel non-zero so openEpoch passes (no publishAnswer in this smoke)
                address(rng),
                coordinator,
                treasury,
                address(allocator),
                ARDI_WN,
                KYA_WN,
                MIN_STAKE
            )
        );
        epoch = ArdiEpochDrawV3(address(new ERC1967Proxy(address(impl), init)));

        // Open an epoch as coordinator
        vm.prank(coordinator);
        epoch.openEpoch(1, 60, 60);

        vm.deal(agent, 1 ether);
    }

    // === SD-1 staker semantics ===

    function test_commit_selfStake_zeroStakerDefaultsToMsgSender() public {
        allocator.set(agent, agent, ARDI_WN, MIN_STAKE);
        vm.prank(agent);
        epoch.commit{value: 0.00001 ether}(1, 100, bytes32(uint256(1)), new address[](0));

        epoch.commits(1, 100, agent); // discard
        address[] memory _ss = epoch.getCommitStakers(1, 100, agent);
        address staker = _ss.length > 0 ? _ss[0] : address(0);
        assertEq(staker, agent, "staker should default to msg.sender on zero");
    }

    function test_commit_kyaDelegated_passesWithProviderAddr() public {
        // KYA flow: provider allocates to agent on KYA worknet, agent never bound.
        allocator.set(provider, agent, KYA_WN, MIN_STAKE);

        vm.prank(agent);
        { address[] memory _ss = new address[](1); _ss[0] = provider; epoch.commit{value: 0.00001 ether}(1, 100, bytes32(uint256(1)), _ss); }

        epoch.commits(1, 100, agent); // discard
        address[] memory _ss = epoch.getCommitStakers(1, 100, agent);
        address staker = _ss.length > 0 ? _ss[0] : address(0);
        assertEq(staker, provider, "staker should be locked at commit time");
    }

    function test_commit_revertsWhenNeitherWorknetMeetsMinStake() public {
        // 9000 AWP on Ardi via self — below 10K threshold
        allocator.set(agent, agent, ARDI_WN, 9_000 ether);
        vm.prank(agent);
        vm.expectRevert(ArdiEpochDrawV3.InsufficientStake.selector);
        epoch.commit{value: 0.00001 ether}(1, 100, bytes32(uint256(1)), new address[](0));
    }

    function test_commit_kyaDelegated_revertsIfWrongStaker() public {
        // Provider allocated, but agent passes Address(0) -> defaults to self
        // -> self has no stake -> revert.
        allocator.set(provider, agent, KYA_WN, MIN_STAKE);
        vm.prank(agent);
        vm.expectRevert(ArdiEpochDrawV3.InsufficientStake.selector);
        epoch.commit{value: 0.00001 ether}(1, 100, bytes32(uint256(1)), new address[](0));
    }

    function test_commit_eitherWorknetSatisfies() public {
        // Stake on KYA only — should pass even when probing Ardi first.
        allocator.set(agent, agent, KYA_WN, MIN_STAKE);
        vm.prank(agent);
        epoch.commit{value: 0.00001 ether}(1, 100, bytes32(uint256(1)), new address[](0));
    }
}
