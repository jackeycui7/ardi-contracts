// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArdiToken} from "../src/ArdiToken.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";
import {ArdiMintController} from "../src/ArdiMintController.sol";
import {ArdiEpochDraw} from "../src/ArdiEpochDraw.sol";

/// @notice Mainnet deployment script.
/// @dev    Required env:
///           OWNER_ADDR         — Owner / DEFAULT_ADMIN_ROLE (multisig+Timelock)
///           COORDINATOR_ADDR   — off-chain Coordinator EOA
///           AWP_TOKEN_ADDR     — $AWP ERC-20 on the target chain
///           AWP_REGISTRY_ADDR  — AWPRegistry on the target chain (provides
///                                 getAgentInfo for eligibility)
///           VAULT_MERKLE_ROOT  — bytes32 Merkle root of the 21,000 vault entries
///           LP_ESCROW_ADDR     — destination for the 1B initial $aArdi LP mint
///           TREASURY_ADDR      — destination for forfeited COMMIT_BONDs +
///                                 protocol fees. MUST be a multisig / treasury.
///           OWNER_OPS_ADDR     — single EOA receiving the AWP ops cut from
///                                 MintController (10% by default).
///           RANDOMNESS_ADDR    — IRandomnessSource. On mainnet MUST be a
///                                 ChainlinkVRFAdapter pointing at the chain's
///                                 official VRF Coordinator. Operator deploys +
///                                 funds the subscription separately.
///           ARDI_WORKNET_ID    — Ardi's WorkNet ID (chainId * 1e8 + localId)
///           KYA_WORKNET_ID     — KYA WorkNet ID (alternate eligibility path)
///           MIN_STAKE          — minimum AWP allocation in wei (default 10_000e18)
///           GENESIS_TS         — unix timestamp marking day 1 of emission
///
///         v2 dropped ArdiBondEscrow + IKYA. Eligibility is a real-time
///         AWPRegistry.getAgentInfo read at commit() time. No bond escrow,
///         no slash mechanism — agents who de-allocate simply can't commit
///         on new wordIds.
contract Deploy is Script {
    error InvalidTreasury();

    struct Addrs {
        address ardiToken;
        address ardiNFT;
        address otc;
        address mintController;
        address epochDraw;
    }

    function run() external returns (Addrs memory out) {
        address owner = vm.envAddress("OWNER_ADDR");
        address coordinator = vm.envAddress("COORDINATOR_ADDR");
        address awp = vm.envAddress("AWP_TOKEN_ADDR");
        address awpRegistry = vm.envAddress("AWP_REGISTRY_ADDR");
        bytes32 vaultRoot = vm.envBytes32("VAULT_MERKLE_ROOT");
        address lpEscrow = vm.envAddress("LP_ESCROW_ADDR");
        address treasury = vm.envAddress("TREASURY_ADDR");
        address randomness = vm.envAddress("RANDOMNESS_ADDR");
        address ownerOpsAddr = vm.envAddress("OWNER_OPS_ADDR");
        uint256 ardiWnId = vm.envUint("ARDI_WORKNET_ID");
        uint256 kyaWnId = vm.envUint("KYA_WORKNET_ID");
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(10_000 ether));
        uint256 genesisTs = vm.envUint("GENESIS_TS");

        if (treasury == address(0)) revert InvalidTreasury();

        vm.startBroadcast();

        ArdiToken token = new ArdiToken(owner);
        ArdiNFT nft = new ArdiNFT(owner, coordinator, vaultRoot);
        ArdiOTC otc = new ArdiOTC(owner, address(nft));
        ArdiMintController ctrl = new ArdiMintController(
            owner, address(token), awp, coordinator, ownerOpsAddr, genesisTs
        );
        ArdiEpochDraw epochDraw = new ArdiEpochDraw(
            owner,
            vaultRoot,
            randomness,
            coordinator,
            treasury,
            awpRegistry,
            ardiWnId,
            kyaWnId,
            minStake
        );

        nft.setEpochDraw(address(epochDraw));
        token.mintLp(lpEscrow, 1_000_000_000 ether);
        token.setMinter(address(ctrl));
        token.lockMinter();

        require(address(nft.epochDraw()) == address(epochDraw), "epochDraw not wired");
        require(ctrl.ownerOpsAddr() == ownerOpsAddr, "ownerOpsAddr mismatch");
        require(ctrl.coordinator() == coordinator, "coordinator mismatch");

        vm.stopBroadcast();

        out = Addrs({
            ardiToken: address(token),
            ardiNFT: address(nft),
            otc: address(otc),
            mintController: address(ctrl),
            epochDraw: address(epochDraw)
        });

        console2.log("ArdiToken         :", out.ardiToken);
        console2.log("ArdiNFT           :", out.ardiNFT);
        console2.log("ArdiOTC           :", out.otc);
        console2.log("ArdiMintController:", out.mintController);
        console2.log("ArdiEpochDraw     :", out.epochDraw);
    }
}
