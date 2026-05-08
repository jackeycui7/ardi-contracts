// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {OtcSweeper} from "../src/OtcSweeper.sol";

/// @title DeployOtcSweeper — single-tx deploy on Base mainnet.
/// @notice The sweeper is a passive batch-buyer; it has no admin, no
///   storage state, and no token approvals to set. Just deploy and
///   plumb the address into the frontend.
///
/// Inputs (env):
///   DEPLOYER_PK      — owner's private key (any funded EOA works; the
///                      sweeper has no ownership concept)
///   ARDI_OTC_ADDR    — ArdiOTC marketplace (default: prod OTC)
///   ARDI_NFT_ADDR    — ArdiNFT proxy       (default: prod NFT)
contract DeployOtcSweeper is Script {
    address constant DEFAULT_OTC = 0xEd4A2B66756fB3aB0f7a4fC9d442dccF3162B68F;
    address constant DEFAULT_NFT = 0xf68425D0d451699d0d766150634E436Acd2F05A1;

    function run() external {
        require(block.chainid == 8453, "expects Base mainnet (8453)");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address otc = vm.envOr("ARDI_OTC_ADDR", DEFAULT_OTC);
        address nft = vm.envOr("ARDI_NFT_ADDR", DEFAULT_NFT);

        vm.startBroadcast(deployerPk);
        OtcSweeper sweeper = new OtcSweeper(otc, nft);
        vm.stopBroadcast();

        console2.log("OtcSweeper:        ", address(sweeper));
        console2.log("  bound OTC:       ", otc);
        console2.log("  bound ArdiNFT:   ", nft);
        console2.log("");
        console2.log("Add to deployments/base-mainnet-v3.json:");
        console2.log("  ardiOtcSweeper:  <address above>");
    }
}
