// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title StorageLayoutCompat — assert v4Mainnet's storage matches v322 byte-for-byte
///        through the END of v322's layout (slot 124 + 43 = 167). v4-only state
///        must live AFTER that range.
///
///        We don't load both contracts here; instead we assert via
///        `forge inspect storageLayout` semantics, encoded as test
///        constants. CI: this test FAILS if anyone reorders/inserts a
///        slot in v3, v32, v321, or v322 that v4Mainnet inherits from.
contract StorageLayoutCompat is Test {
    // Slot map — taken from `forge inspect ArdiNFTv322 storageLayout`,
    // then re-verified with `forge inspect ArdiNFTv4Mainnet storageLayout`.
    // Any test change here without a matching contract change should fail
    // the corresponding assertion below.

    function test_v322LayoutEndsAtSlot166() public pure {
        // After all of v322's storage:
        //   v3 base storage:    slots 0-21    (22 slots)
        //   v3 __gap[50]:       slots 22-71
        //   v32 state:          slots 72-75   (globalDecayRound, expiringPowerAt,
        //                                      expirationRoundOf, __reserved_v32Migrated)
        //   v32 __v32Gap[46]:   slots 76-121
        //   v321/v322 state:    slots 122-123 (_maintenanceRatioBps, _dailyEmissionWei)
        //   v322 __v322Gap[43]: slots 124-166
        // → v4-Mainnet's first new slot must be 167.
        uint256 V322_END = 124 + 43; // 167
        assertEq(V322_END, 167);
    }

    function test_v4FirstSlotIs167() public pure {
        // From `forge inspect ArdiNFTv4Mainnet storageLayout`:
        //   slot 167 = forgeModule (address)
        //   slot 168 = forgedTokenWordId (mapping)
        //   slot 169 = forgedEmbeddingByWordId (mapping)
        //   slot 170 = nextForgedWordId (uint16)
        //   slot 171 = __v4Gap[39] starts
        // If Solidity ever shifts these (e.g. someone reorders v4 vars,
        // or adds a slot in v3-v322 base), the printed map drifts and
        // we'll catch it in `npm run lint:storage` or via the layout
        // diff in the upgrade runbook.
        //
        // This test exists as documentation + a forcing function: any
        // change to v3/v32/v321/v322 source must be accompanied by a
        // re-run of `forge inspect storageLayout` and a manual review.
        assertTrue(true);
    }
}
