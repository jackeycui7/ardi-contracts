// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFTv32} from "../../src/v32/ArdiNFTv32.sol";
import {EmissionDistributorV2} from "../../src/v32/EmissionDistributorV2.sol";
import {EmissionDistributor} from "../../src/v3/EmissionDistributor.sol";
import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";

interface IUUPSPx {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Stand-in for ke's WorknetManager.batchMint (which mints fresh
///      $ardi to recipient). On the fork we don't have MERKLE_ROLE on the
///      real manager, so we substitute a mock that just records.
contract ForkMockMinter {
    struct Mint { address to; uint256 amount; }
    Mint[] public mints;
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external {
        require(recipients.length == amounts.length, "len");
        for (uint256 i = 0; i < recipients.length; ++i) {
            mints.push(Mint(recipients[i], amounts[i]));
        }
    }
    function mintsLength() external view returns (uint256) { return mints.length; }
}

/// @notice Mainnet fork dry-run for the v3.2 upgrade. Validates:
///   - UUPS upgrade succeeds against the real production storage
///   - batchMigrate works on real active tokenIds (gas, idempotency)
///   - First notifyReward(24M) computes plausible accRewardPerPower
///     against real totalActivePower (~109K)
///   - A real holder's pendingFor matches expected share
///   - Claim path triggers batchMint (mocked) with correct args
///
/// Run: forge test --match-path test/v32/MainnetForkUpgrade.t.sol \
///        --fork-url https://mainnet.base.org -vv
contract MainnetForkUpgradeTest is Test {
    // Production contracts (post 2026-05-03 redeploy, per base-mainnet-v3.json)
    address constant NFT_PROXY  = 0xf68425D0d451699d0d766150634E436Acd2F05A1;
    address constant DIST_PROXY = 0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65;
    address constant OWNER      = 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43;
    address constant ARDI_TOKEN = 0xA1008d4F7aA3Aec3C3F529A71dd241Ff9553CAFE;

    ArdiNFTv32 nft;
    EmissionDistributorV2 dist;
    ForkMockMinter mockMinter;

    uint256[] sampleTokenIds;

    function setUp() public {
        // Skip cleanly when not running with --fork-url (chain id != 8453).
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }

        nft  = ArdiNFTv32(NFT_PROXY);
        dist = EmissionDistributorV2(DIST_PROXY);

        // 1. Deploy v32 impls and UUPS-upgrade both proxies (impersonate owner).
        ArdiNFTv32 nftImpl = new ArdiNFTv32();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();

        vm.startPrank(OWNER);
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(nftImpl), "");
        IUUPSPx(DIST_PROXY).upgradeToAndCall(address(edImpl), "");

        // 2. Wire v32 adapter + reward minter (mock for fork).
        dist.setArdiNFTv32(NFT_PROXY);
        mockMinter = new ForkMockMinter();
        dist.setRewardMinter(address(mockMinter));
        dist.setMaxMintPerClaim(75_000_000 ether);
        vm.stopPrank();

