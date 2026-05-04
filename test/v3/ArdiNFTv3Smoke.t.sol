// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";
import {EmissionDistributor} from "../../src/v3/EmissionDistributor.sol";
import {IArdiEpochDrawV3} from "../../src/v3/interfaces/IArdiEpochDrawV3.sol";
import {IRandomnessSource} from "../../src/interfaces/IRandomnessSource.sol";

contract MockArdi is ERC20 {
    constructor() ERC20("Ardi", "ARDI") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockEpochDraw {
    address public winner;
    bool public published = true;
    bytes32 public wordHash;
    uint16 public power = 50;
    uint8 public lang = 0;
    uint8 public maxDur = 7;
    uint8 public elem = 4;

    function setWinner(address w) external { winner = w; }
    function setAnswer(string memory word) external {
        wordHash = keccak256(bytes(word));
    }
    function winners(uint256, uint256) external view returns (address) { return winner; }
    function getAnswer(uint256, uint256) external view returns (
        bytes32, uint16, uint8, uint8, uint8, bool
    ) {
        return (wordHash, power, lang, maxDur, elem, published);
    }
    function agentWinCount(address) external pure returns (uint8) { return 0; }
}

contract MockVRF is IRandomnessSource {
    uint256 public next = 1;
    function requestRandomness() external returns (uint256) {
        uint256 id = next; next = id + 1; return id;
    }
}

contract ArdiNFTv3Smoke is Test {
    ArdiNFTv3 nft;
    EmissionDistributor dist;
    MockArdi ardi;
    MockEpochDraw draw;
    MockVRF rng;

    address owner = address(0xa11ce);
    address coord = address(0xc0c0);
    address treasury = address(0xfee5);
    address operator = address(0x09e7);
    address holder = address(0xa6e7);

    function setUp() public {
        ardi = new MockArdi();
        draw = new MockEpochDraw();
        rng = new MockVRF();

        ArdiNFTv3 nftImpl = new ArdiNFTv3();
        bytes memory nftInit = abi.encodeCall(
            ArdiNFTv3.initialize, (owner, coord, bytes32(0), address(ardi), treasury)
        );
        nft = ArdiNFTv3(address(new ERC1967Proxy(address(nftImpl), nftInit)));

        EmissionDistributor edImpl = new EmissionDistributor();
        bytes memory edInit = abi.encodeCall(
            EmissionDistributor.initialize, (owner, address(ardi), operator)
        );
        dist = EmissionDistributor(address(new ERC1967Proxy(address(edImpl), edInit)));

        vm.startPrank(owner);
        nft.setEpochDraw(address(draw));
        nft.setEmissionDistributor(address(dist));
        nft.setRandomness(address(rng));
        dist.setArdiNFT(address(nft));
        vm.stopPrank();

        // Seed treasury for keeper bounty + holder for repair fees.
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

    function test_inscribe_setsAttributesAndJoinsActiveSet() public {
        uint256 tokenId = _mintOne(0, "fire");
        ArdiNFTv3.Inscription memory ins = nft.getInscription(tokenId);
        assertEq(ins.power, 50);
        assertEq(ins.maxDurability, 7);
        assertEq(ins.element, 4);
        assertTrue(ins.activeTracked);
        assertEq(dist.totalActivePower(), 50);
    }

    function test_repair_success_routesFeeToBurnAndTreasury() public {
        uint256 tokenId = _mintOne(0, "fire");
        // Push some emission so accPerShare moves and we can verify holder
        // can later claim.
        vm.prank(operator);
        dist.notifyReward(1_000 ether);

        uint256 fee = nft.repairFee(tokenId);
        assertGt(fee, 0);

        uint256 burnBefore = ardi.balanceOf(address(0xdead));
        uint256 trBefore = ardi.balanceOf(treasury);

        vm.prank(holder);
        uint256 reqId = nft.repair(tokenId);

        // Fulfil with a non-failing word (>= 100 mod 10000)
        vm.prank(address(rng));
        nft.onRandomness(reqId, 12345);

        uint256 burnAfter = ardi.balanceOf(address(0xdead));
        uint256 trAfter = ardi.balanceOf(treasury);
        assertEq(burnAfter - burnBefore, fee / 2, "50% to burn");
        assertEq(trAfter - trBefore, fee - fee / 2, "rest to treasury");

        // NFT still active, durability refreshed
        ArdiNFTv3.Inscription memory ins = nft.getInscription(tokenId);
        assertFalse(ins.broken);
        assertEq(ins.currentDurability, ins.maxDurability);
        assertTrue(ins.activeTracked);
    }

    function test_repair_failure_marksBrokenAndDeactivates() public {
        uint256 tokenId = _mintOne(0, "fire");
        vm.prank(holder);
        uint256 reqId = nft.repair(tokenId);

        // randomness % 10000 < 100 -> failure
        vm.prank(address(rng));
        nft.onRandomness(reqId, 50);

        ArdiNFTv3.Inscription memory ins = nft.getInscription(tokenId);
        assertTrue(ins.broken);
        assertFalse(ins.activeTracked);
        assertEq(dist.totalActivePower(), 0, "broken NFT removed from pool");
    }

    function test_emission_accountedPerPowerAfterNotify() public {
        // Two NFTs, both holder
        _mintOne(0, "fire");
        _mintOne(1, "water");
        assertEq(dist.totalActivePower(), 100);

        vm.prank(operator);
        dist.notifyReward(1_000 ether);

        // pendingFor sums: holder has 100 power against accReward, so all 1000 ardi
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        uint256 pending = dist.pendingFor(holder, ids);
        assertApproxEqAbs(pending, 1_000 ether, 1, "single holder gets full pool");

        uint256 balBefore = ardi.balanceOf(holder);
        vm.prank(holder);
        dist.claim(ids);
        assertApproxEqAbs(ardi.balanceOf(holder) - balBefore, 1_000 ether, 1);
    }
}
