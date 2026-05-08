// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EmbeddingStore} from "../src/v4/EmbeddingStore.sol";
import {ArdiForgeModule} from "../src/v4/ArdiForgeModule.sol";
import {ChainlinkVRFAdapter} from "../src/ChainlinkVRFAdapter.sol";

/// @notice Deploy the forge stack on Base mainnet — EmbeddingStore +
///         ForgeModule + VRF adapter. Does NOT touch the existing NFT
///         proxy (that upgrade is a separate step / script after these
///         pieces are wired + Chainlink subscription is funded).
///
/// Usage:
///   PRIVATE_KEY=$(cast wallet ...) \
///   COORDINATOR=0x123... CHAINLINK_KEYHASH=0xabc... CHAINLINK_SUB_ID=42 \
///   forge script script/DeployForgeMainnet.s.sol:DeployForgeMainnet \
///     --rpc-url https://mainnet.base.org --broadcast
contract DeployForgeMainnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Chainlink params (Base mainnet — verify before each deploy):
        //   coordinator: VRF v2.5 coordinator address on Base
        //   keyHash:     gas-lane keyHash (lower = cheaper, slower)
        //   subId:       LINK subscription ID with this contract added
        address coordinator = vm.envAddress("CHAINLINK_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("CHAINLINK_KEYHASH");
        uint256 subId = vm.envUint("CHAINLINK_SUB_ID");

        vm.startBroadcast(pk);

        // 1. EmbeddingStore — empty, owner = deployer. Will load 21K
        //    embeddings via setBatch in a follow-up tx batch, then seal.
        EmbeddingStore store = new EmbeddingStore(deployer);
        console.log("EmbeddingStore:", address(store));

        // 2. ForgeModule — config left blank. Owner sets it later when
        //    NFT proxy is upgraded + VRF adapter is wired.
        ArdiForgeModule module = new ArdiForgeModule(deployer);
        console.log("ArdiForgeModule:", address(module));

        // 3. Forge-dedicated VRF adapter. Consumer = module. Owner
        //    must add this adapter to the Chainlink subscription
        //    (off-chain step) before any forge call works.
        ChainlinkVRFAdapter forgeVrf = new ChainlinkVRFAdapter(
            deployer,        // owner
            coordinator,
            keyHash,
            uint64(subId),
            address(module)  // consumer
        );
        console.log("ForgeVRFAdapter:", address(forgeVrf));

        vm.stopBroadcast();

        console.log("");
        console.log("--- Next steps (off-chain) ---");
        console.log("1. Add ForgeVRFAdapter to Chainlink subscription %s and fund LINK", subId);
        console.log("2. Upload 21K embeddings via setBatch loop:");
        console.log("   ts-node embedding-pipeline/upload_embeddings.ts %s", address(store));
        console.log("3. Call store.seal() once upload verified");
        console.log("4. Run UpgradeNFTToV4.s.sol (deploys impl + upgrades proxy)");
        console.log("5. Call setForgeModule(%s) on NFT proxy", address(module));
        console.log("6. Call setConfig(...) on ArdiForgeModule with all addresses");
    }
}
