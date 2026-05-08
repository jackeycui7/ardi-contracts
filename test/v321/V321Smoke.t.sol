// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";
import {ArdiNFTv32} from "../../src/v32/ArdiNFTv32.sol";
import {ArdiNFTv321} from "../../src/v32/ArdiNFTv321.sol";
import {EmissionDistributor} from "../../src/v3/EmissionDistributor.sol";
import {EmissionDistributorV2} from "../../src/v32/EmissionDistributorV2.sol";
import {IRandomnessSource} from "../../src/interfaces/IRandomnessSource.sol";

contract MockArdi321 is ERC20 {
    constructor() ERC20("Ardi", "ARDI") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockEpochDraw321 {
    address public winner;
    bytes32 public wordHash;
    uint16 public power = 50;
    uint8 public maxDur = 7;
    function setWinner(address w) external { winner = w; }
    function setAnswer(string memory word) external { wordHash = keccak256(bytes(word)); }
    function winners(uint256, uint256) external view returns (address) { return winner; }
    function getAnswer(uint256, uint256) external view returns (
        bytes32, uint16, uint8, uint8, uint8, bool
    ) {
        return (wordHash, power, 0, maxDur, 4, true);
    }
    function agentWinCount(address) external pure returns (uint8) { return 0; }
}

contract MockVRF321 is IRandomnessSource {
    uint256 public next = 1;
    function requestRandomness() external returns (uint256) { uint256 id = next; next = id + 1; return id; }
}

/// @notice Smoke test for v3.2.1 — dynamic repairFee + post-mortem gate.
contract V321Smoke is Test {
    ArdiNFTv321 nft;
    EmissionDistributorV2 dist;
    MockArdi321 ardi;
    MockEpochDraw321 draw;
    MockVRF321 rng;

    address owner = address(0xa11ce);
    address coord = address(0xc0c0);
    address treasury = address(0xfee5);
    address operator = address(0x09e7);
    address holder = address(0xa6e7);

    uint16 constant RATIO = 5_000;            // 0.5×
    uint256 constant DAILY = 24_000_000 ether; // 24M $ardi/day

    function setUp() public {
        ardi = new MockArdi321();
        draw = new MockEpochDraw321();
        rng = new MockVRF321();

        // Deploy v321 directly behind a proxy. v321 inherits v32's full
        // storage layout, so the v3 initializer is the right entrypoint.
        ArdiNFTv321 nftImpl = new ArdiNFTv321();
        bytes memory nftInit = abi.encodeCall(
            ArdiNFTv3.initialize, (owner, coord, bytes32(0), address(ardi), treasury)
        );
        nft = ArdiNFTv321(address(new ERC1967Proxy(address(nftImpl), nftInit)));

        EmissionDistributorV2 edImpl = new EmissionDistributorV2();
        bytes memory edInit = abi.encodeCall(
            EmissionDistributor.initialize, (owner, address(ardi), operator)
        );
        dist = EmissionDistributorV2(address(new ERC1967Proxy(address(edImpl), edInit)));

        vm.startPrank(owner);
        nft.setEpochDraw(address(draw));
        nft.setEmissionDistributor(address(dist));
        nft.setRandomness(address(rng));
        dist.setArdiNFT(address(nft));
        dist.setArdiNFTv32(address(nft));
        nft.configureRepair(RATIO, DAILY);
        vm.stopPrank();

        ardi.mint(treasury, 1_000_000 ether);
        ardi.mint(operator, 100_000_000 ether);
        ardi.mint(holder, 10_000_000 ether);
        vm.prank(treasury);
        ardi.approve(address(nft), type(uint256).max);
        vm.prank(holder);
        ardi.approve(address(nft), type(uint256).max);
        vm.prank(operator);
        ardi.approve(address(dist), type(uint256).max);
    }

    function _mintOne(uint256 wordId, string memory word) internal returns (uint256 tokenId) {
        draw.setAnswer(word);
        draw.setWinner(holder);
        vm.prank(holder);
        nft.inscribe(uint64(1), wordId, word);
        return wordId + 1;
    }

    /// @dev Drive globalDecayRound forward via notifyReward+bumpDecayRound
    ///      until the NFT's effectiveDurability hits 0. v32 EDV2 bumps
    ///      decay-round once per notifyReward.
    function _expire(uint256 tokenId) internal {
        for (uint256 i = 0; i < 10; ++i) {
            if (nft.effectiveDurability(tokenId) == 0) return;
            vm.prank(operator);
            dist.notifyReward(1 ether);
        }
        require(nft.effectiveDurability(tokenId) == 0, "did not expire");
    }

    function test_repairFee_followsDynamicFormula() public {
        uint256 tokenId = _mintOne(0, "fire");
        // totalActivePower = 50 (one NFT, power=50, maxDur=7)
        // expected = (5000 * 24_000_000e18 * 50 * 7) / (10_000 * 50)
        //          = 168_000_000e18 / 1 ... rerun:
        //          numerator   = 5000 * 24e24 * 50 * 7 = 5000 * 24e24 * 350 = 4.2e31
        //          denominator = 10_000 * 50 = 500_000
        //          = 4.2e31 / 5e5 = 8.4e25 = 84_000_000e18
        uint256 expected =
            (uint256(RATIO) * DAILY * 50 * 7) / (10_000 * uint256(50));
        assertEq(nft.repairFee(tokenId), expected, "dynamic formula");
        assertEq(expected, 84_000_000 ether, "sanity: 84M ardi");
    }

    function test_repair_revertsWhenAlive() public {
        uint256 tokenId = _mintOne(0, "fire");
        vm.expectRevert(ArdiNFTv321.NotYetExpired.selector);
        vm.prank(holder);
        nft.repair(tokenId);
    }

    function test_repair_succeedsAfterExpiry() public {
        // First NFT activates at round 0 → expires at round 7.
        uint256 tokenId = _mintOne(0, "fire");
        // Bump rounds 1-3 then mint NFT #2 so its expirationRound = 3+7=10
        // — NFT #1 expires at round 7, NFT #2 stays active to keep
        // totalActivePower non-zero (so the dynamic fee formula's
        // div-by-zero guard doesn't trip).
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(operator);
            dist.notifyReward(1 ether);
        }
        _mintOne(1, "fire");
        // Now drive 4 more rounds to reach round 7 — token #1 expires.
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(operator);
            dist.notifyReward(1 ether);
        }
        require(nft.effectiveDurability(tokenId) == 0, "tok1 not expired");
        require(nft.effectiveDurability(tokenId + 1) > 0, "tok2 must stay alive");

        uint256 fee = nft.repairFee(tokenId);
        ardi.mint(holder, fee);

        vm.prank(holder);
        uint256 reqId = nft.repair(tokenId);
        vm.prank(address(rng));
        nft.onRandomness(reqId, 12345);

        ArdiNFTv3.Inscription memory ins = nft.getInscription(tokenId);
        assertFalse(ins.broken);
        assertEq(ins.currentDurability, ins.maxDurability);
        assertTrue(ins.activeTracked);
    }

    function test_configureRepair_ownerOnly() public {
        vm.expectRevert();
        vm.prank(holder);
        nft.configureRepair(1234, 567);
    }
}
