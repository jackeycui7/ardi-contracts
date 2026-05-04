// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiEpochDrawV3} from "../src/v3/ArdiEpochDrawV3.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external payable;
}

interface IEpochDrawV31 {
    function vaultMerkleRoot() external view returns (bytes32);
    function setVaultMerkleRoot(bytes32 root) external;          // first-time only
    function migrateVaultMerkleRootV31(bytes32 newRoot) external; // already-set rotate
}

/// @notice v3.1 upgrade: new leaf encoding (abi.encode + themeHash + elementHash + maxDurability),
/// element max raised 5→6 (god), and one-shot migrate-root function. Sepolia or mainnet.
///
/// Required env:
///   DEPLOYER_PK         — deployer/owner private key
///   EPOCH_PROXY_ADDR    — UUPS proxy address (e.g. 0x143903...)
///   NEW_VAULT_ROOT      — new v3.1 root (0x77b80d7e...)
///   SKIP_MIGRATE        — optional, "1" to skip the root swap (just upgrade impl)
///
/// Strategy: deploy new impl, upgradeToAndCall(impl, ""), then call
/// migrateVaultMerkleRootV31(NEW_VAULT_ROOT). The migrate is gated on
/// pendingRequestsCount==0 — if a draw is in flight, this will revert and
/// the operator must wait for callback / cancelStuckDraw before retrying.
contract UpgradeEpochDrawV31 is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address proxy = vm.envAddress("EPOCH_PROXY_ADDR");
        bytes32 newRoot = vm.envBytes32("NEW_VAULT_ROOT");
        bool skipMigrate = vm.envOr("SKIP_MIGRATE", false);

        console2.log("chainid:", block.chainid);
        console2.log("proxy:", proxy);
        console2.log("skipMigrate:", skipMigrate);
        console2.logBytes32(newRoot);

        bytes32 oldRoot = IEpochDrawV31(proxy).vaultMerkleRoot();
        console2.log("old root:");
        console2.logBytes32(oldRoot);

        vm.startBroadcast(pk);
        ArdiEpochDrawV3 newImpl = new ArdiEpochDrawV3();
        console2.log("new impl:", address(newImpl));
        IUUPS(proxy).upgradeToAndCall(address(newImpl), "");
        if (!skipMigrate) {
            if (oldRoot == bytes32(0)) {
                // First-time set (sepolia case where v3.0 deploy left root = 0)
                IEpochDrawV31(proxy).setVaultMerkleRoot(newRoot);
            } else {
                // Already set, rotate via the one-shot v3.1 migration
                IEpochDrawV31(proxy).migrateVaultMerkleRootV31(newRoot);
            }
        }
        vm.stopBroadcast();

        bytes32 finalRoot = IEpochDrawV31(proxy).vaultMerkleRoot();
        console2.log("final root:");
        console2.logBytes32(finalRoot);
        require(skipMigrate || finalRoot == newRoot, "migrate failed");
    }
}
