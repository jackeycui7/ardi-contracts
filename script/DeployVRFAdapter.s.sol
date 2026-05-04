// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChainlinkVRFAdapter} from "../src/ChainlinkVRFAdapter.sol";

/// @title Deploy ChainlinkVRFAdapter and wire it to ArdiEpochDraw.
/// @notice Run AFTER the main DeployTestnet / Deploy script has already
///         deployed ArdiEpochDraw + the rest of the stack with
///         MockRandomness as the initial randomness source.
///
/// What this script does:
///   1. Reads the deployed ArdiEpochDraw address from `EPOCH_DRAW_ADDR`.
///   2. Deploys a ChainlinkVRFAdapter pointing at the chain's VRF v2.5
///      Coordinator + the configured key hash + an existing Subscription
///      ID (which the operator must create + fund manually beforehand).
///   3. Adds the adapter as a Consumer on the Subscription requires a
///      separate VRF Coordinator UI / cast call by the operator —
///      this script can't do that step.
///   4. Calls `epochDraw.setRandomnessSource(adapter)` to swap from
///      MockRandomness to the live adapter.
///
/// REQUIRED env:
///   DEPLOYER_PK            — broadcasts (also EpochDraw owner if owner key)
///   EPOCH_DRAW_ADDR        — deployed ArdiEpochDraw address
///   VRF_COORDINATOR        — VRF v2.5 Coordinator address on the target chain
///   VRF_KEY_HASH           — gas lane key hash (chain-specific, see Chainlink docs)
///   VRF_SUB_ID             — Subscription ID (uint256). Must be created and
///                            funded with LINK or native ETH BEFORE running this.
///
/// OPTIONAL env:
///   VRF_REQUEST_CONFIRMATIONS — defaults to 3 (Chainlink minimum on Base)
///   VRF_CALLBACK_GAS_LIMIT     — defaults to 200_000
///
/// Reference VRF v2.5 deployments at the time of writing:
///   Base mainnet  — Coordinator 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
///                   200 gwei keyHash 0x0000...  (see docs.chain.link)
///   Base Sepolia  — Coordinator 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE
///                   200 gwei keyHash 0x9e9e46732b32662b9adc6f3abdf6c5e926a666f174a82d0b0e30dd8b7d30bbe6
///
/// VERIFY these against current Chainlink docs before running on mainnet —
/// VRF deployments do migrate.
///
/// Manual operator steps surrounding this script:
///   (a) Visit https://vrf.chain.link, connect wallet, create new
///       Subscription, fund with at least ~5 LINK (or equivalent ETH for
///       native-payment mode).
///   (b) Set VRF_SUB_ID to the new subscription ID and run this script.
///   (c) Visit the Subscription page again and "Add consumer" — paste
///       the adapter address printed by this script.
///   (d) Test: trigger a `requestDraw` on ArdiEpochDraw with at least one
///       correct revealer in correctList; verify that within ~30s the
///       VRF callback lands and `WinnerSelected` fires.
contract DeployVRFAdapter is Script {
    function run() external returns (address adapterAddr) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address epochDraw = vm.envAddress("EPOCH_DRAW_ADDR");
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUB_ID");

        uint16 confirmations = uint16(vm.envOr("VRF_REQUEST_CONFIRMATIONS", uint256(3)));
        uint32 callbackGas = uint32(vm.envOr("VRF_CALLBACK_GAS_LIMIT", uint256(200_000)));

        console2.log("Deployer        :", vm.addr(deployerPk));
        console2.log("EpochDraw       :", epochDraw);
        console2.log("VRF Coordinator :", coordinator);
        console2.log("Sub ID          :", subId);
        console2.log("Confirmations   :", confirmations);
        console2.log("Callback gas    :", callbackGas);

        vm.startBroadcast(deployerPk);

        // 1. Deploy adapter.
        ChainlinkVRFAdapter adapter = new ChainlinkVRFAdapter(
            vm.addr(deployerPk),
            coordinator,
            keyHash,
            subId,
            epochDraw
        );
        adapter.setConfig(keyHash, subId, confirmations, callbackGas);

        // 2. Wire it on EpochDraw. Owner-only on EpochDraw; deployer is
        //    expected to be the same key. If you've handed ownership off
        //    to a multisig already, run `setRandomnessSource` from the
        //    multisig instead and skip the call below.
        bytes memory setSourceData = abi.encodeWithSignature(
            "setRandomnessSource(address)", address(adapter)
        );
        (bool ok, bytes memory ret) = epochDraw.call(setSourceData);
        if (!ok) {
            console2.log("WARN: setRandomnessSource failed; revert =");
            console2.logBytes(ret);
            console2.log("Re-run setRandomnessSource manually from the EpochDraw owner.");
        } else {
            console2.log("setRandomnessSource OK");
        }

        vm.stopBroadcast();

        adapterAddr = address(adapter);
        console2.log("");
        console2.log("=== ChainlinkVRFAdapter deployed ===");
        console2.log("Adapter:", adapterAddr);
        console2.log("");
        console2.log(unicode"⚠ Manual step left:");
        console2.log("  Add this adapter as a Consumer on the Subscription via");
        console2.log(unicode"  https://vrf.chain.link -> your subscription -> Add consumer");
    }
}
