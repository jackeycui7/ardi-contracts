// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";

/// @notice Proves the production pattern: Ardi contracts owned by a Timelock,
///         changes go through propose → wait → execute. Without the wait,
///         the execute reverts; without proposer role, even the schedule reverts.
///
///         Closes audit findings C-2 / L-1 (single-key owner blast radius).
contract TimelockTest is Test {
    TimelockController timelock;
    ArdiNFT nft;

    address proposer = address(0xA110);    // multisig in prod
    address executor = address(0xE0E0);    // multisig in prod (or address(0) for open)
    address attacker = address(0xBAD);
    address coordinator = address(0xC00D);
    bytes32 vaultRoot = bytes32(uint256(0xCAFE));

    uint256 constant MIN_DELAY = 2 days;

    function setUp() public {
        // Set up a 1-of-1 timelock for test simplicity
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // Deploy NFT and transfer ownership to the Timelock.
        // (Ownable2Step → 2-step transfer; we assume the test admin both sets and accepts.)
        nft = new ArdiNFT(address(this), coordinator, vaultRoot);
        nft.transferOwnership(address(timelock));

        // Timelock has to ACCEPT the pending ownership. We schedule + execute
        // a proposal targeting nft.acceptOwnership(); the timelock is its own
        // executor here (proposer + executor are external).
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");

        vm.prank(proposer);
        timelock.schedule(address(nft), 0, acceptCall, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        vm.prank(executor);
        timelock.execute(address(nft), 0, acceptCall, bytes32(0), bytes32(0));

        assertEq(nft.owner(), address(timelock));
    }

    function test_attackerCannotChangeCoordinator() public {
        // Direct attacker call → reverts (Ownable: not owner)
        vm.prank(attacker);
        vm.expectRevert();
        nft.setCoordinator(attacker);

        // Even via timelock proposal, attacker can't schedule (not a proposer)
        bytes memory call = abi.encodeWithSignature("setCoordinator(address)", attacker);
        vm.prank(attacker);
        vm.expectRevert();  // AccessControl error (PROPOSER_ROLE)
        timelock.schedule(address(nft), 0, call, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_proposerCanProposeButNotExecuteImmediately() public {
        bytes memory call = abi.encodeWithSignature("setCoordinator(address)", address(0xBEEF));

        vm.prank(proposer);
        timelock.schedule(address(nft), 0, call, bytes32(0), bytes32(0), MIN_DELAY);

        // Try to execute too early → reverts
        vm.prank(executor);
        vm.expectRevert();  // TimelockController: operation is not ready
        timelock.execute(address(nft), 0, call, bytes32(0), bytes32(0));

        // After MIN_DELAY, execution succeeds
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.prank(executor);
        timelock.execute(address(nft), 0, call, bytes32(0), bytes32(0));

        assertEq(nft.coordinator(), address(0xBEEF));
    }

    function test_attackerCannotExecute() public {
        bytes memory call = abi.encodeWithSignature("setCoordinator(address)", attacker);
        vm.prank(proposer);
        timelock.schedule(address(nft), 0, call, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        vm.prank(attacker);
        vm.expectRevert();  // AccessControl: missing EXECUTOR_ROLE
        timelock.execute(address(nft), 0, call, bytes32(0), bytes32(0));
    }

    function test_proposerCanCancelBeforeExecution() public {
        bytes memory call = abi.encodeWithSignature("setCoordinator(address)", attacker);

        vm.prank(proposer);
        bytes32 id = timelock.hashOperation(address(nft), 0, call, bytes32(0), bytes32(0));
        vm.prank(proposer);
        timelock.schedule(address(nft), 0, call, bytes32(0), bytes32(0), MIN_DELAY);

        // Cancel via the CANCELLER_ROLE — granted to proposer by default in OZ v5
        vm.prank(proposer);
        timelock.cancel(id);

        // Execution now reverts because operation no longer scheduled
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(nft), 0, call, bytes32(0), bytes32(0));
    }
}
