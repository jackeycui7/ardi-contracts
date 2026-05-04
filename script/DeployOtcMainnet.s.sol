// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";

/// @title DeployOtcMainnet — peer-to-peer marketplace deploy on Base mainnet.
/// @notice ArdiOTC is contract-only (not upgradeable), tied at construction
///         time to the v3 ArdiNFT proxy. v3 contract has TokenLocked guard
///         that blocks transferFrom while a repair/fuse VRF is mid-flight,
///         so listings on locked NFTs effectively go dormant until callback
///         fires — desired behavior, no contract change needed.
///
/// Required env:
///   DEPLOYER_PK
///   OWNER_ADDR    (initial owner; eventually transferred to Timelock)
///   ARDI_NFT_ADDR (v3 ArdiNFT proxy, e.g. 0x91734696...)
contract DeployOtcMainnet is Script {
    function run() external returns (address otc) {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address owner = vm.envAddress("OWNER_ADDR");
        address nft = vm.envAddress("ARDI_NFT_ADDR");

        console2.log("Deployer :", vm.addr(deployerPk));
        console2.log("Owner    :", owner);
        console2.log("ArdiNFT  :", nft);

        vm.startBroadcast(deployerPk);
        ArdiOTC m = new ArdiOTC(owner, nft);
        vm.stopBroadcast();

        otc = address(m);
        console2.log("");
        console2.log("ArdiOTC deployed:", otc);

        vm.writeFile(
            "./deployments/base-mainnet-otc.json",
            string.concat(
                "{\n",
                '  "chainId": 8453,\n',
                '  "deployedAt": ', vm.toString(block.timestamp), ",\n",
                '  "owner": "', vm.toString(owner), '",\n',
                '  "ardiNFT": "', vm.toString(nft), '",\n',
                '  "otc": "', vm.toString(otc), '"\n',
                "}\n"
            )
        );
    }
}
