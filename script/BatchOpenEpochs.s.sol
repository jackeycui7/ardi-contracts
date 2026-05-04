// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IEpochDraw {
    function openEpoch(uint256 epochId, uint64 commitWindow, uint64 revealWindow) external;
    function epochs(uint256) external view returns (uint64, uint64, uint64, bool);
    function coordinator() external view returns (address);
}

/// @notice Launch-week batch epoch opener. Opens N consecutive epochs in one
/// tx-batch so the first wave of riddles is queued without coord-rs needing
/// to be running. Useful as a kickstart on launch day.
///
/// Required env:
///   COORDINATOR_PK    coordinator wallet (NOT deployer) — only it can openEpoch
///   EPOCH_PROXY_ADDR  ArdiEpochDrawV3 proxy
///   FIRST_EPOCH_ID    first epochId (e.g. 1 for fresh deploy, or last+1)
///   EPOCH_COUNT       how many to open (default 5)
///   COMMIT_WINDOW     seconds (default 180 — matches mainnet.toml.template)
///   REVEAL_WINDOW     seconds (default 180)
///
/// Run:
///   COORDINATOR_PK=0x... EPOCH_PROXY_ADDR=0x... FIRST_EPOCH_ID=1 EPOCH_COUNT=5 \
///     forge script script/BatchOpenEpochs.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast
contract BatchOpenEpochs is Script {
    function run() external {
        uint256 pk = vm.envUint("COORDINATOR_PK");
        address proxy = vm.envAddress("EPOCH_PROXY_ADDR");
        uint256 first = vm.envUint("FIRST_EPOCH_ID");
        uint256 count = vm.envOr("EPOCH_COUNT", uint256(5));
        uint64 commitWindow = uint64(vm.envOr("COMMIT_WINDOW", uint256(180)));
        uint64 revealWindow = uint64(vm.envOr("REVEAL_WINDOW", uint256(180)));

        require(count > 0 && count <= 100, "EPOCH_COUNT must be 1..100");
        IEpochDraw ep = IEpochDraw(proxy);
        address coord = ep.coordinator();
        console2.log("coordinator on chain :", coord);
        console2.log("opening epochs       :", first, "..", first + count - 1);
        console2.log("commit/reveal window :", commitWindow, "/", revealWindow);

        // Pre-flight: confirm none of the target epochs already exist.
        for (uint256 i = 0; i < count; i++) {
            (,,, bool exists) = ep.epochs(first + i);
            require(!exists, "an epoch in the requested range already exists");
        }

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < count; i++) {
            ep.openEpoch(first + i, commitWindow, revealWindow);
        }
        vm.stopBroadcast();

        // Post-flight verify
        for (uint256 i = 0; i < count; i++) {
            (uint64 startTs, uint64 cd, uint64 rd, bool exists) = ep.epochs(first + i);
            console2.log("opened epoch", first + i);
            console2.log("  start    :", startTs);
            console2.log("  cd / rd  :", cd, rd);
            require(exists, "epoch not opened?!");
        }
        console2.log("done. opened", count, "epochs.");
    }
}
