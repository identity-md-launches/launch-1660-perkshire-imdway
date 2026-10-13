// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PerkVaultHook} from "../src/PerkVaultHook.sol";
import {PerkVaultBase} from "./utils/PerkVaultBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BlocklistERC20, ReenteringERC20} from "./mocks/BlocklistERC20.sol";

/// @notice The live IMD has an admin blocklist. If 0x…dEaD is ever blocked, the burn must wait
/// without stopping swaps, tenders or asks, and resume once unblocked.
contract PerkVaultHookBlockedDeadTest is PerkVaultBase {
    BlocklistERC20 blockable;

    function _newImd() internal override returns (MockERC20) {
        blockable = new BlocklistERC20("IMD", "IMD", IMD_SUPPLY);
        return blockable;
    }

    function test_burnRefusedByImdStaysOwedAndDoesNotRevertTheSwap() public {
        _addFullRangeLiquidity(1e24);
        blockable.setBlocked(DEAD, true);
        Snapshot memory s = _snapshot();

        _buyExactIn(100 ether); // fee 1 IMD

        assertEq(_feeSince(s), 1 ether);
        assertEq(imd.balanceOf(DEAD), 0, "nothing could be burned");
        assertEq(hook.burnOwed(), 0.5 ether, "the burn half stays owed");
        assertEq(hook.totalBurned(), 0);
        assertEq(imd.balanceOf(address(hook)), 1 ether, "the hook holds the whole fee");
        assertEq(hook.floatBalance(), 0.5 ether, "only the float half backs tenders");
        assertEq(hook.bookValuePerPerk(), 0.5 ether * 1e18 / perk.totalSupply());

        // burn() is a no-op while blocked, and never reverts.
        assertEq(hook.burn(), 0);
        assertEq(hook.burnOwed(), 0.5 ether);

        // A tender pays from the float half only.
        uint256 payout = hook.tender(100_000_000 ether);
        assertEq(payout, 100_000_000 ether * 0.5 ether / perk.totalSupply());
        assertEq(hook.burnOwed(), 0.5 ether);

        // Unblocked: the next trigger sends exactly what is owed.
        blockable.setBlocked(DEAD, false);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PerkVaultHook.Burned(0.5 ether);
        assertEq(hook.burn(), 0.5 ether);
        assertEq(hook.burnOwed(), 0);
        assertEq(hook.totalBurned(), 0.5 ether);
        assertEq(imd.balanceOf(DEAD), 0.5 ether);
        _assertImdConserved();
    }

    function test_askRunsTheBurnFirstAndCountsOnlyTheFloat() public {
        _addFullRangeLiquidity(1e24);
        blockable.setBlocked(DEAD, true);
        _buyExactIn(100 ether); // hook holds 1 IMD, 0.5 owed
        assertEq(hook.floatBalance(), 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(PerkVaultHook.FloatTooSmall.selector, 0.5 ether));
        hook.ask();
        _buyExactIn(100 ether); // hook holds 2 IMD, 1 owed
        hook.ask(); // float 1.0 >= 0.6
        assertEq(imd.balanceOf(address(hook)), 2 ether - 0.6 ether);
        assertEq(hook.burnOwed(), 1 ether, "ask never spends the burn half");
        blockable.setBlocked(DEAD, false);
        hook.burn();
        assertEq(imd.balanceOf(DEAD), 1 ether);
        assertEq(imd.balanceOf(address(hook)), 0.4 ether);
    }

    /// @dev When IMD refuses the transfer *to the hook* inside the swap, the fee is deferred as a
    /// claim, as in #1330, and still split once.
    function test_feeDeferredWhenImdRefusesTheHook() public {
        _addFullRangeLiquidity(1e24);
        blockable.setBlocked(address(hook), true);
        Snapshot memory s = _snapshot();
        _buyExactIn(100 ether);
        assertEq(hook.pendingFloat(), 1 ether);
        assertEq(hook.burnOwed(), 0.5 ether);
        assertEq(hook.totalFloat(), 0.5 ether);
        assertEq(imd.balanceOf(address(hook)), s.hookImd);
        vm.expectRevert();
        hook.redeemPendingFees();
        blockable.setBlocked(address(hook), false);
        hook.redeemPendingFees();
        assertEq(hook.pendingFloat(), 0);
        assertEq(imd.balanceOf(DEAD), 0.5 ether);
        assertEq(imd.balanceOf(address(hook)), 0.5 ether);
        assertEq(hook.totalFloat(), 0.5 ether, "not counted twice");
    }
}

/// @notice A token that calls back into the vault during a payout cannot re-enter a tender.
contract PerkVaultHookReentrancyTest is PerkVaultBase {
    ReenteringERC20 reentering;

    function _newImd() internal override returns (MockERC20) {
        reentering = new ReenteringERC20("IMD", "IMD", IMD_SUPPLY);
        return reentering;
    }

    function test_tenderPayoutCannotReenterTender() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        reentering.arm(address(this), address(hook));
        uint256 payout = hook.tender(1_000_000 ether);
        assertGt(payout, 0);
        assertTrue(reentering.reentered(), "the callback did not fire");
        // The inner call reverted with the guard's error, bubbled through the token's revert check.
        assertEq(bytes4(reentering.lastReason()), PerkVaultHook.Reentrancy.selector);
        assertEq(hook.totalTendered(), 1_000_000 ether, "only the outer tender counted");
    }

    function test_askRewardCannotReenterTender() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        reentering.arm(address(this), address(hook));
        hook.ask();
        assertTrue(reentering.reentered());
        assertEq(bytes4(reentering.lastReason()), PerkVaultHook.Reentrancy.selector);
        assertEq(hook.totalTendered(), 0);
    }
}