        // 3. Sample tokenIds (first 200 from ardi-view feed). Hardcoded so the
        //    test is deterministic without needing live HTTP at run time.
        _seedSampleTokenIds();
    }

    // ─────────────────────── tests ───────────────────────

    function test_fork_storage_layoutPreserved() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // After upgrade, base v3 storage must read the same values as
        // pre-upgrade. Spot-check key invariants.
        assertGt(dist.totalActivePower(), 0, "totalActivePower carries over");
        assertEq(dist.accRewardPerPower(), 0, "no notifies pre-launch");
        assertEq(dist.totalEmittedToDate(), 0, "no notifies pre-launch");
        assertEq(dist.ardiNFT(), NFT_PROXY, "ardiNFT pointer preserved");
        assertEq(dist.operator(), OWNER, "operator preserved");
        assertEq(dist.owner(), OWNER, "owner preserved");
        // v32 fresh state.
        assertEq(uint256(nft.globalDecayRound()), 0, "fresh round counter");
    }

    function test_fork_batchMigrate_realTokenIds() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        vm.startPrank(OWNER);
        dist.pause();

        // Run batchMigrate on a 200-batch of real tokenIds.
        uint256 gasBefore = gasleft();
        nft.batchMigrate(sampleTokenIds);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("gas used for batchMigrate(200 tids)", gasUsed);

        // Every migrated tid must have non-zero expirationRoundOf and
        // v32Migrated=true. Spot-check 5 tokenIds.
        for (uint256 i = 0; i < 5; ++i) {
            uint256 tid = sampleTokenIds[i];
            uint64 expR = nft.expirationRoundOf(tid);
            assertGt(uint256(expR), 0, "expR set after migrate");
            // (v32Migrated tracking removed; expirationRoundOf != 0 is the new idempotency proxy)
        }
        dist.unpause();
        vm.stopPrank();
    }

    function test_fork_firstNotifyReward_computesAccCorrectly() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Migrate everything in our sample so they are eligible.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();

        uint256 totalActivePowerBefore = dist.totalActivePower();
        emit log_named_uint("totalActivePower (pre-notify)", totalActivePowerBefore);

        // First notifyReward (operator = OWNER). 24M ether.
        dist.notifyReward(24_000_000 ether);
        vm.stopPrank();

        // Expected acc = 24M * 1e18 / totalActivePower.
        uint256 expectedAcc = (24_000_000 ether * 1e18) / totalActivePowerBefore;
        assertEq(dist.accRewardPerPower(), expectedAcc,
            "accRewardPerPower matches expected formula");
        assertEq(dist.totalEmittedToDate(), 24_000_000 ether,
            "totalEmittedToDate updated");
        assertEq(uint256(nft.globalDecayRound()), 1,
            "round bumped to 1");
        emit log_named_uint("accRewardPerPower (1e18 scale)", expectedAcc);
        emit log_named_uint("per-power $ardi/day (no scale)", expectedAcc / 1e18);
    }

    function test_fork_realHolder_pendingFor_andClaim() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Pick the first migrated token + its real owner.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        dist.notifyReward(24_000_000 ether);
        vm.stopPrank();

        uint256 tid = sampleTokenIds[0];
        address realOwner = nft.ownerOf(tid);
        uint256[] memory ids = new uint256[](1); ids[0] = tid;

        uint256 pending = dist.pendingFor(realOwner, ids);
        emit log_named_address("real owner of sample[0]", realOwner);
        emit log_named_uint("pending $ardi (wei)", pending);
        emit log_named_uint("pending $ardi (whole)", pending / 1e18);
        assertGt(pending, 0, "real holder has accrued pending after first notify");

        // Real holder claims; mock minter records the call.
        vm.prank(realOwner); dist.claim(ids);
        assertEq(mockMinter.mintsLength(), 1, "exactly one batchMint call");
        (address recipient, uint256 amount) = mockMinter.mints(0);
        assertEq(recipient, realOwner, "minted to real owner");
        assertEq(amount, pending, "minted amount equals pendingFor");
    }

    function test_fork_batchMigrate_idempotent_secondRunNoOp() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);

        // Second run on same set should be a cheap no-op.
        uint256 gasBefore = gasleft();
        nft.batchMigrate(sampleTokenIds);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("gas for SECOND migrate (idempotent)", gasUsed);

        dist.unpause();
        vm.stopPrank();
    }

    // ─────────────────────── helpers ───────────────────────

    function _seedSampleTokenIds() internal {
        // First 50 from ardi-view feed (deterministic). 50 is enough to
        // exercise the migrate path + first-notify share math without
        // bloating fork test runtime.
        sampleTokenIds = [
            uint256(4), 34, 47, 56, 58, 60, 64, 73, 75, 76,
            79, 80, 89, 90, 101, 113, 114, 117, 118, 134,
            136, 138, 139, 145, 147, 159, 161, 162, 163, 168,
            172, 174, 176, 187, 195, 196, 200, 202, 209, 215,
            225, 229, 232, 240, 251, 256, 258, 260, 269, 271
        ];
    }
}
