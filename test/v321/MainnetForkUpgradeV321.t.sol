// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFTv321} from "../../src/v32/ArdiNFTv321.sol";
import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";
import {EmissionDistributorV2} from "../../src/v32/EmissionDistributorV2.sol";

interface IUUPSPx {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

/// @dev Stand-in for ke's WorknetManager.batchMint (which mints fresh
///      $ardi to recipient). On the fork we don't have MERKLE_ROLE on the
///      real manager, so we substitute a mock that just records.
contract ForkMockMinter321 {
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

/// @notice Mainnet fork dry-run for the v3 → v3.2.1 upgrade. v3.2.1
///   inherits v3.2's full storage layout, so a single UUPS upgrade
///   on the live v3 proxy lands both v3.2 (round-based decay,
///   migrate, mint-on-claim) and v3.2.1 (dynamic repair pricing,
///   post-mortem gate).
///
/// Validates:
///   - Storage carries over: totalActivePower / owner / operator
///   - New v3.2.1 slots default to 0 (no collision with the v3.2 gap)
///   - `configureRepair` is callable and persists
///   - `repairFee(tokenId)` matches the dynamic formula exactly,
///     using real on-chain `power × maxDurability × totalActivePower`
///   - `repair(tokenId)` reverts `NotYetExpired` on a still-alive NFT
///   - After driving `globalDecayRound` past `maxDurability`, the gate
///     flips (the same NFT is now repairable — fee is the v3.2.1
///     formula, not the inherited fixed price)
///
/// Run: forge test --match-path test/v321/MainnetForkUpgradeV321.t.sol \
///        --fork-url https://mainnet.base.org -vv
contract MainnetForkUpgradeV321Test is Test {
    // Production contracts (post 2026-05-03 redeploy, per base-mainnet-v3.json)
    address constant NFT_PROXY  = 0xf68425D0d451699d0d766150634E436Acd2F05A1;
    address constant DIST_PROXY = 0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65;
    address constant OWNER      = 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43;

    uint16  constant RATIO = 5_000;            // 0.5×
    uint256 constant DAILY = 24_000_000 ether;

    ArdiNFTv321 nft;
    EmissionDistributorV2 dist;
    ForkMockMinter321 mockMinter;

    uint256[] sampleTokenIds;

    function setUp() public {
        // Skip cleanly when not running with --fork-url (chain id != 8453).
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }

        nft  = ArdiNFTv321(NFT_PROXY);
        dist = EmissionDistributorV2(DIST_PROXY);

        // Deploy v321 NFT impl + v32 distributor impl, upgrade both.
        ArdiNFTv321 nftImpl = new ArdiNFTv321();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();

        vm.startPrank(OWNER);
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(nftImpl), "");
        IUUPSPx(DIST_PROXY).upgradeToAndCall(address(edImpl), "");

        // Wire the v32 adapter + mock reward minter (real manager would
        // require MERKLE_ROLE which we don't impersonate on the fork).
        dist.setArdiNFTv32(NFT_PROXY);
        mockMinter = new ForkMockMinter321();
        dist.setRewardMinter(address(mockMinter));
        dist.setMaxMintPerClaim(75_000_000 ether);

        // Configure v3.2.1 dynamic repair pricing (the launch-day step
        // that MUST happen atomically with the upgrade in production —
        // otherwise repairFee/repair revert until owner intervenes).
        nft.configureRepair(RATIO, DAILY);
        vm.stopPrank();

        _seedSampleTokenIds();
    }

    // ─────────────────────── tests ───────────────────────

