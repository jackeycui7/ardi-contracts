// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArdiNFTv4Mainnet} from "../src/v4/ArdiNFTv4Mainnet.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImpl, bytes memory data) external payable;
    function owner() external view returns (address);
}

/// @notice UUPS upgrade the existing ArdiNFT proxy from v322 → v4Mainnet.
///         No initializer call (v4 has no new init data — `setForgeModule`
///         is a separate later call by owner).
///
/// Pre-flight assumptions:
///   - Proxy address: PROXY env var (= 0xf68425D0d451699d0d766150634E436Acd2F05A1)
///   - Sender = proxy owner (= 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43)
///   - Storage layout already verified compatible (forge inspect)
///   - Mainnet fork test passed (test/v4/MainnetForkUpgrade.t.sol)
///
/// Usage:
///   PRIVATE_KEY=$OWNER_PK PROXY=0xf68425D0d451699d0d766150634E436Acd2F05A1 \
///   forge script script/UpgradeNFTToV4.s.sol:UpgradeNFTToV4 \
///     --rpc-url https://mainnet.base.org --broadcast
contract UpgradeNFTToV4 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PROXY");
        address signer = vm.addr(pk);

        // Sanity: signer must be proxy owner.
        address proxyOwner = IUUPSProxy(proxy).owner();
        require(signer == proxyOwner, "signer != proxy owner");

        vm.startBroadcast(pk);

        ArdiNFTv4Mainnet impl = new ArdiNFTv4Mainnet();
        console.log("v4 impl:", address(impl));

        IUUPSProxy(proxy).upgradeToAndCall(address(impl), "");
        console.log("upgrade complete. proxy:", proxy);

        vm.stopBroadcast();

        console.log("");
        console.log("--- Next: wire forge module ---");
        console.log("cast send %s 'setForgeModule(address)' <FORGE_MODULE> ...", proxy);
    }
}
