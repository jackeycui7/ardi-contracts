// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiToken} from "../src/ArdiToken.sol";

contract ArdiTokenTest is Test {
    ArdiToken token;
    address owner = address(0xA11CE);
    address minter = address(0xC0FFEE);
    address user = address(0xBEEF);

    function setUp() public {
        vm.prank(owner);
        token = new ArdiToken(owner);
    }

    function test_basics() public view {
        assertEq(token.name(), "Ardinal");
        assertEq(token.symbol(), "aArdi");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.MAX_SUPPLY(), 10_000_000_000 ether);
    }

    function test_mintLp_owner() public {
        vm.prank(owner);
        token.mintLp(user, 1_000_000_000 ether);
        assertEq(token.balanceOf(user), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_mintLp_revertsCapExceeded() public {
        vm.prank(owner);
        vm.expectRevert(ArdiToken.CapExceeded.selector);
        token.mintLp(user, 10_000_000_001 ether);
    }

    function test_setMinter() public {
        vm.prank(owner);
        token.setMinter(minter);
        assertEq(token.minter(), minter);
    }

    function test_setMinter_revertsIfAlreadySet() public {
        vm.startPrank(owner);
        token.setMinter(minter);
        vm.expectRevert(ArdiToken.MinterAlreadySet.selector);
        token.setMinter(address(0xDEAD));
        vm.stopPrank();
    }

    function test_lockMinter() public {
        vm.startPrank(owner);
        token.setMinter(minter);
        token.lockMinter();
        assertTrue(token.minterLocked());

        vm.expectRevert(ArdiToken.MinterLocked.selector);
        token.setMinter(address(0xDEAD));
        vm.stopPrank();
    }

    function test_mint_byMinter() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user, 1_000 ether);
        assertEq(token.balanceOf(user), 1_000 ether);
    }

    function test_mint_revertsIfNotMinter() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(user);
        vm.expectRevert(ArdiToken.NotMinter.selector);
        token.mint(user, 1_000 ether);
    }

    function test_mint_respectsCap() public {
        vm.startPrank(owner);
        token.mintLp(user, 9_999_999_999 ether);
        token.setMinter(minter);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(ArdiToken.CapExceeded.selector);
        token.mint(user, 2 ether);
    }

    function test_burn() public {
        vm.prank(owner);
        token.mintLp(user, 1_000 ether);
        vm.prank(user);
        token.burn(400 ether);
        assertEq(token.balanceOf(user), 600 ether);
    }
}
