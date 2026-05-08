// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv322} from "../src/v32/ArdiNFTv322.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

/// @title UpgradeV322 — v3.2.1 → v3.2.2 (atomic ardi-token fix)
/// @notice Single-tx UUPS upgrade. v322 inherits v32 directly (NOT v321)
///         to fit under EIP-170; v321 was 2-byte-margin and the new
///         setter would have busted the limit.
///
///         Bundled atomic op:
///           1. swap impl ArdiNFTv321 → ArdiNFTv322
///           2. setRepairConfig(5000, 24M ardi, aARDI_token) — bumps
///              `ardi` storage from AWP (`0x0000A105…A1`) to aARDI
///              (`0xA1008d4F…CAFE`), and re-asserts the dynamic-repair
///              params that v321 already configured (no functional
///              change to those, but v322's storage layout matches v321
///              so this re-write is also a no-op for ratio/daily).
///
/// Inputs (env):
///   DEPLOYER_PK      — owner's private key
///   ARDI_NFT_ADDR    — production ArdiNFT proxy
///   ARDI_TOKEN_ADDR  — aARDI token (default 0xA1008d4F…CAFE)
///   MAINTENANCE_RATIO  — bps                                 [default 5000]
///   DAILY_EMISSION_WEI — daily emission target wei           [default 24M ether]
///
/// Verify post-upgrade:
///   cast call $ARDI_NFT_ADDR "ardi()(address)" --rpc-url $RPC_URL
///   # → 0xA1008d4F7aA3Aec3C3F529A71dd241Ff9553CAFE
contract UpgradeV322 is Script {
    address constant DEFAULT_AARDI = 0xA1008d4F7aA3Aec3C3F529A71dd241Ff9553CAFE;

    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address ardiNFTProxy = vm.envAddress("ARDI_NFT_ADDR");
        address aardiToken = vm.envOr("ARDI_TOKEN_ADDR", DEFAULT_AARDI);
        uint16 ratioBps = uint16(vm.envOr("MAINTENANCE_RATIO", uint256(5_000)));
        uint256 dailyWei = vm.envOr("DAILY_EMISSION_WEI", uint256(24_000_000 ether));

        require(aardiToken != address(0), "aardi=0");
        require(ratioBps > 0, "ratio=0 disables repair");
        require(dailyWei > 0, "daily=0 disables repair");

        vm.startBroadcast(deployerPk);

        ArdiNFTv322 nftImpl = new ArdiNFTv322();

        bytes memory setupCall = abi.encodeCall(
            ArdiNFTv322.setRepairConfig, (ratioBps, dailyWei, aardiToken)
        );
        IUUPS(ardiNFTProxy).upgradeToAndCall(address(nftImpl), setupCall);

        vm.stopBroadcast();

        console2.log("ArdiNFTv322 impl:        ", address(nftImpl));
        console2.log("Proxy (upgraded):        ", ardiNFTProxy);
        console2.log("ardi token:              ", aardiToken);
        console2.log("maintenanceRatioBps:     ", ratioBps);
        console2.log("dailyEmissionWei:        ", dailyWei);
        console2.log("");
        console2.log("Verify:");
        console2.log("  cast call <proxy> 'ardi()(address)'");
        console2.log("  cast call <proxy> 'repairFee(uint256)(uint256)' <tid>");
    }
}
