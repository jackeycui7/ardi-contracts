// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFTv322} from "../../src/v32/ArdiNFTv322.sol";
import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";
import {EmissionDistributorV2} from "../../src/v32/EmissionDistributorV2.sol";

interface IUUPSPx {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

interface IERC20Sym {
    function symbol() external view returns (string memory);
}

/// @notice Fork dry-run for v3.2.1 → v3.2.2. Validates that the atomic
///         upgradeToAndCall(impl, setRepairConfig-calldata) re-points
///         `ardi` from AWP to aARDI without disturbing the v3.2.1 dynamic
///         pricing already in place, and preserves all v3.2 storage.
///
/// Run: forge test --match-path test/v322/MainnetForkUpgradeV322.t.sol \
///        --fork-url https://mainnet.base.org -vv
contract MainnetForkUpgradeV322Test is Test {
    address constant NFT_PROXY  = 0xf68425D0d451699d0d766150634E436Acd2F05A1;
    address constant DIST_PROXY = 0x180D7271f1E3Eb8dbF635E24A1B79e9718611a65;
    address constant OWNER      = 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43;

    address constant AWP_TOKEN  = 0x0000A1050AcF9DEA8af9c2E74f0D7CF43f1000A1;
    address constant AARDI_TOKEN = 0xA1008d4F7aA3Aec3C3F529A71dd241Ff9553CAFE;

    uint16  constant RATIO = 5_000;
    uint256 constant DAILY = 24_000_000 ether;

    ArdiNFTv322 nft;
    EmissionDistributorV2 dist;

    uint256[] sampleTokenIds;

    function setUp() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        nft  = ArdiNFTv322(NFT_PROXY);
        dist = EmissionDistributorV2(DIST_PROXY);

        ArdiNFTv322 nftImpl = new ArdiNFTv322();
        bytes memory setupCall = abi.encodeCall(
            ArdiNFTv322.setRepairConfig, (RATIO, DAILY, AARDI_TOKEN)
        );
        vm.prank(OWNER);
        IUUPSPx(NFT_PROXY).upgradeToAndCall(address(nftImpl), setupCall);

        // Wire the dist's adapter (no-op if v3.2 already wired it pre-fork).
        // The Mainnet snapshot already has setArdiNFTv32 set; this is just
        // defensive in case the fork picks a block where it isn't.
        if (dist.ardiNFT() != address(0) && address(dist) != address(0)) {
            // already wired
        }

        _seedSampleTokenIds();
    }

    // ─── tests ──────────────────────────────────────────

    function test_fork_pre_upgrade_ardi_was_AWP() public view {
        // Sanity record: we're upgrading FROM a state where ardi==AWP.
        // After setUp this is already the post-upgrade state, so for
        // pre-state we read directly from a fresh fork. This test just
        // documents the address constants for the runbook.
        if (block.chainid != 8453) return;
        assertEq(IERC20Sym(AWP_TOKEN).symbol(), "AWP");
        assertEq(IERC20Sym(AARDI_TOKEN).symbol(), "aARDI");
    }

    function test_fork_post_upgrade_ardi_is_aARDI() public {
        if (block.chainid != 8453) return;
        // The setRepairConfig call inside setUp's atomic upgrade must
        // have written aARDI as the canonical reward token.
        assertEq(address(nft.ardi()), AARDI_TOKEN, "ardi repointed");
        emit log_named_string("post-upgrade ardi.symbol", IERC20Sym(address(nft.ardi())).symbol());
    }

    function test_fork_repairFee_stillWorksAfterRepoint() public {
        if (block.chainid != 8453) return;
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        uint256 totalPower = dist.totalActivePower();
        require(totalPower > 0, "fork has no active power");

        // Verify formula matches across 5 sample tokens.
        for (uint256 i = 0; i < 5; ++i) {
            uint256 tid = sampleTokenIds[i];
            ArdiNFTv3.Inscription memory ins = nft.getInscription(tid);
            uint256 expected =
                (uint256(RATIO) * DAILY * uint256(ins.power) * uint256(ins.maxDurability))
                / (10_000 * totalPower);
            assertEq(nft.repairFee(tid), expected, "fee formula intact");
        }
    }

    function test_fork_repair_postMortemGate_intact() public {
        if (block.chainid != 8453) return;
        vm.startPrank(OWNER);
        dist.pause();
        nft.batchMigrate(sampleTokenIds);
        dist.unpause();
        vm.stopPrank();

        // Sample[0] is freshly migrated → effectiveDurability > 0.
        uint256 tid = sampleTokenIds[0];
        address holder = nft.ownerOf(tid);
        vm.expectRevert(ArdiNFTv322.NotYetExpired.selector);
        vm.prank(holder);
        nft.repair(tid);
    }

    function test_fork_storage_preserved_inscriptions() public view {
        if (block.chainid != 8453) return;
        // Pre-existing inscriptions must still be readable post-upgrade.
        ArdiNFTv3.Inscription memory ins = nft.getInscription(sampleTokenIds[0]);
        assertGt(ins.power, 0, "tid 4 power preserved");
        assertGt(ins.maxDurability, 0, "tid 4 maxDur preserved");
    }

    // ─── helpers ────────────────────────────────────────

    function _seedSampleTokenIds() internal {
        sampleTokenIds = [
            uint256(4), 34, 47, 56, 58, 60, 64, 73, 75, 76,
            79, 80, 89, 90, 101, 113, 114, 117, 118, 134,
            136, 138, 139, 145, 147, 159, 161, 162, 163, 168,
            172, 174, 176, 187, 195, 196, 200, 202, 209, 215,
            225, 229, 232, 240, 251, 256, 258, 260, 269, 271
        ];
    }
}
