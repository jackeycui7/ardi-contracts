// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiEpochDrawV3} from "../src/v3/ArdiEpochDrawV3.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external payable;
}

/// @notice Owner-only UUPS upgrade for ArdiEpochDrawV3 (multi-staker support).
/// Required env: DEPLOYER_PK, EPOCH_PROXY_ADDR.
contract UpgradeEpochDrawV3 is Script {
    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address proxy = vm.envAddress("EPOCH_PROXY_ADDR");
        console2.log("Upgrading proxy:", proxy);

        vm.startBroadcast(pk);
        ArdiEpochDrawV3 newImpl = new ArdiEpochDrawV3();
        console2.log("New impl:", address(newImpl));
        IUUPS(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();
    }
}
