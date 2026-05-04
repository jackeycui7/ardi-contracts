// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ArdiNFTv3} from "../src/v3/ArdiNFTv3.sol";
import {EmissionDistributor} from "../src/v3/EmissionDistributor.sol";
import {ArdiEpochDrawV3} from "../src/v3/ArdiEpochDrawV3.sol";
import {ChainlinkVRFAdapter} from "../src/ChainlinkVRFAdapter.sol";

/// @title  DeployV3Mainnet — fresh v3 stack on Base mainnet.
/// @notice Discards smoke-test deploy from 2026-04-30. Deploys:
///         1. ArdiNFTv3 (UUPS proxy + impl)
///         2. EmissionDistributor (UUPS proxy + impl)
///         3. ArdiEpochDrawV3 (UUPS proxy + impl)
///         4. Two ChainlinkVRFAdapter instances (one per consumer)
///         5. Wires everything; transfers ownership to TIMELOCK_ADDR (post-deploy)
///
/// Note: VRF subscription must be created out-of-band on vrf.chain.link and
///       both adapters added as Consumers AFTER this script runs. SUB_ID env
///       points to the subscription. Operator funds it with ETH.
///
/// Required env (from /etc/ardi/mainnet-secrets.env):
///   DEPLOYER_PK                 deployment EOA private key
///   OWNER_ADDR                  initial owner (transferable to Timelock)
///   COORDINATOR_ADDR            server signer for fuse + epoch ops
///   TREASURY_ADDR               receives sink + funds keeper bounty
///   OPERATOR_ADDR               daily-mint cron caller for notifyReward
///   AWP_TOKEN_ADDR              WorknetToken address ($ardi ERC20)
///   AWP_ALLOCATOR_ADDR          AWPAllocator
///   ARDI_WORKNET_ID             845300000012
///   KYA_WORKNET_ID              845300000014
///   MIN_STAKE                   1e22 (10K AWP wei)
///   VAULT_MERKLE_ROOT_V3        new root (binds maxDurability + element)
///   VRF_COORDINATOR_ADDR        Base mainnet VRF Coordinator
///   VRF_KEY_HASH                gas lane key hash
///   VRF_SUB_ID                  Chainlink subscription id (uint256)
contract DeployV3Mainnet is Script {
    struct Out {
        address vrfAdapterEpoch;
        address vrfAdapterNFT;
        address ardiNFT;
        address emissionDist;
        address epochDraw;
    }

    function run() external returns (Out memory out) {
        require(block.chainid == 8453, "DeployV3Mainnet expects Base mainnet (8453)");

        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        address owner = vm.envAddress("OWNER_ADDR");
        address coordinator = vm.envAddress("COORDINATOR_ADDR");
        address treasury = vm.envAddress("TREASURY_ADDR");
        address operator = vm.envAddress("OPERATOR_ADDR");
        address ardiToken = vm.envAddress("AWP_TOKEN_ADDR");
        address allocator = vm.envAddress("AWP_ALLOCATOR_ADDR");
        uint256 ardiWnId = vm.envUint("ARDI_WORKNET_ID");
        uint256 kyaWnId = vm.envUint("KYA_WORKNET_ID");
        uint256 minStake = vm.envUint("MIN_STAKE");
        bytes32 vaultRoot = vm.envBytes32("VAULT_MERKLE_ROOT_V3");
        address vrfCoord = vm.envAddress("VRF_COORDINATOR_ADDR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUB_ID");

        console2.log("Deployer        :", deployer);
        console2.log("Owner           :", owner);
        console2.log("Coordinator     :", coordinator);
        console2.log("Treasury        :", treasury);
        console2.log("Operator        :", operator);
        console2.log("AWP Token       :", ardiToken);
        console2.log("AWP Allocator   :", allocator);
        console2.log("Ardi WorknetId  :", ardiWnId);
        console2.log("KYA WorknetId   :", kyaWnId);
        console2.log("MinStake (wei)  :", minStake);

        vm.startBroadcast(deployerPk);

        // ----- Implementations -----
        ArdiNFTv3 nftImpl = new ArdiNFTv3();
        EmissionDistributor edImpl = new EmissionDistributor();
        ArdiEpochDrawV3 epochImpl = new ArdiEpochDrawV3();

        // ----- Proxies (init data) -----
        // ArdiNFT init
        bytes memory nftInit = abi.encodeCall(
            ArdiNFTv3.initialize, (owner, coordinator, vaultRoot, ardiToken, treasury)
        );
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl), nftInit);

        // EmissionDistributor init
        bytes memory edInit = abi.encodeCall(
            EmissionDistributor.initialize, (owner, ardiToken, operator)
        );
        ERC1967Proxy edProxy = new ERC1967Proxy(address(edImpl), edInit);

        // VRF adapters: deploy with placeholder consumer first, then setConsumer
        // because adapter takes consumer in ctor. We deploy two — one for
        // EpochDraw, one for ArdiNFT — and set consumer right after the
        // corresponding proxy address is known.
        // First deploy EpochDraw proxy (needs adapter address in init).
        ChainlinkVRFAdapter vrfEpoch =
            new ChainlinkVRFAdapter(owner, vrfCoord, keyHash, subId, address(0xdEaD));
        bytes memory epochInit = abi.encodeCall(
            ArdiEpochDrawV3.initialize,
            (
                owner,
                vaultRoot,
                address(vrfEpoch),
                coordinator,
                treasury,
                allocator,
                ardiWnId,
                kyaWnId,
                minStake
            )
        );
        ERC1967Proxy epochProxy = new ERC1967Proxy(address(epochImpl), epochInit);
        vrfEpoch.setConsumer(address(epochProxy));

        // ArdiNFT VRF adapter
        ChainlinkVRFAdapter vrfNFT =
            new ChainlinkVRFAdapter(owner, vrfCoord, keyHash, subId, address(nftProxy));

        // ----- Wiring -----
        ArdiNFTv3 nft = ArdiNFTv3(address(nftProxy));
        EmissionDistributor ed = EmissionDistributor(address(edProxy));
        ArdiEpochDrawV3 epoch = ArdiEpochDrawV3(address(epochProxy));

        nft.setEpochDraw(address(epoch));
        nft.setEmissionDistributor(address(ed));
        nft.setRandomness(address(vrfNFT));
        ed.setArdiNFT(address(nftProxy));

        // Sanity
        require(address(nft.epochDraw()) == address(epoch), "nft.epochDraw not wired");
        require(address(nft.emissionDist()) == address(ed), "nft.ed not wired");
        require(address(nft.randomness()) == address(vrfNFT), "nft.rng not wired");
        require(ed.ardiNFT() == address(nftProxy), "ed.nft not wired");

        // Note: ownership transfer to Timelock is a post-deploy step using
        // owner.transferOwnership(timelock) on each (nft, ed, epoch, vrfEpoch,
        // vrfNFT). Not done here so deployer can fix wiring without timelock
        // delays during launch week.

        vm.stopBroadcast();

        out = Out({
            vrfAdapterEpoch: address(vrfEpoch),
            vrfAdapterNFT: address(vrfNFT),
            ardiNFT: address(nftProxy),
            emissionDist: address(edProxy),
            epochDraw: address(epochProxy)
        });

        console2.log("");
        console2.log("===== V3 DEPLOYED on Base mainnet (8453) =====");
        console2.log("ArdiNFTv3 (proxy)        :", out.ardiNFT);
        console2.log("EmissionDistributor      :", out.emissionDist);
        console2.log("ArdiEpochDrawV3 (proxy)  :", out.epochDraw);
        console2.log("VRFAdapter (Epoch)       :", out.vrfAdapterEpoch);
        console2.log("VRFAdapter (NFT)         :", out.vrfAdapterNFT);
        console2.log("");
        console2.log("Post-deploy steps:");
        console2.log("  1. Add both VRF adapters as Consumers on Chainlink sub", subId);
        console2.log("  2. Treasury must approve ArdiNFTv3 to pull keeper bounty");
        console2.log("  3. Operator must approve EmissionDistributor to pull notifyReward");
        console2.log("  4. AWP setMinter -> OPERATOR_ADDR (off-chain)");
        console2.log("  5. Tune repairBaseUnitPrice via setSinkParams once econ team gives the value");

        string memory deployJson = string.concat(
            "{\n",
            '  "chainId": 8453,\n',
            '  "network": "base-mainnet",\n',
            '  "version": "v3",\n',
            '  "deployedAt": ',
            vm.toString(block.timestamp),
            ",\n",
            '  "owner": "',
            vm.toString(owner),
            '",\n',
            '  "coordinator": "',
            vm.toString(coordinator),
            '",\n',
            '  "treasury": "',
            vm.toString(treasury),
            '",\n',
            '  "operator": "',
            vm.toString(operator),
            '",\n',
            '  "ardiNFTv3": "',
            vm.toString(out.ardiNFT),
            '",\n',
            '  "emissionDistributor": "',
            vm.toString(out.emissionDist),
            '",\n',
            '  "epochDrawV3": "',
            vm.toString(out.epochDraw),
            '",\n',
            '  "vrfAdapterEpoch": "',
            vm.toString(out.vrfAdapterEpoch),
            '",\n',
            '  "vrfAdapterNFT": "',
            vm.toString(out.vrfAdapterNFT),
            '",\n',
            '  "vaultMerkleRootV3": "',
            vm.toString(vaultRoot),
            '",\n',
            '  "awpAllocator": "',
            vm.toString(allocator),
            '",\n',
            '  "ardiWorknetId": ',
            vm.toString(ardiWnId),
            ",\n",
            '  "kyaWorknetId": ',
            vm.toString(kyaWnId),
            ",\n",
            '  "minStake": "',
            vm.toString(minStake),
            '"\n',
            "}\n"
        );
        vm.writeFile("./deployments/base-mainnet-v3.json", deployJson);
    }
}
