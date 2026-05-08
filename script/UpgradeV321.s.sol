// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv321} from "../src/v32/ArdiNFTv321.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

/// @title UpgradeV321 — UUPS upgrade script for v3.2 → v3.2.1
/// @notice Single-proxy upgrade: only ArdiNFT changes (EmissionDistributorV2
///   stays as-is from v3.2). The script bundles two operations into ONE
///   `upgradeToAndCall` so they execute atomically:
///
///     1) swap impl from ArdiNFTv32 → ArdiNFTv321
///     2) call `configureRepair(5000, 24_000_000e18)` via the upgrade's
///        post-upgrade delegatecall
///
///   This atomicity matters: between (1) and (2) the contract is in a
///   "v3.2.1 code, unconfigured params" state where every `repairFee()`
///   call reverts (NotYetExpired, the bootstrap-safety branch). Bundling
///   them removes the failure window — owner can't forget step (2), and
///   no end-user request can land in between.
///
/// Inputs (env):
///   DEPLOYER_PK         — owner's private key
///   ARDI_NFT_ADDR       — production ArdiNFT proxy (v3.2 currently)
///   MAINTENANCE_RATIO   — bps (e.g. 5000 = 0.5×)              [default 5000]
///   DAILY_EMISSION_WEI  — daily $ardi emission target in wei  [default 24M ether]
///
/// Run:
///   forge script script/UpgradeV321.s.sol:UpgradeV321 \
///     --rpc-url $BASE_RPC --broadcast --slow -vvv
///
/// Verify post-upgrade:
///   cast call $ARDI_NFT_ADDR "repairFee(uint256)(uint256)" <tokenId> \
///     --rpc-url $BASE_RPC
///   # → returns the dynamic fee, NOT a revert
contract UpgradeV321 is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address ardiNFTProxy = vm.envAddress("ARDI_NFT_ADDR");

        // Defaults match the launch-day parameters agreed with sky.
        // 5000 bps = 0.5× lifetime-earnings cost per repair.
        uint16 ratioBps = uint16(vm.envOr("MAINTENANCE_RATIO", uint256(5_000)));
        uint256 dailyWei = vm.envOr("DAILY_EMISSION_WEI", uint256(24_000_000 ether));
        require(ratioBps > 0 && ratioBps <= 50_000, "ratio out of range (1..50_000 bps)");
        require(dailyWei > 0, "daily emission must be non-zero");

        vm.startBroadcast(deployerPk);

        // 1. Deploy v3.2.1 implementation.
        ArdiNFTv321 nftImpl = new ArdiNFTv321();

        // 2. Atomic upgrade + configure: encode configureRepair as the
        //    post-upgrade call. The proxy delegatecalls it on the new
        //    impl in the same tx as the impl swap, so there is never a
        //    block where v3.2.1 code runs without configured params.
        bytes memory configureCall = abi.encodeCall(
            ArdiNFTv321.configureRepair, (ratioBps, dailyWei)
        );
        IUUPS(ardiNFTProxy).upgradeToAndCall(address(nftImpl), configureCall);

        vm.stopBroadcast();

        console2.log("ArdiNFTv321 impl:        ", address(nftImpl));
        console2.log("Proxy (upgraded):        ", ardiNFTProxy);
        console2.log("maintenanceRatioBps:     ", ratioBps);
        console2.log("dailyEmissionWei:        ", dailyWei);
        console2.log("");
        console2.log("Verify on chain:");
        console2.log("  cast call <proxy> 'repairFee(uint256)(uint256)' <tokenId>");
        console2.log("  -> returns formula result, MUST NOT revert");
    }
}
