// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFTv32} from "../../src/v32/ArdiNFTv32.sol";
import {EmissionDistributorV2} from "../../src/v32/EmissionDistributorV2.sol";
import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";

interface IUUPSPx {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

contract ForkMockMinter {
    struct Mint { address to; uint256 amount; }
    Mint[] public mints;
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; ++i) mints.push(Mint(recipients[i], amounts[i]));
    }
    function mintsLength() external view returns (uint256) { return mints.length; }
}

/// @notice Staged-deploy dry-run: simulates "deploy now, notify later" flow.
///   Phase 1: deploy v32 impls (no proxy change). Verify mainnet state untouched.
///   Phase 2: pause -> upgrade -> wire -> migrate -> unpause. Verify gap-window
///            behavior (effectiveDurability=0 between upgrade and migrate),
///            then full restoration after migrate.
///   Phase 3: notifyReward(24M). First reward distributed.
///   Pre-Phase-3 claim must revert/zero-out cleanly (no reward to claim yet).
///
/// Run: forge test --match-path test/v32/MainnetForkStagedDeploy.t.sol \
///        --fork-url https://mainnet.base.org -vv
contract MainnetForkStagedDeployTest is Test {
    address constant NFT_PROXY  = 0xf68425D0d451699d0d766150634E436Acd2F05A1;
    address constant DIST_PROXY = 0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65;
    address constant OWNER      = 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43;
    address constant REAL_MGR   = 0x22cB0f31FCa7d43B42f4eA4bDf9D0d0CFC69E03b;

    ArdiNFTv32 nft;
    EmissionDistributorV2 dist;
    ForkMockMinter mockMinter;
    uint256[] sample;

    function setUp() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        nft  = ArdiNFTv32(NFT_PROXY);
        dist = EmissionDistributorV2(DIST_PROXY);
        // 50 real tokenIds from ardi-view feed
        sample = [
            uint256(4), 34, 47, 56, 58, 60, 64, 73, 75, 76,
            79, 80, 89, 90, 101, 113, 114, 117, 118, 134,
            136, 138, 139, 145, 147, 159, 161, 162, 163, 168,
            172, 174, 176, 187, 195, 196, 200, 202, 209, 215,
            225, 229, 232, 240, 251, 256, 258, 260, 269, 271
        ];
    }

    /// Phase 1: deploy impls only. No proxy change. Mainnet behavior identical.
    function test_phase1_implDeploy_noStateChange() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        uint256 powerBefore = dist.totalActivePower();
        address ownerOfBefore = ArdiNFTv3(NFT_PROXY).ownerOf(sample[0]);

        // Deploy impls. Anyone can do this (gas-paying address irrelevant).
        new ArdiNFTv32();
        new EmissionDistributorV2();

        // Mainnet state is untouched.
        assertEq(dist.totalActivePower(), powerBefore, "totalActivePower untouched");
        assertEq(ArdiNFTv3(NFT_PROXY).ownerOf(sample[0]), ownerOfBefore, "ownerOf untouched");
    }

    /// Phase 2 windows are documented in V32_CHANGES.md. This test walks
    /// the exact sequence and probes user-visible behavior at each step.
    function test_phase2_stagedUpgrade_withGapWindowProbe() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        ArdiNFTv32 nftImpl = new ArdiNFTv32();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();
        mockMinter = new ForkMockMinter();

        uint256 sampleTid = sample[0];
        address sampleHolder = ArdiNFTv3(NFT_PROXY).ownerOf(sampleTid);

        // ─── Step 1: pause distributor ───────────────────────────
        vm.prank(OWNER); dist.pause();
        // (claim path is blocked; pre-launch there's nothing to claim anyway)

        // ─── Step 2 & 3: upgrade BOTH proxies ────────────────────
        vm.startPrank(OWNER);
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(nftImpl), "");
        IUUPSPx(DIST_PROXY).upgradeToAndCall(address(edImpl), "");
        vm.stopPrank();

        // ─── GAP WINDOW: upgraded but not migrated ───────────────
        // Confirmation #1: effectiveDurability reads 0 for everyone here.
        // This is the "frontend will look weird" window.
        assertEq(uint256(nft.effectiveDurability(sampleTid)), 0,
            "GAP: pre-migrate effectiveDurability is 0 (expected, transient)");

        // Confirmation #2: NFT transfer STILL WORKS in the gap (onTransfer
        // is no-op for active NFT under reward-follows-NFT, doesn't touch
        // expR / dura).
        address sink = address(0xdead123);
        vm.prank(sampleHolder);
        ArdiNFTv3(NFT_PROXY).transferFrom(sampleHolder, sink, sampleTid);
        assertEq(ArdiNFTv3(NFT_PROXY).ownerOf(sampleTid), sink, "transfer succeeds in gap");
        // restore for later steps
        vm.prank(sink);
        ArdiNFTv3(NFT_PROXY).transferFrom(sink, sampleHolder, sampleTid);

        // Confirmation #3: claim from a real holder in the gap reverts
        // gracefully. With no reward distributed, total = 0, so the
        // batchMint branch is skipped and claim emits Claimed(holder, 0)
        // — but only after we set rewardMinter. Without rewardMinter set,
        // the function reverts MinterNotSet.
        uint256[] memory ids = new uint256[](1); ids[0] = sampleTid;
        vm.prank(sampleHolder);
        // dist is still paused → reverts EnforcedPause (OZ Pausable).
        vm.expectRevert();
        dist.claim(ids);

        // ─── Step 4-7: wire ──────────────────────────────────────
        vm.startPrank(OWNER);
        dist.setArdiNFTv32(NFT_PROXY);
        dist.setRewardMinter(address(mockMinter));
        dist.setMaxMintPerClaim(75_000_000 ether);
        dist.setMaxNotifyAmount(36_000_000 ether);
        vm.stopPrank();

        // After wiring but BEFORE migrate: pendingFor reads 0 because
        // _capAcc M-1 fix returns 0 for unmigrated tokens. Good — operator
        // mistake (notifyReward'ing now) wouldn't leak anything.
        assertEq(dist.pendingFor(sampleHolder, ids), 0,
            "GAP wired but un-migrated: pending is 0 (M-1 protected)");

        // ─── Step 8: migrate (all 50 in one batch for the test) ──
        vm.prank(OWNER); nft.batchMigrate(sample);

        // Post-migrate: effectiveDurability restores to maxDurability.
        assertGt(uint256(nft.effectiveDurability(sampleTid)), 0,
            "post-migrate: effectiveDurability restored");

        // ─── Step 9: unpause ─────────────────────────────────────
        vm.prank(OWNER); dist.unpause();

        // After unpause but before notifyReward: claim is valid but yields 0.
        uint256 mintsBefore = mockMinter.mintsLength();
        vm.prank(sampleHolder); dist.claim(ids);
        assertEq(mockMinter.mintsLength(), mintsBefore,
            "claim with no reward yet: no mint call (total=0 short-circuit)");
    }

    /// Phase 3: only after notifyReward does pending start accumulating.
    function test_phase3_notifyReward_startsRewardClock() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Run Phase 2 first (boilerplate).
        ArdiNFTv32 nftImpl = new ArdiNFTv32();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();
        mockMinter = new ForkMockMinter();
        vm.startPrank(OWNER);
        dist.pause();
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(nftImpl), "");
        IUUPSPx(DIST_PROXY).upgradeToAndCall(address(edImpl), "");
        dist.setArdiNFTv32(NFT_PROXY);
        dist.setRewardMinter(address(mockMinter));
        dist.setMaxMintPerClaim(75_000_000 ether);
        dist.setMaxNotifyAmount(36_000_000 ether);
        nft.batchMigrate(sample);
        dist.unpause();

        // Pre-notify: pending = 0.
        uint256 sampleTid = sample[0];
        address sampleHolder = ArdiNFTv3(NFT_PROXY).ownerOf(sampleTid);
        uint256[] memory ids = new uint256[](1); ids[0] = sampleTid;
        assertEq(dist.pendingFor(sampleHolder, ids), 0, "pre-notify: 0 pending");

        // Phase 3: first notifyReward.
        dist.notifyReward(24_000_000 ether);
        vm.stopPrank();

        // Pending now non-zero.
        uint256 pending = dist.pendingFor(sampleHolder, ids);
        assertGt(pending, 0, "post-notify: pending accrued");
        emit log_named_uint("first-notify pending for sample[0] (whole $ardi)", pending / 1e18);

        // Real holder claims and gets minted exactly that much.
        vm.prank(sampleHolder); dist.claim(ids);
        assertEq(mockMinter.mintsLength(), 1, "claim triggers one batchMint");
        (address recipient, uint256 amount) = mockMinter.mints(0);
        assertEq(recipient, sampleHolder, "minted to real holder");
        assertEq(amount, pending, "minted exactly pendingFor");
    }

    /// Confirms the WorknetManager (real on chain) really has batchMint
    /// at the expected selector. (Cheap probe — fork tests against the
    /// real contract, so we know the function exists.)
    function test_realManager_hasBatchMint() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Probe by calling without MERKLE_ROLE — should revert
        // AccessControlUnauthorizedAccount, NOT "function does not exist".
        bytes memory call = abi.encodeWithSignature(
            "batchMint(address[],uint256[])",
            new address[](0), new uint256[](0)
        );
        (bool ok, bytes memory data) = REAL_MGR.call(call);
        assertFalse(ok, "should revert (no MERKLE_ROLE)");
        // AccessControl error selector is 0xe2517d3f (AccessControlUnauthorizedAccount)
        assertEq(bytes4(data), bytes4(0xe2517d3f), "reverted with AccessControl, not fallback");
    }
}
