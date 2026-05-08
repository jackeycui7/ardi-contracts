// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmbeddingStore} from "../../src/v4/EmbeddingStore.sol";

contract EmbeddingStoreTest is Test {
    EmbeddingStore store;
    address owner = address(0xA11CE);

    function setUp() public {
        vm.prank(owner);
        store = new EmbeddingStore(owner);
    }

    function testSetBatchAndRead() public {
        uint16[] memory ids = new uint16[](2);
        ids[0] = 1; ids[1] = 2;
        bytes[] memory embs = new bytes[](2);
        embs[0] = _emb(1);
        embs[1] = _emb(2);

        vm.prank(owner);
        store.setBatch(ids, embs);

        assertEq(store.storedCount(), 2);
        assertTrue(store.hasWord(1));
        assertEq(store.embeddings(1).length, 96);
        assertEq(store.embeddings(1)[0], bytes1(uint8(1)));
    }

    function testRejectsBadLength() public {
        uint16[] memory ids = new uint16[](1);
        ids[0] = 1;
        bytes[] memory embs = new bytes[](1);
        embs[0] = new bytes(95); // wrong length

        vm.prank(owner);
        vm.expectRevert(EmbeddingStore.InvalidEmbeddingLength.selector);
        store.setBatch(ids, embs);
    }

    function testSealedRejectsWrites() public {
        vm.prank(owner);
        store.seal();
        assertTrue(store.sealed_());

        uint16[] memory ids = new uint16[](1); ids[0] = 1;
        bytes[] memory embs = new bytes[](1); embs[0] = _emb(1);
        vm.prank(owner);
        vm.expectRevert(EmbeddingStore.AlreadySealed.selector);
        store.setBatch(ids, embs);
    }

    function testIdempotentOverwrite() public {
        uint16[] memory ids = new uint16[](1); ids[0] = 1;
        bytes[] memory embs = new bytes[](1); embs[0] = _emb(1);
        vm.prank(owner);
        store.setBatch(ids, embs);
        vm.prank(owner);
        store.setBatch(ids, embs); // overwrite
        assertEq(store.storedCount(), 1, "no double-count on rewrite");
    }

    function testHashesSet() public {
        bytes32 pca = keccak256("pca-basis-canonical");
        bytes32 model = keccak256("all-MiniLM-L6-v2/1.0");
        vm.prank(owner);
        store.setPcaBasisHash(pca);
        vm.prank(owner);
        store.setModelHash(model);
        assertEq(store.pcaBasisHash(), pca);
        assertEq(store.modelHash(), model);
    }

    function _emb(uint8 fill) internal pure returns (bytes memory v) {
        v = new bytes(96);
        for (uint256 i = 0; i < 96; i++) v[i] = bytes1(fill);
    }
}
