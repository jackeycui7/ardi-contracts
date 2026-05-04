// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {ArdiEpochDraw} from "../src/ArdiEpochDraw.sol";
import {MockRandomness} from "../src/MockRandomness.sol";

/// @title  Mainnet Phase 1 deploy — mining only (no token / OTC / settlement).
/// @notice Deploys ArdiNFT + ArdiEpochDraw + MockRandomness placeholder, wires
///         them, then we run DeployVRFAdapter separately to swap to real VRF.
///
///         Settlement contracts (ArdiToken, ArdiMintController, ArdiOTC) are
///         intentionally NOT deployed — Phase 2 work.
///
/// Required env (all populated from /etc/ardi/mainnet-secrets.env):
///   DEPLOYER_PK
///   OWNER_ADDR
///   COORDINATOR_ADDR
///   TREASURY_ADDR
///   AWP_REGISTRY_ADDR
///   ARDI_WORKNET_ID
///   KYA_WORKNET_ID
///   MIN_STAKE
///   VAULT_MERKLE_ROOT
contract DeployMainnetPhase1 is Script {
    struct Out {
        address mockRandomness;
        address ardiNFT;
        address epochDraw;
    }

    function run() external returns (Out memory out) {
        require(block.chainid == 8453, "DeployMainnetPhase1 expects Base mainnet (8453)");

        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        address owner = vm.envAddress("OWNER_ADDR");
        address coordinator = vm.envAddress("COORDINATOR_ADDR");
        address treasury = vm.envAddress("TREASURY_ADDR");
        address awpRegistry = vm.envAddress("AWP_REGISTRY_ADDR");
        bytes32 vaultRoot = vm.envBytes32("VAULT_MERKLE_ROOT");
        uint256 ardiWnId = vm.envUint("ARDI_WORKNET_ID");
        uint256 kyaWnId = vm.envUint("KYA_WORKNET_ID");
        uint256 minStake = vm.envUint("MIN_STAKE");

        console2.log("Deployer        :", deployer);
        console2.log("Owner           :", owner);
        console2.log("Coordinator     :", coordinator);
        console2.log("Treasury        :", treasury);
        console2.log("AWP Registry    :", awpRegistry);
        console2.log("Ardi WorknetId  :", ardiWnId);
        console2.log("KYA WorknetId   :", kyaWnId);
        console2.log("MinStake (wei)  :", minStake);

        vm.startBroadcast(deployerPk);

        MockRandomness rng = new MockRandomness();
        ArdiNFT nft = new ArdiNFT(owner, coordinator, vaultRoot);
        ArdiEpochDraw epochDraw = new ArdiEpochDraw(
            owner,
            vaultRoot,
            address(rng),
            coordinator,
            treasury,
            awpRegistry,
            ardiWnId,
            kyaWnId,
            minStake
        );
        nft.setEpochDraw(address(epochDraw));

        require(address(nft.epochDraw()) == address(epochDraw), "epochDraw not wired");

        vm.stopBroadcast();

        out = Out({
            mockRandomness: address(rng),
            ardiNFT: address(nft),
            epochDraw: address(epochDraw)
        });

        console2.log("");
        console2.log("===== DEPLOYED on Base mainnet (8453) =====");
        console2.log("MockRandomness :", out.mockRandomness);
        console2.log("ArdiNFT        :", out.ardiNFT);
        console2.log("ArdiEpochDraw  :", out.epochDraw);

        string memory deployJson = string.concat(
            "{\n",
            '  "chainId": 8453,\n',
            '  "network": "base-mainnet",\n',
            '  "deployedAt": ', vm.toString(block.timestamp), ",\n",
            '  "owner": "', vm.toString(owner), '",\n',
            '  "coordinator": "', vm.toString(coordinator), '",\n',
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "mockRandomness": "', vm.toString(out.mockRandomness), '",\n',
            '  "ardiNFT": "', vm.toString(out.ardiNFT), '",\n',
            '  "epochDraw": "', vm.toString(out.epochDraw), '",\n',
            '  "vaultMerkleRoot": "', vm.toString(vaultRoot), '",\n',
            '  "awpRegistry": "', vm.toString(awpRegistry), '",\n',
            '  "ardiWorknetId": ', vm.toString(ardiWnId), ",\n",
            '  "kyaWorknetId": ', vm.toString(kyaWnId), ",\n",
            '  "minStake": "', vm.toString(minStake), '"\n',
            "}\n"
        );
        vm.writeFile("./deployments/base-mainnet.json", deployJson);
    }
}