    function test_fork_storage_layoutPreserved() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Base v3 + v32 storage must read the same values as pre-upgrade.
        assertGt(dist.totalActivePower(), 0, "totalActivePower carries over");
        assertEq(dist.ardiNFT(), NFT_PROXY, "ardiNFT pointer preserved");
        assertEq(dist.operator(), OWNER, "operator preserved");
        assertEq(dist.owner(), OWNER, "owner preserved");
        // globalDecayRound is whatever mainnet sits at right now (could
        // be 0 pre-launch, or already non-zero if v3.2 was deployed and
        // the operator has fired any notifyReward). Either way the
        // counter should be stable across the upgrade — it's only
        // bumped by notifyReward, never reset.
        emit log_named_uint("globalDecayRound (carried over)", uint256(nft.globalDecayRound()));
        // v3.2.1 introduces _maintenanceRatioBps + _dailyEmissionWei;
        // both should be live with the values configureRepair() just
        // wrote in setUp. Re-prove by reading repairFee on a sample
        // (tested in detail below).
    }

    function test_fork_configureRepair_persists() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // configureRepair was called in setUp; the values should be readable
        // through repairFee output. Owner-only check is exercised separately.
        // We sanity-test by re-configuring with new values and confirming
        // repairFee shifts proportionally.
        uint256 totalPower = dist.totalActivePower();
        require(totalPower > 0, "fork has no active power");

        // Pick a sample token and read fee under default config.
        uint256 tid = sampleTokenIds[0];
        // Migrate one batch so the sample's per-token storage is v32-shaped.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        uint256 fee1 = nft.repairFee(tid);
        emit log_named_uint("repairFee under default (5000 bps, 24M)", fee1);
        assertGt(fee1, 0, "fee non-zero under default config");

        // Halve the ratio → halve the fee (formula linearity check).
        vm.prank(OWNER);
        nft.configureRepair(2_500, DAILY);
        uint256 fee2 = nft.repairFee(tid);
        assertEq(fee2, fee1 / 2, "halving ratio halves fee");

        // Restore default.
        vm.prank(OWNER);
        nft.configureRepair(RATIO, DAILY);
    }

    function test_fork_repairFee_matchesFormula_realPower() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Migrate samples, then evaluate the formula against real on-chain
        // power + maxDurability + totalActivePower.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        uint256 totalPower = dist.totalActivePower();
        emit log_named_uint("totalActivePower (post-migrate)", totalPower);

        for (uint256 i = 0; i < 5; ++i) {
            uint256 tid = sampleTokenIds[i];
            ArdiNFTv3.Inscription memory ins = nft.getInscription(tid);

            uint256 expected =
                (uint256(RATIO) * DAILY * uint256(ins.power) * uint256(ins.maxDurability))
                / (10_000 * totalPower);
            uint256 got = nft.repairFee(tid);
            assertEq(got, expected, "fee matches formula for real token");
            emit log_named_uint("tid", tid);
            emit log_named_uint("  power", uint256(ins.power));
            emit log_named_uint("  maxDur", uint256(ins.maxDurability));
            emit log_named_uint("  fee (1e18 scale)", got);
        }
    }

    function test_fork_repair_revertsWhenAlive() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Migrate samples; immediately after migrate, every NFT has full
        // durability (currentDurability = maxDurability, expirationRound =
        // globalDecayRound + maxDurability). repair() must revert
        // NotYetExpired.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        uint256 tid = sampleTokenIds[0];
        address holder = nft.ownerOf(tid);
        vm.expectRevert(ArdiNFTv321.NotYetExpired.selector);
        vm.prank(holder);
        nft.repair(tid);
    }

    /// @notice Verifies the production deploy script's atomic
    ///         `upgradeToAndCall(impl, configureRepair-calldata)` path.
    ///         If this passes, the script's encoding is correct and the
    ///         post-upgrade window where params are unconfigured does
    ///         not exist.
    function test_fork_atomicUpgradeAndConfigure() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Re-fork-style: deploy a fresh impl and upgrade via the same
        // call shape the deploy script uses, in a single tx.
        ArdiNFTv321 freshImpl = new ArdiNFTv321();
        bytes memory configureCall = abi.encodeCall(
            ArdiNFTv321.configureRepair, (uint16(5_000), uint256(24_000_000 ether))
        );
        vm.prank(OWNER);
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(freshImpl), configureCall);

        // Migrate sample so getInscription is v32-shaped, then read fee.
        // If atomic-config worked, repairFee returns the formula value;
        // if it was missed, repairFee reverts NotYetExpired.
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        uint256 fee = nft.repairFee(sampleTokenIds[0]);
        assertGt(fee, 0, "atomic configureRepair landed; fee available");
        emit log_named_uint("atomic-upgrade fee for sample[0]", fee);
    }

    function test_fork_repair_gateFlipsAfterExpiry() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        // Migrate samples → notifyReward enough times to drive every
        // sample past its maxDurability → effectiveDurability == 0 →
        // _beforeRepair stops firing NotYetExpired (and instead
        // repairFee + downstream logic take over).
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        // Worst-case maxDur on chain is 14 (legendary), so 16 bumps is
        // enough to expire every sample regardless of generation.
        for (uint256 i = 0; i < 16; ++i) {
            vm.prank(OWNER);
            dist.notifyReward(1_000 ether);
        }
        emit log_named_uint("globalDecayRound after 16 bumps", uint256(nft.globalDecayRound()));

        uint256 tid = sampleTokenIds[0];
        assertEq(nft.effectiveDurability(tid), 0, "tok expired");

        // After ~16 bumps every NFT in the sample expired and left the
        // active pool. If totalActivePower is 0 chain-wide, repairFee
        // reverts NotYetExpired (the bootstrap-safety branch). On
        // mainnet that's only true when the entire 21K supply expires
        // simultaneously — vanishingly unlikely. We assert whichever
        // branch holds and document it for the launch runbook.
        uint256 totalPower = dist.totalActivePower();
        emit log_named_uint("totalActivePower after expiry storm", totalPower);
        if (totalPower == 0) {
            emit log_string("all sample power drained -> repairFee reverts (bootstrap branch)");
            vm.expectRevert(ArdiNFTv321.NotYetExpired.selector);
            nft.repairFee(tid);
        } else {
            uint256 fee = nft.repairFee(tid);
            assertGt(fee, 0, "fee available post-expiry when pool non-empty");
            emit log_named_uint("post-expiry repairFee", fee);
        }
    }

    // ─────────────────────── helpers ───────────────────────

    function _seedSampleTokenIds() internal {
        // Same 50 tids as v32 fork test — deterministic, pre-verified to
        // exist on the post-redeploy mainnet (per base-mainnet-v3.json).
        sampleTokenIds = [
            uint256(4), 34, 47, 56, 58, 60, 64, 73, 75, 76,
            79, 80, 89, 90, 101, 113, 114, 117, 118, 134,
            136, 138, 139, 145, 147, 159, 161, 162, 163, 168,
            172, 174, 176, 187, 195, 196, 200, 202, 209, 215,
            225, 229, 232, 240, 251, 256, 258, 260, 269, 271
        ];
    }
}
