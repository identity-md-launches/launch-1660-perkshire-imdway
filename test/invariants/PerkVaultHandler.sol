// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {PerkVaultHook} from "../../src/PerkVaultHook.sol";
import {PerkToken} from "../../src/PerkToken.sol";
import {BlocklistERC20} from "../mocks/BlocklistERC20.sol";

/// @notice Drives the vault with bounded inputs from several actors, in random order, and keeps the
/// ghost totals the invariants are checked against. Every function is non-reverting: a revert the
/// pool or the vault is expected to produce is caught and, where the outcome is decidable in
/// advance, asserted; anything else fails the run (`fail_on_revert` is on).
contract PerkVaultHandler is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 constant TICK_SPACING = 60;

    PoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    BlocklistERC20 public immutable imd;
    PerkToken public immutable perk;
    PerkVaultHook public immutable hook;
    address public immutable intake;
    PoolKey public key;
    bool public immutable perkIsZero;

    address[] public actors;

    // ---------------------------------------------------------------------------------------------
    // Ghost state
    // ---------------------------------------------------------------------------------------------

    /// @dev IMD paid to tendering holders, over all time.
    uint256 public ghostTenderedOut;
    /// @dev IMD that left the hook through `ask()` (0.5 to the Intake, 0.1 to the caller).
    uint256 public ghostAskedOut;
    /// @dev IMD paid to callers of `ask()`.
    uint256 public ghostAskRewards;
    /// @dev IMD sent to the hook outside the fee path.
    uint256 public ghostDonated;
    /// @dev Swaps that went through: an upper bound on the number of fees ever taken.
    uint256 public ghostSwaps;
    /// @dev Swaps that were deferred (the whole fee left pending) at the moment they ran.
    uint256 public ghostDeferredSwaps;
    /// @dev Claim-inclusive book value per PERK after the last action that is not allowed to lower it.
    uint256 public ghostBookValueFloor;
    /// @dev Calls that reached each path, so a run that never exercised one is visible.
    uint256 public ghostTenders;
    uint256 public ghostAsks;
    uint256 public ghostRedeems;
    uint256 public ghostBurns;
    uint256 public ghostZeroPayoutReverts;
    /// @dev Whether the IMD stand-in refuses transfers to 0x…dEaD / to the hook right now.
    bool public deadBlocked;
    bool public hookBlocked;

    constructor(
        PoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        BlocklistERC20 imd_,
        PerkToken perk_,
        PerkVaultHook hook_,
        PoolKey memory key_,
        address[] memory actors_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        imd = imd_;
        perk = perk_;
        hook = hook_;
        key = key_;
        perkIsZero = address(perk_) < address(imd_);
        intake = address(hook_.INTAKE());
        actors = actors_;
        for (uint256 i = 0; i < actors_.length; i++) {
            vm.startPrank(actors_[i]);
            imd_.approve(address(swapRouter_), type(uint256).max);
            imd_.approve(address(lpRouter_), type(uint256).max);
            perk_.approve(address(swapRouter_), type(uint256).max);
            perk_.approve(address(lpRouter_), type(uint256).max);
            perk_.approve(address(hook_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: the four modes
    // ---------------------------------------------------------------------------------------------

    /// @dev IMD in (specified), PERK out. The fee is 1% of the trader's IMD on a full fill and 1%
    /// of what the pool took on a short one; either way the trader pays exactly fill + fee.
    function buyExactIn(uint256 actorSeed, uint256 amountIn) external {
        address actor = _actor(actorSeed);
        if (imd.balanceOf(actor) == 0) return;
        amountIn = bound(amountIn, 1, _min(imd.balanceOf(actor), 1e22));
        Snap memory s = _snap(actor);
        bool ok = _trySwap(actor, !perkIsZero, -int256(amountIn));
        if (!ok) return;
        uint256 fee = _feeSince(s);
        uint256 paid = s.actorImd - imd.balanceOf(actor);
        // What the pool kept is what the trader paid less the fee (the hook may have taken the fee
        // out of the manager within the swap, so measure it from the trader's side).
        uint256 filled = paid - fee;
        assertLe(paid, amountIn, "buy exact-in: trader paid more than specified");
        assertGe(fee, filled / 100, "buy exact-in: fee under 1% of the fill");
        assertLe(fee, paid / 100, "buy exact-in: fee over 1% of what was paid");
        if (paid == amountIn) assertEq(fee, amountIn / 100, "buy exact-in: full fill is not 1% of amountIn");
        _afterSwap(s);
    }

    /// @dev PERK out (specified), IMD in (unspecified): the fee is exactly 1% of the IMD the pool took.
    function buyExactOut(uint256 actorSeed, uint256 perkOut) external {
        address actor = _actor(actorSeed);
        perkOut = bound(perkOut, 1, 1e22);
        Snap memory s = _snap(actor);
        bool ok = _trySwap(actor, !perkIsZero, int256(perkOut));
        if (!ok) return;
        uint256 fee = _feeSince(s);
        uint256 paid = s.actorImd - imd.balanceOf(actor);
        // A short fill (liquidity ran out) delivers less; never more.
        assertLe(perk.balanceOf(actor) - s.actorPerk, perkOut, "buy exact-out: delivered more than asked");
        assertEq(fee, (paid - fee) / 100, "buy exact-out: fee is not 1% of the IMD the pool took");
        _afterSwap(s);
    }

    /// @dev PERK in (specified), IMD out (unspecified): the fee is exactly 1% of the IMD the pool paid.
    function sellExactIn(uint256 actorSeed, uint256 perkIn) external {
        address actor = _actor(actorSeed);
        if (perk.balanceOf(actor) == 0) return; // tendered everything
        perkIn = bound(perkIn, 1, _min(perk.balanceOf(actor), 1e22));
        Snap memory s = _snap(actor);
        bool ok = _trySwap(actor, perkIsZero, -int256(perkIn));
        if (!ok) return;
        uint256 fee = _feeSince(s);
        uint256 received = imd.balanceOf(actor) - s.actorImd;
        assertLe(s.actorPerk - perk.balanceOf(actor), perkIn, "sell exact-in: took more than specified");
        assertEq(fee, (received + fee) / 100, "sell exact-in: fee is not 1% of the IMD the pool paid");
        _afterSwap(s);
    }

    /// @dev IMD out (specified), PERK in. 1% of the requested IMD on a full fill, 1% of the IMD the
    /// pool moved on a short one.
    function sellExactOut(uint256 actorSeed, uint256 imdOut) external {
        address actor = _actor(actorSeed);
        imdOut = bound(imdOut, 1, 1e22);
        Snap memory s = _snap(actor);
        bool ok = _trySwap(actor, perkIsZero, int256(imdOut));
        if (!ok) return;
        uint256 fee = _feeSince(s);
        uint256 received = imd.balanceOf(actor) - s.actorImd;
        assertLe(received, imdOut, "sell exact-out: received more than specified");
        assertGe(fee, received / 100, "sell exact-out: fee under 1% of what was received");
        assertLe(fee, (received + fee) / 100, "sell exact-out: fee over 1% of what the pool moved");
        if (received == imdOut) assertEq(fee, imdOut / 100, "sell exact-out: full fill is not 1% of imdOut");
        _afterSwap(s);
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity, so sells have IMD to take and the pool is not stuck PERK-only for ever
    // ---------------------------------------------------------------------------------------------

    function addFullRangeLiquidity(uint256 actorSeed, uint256 liquidity) external {
        address actor = _actor(actorSeed);
        liquidity = bound(liquidity, 1e18, 1e23);
        uint256 bv = hook.bookValuePerPerk();
        vm.prank(actor);
        try lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING),
                TickMath.maxUsableTick(TICK_SPACING),
                int256(liquidity),
                bytes32(0)
            ),
            ""
        ) {}
            catch {}
        assertEq(hook.bookValuePerPerk(), bv, "adding liquidity moved book value");
        _noteBookValue();
    }

    // ---------------------------------------------------------------------------------------------
    // The vault
    // ---------------------------------------------------------------------------------------------

    /// @dev A tender pays exactly the rounded-down pro-rata share of the float, or reverts with
    /// ZeroPayout when that is zero. It never lowers book value.
    function tender(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 balance = perk.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        // The burn `tender` runs first does not move the float (balance and owed fall together).
        uint256 float_ = hook.floatBalance();
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        uint256 expected = amount * float_ / circulating;
        uint256 bvBefore = hook.bookValuePerPerk();
        uint256 deadPerkBefore = perk.balanceOf(DEAD);
        uint256 actorImdBefore = imd.balanceOf(actor);

        vm.prank(actor);
        try hook.tender(amount) returns (uint256 payout) {
            assertGt(expected, 0, "tender went through with a zero expected payout");
            assertEq(payout, expected, "tender paid other than the pro-rata share");
            assertLe(payout * circulating, amount * float_, "tender paid above pro rata");
            assertEq(imd.balanceOf(actor) - actorImdBefore, payout, "holder received other than the payout");
            assertEq(perk.balanceOf(DEAD) - deadPerkBefore, amount, "tendered PERK did not reach dEaD");
            assertEq(perk.balanceOf(address(hook)), 0, "hook kept PERK");
            ghostTenderedOut += payout;
            ghostTenders += 1;
            if (perk.totalSupply() > perk.balanceOf(DEAD)) {
                assertGe(hook.bookValuePerPerk(), bvBefore, "a tender lowered book value");
            }
        } catch (bytes memory reason) {
            if (hookBlocked && bytes4(reason) == PerkVaultHook.TransferFailed.selector) {
                // IMD refuses to leave a blocked hook: the tender fails whole, nothing moves.
                assertGt(expected, 0, "a blocked hook failed a tender that was zero anyway");
            } else {
                assertEq(bytes4(reason), PerkVaultHook.ZeroPayout.selector, "tender reverted for another reason");
                assertEq(expected, 0, "tender refused a non-zero payout");
                ghostZeroPayoutReverts += 1;
            }
            assertEq(perk.balanceOf(DEAD), deadPerkBefore, "a failed tender burned PERK");
            assertEq(imd.balanceOf(actor), actorImdBefore, "a failed tender paid IMD");
        }
        _noteBookValue();
    }

    /// @dev `burn()` never reverts. When IMD accepts the transfer it leaves either nothing owed or
    /// nothing in the hook; when it refuses, nothing changes.
    function burn() external {
        uint256 owedBefore = hook.burnOwed();
        uint256 deadBefore = imd.balanceOf(DEAD);
        uint256 float_ = hook.floatBalance();
        uint256 sent = hook.burn();
        assertEq(imd.balanceOf(DEAD) - deadBefore, sent, "burn sent other than it reported");
        assertEq(owedBefore - hook.burnOwed(), sent, "burnOwed did not fall by what was sent");
        assertEq(hook.floatBalance(), float_, "a burn moved the float");
        if (deadBlocked || hookBlocked) {
            assertEq(sent, 0, "burned while IMD refused the transfer");
        } else {
            assertTrue(hook.burnOwed() == 0 || imd.balanceOf(address(hook)) == 0, "burn left IMD and debt");
        }
        ghostBurns += 1;
        _noteBookValue();
    }

    /// @dev Redeeming moves pending claims to the hook as IMD and changes no counter: nothing is
    /// counted twice. It can only fail when there is nothing to redeem or IMD refuses the hook.
    function redeemPendingFees(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 pendingBefore = hook.pendingFloat();
        uint256 totalFloatBefore = hook.totalFloat();
        uint256 burnPartBefore = hook.burnOwed() + hook.totalBurned();
        uint256 hookImdBefore = imd.balanceOf(address(hook));
        uint256 deadBefore = imd.balanceOf(DEAD);
        uint256 redeemable = _min(pendingBefore, imd.balanceOf(address(manager)));
        vm.prank(actor);
        try hook.redeemPendingFees() returns (uint256 amount) {
            assertGt(amount, 0, "redeemed nothing");
            assertEq(amount, redeemable, "redeemed other than what the manager could pay");
            assertEq(pendingBefore - hook.pendingFloat(), amount, "pending did not fall by the redeemed amount");
            assertEq(
                imd.balanceOf(address(hook)) + imd.balanceOf(DEAD) - hookImdBefore - deadBefore,
                amount,
                "redeemed IMD did not all land in the hook or dEaD"
            );
            assertEq(hook.totalFloat(), totalFloatBefore, "redeem counted the float half again");
            assertEq(hook.burnOwed() + hook.totalBurned(), burnPartBefore, "redeem counted the burn half again");
            ghostRedeems += 1;
        } catch {
            assertTrue(redeemable == 0 || hookBlocked, "redeem failed with something redeemable and IMD willing");
        }
        _noteBookValue();
    }

    /// @dev `ask()` is decidable in advance: too soon, too poor, or it pays exactly 0.5 to the
    /// Intake and 0.1 to the caller and leaves no allowance.
    function ask(uint256 actorSeed, uint256 warpBy) external {
        address actor = _actor(actorSeed);
        warpBy = bound(warpBy, 0, 8 days);
        vm.warp(block.timestamp + warpBy);
        uint256 lastAsk = hook.lastAsk();
        bool tooSoon = lastAsk != 0 && block.timestamp < lastAsk + hook.ASK_INTERVAL();
        uint256 float_ = hook.floatBalance(); // unchanged by the burn `ask` runs first
        uint256 intakeBefore = imd.balanceOf(intake);
        uint256 actorBefore = imd.balanceOf(actor);
        uint256 askedBefore = hook.totalAsked();
        uint256 hookBefore = imd.balanceOf(address(hook));
        uint256 deadBefore = imd.balanceOf(DEAD);

        vm.prank(actor);
        try hook.ask() returns (bytes32 requestId) {
            assertFalse(tooSoon, "ask went through inside 7 days");
            assertGe(float_, 0.6 ether, "ask went through under 0.6 IMD");
            assertTrue(requestId != bytes32(0));
            assertEq(imd.balanceOf(intake) - intakeBefore, 0.5 ether, "Intake paid other than 0.5");
            assertEq(imd.balanceOf(actor) - actorBefore, 0.1 ether, "caller paid other than 0.1");
            assertEq(
                hookBefore - imd.balanceOf(address(hook)) - (imd.balanceOf(DEAD) - deadBefore),
                0.6 ether,
                "ask spent other than 0.6 beyond the burn"
            );
            assertEq(imd.allowance(address(hook), intake), 0, "ask left an allowance");
            assertEq(hook.totalAsked(), askedBefore + 1);
            assertEq(hook.lastAsk(), block.timestamp);
            if (lastAsk != 0) assertGe(block.timestamp - lastAsk, 7 days, "two asks closer than 7 days");
            ghostAskedOut += 0.6 ether;
            ghostAskRewards += 0.1 ether;
            ghostAsks += 1;
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            if (tooSoon) {
                assertEq(sel, PerkVaultHook.AskTooSoon.selector, "ask inside 7 days reverted for another reason");
            } else if (sel == PerkVaultHook.FloatTooSmall.selector) {
                assertLt(float_, 0.6 ether, "ask refused a float of at least 0.6");
            } else {
                // Only a blocked hook, whose IMD cannot be pulled by the Intake or paid to the
                // caller, may fail an otherwise valid ask.
                assertTrue(hookBlocked, "ask reverted for another reason");
                assertGe(float_, 0.6 ether, "a blocked hook failed an ask that was too poor anyway");
            }
            assertEq(
                imd.balanceOf(address(hook)) + (imd.balanceOf(DEAD) - deadBefore), hookBefore, "a failed ask moved IMD"
            );
            assertEq(hook.totalAsked(), askedBefore, "a failed ask was counted");
            assertEq(hook.lastAsk(), lastAsk, "a failed ask moved lastAsk");
            assertEq(imd.balanceOf(intake), intakeBefore, "a failed ask paid the Intake");
            assertEq(imd.allowance(address(hook), intake), 0, "a failed ask left an allowance");
        }
        // An ask spends float: it may lower book value, so the floor restarts here.
        ghostBookValueFloor = claimInclusiveBookValue();
    }

    /// @dev Anyone may send IMD to the hook; it joins the float and touches no counter.
    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        if (hookBlocked) return; // IMD refuses the transfer; nothing to observe.
        amount = bound(amount, 0, _min(imd.balanceOf(actor), 1e21));
        uint256 owed = hook.burnOwed();
        uint256 totalFloat = hook.totalFloat();
        uint256 bv = hook.bookValuePerPerk();
        vm.prank(actor);
        imd.transfer(address(hook), amount);
        ghostDonated += amount;
        assertEq(hook.burnOwed(), owed, "a donation changed burnOwed");
        assertEq(hook.totalFloat(), totalFloat, "a donation was counted as a fee");
        assertGe(hook.bookValuePerPerk(), bv, "a donation lowered book value");
        _noteBookValue();
    }

    /// @dev The live IMD has an admin blocklist; flip it for 0x…dEaD and for the hook.
    function setDeadBlocked(bool on) external {
        imd.setBlocked(DEAD, on);
        deadBlocked = on;
    }

    function setHookBlocked(bool on) external {
        imd.setBlocked(address(hook), on);
        hookBlocked = on;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    struct Snap {
        uint256 actorImd;
        uint256 actorPerk;
        uint256 managerImd;
        uint256 hookImd;
        uint256 pending;
        uint256 totalFloat;
        uint256 burnOwed;
        uint256 totalBurned;
        uint256 bookValue;
    }

    function _snap(address actor) internal view returns (Snap memory s) {
        s.actorImd = imd.balanceOf(actor);
        s.actorPerk = perk.balanceOf(actor);
        s.managerImd = imd.balanceOf(address(manager));
        s.hookImd = imd.balanceOf(address(hook));
        s.pending = hook.pendingFloat();
        s.totalFloat = hook.totalFloat();
        s.burnOwed = hook.burnOwed();
        s.totalBurned = hook.totalBurned();
        s.bookValue = hook.bookValuePerPerk();
    }

    /// @dev Every fee is counted once, at the moment it is taken: the float half in `totalFloat`,
    /// the burn half in `burnOwed` or `totalBurned`.
    function _feeSince(Snap memory s) internal view returns (uint256) {
        return (hook.totalFloat() - s.totalFloat) + (hook.totalBurned() + hook.burnOwed() - s.totalBurned - s.burnOwed);
    }

    function _afterSwap(Snap memory s) internal {
        ghostSwaps += 1;
        uint256 fee = _feeSince(s);
        assertEq(hook.totalFloat() - s.totalFloat, fee - fee / 2, "float half is not the rounded-up half");
        assertEq(
            hook.totalBurned() + hook.burnOwed() - s.totalBurned - s.burnOwed, fee / 2, "burn half is not floor(fee/2)"
        );
        if (hook.pendingFloat() > s.pending) {
            // Deferred: the whole fee is a claim and none of it reached the hook. Its burn half is
            // owed at once and is paid from whatever IMD the hook already holds, so the book value
            // *view* can fall by up to fee/2 until the claim is redeemed (see the findings file).
            // Counting the claim, book value still rises: `_noteBookValue` checks that.
            assertEq(hook.pendingFloat() - s.pending, fee, "deferred other than the whole fee");
            ghostDeferredSwaps += 1;
        } else {
            assertGe(hook.bookValuePerPerk(), s.bookValue, "a paid-at-once swap lowered book value");
        }
        assertEq(perk.balanceOf(address(hook)), 0, "the hook took PERK");
        _noteBookValue();
    }

    /// @notice Book value per PERK counting the fees still pending in the manager, which the view
    /// does not count. This is the measure that nothing but `ask()` may lower.
    function claimInclusiveBookValue() public view returns (uint256) {
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        if (circulating == 0) return 0;
        uint256 assets = imd.balanceOf(address(hook)) + hook.pendingFloat();
        uint256 owed = hook.burnOwed();
        assertGe(assets, owed, "owed more than cash plus pending");
        return (assets - owed) * 1e18 / circulating;
    }

    function _trySwap(address actor, bool zeroForOne, int256 amountSpecified) internal returns (bool) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(actor);
        try swapRouter.swap(
            key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _noteBookValue() internal {
        uint256 bv = claimInclusiveBookValue();
        assertGe(bv, ghostBookValueFloor, "claim-inclusive book value fell outside an ask");
        ghostBookValueFloor = bv;
        // The view never counts pending claims, so it is at most the claim-inclusive value.
        assertLe(hook.bookValuePerPerk(), bv, "the view counts pending claims");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
