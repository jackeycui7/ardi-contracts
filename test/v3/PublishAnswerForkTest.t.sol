// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArdiEpochDrawV3} from "../../src/v3/ArdiEpochDrawV3.sol";

/// @notice End-to-end smoke for v3.1: deploys a fresh ArdiEpochDrawV3, sets
/// the same Merkle root that's live on Base Sepolia (0x77b80d7e...), opens
/// an epoch, and calls publishAnswer with a REAL Merkle proof generated
/// from Leslie's wordbank for wordId=0 (bitcoin). If this passes, the
/// three-way leaf encoding (Python → Rust → Solidity) is byte-for-byte
/// consistent and the new Merkle root verifies correctly under the new
/// abi.encode + themeHash + elementHash + maxDurability layout.
///
/// Why a fresh deploy instead of fork-testing the live proxy: foundry
/// invalidates fork state on vm.warp, which would silently wipe the
/// epoch we just opened.
contract PublishAnswerForkTest is Test {
    ArdiEpochDrawV3 epoch;
    address coordinator = address(0xC001);
    address treasury = address(0xBEEF);

    bytes32 constant V31_ROOT =
        0x77b80d7e350c323fb9498e45dcb4b940041587971772ecb58b80d275475840d6;

    function setUp() public {
        ArdiEpochDrawV3 impl = new ArdiEpochDrawV3();
        bytes memory init = abi.encodeCall(
            ArdiEpochDrawV3.initialize,
            (
                address(this),  // owner
                bytes32(0),     // vaultRoot — set after via setVaultMerkleRoot
                address(0xDEAD), // randomness (unused for publishAnswer test)
                coordinator,
                treasury,
                address(0xBEAD), // awpAllocator (unused)
                845300000014,    // ardiWorknetId
                845300000012,    // kyaWorknetId
                10_000e18        // minStake
            )
        );
        epoch = ArdiEpochDrawV3(address(new ERC1967Proxy(address(impl), init)));
        epoch.setVaultMerkleRoot(V31_ROOT);
    }

    function test_publishAnswer_acceptsBitcoinProof() public {
        // Open epoch
        uint256 epochId = 1;
        uint64 commitWindow = 60;
        uint64 revealWindow = 600;
        vm.prank(coordinator);
        epoch.openEpoch(epochId, commitWindow, revealWindow);

        // Skip past commit window so publish window opens
        skip(commitWindow + 1);

        // ---- bitcoin (wordId 0) from leslieshen1/ardinals-wordbankv3 main ----
        //   word="bitcoin" power=100 lang=en(0) durability=9 theme=crypto elem=god(6)
        bytes32 wordHash = keccak256(bytes("bitcoin"));
        bytes32 themeHash = keccak256(bytes("crypto"));
        bytes32 elementHash = keccak256(bytes("god"));

        bytes32[] memory proof = new bytes32[](15);
        proof[0]  = 0xca7d616ef7ba7d650b7e030b1cd8397251613a5a485b8b245d3331f4e7d38983;
        proof[1]  = 0x4aca70fd661b1a5c38bd44df7ac3457edd5e97b4397feab63b70a5c6c2b00c9f;
        proof[2]  = 0x4e7d912ac57ec986d0b39d7a1966e3ba1e685d30a4219ca9cb156d3a6e0e3599;
        proof[3]  = 0x74ebf2b17585b80950c0c8d4c9794b5ad67e28f4de4c4e7ecfece8d7f08cc8ee;
        proof[4]  = 0x33cc9737ce445a1a8f83c1e64d0ca8c7f32c0f2599e443c80f77da5914420ce1;
        proof[5]  = 0xb3e5ef2d3f78e52da5da3617ac4e23dad49b37f7e85c47ebfe4d37befb28a5b5;
        proof[6]  = 0xf5ac9802ed8f72fecb91d56b7e6be1ddf2a85613bc37539977aebcfbb6b0de0b;
        proof[7]  = 0xbe7a80cf0bd0e1570c47f6372b396f5839aaaaa1cdf7f91acc0ef31e7a04f647;
        proof[8]  = 0x3d8faf958af1c275bf8446bfff1b6bb673e622b998776e2ccec26bfa0f68cf7d;
        proof[9]  = 0x90c6ec92cd651b6c3671147cb9cd53fedfc95ce640f526abdc71558bab74a1f7;
        proof[10] = 0x1208ab8a04d3261549467a7143dbf7902f540ba9e2a1a8bdfe35c6e22103f18a;
        proof[11] = 0xeaaea8fac9fd98f95020d4507cbf2a3f252aae9f8cf1c8d853ca9c3f4e7e7783;
        proof[12] = 0xb9378341bb88f2693f1f06bb92a5de42ea451c3a6da3eae5da963dcc1317fef6;
        proof[13] = 0xa15c1e762ad44938ca8cdf60d8216653e18168c1e31dc1656d0aa560441bc65e;
        proof[14] = 0x7e0df065a139cd55cb33c308048fb708a64ff90c17473e286b0a816e19b182c4;

        vm.prank(coordinator);
        epoch.publishAnswer(
            epochId,
            0,           // wordId
            wordHash,
            100,         // power
            0,           // languageId (en)
            9,           // maxDurability (recomputed via keccak)
            6,           // element (god)
            themeHash,
            elementHash,
            proof
        );

        // Read back to confirm storage.
        (bytes32 storedHash, uint16 storedPower,, uint8 storedDur, uint8 storedElem, bool published)
            = epoch.getAnswer(epochId, 0);
        assertTrue(published, "answer not published");
        assertEq(storedHash, wordHash, "wordHash mismatch");
        assertEq(storedPower, 100, "power mismatch");
        assertEq(storedDur, 9, "durability mismatch");
        assertEq(storedElem, 6, "element mismatch (god should be 6)");
        console2.log("PASS: bitcoin (wordId=0) published with v3.1 leaf + god element");
    }
}
