// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArdiToken} from "../src/ArdiToken.sol";
import {MockRandomness} from "../src/MockRandomness.sol";
import {EmbeddingStore} from "../src/v4/EmbeddingStore.sol";
import {ArdiNFTv4Testnet} from "../src/v4/ArdiNFTv4Testnet.sol";

/// @notice Fresh Sepolia deploy of the forge stack:
///         MockArdi token + MockRandomness + EmbeddingStore + ArdiNFTv4Testnet.
///         Deployer becomes owner / treasury / oracle for simplicity.
///
/// Usage:
///   forge script script/DeployForgeTestnet.s.sol:DeployForgeTestnet \
///     --rpc-url https://sepolia.base.org --broadcast --private-key $PK
contract DeployForgeTestnet is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // 1. Mock aARDI token (ArdiToken is mintable, owner == deployer).
        ArdiToken ardi = new ArdiToken(deployer);

        // 2. MockRandomness (synchronous for testnet smoke).
        MockRandomness rand = new MockRandomness();

        // 3. EmbeddingStore (deployer-owned; we'll seal after upload).
        EmbeddingStore store = new EmbeddingStore(deployer);

        // 4. ArdiNFTv4Testnet behind UUPS proxy.
        ArdiNFTv4Testnet impl = new ArdiNFTv4Testnet();
        bytes memory initData = abi.encodeCall(
            ArdiNFTv4Testnet.initialize,
            (deployer, address(ardi), deployer, deployer)  // owner, ardi, treasury, oracle
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ArdiNFTv4Testnet nft = ArdiNFTv4Testnet(address(proxy));

        // 5. Wire it up.
        nft.setRandomness(address(rand));
        // EmbeddingStore set later, after we upload + seal.

        // 6. Set deployer as minter and mint plenty of test tAARDI for forge fees.
        ardi.setMinter(deployer);
        ardi.mint(deployer, 100_000_000 ether);

        vm.stopBroadcast();

        console.log("=== Forge Testnet Deploy ===");
        console.log("ArdiToken (test aARDI)", address(ardi));
        console.log("MockRandomness", address(rand));
        console.log("EmbeddingStore", address(store));
        console.log("ArdiNFTv4 impl", address(impl));
        console.log("ArdiNFTv4 proxy", address(proxy));
        console.log("Deployer/owner/oracle/treasury", deployer);
    }
}
