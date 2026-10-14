// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PerkVaultBase} from "../utils/PerkVaultBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlocklistERC20} from "../mocks/BlocklistERC20.sol";
import {PerkVaultHandler} from "./PerkVaultHandler.sol";

/// @notice Invariants of the Retained Earnings Vault over random call sequences: swaps in all four
/// modes, liquidity, tenders, burns, redeems, asks, donations and an IMD that blocks 0x…dEaD or the
/// hook at random. The pool starts launch-shaped (PERK-only liquidity, no IMD in the manager) so the
/// first fees are deferred as claims and redeemed later.
contract PerkVaultInvariantsTest is PerkVaultBase {
    PerkVaultHandler handler;
    BlocklistERC20 blockable;
    address[] actors;

    uint256 constant ACTOR_IMD = 1e26;
    uint256 constant ACTOR_PERK = 5e25;

    function _newImd() internal override returns (MockERC20) {
        blockable = new BlocklistERC20("IMD", "IMD", IMD_SUPPLY);
        return blockable;
    }

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        _addPerkOnlyLiquidity(1e24);
        assertEq(imd.balanceOf(address(manager)), 0, "launch shape: the manager starts without IMD");

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            imd.transfer(actors[i], ACTOR_IMD);
            perk.transfer(actors[i], ACTOR_PERK);
        }

        handler = new PerkVaultHandler(manager, swapRouter, lpRouter, blockable, perk, hook, key, actors);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = PerkVaultHandler.buyExactIn.selector;
        selectors[1] = PerkVaultHandler.buyExactOut.selector;
        selectors[2] = PerkVaultHandler.sellExactIn.selector;
        selectors[3] = PerkVaultHandler.sellExactOut.selector;
        selectors[4] = PerkVaultHandler.addFullRangeLiquidity.selector;
        selectors[5] = PerkVaultHandler.tender.selector;
        selectors[6] = PerkVaultHandler.burn.selector;
        selectors[7] = PerkVaultHandler.redeemPendingFees.selector;
        selectors[8] = PerkVaultHandler.ask.selector;
        selectors[9] = PerkVaultHandler.donate.selector;
        selectors[10] = PerkVaultHandler.setDeadBlocked.selector;
        selectors[11] = PerkVaultHandler.setHookBlocked.selector;
        selectors[12] = PerkVaultHandler.buyExactIn.selector; // buys twice as often: they fund everything else
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation
    // ---------------------------------------------------------------------------------------------

    /// @dev Every unit of IMD is with a known holder: nothing is minted, nothing vanishes.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_imdIsConserved() public view {
        uint256 total = imd.balanceOf(address(this)) + imd.balanceOf(address(manager)) + imd.balanceOf(address(hook))
            + imd.balanceOf(DEAD) + imd.balanceOf(address(intake)) + imd.balanceOf(address(handler));
        for (uint256 i = 0; i < actors.length; i++) {
            total += imd.balanceOf(actors[i]);
        }
        assertEq(total, IMD_SUPPLY, "IMD leaked");
    }

    /// @dev The hook's IMD is exactly what the fee path delivered plus donations, less the three
    /// exits: burn, tender, ask. Any other way out, or any fee counted twice, breaks this.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_imdLeavesOnlyByTenderBurnAndAsk() public view {
        // Fees ever taken = totalFloat + totalBurned + burnOwed; those still pending never arrived.
        int256 received = int256(hook.totalFloat() + hook.totalBurned() + hook.burnOwed()) - int256(hook.pendingFloat());
        int256 expected = received + int256(handler.ghostDonated()) - int256(hook.totalBurned())
            - int256(handler.ghostTenderedOut()) - int256(handler.ghostAskedOut());
        assertEq(int256(imd.balanceOf(address(hook))), expected, "IMD left the hook by another path");
    }

    /// @dev 0x…dEaD holds exactly what the burn says it sent, and exactly the PERK ever tendered.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_deadHoldsExactlyTotalBurnedAndTotalTendered() public view {
        assertEq(imd.balanceOf(DEAD), hook.totalBurned(), "dEaD IMD differs from totalBurned");
        assertEq(perk.balanceOf(DEAD), hook.totalTendered(), "dEaD PERK differs from totalTendered");
    }

    // ---------------------------------------------------------------------------------------------
    // The fee split
    // ---------------------------------------------------------------------------------------------

    /// @dev The burn halves are floor(fee/2) and the float halves ceil(fee/2): their totals differ
    /// by at most one wei per fee, and the burn side never exceeds the float side.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_halfOfEveryFeeIsOwedToTheBurnOnce() public view {
        uint256 burnSide = hook.burnOwed() + hook.totalBurned();
        assertLe(burnSide, hook.totalFloat(), "burn side exceeds the float side");
        assertLe(hook.totalFloat() - burnSide, handler.ghostSwaps(), "more odd fees than swaps");
    }

    /// @dev The burn is paid as far as the hook's IMD allows: debt and cash never coexist unless the
    /// IMD token is refusing 0x…dEaD, or IMD arrived by a path that runs no burn (a donation).
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_burnOwedNeverExceedsWhatCouldNotBePaid() public view {
        // Whatever is owed is covered by what has not arrived yet (pending), by a refusing token,
        // or by cash that a donation brought in after the last burn ran. In every case the float
        // view never counts the owed half.
        uint256 bal = imd.balanceOf(address(hook));
        uint256 owed = hook.burnOwed();
        uint256 deferred = hook.deferredBurn();
        assertLe(deferred, owed, "deferredBurn exceeds burnOwed");
        assertLe(deferred, hook.pendingFloat(), "deferredBurn exceeds the pending claims");
        assertEq(hook.burnDue(), owed - deferred, "burnDue formula");
        uint256 due = owed - deferred;
        assertEq(hook.floatBalance(), bal > due ? bal - due : 0, "float counts the burn half due");
        // Tenders and asks spend only the float, so the only way owed can exceed cash is a fee
        // whose IMD is still pending: cash plus pending always covers the debt, and cash alone
        // covers the part due unless IMD refuses the hook or 0x…dEaD.
        assertGe(bal + hook.pendingFloat(), owed, "owed more than pending plus cash");
        assertGe(bal, due, "burn due exceeds the hook's IMD");
    }

    // ---------------------------------------------------------------------------------------------
    // Claims and the manager
    // ---------------------------------------------------------------------------------------------

    /// @dev Deferred fees are claims on the manager, and the manager's IMD always covers them: a
    /// claim is never minted against IMD the pool does not hold.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_managerCoversPendingClaims() public view {
        assertGe(imd.balanceOf(address(manager)), hook.pendingFloat(), "claims exceed the manager's IMD");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(perk)))), 0, "the hook holds PERK claims");
        assertEq(perk.balanceOf(address(hook)), 0, "the hook holds PERK");
    }

    // ---------------------------------------------------------------------------------------------
    // Book value and the ask
    // ---------------------------------------------------------------------------------------------

    /// @dev Book value per PERK, counting the fees still pending as claims, only ever falls through
    /// `ask()`; everything else leaves it where it was or raises it. The handler restarts the floor
    /// after each ask. The view (`bookValuePerPerk`) excludes pending claims, so it is never above
    /// that measure and equals it whenever nothing is pending.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_bookValueFallsOnlyByAsk() public view {
        uint256 inclusive = handler.claimInclusiveBookValue();
        assertGe(inclusive, handler.ghostBookValueFloor(), "book value fell outside an ask");
        assertLe(hook.bookValuePerPerk(), inclusive, "the view counts pending claims");
        if (hook.pendingFloat() == 0) assertEq(hook.bookValuePerPerk(), inclusive, "nothing pending yet they differ");
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        if (circulating > 0) {
            assertEq(hook.bookValuePerPerk(), hook.floatBalance() * 1e18 / circulating, "book value formula");
        }
    }

    /// @dev Every ask paid the Intake 0.5 and its caller 0.1, and nothing else did.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_askAccounting() public view {
        assertEq(imd.balanceOf(address(intake)), hook.totalAsked() * 0.5 ether, "Intake holds other than 0.5 per ask");
        assertEq(handler.ghostAskRewards(), hook.totalAsked() * 0.1 ether, "callers got other than 0.1 per ask");
        assertEq(handler.ghostAskedOut(), hook.totalAsked() * 0.6 ether);
        assertEq(imd.allowance(address(hook), address(intake)), 0, "an allowance to the Intake is standing");
        assertLe(hook.lastAsk(), block.timestamp);
        assertEq(hook.lastAsk() == 0, hook.totalAsked() == 0, "lastAsk and totalAsked disagree");
    }

    /// @dev Fixed supply; no PERK is ever created or destroyed, only parked at 0x…dEaD.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_perkSupplyIsFixed() public view {
        assertEq(perk.totalSupply(), 1_000_000_000 ether);
        uint256 total = perk.balanceOf(address(this)) + perk.balanceOf(address(manager)) + perk.balanceOf(DEAD)
            + perk.balanceOf(address(hook));
        for (uint256 i = 0; i < actors.length; i++) {
            total += perk.balanceOf(actors[i]);
        }
        assertEq(total, perk.totalSupply(), "PERK leaked");
    }
}
