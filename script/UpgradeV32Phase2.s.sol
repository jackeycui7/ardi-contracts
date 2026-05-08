// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv32} from "../src/v32/ArdiNFTv32.sol";
import {EmissionDistributorV2} from "../src/v32/EmissionDistributorV2.sol";

interface IUUPSPx {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

/// @title UpgradeV32Phase2 — Pause + upgrade + wire (no migrate, no notify)
/// @notice Step 2 of staged deploy. Runs as ONE atomic broadcast:
///   1. dist.pause()
///   2. upgrade NFT proxy
///   3. upgrade Distributor proxy
///   4. dist.setArdiNFTv32(nft proxy)
///   5. dist.setRewardMinter(WorknetManager)
///   6. dist.setMaxMintPerClaim(75M ether)
///   7. dist.setMaxNotifyAmount(36M ether)
///
///   Migration runs separately via UpgradeV32Phase2Migrate.s.sol (batch
///   loop). Unpause + first notifyReward also separate (manual cast
///   commands, gated on (a) all NFTs migrated and (b) ke's MERKLE_ROLE
///   grant confirmed on chain).
///
/// @dev Required env:
///   DEPLOYER_PK         — owner key (must hold owner role on both proxies)
///   NFT_V32_IMPL        — output of Phase 1
///   ED_V32_IMPL         — output of Phase 1
///   NFT_PROXY           — production proxy (0xf68425D0...)
///   DIST_PROXY          — production proxy (0x180D7271...)
///   WORKNET_MANAGER     — ke's manager (0x22cB0f31...)
contract UpgradeV32Phase2 is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 ownerPk = vm.envUint("DEPLOYER_PK");
        address nftImpl = vm.envAddress("NFT_V32_IMPL");
        address edImpl  = vm.envAddress("ED_V32_IMPL");
        address nftProxy = vm.envAddress("NFT_PROXY");
        address distProxy = vm.envAddress("DIST_PROXY");
        address worknetManager = vm.envAddress("WORKNET_MANAGER");

        EmissionDistributorV2 dist = EmissionDistributorV2(distProxy);

        vm.startBroadcast(ownerPk);
        // 1. Pause distributor (claim disabled during the window).
        dist.pause();
        // 2-3. Upgrade both proxies.
        IUUPSPx(nftProxy).upgradeToAndCall(nftImpl, "");
        IUUPSPx(distProxy).upgradeToAndCall(edImpl, "");
        // 4-7. Wire v32 adapters + safety caps.
        dist.setArdiNFTv32(nftProxy);
        dist.setRewardMinter(worknetManager);
        dist.setMaxMintPerClaim(75_000_000 ether);
        dist.setMaxNotifyAmount(36_000_000 ether);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Phase 2 complete. Distributor is PAUSED.");
        console2.log("Effective durability shows 0 for all NFTs until migration.");
        console2.log("");
        console2.log("Next: run UpgradeV32Phase2Migrate over /tmp/ardi_active_tids.json");
        console2.log("      then manually `cast send dist unpause()`");
        console2.log("      then operator `cast send dist notifyReward(24M)` at 12:00 UTC");
    }
}
