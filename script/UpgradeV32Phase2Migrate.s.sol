// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv32} from "../src/v32/ArdiNFTv32.sol";

/// @title UpgradeV32Phase2Migrate — Batch-migrate active tokenIds
/// @notice Reads tokenIds from `MIGRATE_TIDS` env (comma-separated decimal
///         numbers). Calls migrateExisting in a single tx.
/// @dev Run multiple times with batched lists of ≤200 to stay under block gas.
///      For ardi mainnet at launch (~2700 active NFTs), 14 calls of 200 each.
contract UpgradeV32Phase2Migrate is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 ownerPk = vm.envUint("DEPLOYER_PK");
        address nftProxy = vm.envAddress("NFT_PROXY");
        // Comma-separated decimal token IDs.
        string memory raw = vm.envString("MIGRATE_TIDS");
        uint256[] memory tids = _parseCsv(raw);
        require(tids.length > 0 && tids.length <= 200, "batch must be 1..200");

        ArdiNFTv32 nft = ArdiNFTv32(nftProxy);
        vm.startBroadcast(ownerPk);
        nft.batchMigrate(tids);
        vm.stopBroadcast();

        console2.log("Migrated batch of", tids.length, "tokenIds");
    }

    function _parseCsv(string memory raw) internal pure returns (uint256[] memory out) {
        bytes memory b = bytes(raw);
        // Count commas + 1 to size the array.
        uint256 n = 1;
        for (uint256 i = 0; i < b.length; ++i) if (uint8(b[i]) == 0x2c /* ',' */) ++n;
        out = new uint256[](n);
        uint256 idx = 0;
        uint256 cur = 0;
        bool any = false;
        for (uint256 i = 0; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x30 && c <= 0x39) {
                cur = cur * 10 + (c - 0x30);
                any = true;
            } else if (c == 0x2c /* ',' */) {
                if (any) { out[idx++] = cur; cur = 0; any = false; }
            }
            // ignore other characters (spaces, newlines)
        }
        if (any) out[idx++] = cur;
        // Trim if there were trailing empties.
        if (idx < n) {
            uint256[] memory trimmed = new uint256[](idx);
            for (uint256 i = 0; i < idx; ++i) trimmed[i] = out[i];
            out = trimmed;
        }
    }
}
