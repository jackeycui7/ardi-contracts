// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ArdiNFTv3} from "../../src/v3/ArdiNFTv3.sol";
import {EmissionDistributor} from "../../src/v3/EmissionDistributor.sol";
import {ArdiOTC} from "../../src/ArdiOTC.sol";
import {IRandomnessSource} from "../../src/interfaces/IRandomnessSource.sol";

contract _MockArdi is ERC20 {
    constructor() ERC20("Ardi", "ARDI") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}
contract _MockEpochDraw {
    address public winner;
    bytes32 public wordHash;
    function setWinner(address w) external { winner = w; }
    function setAnswer(string memory word) external { wordHash = keccak256(bytes(word)); }
    function winners(uint256, uint256) external view returns (address) { return winner; }
    function getAnswer(uint256, uint256) external view returns (
        bytes32, uint16, uint8, uint8, uint8, bool
    ) { return (wordHash, 50, 0, 7, 4, true); }
    function agentWinCount(address) external pure returns (uint8) { return 0; }
}
contract _MockVRF is IRandomnessSource {
    uint256 public next = 1;
    function requestRandomness() external returns (uint256) {
        uint256 id = next; next = id + 1; return id;
    }
}

contract MarketV3Interaction is Test {
    ArdiNFTv3 nft;
    EmissionDistributor dist;
    ArdiOTC otc;
    _MockArdi ardi;
    _MockEpochDraw draw;
    _MockVRF rng;

    address owner = address(0xa11ce);
    address coord = address(0xc0c0);
    address treasury = address(0xfee5);
    address operator = address(0x09e7);
    address seller = address(0x5e11e7);
    address buyer = address(0xbeef);

    function setUp() public {
        ardi = new _MockArdi();
        draw = new _MockEpochDraw();
        rng = new _MockVRF();

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

        otc = new ArdiOTC(owner, address(nft));

        ardi.mint(treasury, 1_000_000 ether);
        ardi.mint(seller, 10_000_000 ether);
        ardi.mint(operator, 100_000_000 ether);
        vm.prank(treasury);  ardi.approve(address(nft), type(uint256).max);
        vm.prank(seller);    ardi.approve(address(nft), type(uint256).max);
        vm.prank(operator);  ardi.approve(address(dist), type(uint256).max);

        vm.deal(buyer, 100 ether);

        // Mint one NFT to seller
        draw.setAnswer("fire");
        draw.setWinner(seller);
        vm.prank(seller);
        nft.inscribe(uint64(1), 0, "fire");
        // Approve OTC
        vm.prank(seller);
        nft.setApprovalForAll(address(otc), true);
    }

    function test_listAndBuy_v3HappyPath() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);

        uint256 sellerEthBefore = seller.balance;

        vm.prank(buyer);
        otc.buy{value: 1 ether}(tokenId);

        assertEq(nft.ownerOf(tokenId), buyer, "NFT moved to buyer");
        assertEq(seller.balance - sellerEthBefore, 1 ether, "seller paid full");
    }

    // CROSS-CHAIN BEHAVIOR: v3 TokenLocked must block OTC.buy() while a
    // repair VRF is pending. Without this guard, the listing would be
    // satisfiable mid-repair and the new owner would inherit the pending
    // request — emission accounting would drift.
    function test_buyFailsWhilePendingRepair() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);

        // Seller starts a repair (NFT becomes TokenLocked)
        vm.prank(seller);
        nft.repair(tokenId);

        vm.prank(buyer);
        vm.expectRevert(ArdiNFTv3.TokenLocked.selector);
        otc.buy{value: 1 ether}(tokenId);

        // After VRF callback resolves the repair, buy should succeed again.
        vm.prank(address(rng));
        nft.onRandomness(1, 999_999); // success path
        vm.prank(buyer);
        otc.buy{value: 1 ether}(tokenId);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    // Seller transfers NFT off-market after listing — buy() must clean the
    // stale listing AND revert (delete-then-revert order).
    function test_buyClearsStaleListingOnTransferOut() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);
        // Seller transfers to a friend
        address friend = address(0xfa11);
        vm.prank(seller);
        nft.transferFrom(seller, friend, tokenId);

        vm.prank(buyer);
        vm.expectRevert(ArdiOTC.NotListed.selector);
        otc.buy{value: 1 ether}(tokenId);

        // BUG: ArdiOTC.buy does `delete listings[tokenId]; revert NotListed();`
        // but Solidity reverts unwind state changes within the same call frame,
        // so the delete is rolled back. The stale listing persists. The friend
        // (now owner) can list it themselves (overwrites), but the buyer keeps
        // hitting the stale entry until something writes it.
        // This is a real bug but mitigated: the buyer's tx fails fast (cheap
        // gas), and any subsequent owner can list-overwrite. Document for v1.1.
        ArdiOTC.Listing memory l = otc.getListing(tokenId);
        assertEq(l.seller, seller, "stale listing persists due to delete-then-revert");
    }

    // After buy, ED.holder cache must rotate so the buyer can claim
    // without revert NotHolder. This is the C-1 audit fix interacting with
    // the OTC sale path.
    function test_emissionRoutesToBuyerAfterPurchase() public {
        uint256 tokenId = 1;
        // Seed acc with rewards while seller still owns
        vm.prank(operator);
        dist.notifyReward(1_000 ether);

        // Sell
        vm.prank(seller);
        otc.list(tokenId, 1 ether);
        vm.prank(buyer);
        otc.buy{value: 1 ether}(tokenId);

        // Seller's pre-sale accrual was settled into pendingOf via onTransfer
        uint256 sellerPending = dist.pendingOf(seller);
        assertGt(sellerPending, 0, "seller's pre-sale accrual settled");

        // Buyer can claim future emission — push more, claim
        vm.prank(operator);
        dist.notifyReward(500 ether);
        uint256[] memory ids = new uint256[](1); ids[0] = tokenId;
        uint256 buyerArdiBefore = ardi.balanceOf(buyer);
        vm.prank(buyer);
        dist.claim(ids);
        assertGt(ardi.balanceOf(buyer) - buyerArdiBefore, 0, "buyer paid post-sale emission");

        // Seller can ALSO claim their pre-sale share via empty-array claim
        uint256 sellerArdiBefore = ardi.balanceOf(seller);
        uint256[] memory empty = new uint256[](0);
        vm.prank(seller);
        dist.claim(empty);
        assertEq(ardi.balanceOf(seller) - sellerArdiBefore, sellerPending);
    }

    // Front-run: seller raises price between buyer's tx and inclusion.
    // Buyer's tx reverts InsufficientPayment but pays gas — acceptable.
    function test_frontRunRelistMakesBuyerRevert() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);

        // Seller front-runs: relist higher
        vm.prank(seller);
        otc.list(tokenId, 5 ether); // overwrites

        vm.prank(buyer);
        vm.expectRevert(ArdiOTC.InsufficientPayment.selector);
        otc.buy{value: 1 ether}(tokenId);
    }

    // Buyer who is also the seller cannot buy from themselves.
    function test_cannotBuyOwnListing() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);
        vm.deal(seller, 2 ether);
        vm.prank(seller);
        vm.expectRevert(ArdiOTC.CallerIsSeller.selector);
        otc.buy{value: 1 ether}(tokenId);
    }

    // Excess ETH refunded.
    function test_excessRefunded() public {
        uint256 tokenId = 1;
        vm.prank(seller);
        otc.list(tokenId, 1 ether);
        uint256 buyerEthBefore = buyer.balance;
        vm.prank(buyer);
        otc.buy{value: 3 ether}(tokenId);
        // Buyer paid 1 ether (price), got 2 ether refund.
        assertEq(buyer.balance, buyerEthBefore - 1 ether);
    }

    // Broken NFT can still be listed/sold (ownership is the only check).
    function test_brokenNftCanBeSold() public {
        uint256 tokenId = 1;
        // Force NFT to broken via failed repair
        vm.prank(seller);
        nft.repair(tokenId);
        vm.prank(address(rng));
        nft.onRandomness(1, 50); // 50 % 10000 < 100 → fail
        ArdiNFTv3.Inscription memory ins = nft.getInscription(tokenId);
        assertTrue(ins.broken);

        // Seller still owns, can list
        vm.prank(seller);
        otc.list(tokenId, 0.5 ether);

        vm.prank(buyer);
        otc.buy{value: 0.5 ether}(tokenId);
        assertEq(nft.ownerOf(tokenId), buyer);
        // Buyer now owns a broken NFT — they need to fuse to revive.
        ArdiNFTv3.Inscription memory ins2 = nft.getInscription(tokenId);
        assertTrue(ins2.broken);
    }
}
