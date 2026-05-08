// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {ArdiNFTv4Mainnet} from "../../src/v4/ArdiNFTv4Mainnet.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImpl, bytes memory data) external payable;
    function owner() external view returns (address);
}

interface IArdiNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalInscribed() external view returns (uint256);
    function fusionCount() external view returns (uint256);
    function inscriptions(uint256 tokenId) external view returns (
        string memory word, uint16 power, uint8 languageId, uint8 generation,
        address inscriber, uint64 mintTimestamp, uint8 element,
        uint8 maxDurability, uint8 currentDurability, uint64 lastDecayCheckpoint,
        bool broken, bool activeTracked
    );
    function effectiveDurability(uint256 tokenId) external view returns (uint8);
    function globalDecayRound() external view returns (uint64);
}

/// @title MainnetForkUpgrade — verify the v322→v4Mainnet UUPS upgrade
///         preserves all NFT data on a real mainnet fork.
///
/// Setup: BASE_RPC=https://mainnet.base.org forge test --match-path test/v4/MainnetForkUpgrade.t.sol -vv
contract MainnetForkUpgrade is Test {
    address constant PROXY = 0xf68425D0d451699d0d766150634E436Acd2F05A1;
    address constant OWNER = 0x7aC6e9042fB5148B3f5dAf9bADFb8cF33Ef66f43;

    // Sample tokenIds spanning the supply range (1, 100, 5000, ~16000).
    uint256[5] sampleIds = [uint256(1), 100, 5000, 10000, 16000];

    string rpc = vm.envOr("BASE_RPC", string("https://mainnet.base.org"));

    function setUp() public {
        // Fork at latest mainnet state.
        vm.createSelectFork(rpc);
    }

    function test_upgradePreservesAllNFTData() public {
        IArdiNFT nft = IArdiNFT(PROXY);

        // Snapshot pre-upgrade state.
        uint256 totalInscribedBefore = nft.totalInscribed();
        uint256 fusionCountBefore = nft.fusionCount();
        uint64 decayRoundBefore = nft.globalDecayRound();
        console.log("pre-upgrade totalInscribed:", totalInscribedBefore);
        console.log("pre-upgrade fusionCount:   ", fusionCountBefore);
        console.log("pre-upgrade globalDecayRound:", decayRoundBefore);

        // Snapshot 5 sample NFTs in detail.
        address[5] memory ownersBefore;
        uint16[5]  memory powersBefore;
        uint8[5]   memory effDurBefore;
        string[5]  memory wordsBefore;
        for (uint i = 0; i < sampleIds.length; i++) {
            uint256 tid = sampleIds[i];
            try nft.ownerOf(tid) returns (address o) {
                ownersBefore[i] = o;
                (string memory w, uint16 p, , , , , , , , , , ) = nft.inscriptions(tid);
                powersBefore[i] = p;
                wordsBefore[i] = w;
                effDurBefore[i] = nft.effectiveDurability(tid);
            } catch {
                // Token doesn't exist — sampleIds list assumes typical mainnet
                // state where these tokens are minted; if not, treat as pass.
                ownersBefore[i] = address(0);
            }
        }

        // Deploy v4 impl + execute upgrade as owner.
        ArdiNFTv4Mainnet newImpl = new ArdiNFTv4Mainnet();
        console.log("new impl:", address(newImpl));

        vm.startPrank(OWNER);
        IUUPSProxy(PROXY).upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        // Verify post-upgrade state matches pre-upgrade.
        assertEq(nft.totalInscribed(), totalInscribedBefore, "totalInscribed drift");
        assertEq(nft.fusionCount(), fusionCountBefore, "fusionCount drift");
        assertEq(nft.globalDecayRound(), decayRoundBefore, "decayRound drift");

        for (uint i = 0; i < sampleIds.length; i++) {
            uint256 tid = sampleIds[i];
            if (ownersBefore[i] == address(0)) continue;

            assertEq(nft.ownerOf(tid), ownersBefore[i], "owner drift");
            (string memory w, uint16 p, , , , , , , , , , ) = nft.inscriptions(tid);
            assertEq(p, powersBefore[i], "power drift");
            assertEq(w, wordsBefore[i], "word drift");
            assertEq(nft.effectiveDurability(tid), effDurBefore[i], "eff dura drift");
            console.log("token ok:", tid, p, w);
        }

        // v4-specific reads should work. Test re-upgrade safety: even if the
        // proxy already has v4 deployed (mainnet post-launch state), upgrading
        // to a freshly-built impl preserves forgeModule + nextForgedWordId.
        ArdiNFTv4Mainnet v4 = ArdiNFTv4Mainnet(PROXY);
        // Don't assert specific values — they depend on whether the proxy
        // was previously upgraded. Just verify the slots are readable.
        v4.forgeModule();         // must not revert
        v4.nextForgedWordId();    // must not revert
    }

    function test_setForgeModuleInitializesWordIdCounter() public {
        // Upgrade first.
        ArdiNFTv4Mainnet newImpl = new ArdiNFTv4Mainnet();
        vm.startPrank(OWNER);
        IUUPSProxy(PROXY).upgradeToAndCall(address(newImpl), "");
        ArdiNFTv4Mainnet v4 = ArdiNFTv4Mainnet(PROXY);

        // Set a dummy module address.
        address dummyModule = address(0x1234);
        v4.setForgeModule(dummyModule);
        vm.stopPrank();

        assertEq(v4.forgeModule(), dummyModule);
        assertEq(v4.nextForgedWordId(), 21001, "should init to ORIGINAL_CAP+1");
    }
}
