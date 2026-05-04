// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiToken} from "../src/ArdiToken.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";
import {ArdiMintController} from "../src/ArdiMintController.sol";
import {ArdiEpochDraw} from "../src/ArdiEpochDraw.sol";
import {MockRandomness} from "../src/MockRandomness.sol";
import {MockAWP, MockAWPRegistry} from "../test/Mocks.sol";

/// @title Local deployment script.
/// @notice For Anvil + integration testing. v2 dropped ArdiBondEscrow — eligibility
///         is now a real-time read against AWPRegistry.getAgentInfo. We deploy a
///         MockAWPRegistry stub that lets tests programmatically set
///         (agent, worknetId) → (isValid, stake).
///
/// Env (all optional with sensible defaults):
///   DEPLOYER_PK       — broadcast key. Default = anvil acct #0.
///   COORDINATOR_PK    — coord signer. Default = 0x22..22.
///   TREASURY_ADDR     — treasury / fee sink. Default = deployer.
///   OWNER_OPS_ADDR    — receives AWP ops cut. Default = deployer.
///   GENESIS_TS        — controller genesis. Default = now.
///   ARDI_WN_ID        — Ardi WorkNet ID. Default = 845300000012.
///   KYA_WN_ID         — KYA WorkNet ID.  Default = 845300000014.
///   MIN_STAKE         — eligibility threshold (wei units). Default = 10_000e18.
///   VAULT_ROOT        — vault Merkle root. Default placeholder; e2e injects real.
contract DeployLocal is Script {
    struct Addrs {
        address mockAWP;
        address mockAWPRegistry;
        address ardiToken;
        address ardiNFT;
        address otc;
        address mintController;
        address epochDraw;
        address mockRandomness;
    }

    function run() external returns (Addrs memory out) {
        uint256 deployerPk =
            vm.envOr("DEPLOYER_PK", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPk);
        uint256 coordinatorPk =
            vm.envOr("COORDINATOR_PK", uint256(0x2222222222222222222222222222222222222222222222222222222222222222));
        address coordinator = vm.addr(coordinatorPk);

        address owner = deployer;
        address lpEscrow = vm.envOr("LP_ESCROW_ADDR", deployer);
        address treasury = vm.envOr("TREASURY_ADDR", deployer);
        address ownerOpsAddr = vm.envOr("OWNER_OPS_ADDR", deployer);
        uint256 genesisTs = vm.envOr("GENESIS_TS", block.timestamp);

        uint256 ardiWnId = vm.envOr("ARDI_WN_ID", uint256(845300000012));
        uint256 kyaWnId = vm.envOr("KYA_WN_ID", uint256(845300000014));
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(10_000 ether));

        console2.log("Deployer        :", deployer);
        console2.log("Coordinator     :", coordinator);
        console2.log("Treasury        :", treasury);
        console2.log("Ardi WN ID      :", ardiWnId);
        console2.log("KYA WN ID       :", kyaWnId);
        console2.log("MinStake (wei)  :", minStake);

        vm.startBroadcast(deployerPk);

        // 1. Mock AWP token + Mock AWPRegistry for local testing.
        MockAWP awp = new MockAWP();
        MockAWPRegistry awpRegistry = new MockAWPRegistry();

        // 2. Vault Merkle root (override via VAULT_ROOT env).
        bytes32 vaultRoot = bytes32(
            vm.envOr(
                "VAULT_ROOT",
                uint256(0x4c52cbe743bcefd09feb473c96a0a0fc705e16c7ae320e028cd2589a71848590)
            )
        );

        // 3. Core contracts.
        ArdiToken token = new ArdiToken(owner);
        ArdiNFT nft = new ArdiNFT(owner, coordinator, vaultRoot);
        ArdiOTC otc = new ArdiOTC(owner, address(nft));
        ArdiMintController ctrl = new ArdiMintController(
            owner,
            address(token),
            address(awp),
            coordinator,
            ownerOpsAddr,
            genesisTs
        );

        // 4. EpochDraw + Mock VRF. New constructor wires AWP eligibility.
        MockRandomness rng = new MockRandomness();
        ArdiEpochDraw epochDraw = new ArdiEpochDraw(
            owner,
            vaultRoot,
            address(rng),
            coordinator,
            treasury,
            address(awpRegistry),
            ardiWnId,
            kyaWnId,
            minStake
        );

        // 5. Wire NFT → EpochDraw.
        nft.setEpochDraw(address(epochDraw));

        // 6. LP one-shot mint + lock minter.
        token.mintLp(lpEscrow, 1_000_000_000 ether);
        token.setMinter(address(ctrl));
        token.lockMinter();

        require(address(nft.epochDraw()) == address(epochDraw), "nft epochDraw not wired");
        require(ctrl.coordinator() == coordinator, "coordinator mismatch");

        vm.stopBroadcast();

        out = Addrs({
            mockAWP: address(awp),
            mockAWPRegistry: address(awpRegistry),
            ardiToken: address(token),
            ardiNFT: address(nft),
            otc: address(otc),
            mintController: address(ctrl),
            epochDraw: address(epochDraw),
            mockRandomness: address(rng)
        });

        console2.log("");
        console2.log("===== DEPLOYED =====");
        console2.log("MockAWP          :", out.mockAWP);
        console2.log("MockAWPRegistry  :", out.mockAWPRegistry);
        console2.log("ArdiToken        :", out.ardiToken);
        console2.log("ArdiNFT          :", out.ardiNFT);
        console2.log("ArdiOTC          :", out.otc);
        console2.log("ArdiMintCtrl     :", out.mintController);
        console2.log("ArdiEpochDraw    :", out.epochDraw);
        console2.log("MockRandomness   :", out.mockRandomness);

        string memory deployJson = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "owner": "', vm.toString(owner), '",\n',
            '  "coordinator": "', vm.toString(coordinator), '",\n',
            '  "mockAWP": "', vm.toString(out.mockAWP), '",\n',
            '  "mockAWPRegistry": "', vm.toString(out.mockAWPRegistry), '",\n',
            '  "ardiToken": "', vm.toString(out.ardiToken), '",\n',
            '  "ardiNFT": "', vm.toString(out.ardiNFT), '",\n',
            '  "otc": "', vm.toString(out.otc), '",\n',
            '  "mintController": "', vm.toString(out.mintController), '",\n',
            '  "epochDraw": "', vm.toString(out.epochDraw), '",\n',
            '  "mockRandomness": "', vm.toString(out.mockRandomness), '",\n',
            '  "vaultMerkleRoot": "', vm.toString(vaultRoot), '",\n',
            '  "ardiWorknetId": ', vm.toString(ardiWnId), ",\n",
            '  "kyaWorknetId": ', vm.toString(kyaWnId), ",\n",
            '  "minStake": "', vm.toString(minStake), '"\n',
            "}\n"
        );
        vm.writeFile("./deployments/local.json", deployJson);
    }
}
