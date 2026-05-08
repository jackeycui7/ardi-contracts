// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArdiNFTv4Testnet} from "../src/v4/ArdiNFTv4Testnet.sol";

/// @notice UUPS upgrade pushing the rebalanced ForgeMath constants to the
///         live Sepolia v4 testnet proxy. Storage layout unchanged.
///
///         Tier boundaries: [21,41,61,81] → [8,15,24,36]  (equal-share)
///         Mult bands:      T2 2.2-3.0 → 2.3-3.1, T4 1.3-1.5 → 1.4-1.6,
///                          T5 1.2-1.4 → 1.2-1.35  (T1/T3 unchanged)
///         Mythic prob:     1.0% → 2.5% (T1 only)
///         God Touch prob:  0.1% → 0.25% (T1 only)
///
/// Usage:
///   PROXY=0x3F8eea4ab4f62BD119C820320e54dD530ebe6552 \
///   DEPLOYER_PK=$(cat /root/.ardi-secrets/sepolia-deployer.txt | grep "Private key" | awk '{print $NF}') \
///   forge script script/UpgradeForgeV4Math.s.sol:UpgradeForgeV4Math \
///     --rpc-url https://sepolia.base.org --broadcast
contract UpgradeForgeV4Math is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");

        vm.startBroadcast(deployerPk);

        // 1. Deploy new impl (with updated ForgeMath constants).
        ArdiNFTv4Testnet newImpl = new ArdiNFTv4Testnet();
        console.log("new impl:", address(newImpl));

        // 2. UUPS upgrade — empty data (no re-init).
        ArdiNFTv4Testnet(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console.log("upgrade complete. proxy:", proxy);
    }
}
