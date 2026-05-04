// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ArdiNFTv3} from "../src/v3/ArdiNFTv3.sol";
import {EmissionDistributor} from "../src/v3/EmissionDistributor.sol";
import {ArdiEpochDrawV3} from "../src/v3/ArdiEpochDrawV3.sol";
import {MockRandomness} from "../src/MockRandomness.sol";

/// Test-only $ardi ERC20 + AWP allocator mock that the v3 stack reads from.
/// MockAWPAllocator stake is settable; testers can grant any agent any amount
/// without going through the AWP rootnet flow.
contract MockArdiToken is ERC20 {
    constructor() ERC20("Test Ardi", "tARDI") {
        _mint(msg.sender, 100_000_000_000 ether); // plenty for testing
    }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockAWPAllocator {
    mapping(bytes32 => uint256) public _s;
    address public owner;
    constructor() { owner = msg.sender; }
    function set(address staker, address agent, uint256 worknetId, uint256 amount) external {
        require(msg.sender == owner, "only owner");
        _s[keccak256(abi.encode(staker, agent, worknetId))] = amount;
    }
    function getAgentStake(address staker, address agent, uint256 worknetId)
        external view returns (uint256) {
        return _s[keccak256(abi.encode(staker, agent, worknetId))];
    }
}

/// @title  Deploy V3 to Base Sepolia (chainId 84532) for dry-run.
/// @notice Uses MockRandomness (instant fulfil via fulfill(reqId)) and
///         MockAWPAllocator (testers grant stake). Deploys MockArdiToken
///         as the $ardi ERC20 (stand-in for AWP WorknetToken).
///         Deploys with a placeholder vault root (bytes32(0)); openEpoch is
///         gated until owner calls setVaultMerkleRoot — same flow as mainnet.
///
/// Required env:
///   DEPLOYER_PK        Sepolia EOA private key (with testnet ETH)
///   COORDINATOR_ADDR   defaults to deployer
///   TREASURY_ADDR      defaults to deployer
///   OPERATOR_ADDR      defaults to deployer
///   VAULT_MERKLE_ROOT_V3   optional; if set, locks at deploy. Else bytes32(0).
contract DeployV3Testnet is Script {
    struct Out {
        address mockArdi;
        address mockAllocator;
        address mockRandomness;
        address ardiNFT;
        address emissionDist;
        address epochDraw;
    }

    function run() external returns (Out memory out) {
        require(block.chainid == 84532, "DeployV3Testnet expects Base Sepolia (84532)");

        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        address coordinator = vm.envOr("COORDINATOR_ADDR", deployer);
        address treasury = vm.envOr("TREASURY_ADDR", deployer);
        address operator = vm.envOr("OPERATOR_ADDR", deployer);
        bytes32 vaultRoot = vm.envOr("VAULT_MERKLE_ROOT_V3", bytes32(0));
        uint256 ardiWnId = vm.envOr("ARDI_WORKNET_ID", uint256(845300000012));
        uint256 kyaWnId = vm.envOr("KYA_WORKNET_ID", uint256(845300000014));
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(10_000 ether));

        console2.log("Deployer        :", deployer);
        console2.log("Coordinator     :", coordinator);
        console2.log("Treasury        :", treasury);
        console2.log("Operator        :", operator);
        console2.log("VaultRoot (init):", vm.toString(vaultRoot));

        vm.startBroadcast(deployerPk);

        // Mocks
        MockArdiToken ardi = new MockArdiToken();
        MockAWPAllocator allocator = new MockAWPAllocator();
        MockRandomness rng = new MockRandomness();

        // Implementations
        ArdiNFTv3 nftImpl = new ArdiNFTv3();
        EmissionDistributor edImpl = new EmissionDistributor();
        ArdiEpochDrawV3 epochImpl = new ArdiEpochDrawV3();

        // Proxies
        bytes memory nftInit = abi.encodeCall(
            ArdiNFTv3.initialize, (deployer, coordinator, vaultRoot, address(ardi), treasury)
        );
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl), nftInit);

        bytes memory edInit = abi.encodeCall(
            EmissionDistributor.initialize, (deployer, address(ardi), operator)
        );
        ERC1967Proxy edProxy = new ERC1967Proxy(address(edImpl), edInit);

        bytes memory epochInit = abi.encodeCall(
            ArdiEpochDrawV3.initialize,
            (
                deployer, vaultRoot, address(rng), coordinator, treasury,
                address(allocator), ardiWnId, kyaWnId, minStake
            )
        );
        ERC1967Proxy epochProxy = new ERC1967Proxy(address(epochImpl), epochInit);

        // Wiring
        ArdiNFTv3 nft = ArdiNFTv3(address(nftProxy));
        EmissionDistributor ed = EmissionDistributor(address(edProxy));
        ArdiEpochDrawV3 epoch = ArdiEpochDrawV3(address(epochProxy));

        nft.setEpochDraw(address(epoch));
        nft.setEmissionDistributor(address(ed));
        nft.setRandomness(address(rng));
        ed.setArdiNFT(address(nftProxy));

        // Convenience for dry-run: pre-fund treasury with $ardi for keeper
        // bounty payouts, fund operator for notifyReward, and approve from
        // both. NOT done on mainnet (operational opsec: treasury PK should be
        // a multisig; operator should be a separate cron addr).
        ardi.transfer(treasury, 10_000_000 ether);
        ardi.transfer(operator, 10_000_000 ether);

        vm.stopBroadcast();

        // From treasury / operator: approve. Skip if deployer != these (set up
        // separately). When deployer IS treasury+operator (default), do both.
        if (treasury == deployer && operator == deployer) {
            vm.startBroadcast(deployerPk);
            ardi.approve(address(nft), type(uint256).max);   // treasury → NFT (keeper bounty)
            ardi.approve(address(ed), type(uint256).max);    // operator → ED (notifyReward)
            vm.stopBroadcast();
        }

        out = Out({
            mockArdi: address(ardi),
            mockAllocator: address(allocator),
            mockRandomness: address(rng),
            ardiNFT: address(nftProxy),
            emissionDist: address(edProxy),
            epochDraw: address(epochProxy)
        });

        console2.log("");
        console2.log("===== V3 DEPLOYED on Base Sepolia (84532) =====");
        console2.log("MockArdi (tARDI)         :", out.mockArdi);
        console2.log("MockAWPAllocator         :", out.mockAllocator);
        console2.log("MockRandomness           :", out.mockRandomness);
        console2.log("ArdiNFTv3 (proxy)        :", out.ardiNFT);
        console2.log("EmissionDistributor      :", out.emissionDist);
        console2.log("ArdiEpochDrawV3 (proxy)  :", out.epochDraw);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. allocator.set(agent, agent, 845300000012, 10_000e18)  // grant stake");
        console2.log("  2. epoch.setVaultMerkleRoot(realRoot)                    // unblock openEpoch");
        console2.log("  3. coord.openEpoch(...)                                  // start mining");

        _writeDeployJson(out, deployer, coordinator, treasury, operator, vaultRoot, ardiWnId, kyaWnId, minStake);
    }

    function _writeDeployJson(
        Out memory out,
        address deployer,
        address coordinator,
        address treasury,
        address operator,
        bytes32 vaultRoot,
        uint256 ardiWnId,
        uint256 kyaWnId,
        uint256 minStake
    ) internal {
        string memory part1 = string.concat(
            "{\n",
            '  "chainId": 84532,\n',
            '  "network": "base-sepolia",\n',
            '  "version": "v3",\n',
            '  "deployedAt": ', vm.toString(block.timestamp), ",\n",
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "coordinator": "', vm.toString(coordinator), '",\n',
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "operator": "', vm.toString(operator), '",\n'
        );
        string memory part2 = string.concat(
            '  "mockArdi": "', vm.toString(out.mockArdi), '",\n',
            '  "mockAllocator": "', vm.toString(out.mockAllocator), '",\n',
            '  "mockRandomness": "', vm.toString(out.mockRandomness), '",\n',
            '  "ardiNFTv3": "', vm.toString(out.ardiNFT), '",\n',
            '  "emissionDistributor": "', vm.toString(out.emissionDist), '",\n',
            '  "epochDrawV3": "', vm.toString(out.epochDraw), '",\n'
        );
        string memory part3 = string.concat(
            '  "vaultMerkleRootV3": "', vm.toString(vaultRoot), '",\n',
            '  "ardiWorknetId": ', vm.toString(ardiWnId), ",\n",
            '  "kyaWorknetId": ', vm.toString(kyaWnId), ",\n",
            '  "minStake": "', vm.toString(minStake), '"\n',
            "}\n"
        );
        vm.writeFile("./deployments/base-sepolia-v3.json", string.concat(part1, part2, part3));
    }
}
