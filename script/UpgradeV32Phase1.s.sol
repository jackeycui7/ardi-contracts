// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv32} from "../src/v32/ArdiNFTv32.sol";
import {EmissionDistributorV2} from "../src/v32/EmissionDistributorV2.sol";

/// @title UpgradeV32Phase1 — Deploy v32 implementations only.
/// @notice Step 1 of the staged deploy: deploy the two new impls. NO
///         proxy upgrade happens here; mainnet behavior is unchanged.
///         Output: prints both impl addresses for use as input to
///         UpgradeV32Phase2.
/// @dev Run with: `forge script script/UpgradeV32Phase1.s.sol --rpc-url
///      <base> --private-key $DEPLOYER_PK --broadcast`. Requires no env
///      vars. Idempotent — running twice deploys two more impls (waste
///      of gas, no harm).
contract UpgradeV32Phase1 is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");

        vm.startBroadcast(deployerPk);
        ArdiNFTv32 nftImpl = new ArdiNFTv32();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();
        vm.stopBroadcast();

        console2.log("");
        console2.log("Phase 1 complete. Save these for Phase 2:");
        console2.log("  NFT_V32_IMPL=",  address(nftImpl));
        console2.log("  ED_V32_IMPL=",   address(edImpl));
    }
}
