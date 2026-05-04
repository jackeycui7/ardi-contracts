// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {MockEpochDraw} from "./Mocks.sol";

contract ArdiOTCTest is Test {
    ArdiOTC otc;
    ArdiNFT nft;
    MockEpochDraw epochDraw;

    address owner = address(0xA11CE);
    uint256 coordinatorPk = 0xC00D;
    address coordinator;

    address seller = address(0xBEEF);
    address buyer = address(0xCAFE);

    function setUp() public {
        coordinator = vm.addr(coordinatorPk);
        epochDraw = new MockEpochDraw();

        vm.startPrank(owner);
        nft = new ArdiNFT(owner, coordinator, bytes32(0));
        nft.setEpochDraw(address(epochDraw));
        otc = new ArdiOTC(owner, address(nft));
        vm.stopPrank();

        // v2: no bond/registerMiner step — eligibility is at EpochDraw.commit
        // and unrelated to inscribe. Inscribe directly given the win.
        epochDraw.setWinner(1, 0, seller);
        epochDraw.setAnswer(1, 0, "x", 50, 0);
        vm.prank(seller);
        nft.inscribe(1, 0, "x");

        vm.deal(buyer, 10 ether);
    }

    function test_listAndBuy() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.stopPrank();

        ArdiOTC.Listing memory l = otc.getListing(1);
        assertEq(l.seller, seller);
        assertEq(l.priceWei, 1 ether);

        uint256 sellerBalBefore = seller.balance;
        vm.prank(buyer);
        otc.buy{value: 1 ether}(1);

        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, sellerBalBefore + 1 ether);
        assertFalse(otc.isListed(1));
    }

    function test_unlist() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        otc.unlist(1);
        vm.stopPrank();

        assertFalse(otc.isListed(1));
    }

    function test_buy_refundsExcess() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.stopPrank();

        uint256 buyerBalBefore = buyer.balance;
        vm.prank(buyer);
        otc.buy{value: 3 ether}(1);

        // Buyer paid 1 ether, refunded 2
        assertEq(buyer.balance, buyerBalBefore - 1 ether);
    }

    function test_buy_revertsIfStaleListing() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        // seller transfers token away
        nft.transferFrom(seller, address(0xDEAD), 1);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(ArdiOTC.NotListed.selector);
        otc.buy{value: 1 ether}(1);
    }

    function test_buy_revertsIfInsufficientPayment() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(ArdiOTC.InsufficientPayment.selector);
        otc.buy{value: 0.5 ether}(1);
    }

    function test_buy_revertsIfBuyerIsSeller() public {
        vm.startPrank(seller);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.deal(seller, 1 ether);
        vm.expectRevert(ArdiOTC.CallerIsSeller.selector);
        otc.buy{value: 1 ether}(1);
        vm.stopPrank();
    }

    function test_list_revertsIfNotOwner() public {
        vm.prank(buyer);
        vm.expectRevert(ArdiOTC.NotOwner.selector);
        otc.list(1, 1 ether);
    }

    function test_list_revertsIfZeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(ArdiOTC.ZeroPrice.selector);
        otc.list(1, 0);
    }
}
