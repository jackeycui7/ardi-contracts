// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv32} from "../src/v32/ArdiNFTv32.sol";
import {EmissionDistributorV2} from "../src/v32/EmissionDistributorV2.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

/// @title UpgradeV32 — UUPS upgrade script for v3 → v32
/// @notice Two-step:
///   1) Deploy new ArdiNFTv32 + EmissionDistributorV2 implementations
///   2) Call upgradeToAndCall on each proxy (owner-only)
///
/// After upgrade, owner MUST:
///   a) Call EmissionDistributorV2.setArdiNFTv32(<ardiNFTAddr>)
///   b) Run ArdiNFTv32.migrateExisting([...]) in batches over all
///      currently active tokenIds. Until migration completes for a
///      tokenId, that NFT will lose all durability on the next
///      `notifyReward` (its expirationRound defaults to 0 < globalDecayRound).
///      Recommended: pause emission via `EmissionDistributorV2.pause()`
///      until migration finishes, then unpause + run first notifyReward.
contract UpgradeV32 is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address ardiNFTProxy = vm.envAddress("ARDI_NFT_ADDR");
        address emissionProxy = vm.envAddress("EMISSION_DIST_ADDR");

        vm.startBroadcast(deployerPk);

        ArdiNFTv32 nftImpl = new ArdiNFTv32();
        EmissionDistributorV2 edImpl = new EmissionDistributorV2();

        // No initializer call on upgrade — storage is preserved.
        IUUPS(ardiNFTProxy).upgradeToAndCall(address(nftImpl), "");
        IUUPS(emissionProxy).upgradeToAndCall(address(edImpl), "");

        vm.stopBroadcast();

        console2.log("ArdiNFTv32 impl:           ", address(nftImpl));
        console2.log("EmissionDistributorV2 impl:", address(edImpl));
        console2.log("");
        console2.log("Next steps (owner):");
        console2.log("  1. EmissionDistributorV2.pause()");
        console2.log("  2. EmissionDistributorV2.setArdiNFTv32(", ardiNFTProxy, ")");
        console2.log("  3. ArdiNFTv32.migrateExisting([...]) in batches of <=200");
        console2.log("  4. EmissionDistributorV2.unpause()");
        console2.log("  5. EmissionDistributorV2.notifyReward(<amount>)  -- first round");
    }
}
