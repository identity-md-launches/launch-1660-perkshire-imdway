// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PerkToken} from "../src/PerkToken.sol";

contract PerkTokenTest is Test {
    PerkToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new PerkToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Perkshire IMDway");
        assertEq(token.symbol(), "PERK");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployerOnce() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRespectsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(PerkToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 5 ether));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 5 ether);
        vm.prank(bob);
        vm.expectRevert(PerkToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_transferRevertsOnInsufficientBalanceAndZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(PerkToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
        vm.expectRevert(PerkToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_transferToDeadIsAnOrdinaryTransfer() public {
        address dead = 0x000000000000000000000000000000000000dEaD;
        token.transfer(dead, 7 ether);
        assertEq(token.balanceOf(dead), 7 ether);
        assertEq(token.totalSupply(), 1e27, "supply never changes");
    }

    function test_noMintOrAdminPath() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, type(uint128).max));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 1e27, signatures[i]);
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, 1e27);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), 1e27);
    }
}
