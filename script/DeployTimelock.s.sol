// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Deploy a TimelockController for Ardi protocol governance.
/// @notice This contract becomes the OWNER of all Ardi protocol contracts
///         (ArdiNFT, ArdiBondEscrow, ArdiMintController, ArdiEpochDraw, etc.).
///         Any owner-only call (setCoordinator, setKYA, setRandomnessSource,
///         setEpochDraw, setBondEscrow, setSealed-emergency-paths, etc.) must:
///           1. Be proposed by a PROPOSER (multisig).
///           2. Wait `MIN_DELAY` seconds.
///           3. Be executed by an EXECUTOR (multisig or open-execution role).
///
///         Closes audit findings:
///           - C-2 (KYA setter compromise blast radius)
///           - L-1 (setEpochDraw / setRandomnessSource / setCoordinator
///                  single-key risk)
///
/// Deployment plan:
///   1. Set up Gnosis Safe for OWNER (e.g. 2-of-3 founder multisig).
///   2. Run this script with:
///        - PROPOSERS_ENV: comma-separated proposer addresses (typically just
///          the multisig)
///        - EXECUTORS_ENV: same multisig OR address(0) for open execution
///        - MIN_DELAY_SECONDS: 172800 (48h) for mainnet, lower for testnet
///   3. After deploy, transfer ownership of each Ardi contract to the Timelock.
///   4. Document the runbook for proposing + executing changes.
contract DeployTimelock is Script {
    function run() external returns (TimelockController timelock) {
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
        // Comma-separated lists; in practice you'd hard-code your multisig here.
        address[] memory proposers = _splitAddresses(vm.envString("TIMELOCK_PROPOSERS"));
        address[] memory executors = _splitAddresses(vm.envString("TIMELOCK_EXECUTORS"));
        // Admin = address(0) makes the timelock self-administered (no canceller key);
        // production-safe per OpenZeppelin's recommendation for trust-minimized setups.
        address admin = vm.envOr("TIMELOCK_ADMIN", address(0));

        require(proposers.length >= 1, "no proposers");
        require(executors.length >= 1, "no executors");

        vm.startBroadcast();
        timelock = new TimelockController(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        console2.log("TimelockController deployed at:", address(timelock));
        console2.log("  minDelay (seconds):", minDelay);
        console2.log("  proposers:");
        for (uint256 i; i < proposers.length; i++) {
            console2.log("    -", proposers[i]);
        }
        console2.log("  executors:");
        for (uint256 i; i < executors.length; i++) {
            console2.log("    -", executors[i]);
        }
        console2.log("  admin:", admin);
        console2.log("");
        console2.log("Next: transfer ownership of each Ardi contract to this address.");
        console2.log("  e.g. ArdiNFT(...).transferOwnership(", address(timelock), ");");
        console2.log("       ArdiNFT(...).acceptOwnership() called by Timelock via proposal+execute.");
    }

    /// @dev Tolerant comma-split (no whitespace stripping) — in production
    ///      operators should pass clean comma-separated env vars.
    function _splitAddresses(string memory s) internal pure returns (address[] memory) {
        bytes memory b = bytes(s);
        if (b.length == 0) {
            return new address[](0);
        }
        // Count commas to size the array
        uint256 count = 1;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == ",") count++;
        }
        address[] memory out = new address[](count);
        uint256 outIdx;
        uint256 start;
        for (uint256 i; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory part = new bytes(i - start);
                for (uint256 j; j < part.length; j++) {
                    part[j] = b[start + j];
                }
                out[outIdx++] = _parseAddr(string(part));
                start = i + 1;
            }
        }
        return out;
    }

    function _parseAddr(string memory s) internal pure returns (address a) {
        bytes memory b = bytes(s);
        require(b.length == 42, "address: expected 0x + 40 hex");
        require(b[0] == "0" && b[1] == "x", "address: missing 0x prefix");
        uint160 acc;
        for (uint256 i = 2; i < 42; i++) {
            uint8 c = uint8(b[i]);
            uint8 d;
            if (c >= 48 && c <= 57) d = c - 48;          // 0-9
            else if (c >= 97 && c <= 102) d = c - 97 + 10; // a-f
            else if (c >= 65 && c <= 70) d = c - 65 + 10;  // A-F
            else revert("address: bad hex");
            acc = (acc << 4) | uint160(d);
        }
        a = address(acc);
    }
}
