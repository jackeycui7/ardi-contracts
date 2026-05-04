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

/// @title Testnet deployment — Base Sepolia (chainId 84532)
/// @notice v2 dropped ArdiBondEscrow + IKYA. Eligibility is read live from
///         AWPRegistry.getAgentInfo. On Sepolia we still deploy a
///         MockAWPRegistry so testers can manually grant stake to agents
///         without going through the AWP rootnet flow. On mainnet, point
///         AWP_REGISTRY_ADDR at the real AWPRegistry deployment.
///
/// Required env:
///   DEPLOYER_PK
///   COORDINATOR_PK     (defaults to DEPLOYER_PK)
///   TREASURY_ADDR      (defaults to deployer)
///   OWNER_OPS_ADDR     (defaults to deployer)
///   GENESIS_TS         (defaults to block.timestamp)
///   ARDI_WN_ID         (default 845300000012)
///   KYA_WN_ID          (default 845300000014)
///   MIN_STAKE          (default 10_000e18)
///   AWP_REGISTRY_ADDR  (optional; if set, skips MockAWPRegistry deploy)
contract DeployTestnet is Script {
    struct Addrs {
        address mockAWP;
        address awpRegistry;
        address ardiToken;
        address ardiNFT;
        address otc;
        address mintController;
        address epochDraw;
        address mockRandomness;
    }

    function run() external returns (Addrs memory out) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);

        uint256 coordinatorPk = vm.envOr("COORDINATOR_PK", deployerPk);
        address coordinator = vm.addr(coordinatorPk);

        address owner = deployer;
        address lpEscrow = vm.envOr("LP_ESCROW_ADDR", deployer);
        address treasury = vm.envOr("TREASURY_ADDR", deployer);
        address ownerOpsAddr = vm.envOr("OWNER_OPS_ADDR", deployer);
        uint256 genesisTs = vm.envOr("GENESIS_TS", block.timestamp);

        uint256 ardiWnId = vm.envOr("ARDI_WN_ID", uint256(845300000012));
        uint256 kyaWnId = vm.envOr("KYA_WN_ID", uint256(845300000014));
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(10_000 ether));

        require(block.chainid == 84532, "DeployTestnet expects Base Sepolia (84532)");

        console2.log("Deployer       :", deployer);
        console2.log("Coordinator    :", coordinator);
        console2.log("Treasury       :", treasury);
        console2.log("Ardi WN ID     :", ardiWnId);
        console2.log("KYA WN ID      :", kyaWnId);
        console2.log("MinStake (wei) :", minStake);

        vm.startBroadcast(deployerPk);

        // 1. Mock AWP token. Real Sepolia AWP isn't yet live.
        MockAWP awp = new MockAWP();

        // 2. AWPRegistry — use real address if env says so, else deploy a
        //    Mock and let testers manually grant stake.
        address awpRegistryAddr = vm.envOr("AWP_REGISTRY_ADDR", address(0));
        if (awpRegistryAddr == address(0)) {
            awpRegistryAddr = address(new MockAWPRegistry());
            console2.log("Using MockAWPRegistry");
        } else {
            console2.log("Using real AWPRegistry @", awpRegistryAddr);
        }

        // 3. Vault Merkle root.
        bytes32 vaultRoot = bytes32(
            vm.envOr(
                "VAULT_ROOT",
                uint256(0x135744267bf3b8c5cc4f998f5bac489c3cffcedfb888931e8defb0ea80a10c28)
            )
        );

        // 4. Core contracts.
        ArdiToken token = new ArdiToken(owner);
        ArdiNFT nft = new ArdiNFT(owner, coordinator, vaultRoot);
        ArdiOTC otc = new ArdiOTC(owner, address(nft));
        ArdiMintController ctrl = new ArdiMintController(
            owner, address(token), address(awp), coordinator, ownerOpsAddr, genesisTs
        );

        // 5. EpochDraw + Mock VRF. New 9-arg constructor wires AWP eligibility.
        MockRandomness rng = new MockRandomness();
        ArdiEpochDraw epochDraw = new ArdiEpochDraw(
            owner,
            vaultRoot,
            address(rng),
            coordinator,
            treasury,
            awpRegistryAddr,
            ardiWnId,
            kyaWnId,
            minStake
        );

        // 6. Wire NFT → EpochDraw.
        nft.setEpochDraw(address(epochDraw));

        // 7. Initial LP + minter lock.
        token.mintLp(lpEscrow, 1_000_000_000 ether);
        token.setMinter(address(ctrl));
        token.lockMinter();

        // 8. Invariants.
        require(address(nft.epochDraw()) == address(epochDraw), "nft epochDraw not wired");
        require(ctrl.coordinator() == coordinator, "coordinator mismatch");
        require(token.minterLocked(), "minter not locked");

        vm.stopBroadcast();

        out = Addrs({
            mockAWP: address(awp),
            awpRegistry: awpRegistryAddr,
            ardiToken: address(token),
            ardiNFT: address(nft),
            otc: address(otc),
            mintController: address(ctrl),
            epochDraw: address(epochDraw),
            mockRandomness: address(rng)
        });

        console2.log("");
        console2.log("===== DEPLOYED on Base Sepolia (84532) =====");
        console2.log("MockAWP         :", out.mockAWP);
        console2.log("AWPRegistry     :", out.awpRegistry);
        console2.log("ArdiToken       :", out.ardiToken);
        console2.log("ArdiNFT         :", out.ardiNFT);
        console2.log("ArdiOTC         :", out.otc);
        console2.log("ArdiMintCtrl    :", out.mintController);
        console2.log("ArdiEpochDraw   :", out.epochDraw);
        console2.log("MockRandomness  :", out.mockRandomness);

        string memory deployJson = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "network": "base-sepolia",\n',
            '  "deployedAt": ', vm.toString(block.timestamp), ",\n",
            '  "genesisTs": ', vm.toString(genesisTs), ",\n",
            '  "owner": "', vm.toString(owner), '",\n',
            '  "coordinator": "', vm.toString(coordinator), '",\n',
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "ownerOpsAddr": "', vm.toString(ownerOpsAddr), '",\n',
            '  "mockAWP": "', vm.toString(out.mockAWP), '",\n',
            '  "awpRegistry": "', vm.toString(out.awpRegistry), '",\n',
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
        vm.writeFile("./deployments/base-sepolia.json", deployJson);
    }
}
