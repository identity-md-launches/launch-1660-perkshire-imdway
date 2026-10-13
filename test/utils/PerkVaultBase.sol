// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {PerkVaultHook} from "../../src/PerkVaultHook.sol";
import {PerkToken} from "../../src/PerkToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookDeployer} from "./HookDeployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIntake} from "../mocks/MockIntake.sol";

/// @dev A separate CREATE2 deployer, so a second hook can be mined without colliding with the first.
contract FreshDeployer {
    function deploy(bytes memory creationCode, uint160 flags) external returns (address) {
        return HookDeployer.deployAtFlags(creationCode, flags);
    }
}

/// @notice Shared fixture: a PoolManager, the PERK token, an IMD stand-in, the hook bound to the
/// launch pool by the factory, and a mock Intake etched at the live Intake's address.
abstract contract PerkVaultBase is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant IMD_SUPPLY = 1e30;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 imd;
    PerkToken perk;
    PerkVaultHook hook;
    MockIntake intake;
    PoolKey key;
    bool perkIsZero;

    address factory = makeAddr("factory");
    address stranger = makeAddr("stranger");

    function _newImd() internal virtual returns (MockERC20) {
        return new MockERC20("IMD", "IMD", IMD_SUPPLY);
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        imd = _newImd();
        perk = new PerkToken();

        hook = _deployHook(address(manager), address(perk), address(imd), factory);

        perkIsZero = address(perk) < address(imd);
        key = _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING);
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        intake = MockIntake(address(hook.INTAKE()));
        vm.etch(address(intake), address(new MockIntake()).code);

        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        perk.approve(address(swapRouter), type(uint256).max);
        perk.approve(address(lpRouter), type(uint256).max);
        perk.approve(address(hook), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment helpers
    // ---------------------------------------------------------------------------------------------

    function _creationCode(address manager_, address perk_, address imd_, address factory_)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(PerkVaultHook).creationCode, abi.encode(manager_, perk_, imd_, factory_));
    }

    function _deployHook(address manager_, address perk_, address imd_, address factory_)
        internal
        returns (PerkVaultHook)
    {
        return PerkVaultHook(HookDeployer.deployAtFlags(_creationCode(manager_, perk_, imd_, factory_), FLAGS));
    }

    function _tryDeployHook(address manager_, address perk_, address imd_, address factory_)
        internal
        returns (address)
    {
        return HookDeployer.tryDeployAtFlags(_creationCode(manager_, perk_, imd_, factory_), FLAGS);
    }

    uint256 internal freshHooks;

    /// @dev A second, unbound hook for binding tests, deployed from a fresh CREATE2 deployer so its
    /// salt search does not collide with the hook already at the mined address.
    function _freshHook() internal returns (PerkVaultHook) {
        freshHooks += 1;
        FreshDeployer d = new FreshDeployer{salt: bytes32(freshHooks)}();
        return PerkVaultHook(d.deploy(_creationCode(address(manager), address(perk), address(imd), factory), FLAGS));
    }

    function _keyFor(Currency a, Currency b, uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return _keyFor(a, b, fee, spacing, address(hook));
    }

    function _keyFor(Currency a, Currency b, uint24 fee, int24 spacing, address hook_)
        internal
        pure
        returns (PoolKey memory)
    {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: IHooks(hook_)});
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity and swap helpers
    // ---------------------------------------------------------------------------------------------

    function _addFullRangeLiquidity(int256 liquidity) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), liquidity, bytes32(0)
            ),
            ""
        );
    }

    /// @dev Liquidity entirely on the PERK side of the current price, the shape the launch seeds.
    function _addPerkOnlyLiquidity(int256 liquidity) internal {
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(_perkOnlyLower(), _perkOnlyUpper(), liquidity, bytes32(0)), ""
        );
    }

    function _perkOnlyLower() internal view returns (int24) {
        return perkIsZero ? TICK_SPACING : TickMath.minUsableTick(TICK_SPACING);
    }

    function _perkOnlyUpper() internal view returns (int24) {
        return perkIsZero ? TickMath.maxUsableTick(TICK_SPACING) : -TICK_SPACING;
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _limitTicksAway(bool zeroForOne, int24 ticks) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(zeroForOne ? -ticks : ticks);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swapWithLimit(zeroForOne, amountSpecified, _limit(zeroForOne));
    }

    function _swapWithLimit(bool zeroForOne, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    /// @dev IMD in, PERK out.
    function _buyExactIn(uint256 imdIn) internal returns (BalanceDelta) {
        return _swap(!perkIsZero, -int256(imdIn));
    }

    function _buyExactOut(uint256 perkOut) internal returns (BalanceDelta) {
        return _swap(!perkIsZero, int256(perkOut));
    }

    /// @dev PERK in, IMD out.
    function _sellExactIn(uint256 perkIn) internal returns (BalanceDelta) {
        return _swap(perkIsZero, -int256(perkIn));
    }

    function _sellExactOut(uint256 imdOut) internal returns (BalanceDelta) {
        return _swap(perkIsZero, int256(imdOut));
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return perkIsZero ? delta.amount1() : delta.amount0();
    }

    // ---------------------------------------------------------------------------------------------
    // Accounting helpers
    // ---------------------------------------------------------------------------------------------

    struct Snapshot {
        uint256 swapperImd;
        uint256 swapperPerk;
        uint256 managerImd;
        uint256 hookImd;
        uint256 deadImd;
        uint256 deadPerk;
        uint256 burnOwed;
        uint256 totalBurned;
        uint256 totalFloat;
        uint256 pendingFloat;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.swapperImd = imd.balanceOf(address(this));
        s.swapperPerk = perk.balanceOf(address(this));
        s.managerImd = imd.balanceOf(address(manager));
        s.hookImd = imd.balanceOf(address(hook));
        s.deadImd = imd.balanceOf(DEAD);
        s.deadPerk = perk.balanceOf(DEAD);
        s.burnOwed = hook.burnOwed();
        s.totalBurned = hook.totalBurned();
        s.totalFloat = hook.totalFloat();
        s.pendingFloat = hook.pendingFloat();
    }

    /// @dev IMD the hook took in since `s`, paid or deferred: what the burn and the float split.
    function _feeSince(Snapshot memory s) internal view returns (uint256) {
        return (hook.totalFloat() - s.totalFloat) + (hook.totalBurned() + hook.burnOwed() - s.totalBurned - s.burnOwed);
    }

    /// @dev A fee that was paid at once: half went to 0x…dEaD, the rest stays in the hook, nothing
    /// is pending and nothing is owed.
    function _assertPaidFeeSplit(Snapshot memory s, uint256 fee) internal view {
        assertEq(imd.balanceOf(DEAD) - s.deadImd, fee / 2, "dead did not get half");
        assertEq(imd.balanceOf(address(hook)) - s.hookImd, fee - fee / 2, "hook did not keep the other half");
        assertEq(hook.totalBurned() - s.totalBurned, fee / 2, "totalBurned");
        assertEq(hook.totalFloat() - s.totalFloat, fee - fee / 2, "totalFloat");
        assertEq(hook.burnOwed(), s.burnOwed, "burnOwed changed");
        assertEq(hook.pendingFloat(), 0, "something is pending");
        assertEq(perk.balanceOf(address(hook)), 0, "hook holds PERK");
    }

    /// @dev Every IMD unit is with the swapper, the pool, the hook, the dead address, the intake or
    /// a named stranger.
    function _assertImdConserved(address[] memory others) internal view {
        uint256 total = imd.balanceOf(address(this)) + imd.balanceOf(address(manager)) + imd.balanceOf(address(hook))
            + imd.balanceOf(DEAD) + imd.balanceOf(address(intake));
        for (uint256 i = 0; i < others.length; i++) {
            total += imd.balanceOf(others[i]);
        }
        assertEq(total, IMD_SUPPLY, "IMD leaked");
    }

    function _assertImdConserved() internal view {
        _assertImdConserved(new address[](0));
    }

    function _bookValue() internal view returns (uint256) {
        return hook.bookValuePerPerk();
    }
}
