// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFTv3} from "../src/v3/ArdiNFTv3.sol";

interface IUUPS {
    function upgradeToAndCall(address newImpl, bytes calldata data) external payable;
}

interface INFTv31 {
    function ELEMENT_MAX() external view returns (uint8);
}

/// @notice v3.1 ArdiNFTv3 upgrade: ELEMENT_MAX bump 5→6 so winners of
/// god-tier words (22 hand-picked legendary entries — bitcoin/ethereum/etc)
/// can actually inscribe their NFTs. Pairs with the ArdiEpochDrawV3 v3.1
/// upgrade which raised its own element validation to 6.
///
/// Required env: DEPLOYER_PK, NFT_PROXY_ADDR.
contract UpgradeNFTv31 is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address proxy = vm.envAddress("NFT_PROXY_ADDR");

        console2.log("chainid:", block.chainid);
        console2.log("proxy:", proxy);
        uint8 oldMax = INFTv31(proxy).ELEMENT_MAX();
        console2.log("ELEMENT_MAX before:", oldMax);
        require(oldMax == 5, "expected v3.0 ELEMENT_MAX=5 before upgrade");

        vm.startBroadcast(pk);
        ArdiNFTv3 newImpl = new ArdiNFTv3();
        console2.log("new impl:", address(newImpl));
        IUUPS(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        uint8 newMax = INFTv31(proxy).ELEMENT_MAX();
        console2.log("ELEMENT_MAX after:", newMax);
        require(newMax == 6, "ELEMENT_MAX did not bump to 6");
    }
}
