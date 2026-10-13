// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {PerkVaultHook} from "../src/PerkVaultHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {PerkVaultBase} from "./utils/PerkVaultBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PerkVaultHookTest is PerkVaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev keccak256 of the brief's BODY, computed outside Solidity (`cast keccak`).
    bytes32 constant BODY_HASH = 0x0e84c095ed9c231763b35dc8959f58978742666369a6f19d78d0bbff1acb307b;

    // ---------------------------------------------------------------------------------------------
    // Deployment, permissions, access control
    // ---------------------------------------------------------------------------------------------

    function test_permissionsMatchTheAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertEq(FLAGS, 0x20CC);
    }

    function test_immutablesAndConstants() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.perk()), address(perk));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.factory(), factory);
        assertEq(hook.FEE_BPS(), 100);
        assertEq(hook.POOL_FEE(), 12_500);
        assertEq(hook.DEAD(), DEAD);
        assertEq(address(hook.INTAKE()), 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(hook.ACTION(), 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000);
        assertEq(hook.ASK_PRICE(), 0.5 ether);
        assertEq(hook.ASK_REWARD(), 0.1 ether);
        assertEq(hook.ASK_MINIMUM(), 0.6 ether);
        assertEq(hook.ASK_INTERVAL(), 7 days);
        assertEq(keccak256(bytes(hook.BODY())), BODY_HASH, "BODY differs from the brief byte for byte");
        assertEq(bytes(hook.BODY()).length, 402);
        assertEq(hook.feeFor(100 ether), 1 ether);
        assertEq(hook.totalFloat(), 0);
        assertEq(hook.pendingFloat(), 0);
        assertEq(hook.burnOwed(), 0);
        assertEq(hook.totalBurned(), 0);
        assertEq(hook.lastAsk(), 0);
        assertEq(hook.totalAsked(), 0);
        assertEq(hook.totalTendered(), 0);
        assertEq(hook.bookValuePerPerk(), 0, "book value starts at zero");
    }

    function test_constructorRejectsZeroAndEqualAddresses() public {
        assertEq(_tryDeployHook(address(0), address(perk), address(imd), factory), address(0), "zero manager");
        assertEq(_tryDeployHook(address(manager), address(0), address(imd), factory), address(0), "zero perk");
        assertEq(_tryDeployHook(address(manager), address(perk), address(0), factory), address(0), "zero imd");
        assertEq(_tryDeployHook(address(manager), address(perk), address(imd), address(0)), address(0), "zero factory");
        assertEq(_tryDeployHook(address(manager), address(imd), address(imd), factory), address(0), "perk == imd");
    }

    function test_constructorRejectsAnAddressWithoutTheRightFlags() public {
        bytes memory code = _creationCode(address(manager), address(perk), address(imd), factory);
        assertEq(HookDeployer.tryDeployAtFlags(code, FLAGS ^ HookFlags.AFTER_SWAP), address(0), "missing flag");
        assertEq(HookDeployer.tryDeployAtFlags(code, FLAGS | HookFlags.BEFORE_DONATE), address(0), "extra flag");
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));

        vm.startPrank(factory);
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, zero, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(PerkVaultHook.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function test_unusedCallbacksRevertEvenFromTheManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.startPrank(address(manager));
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(PerkVaultHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function test_simulateSwapRefusesEveryoneButTheHook() public {
        SwapParams memory params = SwapParams(!perkIsZero, -100 ether, _limit(!perkIsZero));
        vm.expectRevert(PerkVaultHook.NotSelf.selector);
        hook.simulateSwap(key, params);
        vm.prank(address(manager));
        vm.expectRevert(PerkVaultHook.NotSelf.selector);
        hook.simulateSwap(key, params);
    }

    /// @dev No owner, no setter, no rescue: every common administrative selector fails from anyone,
    /// and the hook refuses ETH.
    function test_noPrivilegedFunctions() public {
        string[18] memory signatures = [
            "setFeeRecipient(address)",
            "setFee(uint256)",
            "setIntake(address)",
            "setFactory(address)",
            "setBody(bytes)",
            "transferOwnership(address)",
            "setOwner(address)",
            "renounceOwnership()",
            "owner()",
            "pause()",
            "unpause()",
            "mint(address,uint256)",
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address)",
            "skim(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, uint256(1));
            vm.prank(stranger);
            (bool okStranger,) = address(hook).call(data);
            assertFalse(okStranger, signatures[i]);
            vm.prank(factory);
            (bool okFactory,) = address(hook).call(data);
            assertFalse(okFactory, signatures[i]);
        }
        (bool okEth,) = address(hook).call{value: 1 wei}("");
        assertFalse(okEth);
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Binding
    // ---------------------------------------------------------------------------------------------

    function test_factoryBindsTheLaunchPool() public view {
        assertEq(PoolId.unwrap(hook.boundPool()), PoolId.unwrap(key.toId()));
        (uint160 price,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(lpFee, POOL_FEE, "the hook must not touch the LP fee");
    }

    function test_bindingEmitsPoolBound() public {
        PerkVaultHook fresh = _freshHook();
        PoolKey memory k =
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, 10, address(fresh));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit PerkVaultHook.PoolBound(k.toId(), 10);
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(fresh.boundPool()), PoolId.unwrap(k.toId()), "tick spacing is not hard-coded");
    }

    function test_initializeRefusesANonFactorySender() public {
        PerkVaultHook fresh = _freshHook();
        PoolKey memory k =
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING, address(fresh));
        vm.expectRevert(_initRevert(address(fresh), PerkVaultHook.NotFactory.selector));
        vm.prank(stranger);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(fresh.boundPool()), bytes32(0), "nothing bound");
        // The factory still can.
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesAFakeTokenWithImd() public {
        PerkVaultHook fresh = _freshHook();
        MockERC20 fake = new MockERC20("Fake PERK", "PERK", 1e27);
        PoolKey memory k =
            _keyFor(Currency.wrap(address(fake)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING, address(fresh));
        vm.prank(factory);
        vm.expectRevert(_initRevert(address(fresh), PerkVaultHook.WrongCurrencies.selector));
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesAPoolWithoutImdOrWithEth() public {
        PerkVaultHook fresh = _freshHook();
        MockERC20 other = new MockERC20("Other", "OTHER", 1e27);
        PoolKey memory k = _keyFor(
            Currency.wrap(address(perk)), Currency.wrap(address(other)), POOL_FEE, TICK_SPACING, address(fresh)
        );
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        PoolKey memory eth =
            _keyFor(Currency.wrap(address(0)), Currency.wrap(address(perk)), POOL_FEE, TICK_SPACING, address(fresh));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(eth, SQRT_PRICE_1_1);
        PoolKey memory ethImd =
            _keyFor(Currency.wrap(address(0)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING, address(fresh));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(ethImd, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesWrongAndDynamicFees() public {
        PerkVaultHook fresh = _freshHook();
        PoolKey memory wrong =
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), 3_000, TICK_SPACING, address(fresh));
        vm.prank(factory);
        vm.expectRevert(_initRevert(address(fresh), PerkVaultHook.WrongFee.selector));
        manager.initialize(wrong, SQRT_PRICE_1_1);
        PoolKey memory zero =
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), 0, TICK_SPACING, address(fresh));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(zero, SQRT_PRICE_1_1);
        PoolKey memory dynamic = _keyFor(
            Currency.wrap(address(perk)),
            Currency.wrap(address(imd)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            address(fresh)
        );
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(dynamic, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(fresh.boundPool()), bytes32(0));
    }

    function test_initializeRefusesASecondPoolAndReinitialization() public {
        // Same tokens and fee, another tick spacing: a distinct pool. Refused even from the factory.
        PoolKey memory second = _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, 10);
        vm.prank(factory);
        vm.expectRevert(_initRevert(address(hook), PerkVaultHook.AlreadyBound.selector));
        manager.initialize(second, SQRT_PRICE_1_1);
        // The bound pool again: the hook (and the manager) refuse.
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1 * 2);
        assertEq(PoolId.unwrap(hook.boundPool()), PoolId.unwrap(key.toId()));
    }

    /// @dev Even the PoolManager's address cannot drive a swap callback for a pool that is not the
    /// bound one.
    function test_swapCallbacksRefuseAnUnboundPool() public {
        PoolKey memory other = _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, 10);
        SwapParams memory params = SwapParams(!perkIsZero, -100 ether, _limit(!perkIsZero));
        vm.startPrank(address(manager));
        vm.expectRevert(PerkVaultHook.NotBoundPool.selector);
        hook.beforeSwap(address(this), other, params, "");
        vm.expectRevert(PerkVaultHook.NotBoundPool.selector);
        hook.afterSwap(address(this), other, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    /// @dev The factory collects the pool's fees with a zero liquidity change; the hook has no
    /// remove-liquidity callbacks, so nothing can block it.
    function test_zeroLiquidityChangeGoesThrough() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(100 ether);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0, bytes32(0)
            ),
            ""
        );
    }

    // ---------------------------------------------------------------------------------------------
    // The fee: exactly 1% of the IMD side in all four swap modes, half burned, half kept
    // ---------------------------------------------------------------------------------------------

    function test_buyExactInput_takesOnePercentIntoTheVault() public {
        _addFullRangeLiquidity(1e24);
        uint256 amountIn = 100 ether;
        Snapshot memory s = _snapshot();

        vm.expectEmit(true, false, false, true, address(hook));
        emit PerkVaultHook.FloatCollected(key.toId(), 1 ether, 0.5 ether, 0.5 ether, true);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PerkVaultHook.Burned(0.5 ether);
        BalanceDelta delta = _buyExactIn(amountIn);

        uint256 fee = _feeSince(s);
        assertEq(fee, 1 ether, "fee is not 1%");
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn, "swapper paid other than amountIn");
        assertEq(imd.balanceOf(address(manager)) - s.managerImd, amountIn - fee, "pool got other than 99%");
        assertEq(uint256(uint128(-_imdDelta(delta))), amountIn);
        assertGt(perk.balanceOf(address(this)), s.swapperPerk, "swapper got no PERK");
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function test_sellExactInput_takesOnePercentIntoTheVault() public {
        _addFullRangeLiquidity(1e24);
        Snapshot memory s = _snapshot();

        BalanceDelta delta = _sellExactIn(1_000 ether);

        uint256 fee = _feeSince(s);
        uint256 received = imd.balanceOf(address(this)) - s.swapperImd;
        assertGt(fee, 0);
        assertEq(received, uint256(uint128(_imdDelta(delta))));
        assertEq(fee, (received + fee) / 100, "fee is not 1% of the IMD side");
        assertEq(s.managerImd - imd.balanceOf(address(manager)), received + fee);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function test_buyExactOutput_takesOnePercentIntoTheVault() public {
        _addFullRangeLiquidity(1e24);
        uint256 perkOut = 50 ether;
        Snapshot memory s = _snapshot();

        _buyExactOut(perkOut);

        uint256 fee = _feeSince(s);
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        assertGt(fee, 0);
        assertEq(perk.balanceOf(address(this)) - s.swapperPerk, perkOut, "exact output not honoured");
        assertEq(fee, (paid - fee) / 100, "fee is not 1% of the IMD side");
        assertEq(imd.balanceOf(address(manager)) - s.managerImd, paid - fee);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function test_sellExactOutput_takesOnePercentIntoTheVault() public {
        _addFullRangeLiquidity(1e24);
        uint256 imdOut = 100 ether;
        Snapshot memory s = _snapshot();

        _sellExactOut(imdOut);

        uint256 fee = _feeSince(s);
        assertEq(fee, 1 ether, "fee is not 1%");
        assertEq(imd.balanceOf(address(this)) - s.swapperImd, imdOut, "exact output not honoured");
        assertEq(s.managerImd - imd.balanceOf(address(manager)), imdOut + fee);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function test_oddFeeRoundsTheBurnDown() public {
        _addFullRangeLiquidity(1e24);
        Snapshot memory s = _snapshot();
        _buyExactIn(300); // fee 3 wei: 1 burned, 2 to the float
        assertEq(_feeSince(s), 3);
        assertEq(imd.balanceOf(DEAD) - s.deadImd, 1);
        assertEq(hook.totalFloat() - s.totalFloat, 2);
        assertEq(imd.balanceOf(address(hook)) - s.hookImd, 2);
    }

    function test_tinySwapWithZeroFeeStillSucceeds() public {
        _addFullRangeLiquidity(1e24);
        Snapshot memory s = _snapshot();
        _buyExactIn(99);
        assertEq(_feeSince(s), 0);
        assertEq(hook.pendingFloat(), 0);
    }

    function test_lpFeeIsUntouchedAndNoPerkIsEverTaken() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(10 ether);
        _sellExactIn(10 ether);
        _buyExactOut(10 ether);
        _sellExactOut(10 ether);
        assertEq(perk.balanceOf(address(hook)), 0);
        assertEq(perk.balanceOf(DEAD), 0, "no PERK is burned by swaps");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(perk)).toId()), 0);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, POOL_FEE);
        _assertImdConserved();
    }

    function testFuzz_buyExactInput_feeIsExactlyOnePercent(uint256 amountIn) public {
        _addFullRangeLiquidity(1e26);
        amountIn = bound(amountIn, 100, 1e24);
        Snapshot memory s = _snapshot();
        _buyExactIn(amountIn);
        uint256 fee = _feeSince(s);
        assertEq(fee, amountIn / 100);
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function testFuzz_sellExactInput_feeIsExactlyOnePercent(uint256 perkIn) public {
        _addFullRangeLiquidity(1e26);
        perkIn = bound(perkIn, 100, 1e24);
        Snapshot memory s = _snapshot();
        _sellExactIn(perkIn);
        uint256 fee = _feeSince(s);
        uint256 received = imd.balanceOf(address(this)) - s.swapperImd;
        assertEq(fee, (received + fee) / 100);
        assertEq(s.managerImd - imd.balanceOf(address(manager)), received + fee);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function testFuzz_sellExactOutput_feeIsExactlyOnePercent(uint256 imdOut) public {
        _addFullRangeLiquidity(1e26);
        imdOut = bound(imdOut, 100, 1e24);
        Snapshot memory s = _snapshot();
        _sellExactOut(imdOut);
        uint256 fee = _feeSince(s);
        assertEq(fee, imdOut / 100);
        assertEq(imd.balanceOf(address(this)) - s.swapperImd, imdOut);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function testFuzz_buyExactOutput_feeIsExactlyOnePercent(uint256 perkOut) public {
        _addFullRangeLiquidity(1e26);
        perkOut = bound(perkOut, 100, 1e24);
        Snapshot memory s = _snapshot();
        _buyExactOut(perkOut);
        uint256 fee = _feeSince(s);
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        assertEq(fee, (paid - fee) / 100);
        assertEq(perk.balanceOf(address(this)) - s.swapperPerk, perkOut);
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    function testFuzz_buyExactInputWithLimit_feeIsOnePercentOfTheFill(uint256 amountIn, uint24 ticks) public {
        _addFullRangeLiquidity(1e24);
        amountIn = bound(amountIn, 100, 1e25);
        ticks = uint24(bound(ticks, 1, 20_000));
        bool zeroForOne = !perkIsZero;
        Snapshot memory s = _snapshot();
        _swapWithLimit(zeroForOne, -int256(amountIn), _limitTicksAway(zeroForOne, int24(ticks)));
        uint256 fee = _feeSince(s);
        uint256 filled = imd.balanceOf(address(manager)) - s.managerImd;
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        assertEq(paid, filled + fee);
        if (paid == amountIn) assertEq(fee, amountIn / 100, "full fill: 1% of the trader's IMD");
        else assertEq(fee, filled / 100, "short fill: 1% of the IMD the pool took");
        _assertPaidFeeSplit(s, fee);
        _assertImdConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // Deferred fees on the launch-shaped pool (PERK only): recorded once, redeemed once
    // ---------------------------------------------------------------------------------------------

    function test_firstBuyOnPerkOnlyPool_defersTheFeeAndCountsBothHalvesOnce() public {
        _addPerkOnlyLiquidity(1e24);
        assertEq(imd.balanceOf(address(manager)), 0, "manager must start without IMD");
        uint256 amountIn = 100 ether;
        Snapshot memory s = _snapshot();

        vm.expectEmit(true, false, false, true, address(hook));
        emit PerkVaultHook.FloatCollected(key.toId(), 1 ether, 0.5 ether, 0.5 ether, false);
        _buyExactIn(amountIn);

        // Taken and split at once, but nothing moved yet.
        assertEq(hook.pendingFloat(), 1 ether, "the whole fee is pending");
        assertEq(hook.burnOwed(), 0.5 ether, "burn half counted when deferred");
        assertEq(hook.totalFloat(), 0.5 ether, "float half counted when deferred");
        assertEq(hook.totalBurned(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(DEAD), 0);
        assertEq(hook.bookValuePerPerk(), 0, "pending claims do not back tenders");
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn);
        assertEq(imd.balanceOf(address(manager)), amountIn, "manager now holds the whole input");

        // Anyone redeems; the hook receives the fee, burns its half, and the totals do not move.
        vm.expectEmit(true, false, false, true, address(hook));
        emit PerkVaultHook.PendingFeesRedeemed(stranger, 1 ether);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PerkVaultHook.Burned(0.5 ether);
        vm.prank(stranger);
        uint256 redeemed = hook.redeemPendingFees();
        assertEq(redeemed, 1 ether);
        assertEq(hook.pendingFloat(), 0);
        assertEq(hook.burnOwed(), 0);
        assertEq(hook.totalBurned(), 0.5 ether);
        assertEq(hook.totalFloat(), 0.5 ether, "not counted twice");
        assertEq(imd.balanceOf(DEAD), 0.5 ether);
        assertEq(imd.balanceOf(address(hook)), 0.5 ether);
        assertEq(imd.balanceOf(address(manager)), amountIn - 1 ether);

        // Nothing left to redeem.
        vm.expectRevert(PerkVaultHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
        _assertImdConserved();
    }

    function test_firstExactOutputBuyOnPerkOnlyPool_defersTheFee() public {
        _addPerkOnlyLiquidity(1e24);
        Snapshot memory s = _snapshot();
        _buyExactOut(50 ether);
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        uint256 pending = hook.pendingFloat();
        assertGt(pending, 0);
        assertEq(pending, (paid - pending) / 100, "pending fee is not 1% of the IMD side");
        assertEq(hook.burnOwed() + hook.totalFloat(), pending);
        hook.redeemPendingFees();
        assertEq(imd.balanceOf(DEAD), pending / 2);
        assertEq(imd.balanceOf(address(hook)), pending - pending / 2);
        assertEq(hook.burnOwed(), 0);
        _assertImdConserved();
    }

    function test_pendingFeesAreFlushedByTheNextSwapThatFindsImd_withoutDoubleCounting() public {
        _addPerkOnlyLiquidity(1e24);
        _buyExactIn(100 ether);
        assertEq(hook.pendingFloat(), 1 ether);

        // The manager now holds 99 IMD, enough for this swap's fee and the pending one.
        vm.expectEmit(true, false, false, true, address(hook));
        emit PerkVaultHook.PendingFeesRedeemed(address(hook), 1 ether);
        _buyExactIn(100 ether);
        assertEq(hook.pendingFloat(), 0);
        assertEq(hook.totalFloat(), 1 ether, "two fees, half each");
        assertEq(hook.totalBurned(), 1 ether);
        assertEq(hook.burnOwed(), 0);
        assertEq(imd.balanceOf(DEAD), 1 ether);
        assertEq(imd.balanceOf(address(hook)), 1 ether);
        _assertImdConserved();
    }

    function test_redeemPendingFeesRevertsWhenNothingIsPending() public {
        vm.expectRevert(PerkVaultHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
    }

    /// @dev Over a mixed sequence of paid and deferred fees, exactly half of every fee (rounded
    /// down) reaches 0x…dEaD, once, and the rest is in the hook.
    function test_halfOfEveryFeeReachesTheDeadAddressOnceAndOnlyOnce() public {
        _addPerkOnlyLiquidity(1e24);
        vm.recordLogs();
        _buyExactIn(100 ether); // deferred
        _buyExactIn(50 ether); // flushes
        _buyExactOut(10 ether);
        _sellExactIn(20 ether);
        _sellExactOut(5 ether);
        _buyExactIn(1_000_000 ether); // deferred: more than the manager holds
        assertGt(hook.pendingFloat(), 0, "setup: something is deferred");
        _sellExactIn(1 ether);
        if (hook.pendingFloat() > 0) hook.redeemPendingFees();
        hook.burn();

        uint256 sumFees;
        uint256 sumBurn;
        uint256 sumFloat;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == PerkVaultHook.FloatCollected.selector) {
                (uint256 amount, uint256 toBurn, uint256 toFloat,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                sumFees += amount;
                sumBurn += toBurn;
                sumFloat += toFloat;
                assertEq(toBurn, amount / 2);
                assertEq(toBurn + toFloat, amount);
            }
        }
        assertGt(sumFees, 0);
        assertEq(imd.balanceOf(DEAD), sumBurn, "dead holds other than half of every fee");
        assertEq(hook.totalBurned(), sumBurn);
        assertEq(hook.burnOwed(), 0);
        assertEq(hook.totalFloat(), sumFloat);
        assertEq(imd.balanceOf(address(hook)), sumFloat, "hook holds other than the float halves");
        assertEq(hook.pendingFloat(), 0);
        _assertImdConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // Tender
    // ---------------------------------------------------------------------------------------------

    function test_firstTenderPaysBookValueAndBurnsThePerk() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether); // 10 IMD fee: 5 burned, 5 float
        uint256 float_ = imd.balanceOf(address(hook));
        assertEq(float_, 5 ether);
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        uint256 amount = 1_000_000 ether;
        uint256 expected = amount * float_ / circulating;
        assertGt(expected, 0);
        uint256 bvBefore = hook.bookValuePerPerk();
        Snapshot memory s = _snapshot();

        vm.expectEmit(true, false, false, true, address(hook));
        emit PerkVaultHook.Tendered(address(this), amount, expected);
        uint256 payout = hook.tender(amount);

        assertEq(payout, expected);
        assertEq(hook.quoteTender(amount) <= expected, true);
        assertEq(imd.balanceOf(address(this)) - s.swapperImd, expected, "holder did not get book value");
        assertEq(s.hookImd - imd.balanceOf(address(hook)), expected);
        assertEq(perk.balanceOf(DEAD) - s.deadPerk, amount, "tendered PERK was not burned");
        assertEq(s.swapperPerk - perk.balanceOf(address(this)), amount);
        assertEq(perk.balanceOf(address(hook)), 0);
        assertEq(hook.totalTendered(), amount);
        assertGe(hook.bookValuePerPerk(), bvBefore, "a tender lowered book value");
        _assertImdConserved();
    }

    function test_tenderRevertsOnZeroPayout() public {
        // No float yet.
        vm.expectRevert(PerkVaultHook.ZeroPayout.selector);
        hook.tender(1 ether);
        vm.expectRevert(PerkVaultHook.ZeroPayout.selector);
        hook.tender(0);
        // Dust: with 5 IMD of float over 1e9 PERK, one wei of PERK is worth nothing.
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        vm.expectRevert(PerkVaultHook.ZeroPayout.selector);
        hook.tender(1);
        assertEq(perk.balanceOf(DEAD), 0, "a failed tender burned PERK");
    }

    function test_dustTenderPaysTheRoundedDownWeiAndRaisesBookValue() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        uint256 float_ = imd.balanceOf(address(hook));
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        // The smallest amount that pays one wei, plus a little so rounding is visible.
        uint256 amount = (circulating + float_ - 1) / float_ + circulating / float_ / 2;
        uint256 expected = amount * float_ / circulating;
        assertEq(expected, 1);
        uint256 bvBefore = hook.bookValuePerPerk();
        uint256 payout = hook.tender(amount);
        assertEq(payout, 1);
        assertGe(hook.bookValuePerPerk(), bvBefore);
        assertEq(perk.balanceOf(DEAD), amount);
    }

    function test_tenderNeedsAllowanceAndBalance() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        vm.prank(stranger);
        vm.expectRevert(PerkVaultHook.TransferFailed.selector);
        hook.tender(1_000_000 ether);
        perk.transfer(stranger, 1_000_000 ether);
        vm.prank(stranger);
        vm.expectRevert(PerkVaultHook.TransferFailed.selector);
        hook.tender(1_000_000 ether);
        vm.startPrank(stranger);
        perk.approve(address(hook), type(uint256).max);
        uint256 payout = hook.tender(1_000_000 ether);
        vm.stopPrank();
        assertGt(payout, 0);
        assertEq(imd.balanceOf(stranger), payout);
    }

    /// @dev The last holder tenders everything outside the pool: the float is paid out pro rata to
    /// what remains in the pool, book value does not fall, and the hook keeps only the pool's share.
    function test_lastTenderDrainsTheFloatProRata() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        _sellExactIn(100 ether);
        // Pull the liquidity so almost all PERK is back with this holder.
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -1e24, bytes32(0)
            ),
            ""
        );
        uint256 float_ = imd.balanceOf(address(hook)) - hook.burnOwed();
        uint256 circulating = perk.totalSupply() - perk.balanceOf(DEAD);
        uint256 mine = perk.balanceOf(address(this));
        assertGt(mine, circulating * 999 / 1000, "setup: this holder has nearly everything");
        uint256 bvBefore = hook.bookValuePerPerk();

        uint256 payout = hook.tender(mine);

        assertEq(payout, mine * float_ / circulating);
        assertLe(payout, float_);
        assertGe(hook.bookValuePerPerk(), bvBefore, "the last tender lowered book value");
        assertEq(perk.balanceOf(address(this)), 0);
        assertEq(perk.balanceOf(DEAD), mine);
        // What is left in the hook backs the dust still in the pool, at no lower a book value.
        uint256 left = imd.balanceOf(address(hook)) - hook.burnOwed();
        uint256 leftCirculating = perk.totalSupply() - perk.balanceOf(DEAD);
        assertGe(left * circulating, float_ * leftCirculating, "pro-rata broke");
        _assertImdConserved();
    }

    /// @dev A tender never pays more than the holder's pro-rata share of the float and never
    /// lowers book value per PERK, whatever the float and the amount.
    function testFuzz_tenderNeverPaysAboveProRataAndNeverLowersBookValue(
        uint256 imdIn,
        uint256 amount,
        uint256 donation
    ) public {
        _addFullRangeLiquidity(1e24);
        imdIn = bound(imdIn, 1_000, 1e24);
        donation = bound(donation, 0, 1e21);
        _buyExactIn(imdIn);
        if (donation > 0) imd.transfer(address(hook), donation);
        amount = bound(amount, 1, perk.balanceOf(address(this)));

        uint256 floatBefore = imd.balanceOf(address(hook)) - hook.burnOwed();
        uint256 circBefore = perk.totalSupply() - perk.balanceOf(DEAD);
        uint256 bvBefore = hook.bookValuePerPerk();
        uint256 expected = amount * floatBefore / circBefore;

        if (expected == 0) {
            vm.expectRevert(PerkVaultHook.ZeroPayout.selector);
            hook.tender(amount);
            return;
        }
        uint256 payout = hook.tender(amount);

        assertEq(payout, expected, "payout is not the rounded-down pro-rata share");
        assertLe(payout * circBefore, amount * floatBefore, "paid above pro rata");
        uint256 floatAfter = imd.balanceOf(address(hook)) - hook.burnOwed();
        uint256 circAfter = perk.totalSupply() - perk.balanceOf(DEAD);
        assertEq(floatAfter, floatBefore - payout);
        assertEq(circAfter, circBefore - amount);
        if (circAfter > 0) {
            assertGe(floatAfter * circBefore, floatBefore * circAfter, "book value fell (exact)");
            assertGe(hook.bookValuePerPerk(), bvBefore, "book value fell (view)");
        }
        _assertImdConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // Donations
    // ---------------------------------------------------------------------------------------------

    function test_donationsOnlyRaiseBookValue() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        uint256 bvBefore = hook.bookValuePerPerk();
        uint256 owedBefore = hook.burnOwed();
        uint256 floatCounter = hook.totalFloat();
        imd.transfer(address(hook), 10 ether);
        assertGt(hook.bookValuePerPerk(), bvBefore, "a donation did not raise book value");
        assertEq(hook.burnOwed(), owedBefore, "a donation changed the burn");
        assertEq(hook.totalFloat(), floatCounter, "a donation is not a fee");
        assertEq(hook.floatBalance(), 5 ether + 10 ether);
        // PERK sent to the hook stays in circulation and changes nothing.
        perk.transfer(address(hook), 1 ether);
        assertEq(hook.circulatingSupply(), perk.totalSupply());
        // A tender after the donation is paid at the higher book value.
        uint256 payout = hook.tender(1_000_000 ether);
        assertEq(payout, 1_000_000 ether * 15 ether / perk.totalSupply());
    }

    function testFuzz_bookValueNeverFallsFromDonationsOrFees(uint256 imdIn, uint256 donation) public {
        _addFullRangeLiquidity(1e24);
        imdIn = bound(imdIn, 100, 1e24);
        donation = bound(donation, 0, 1e24);
        uint256 bv0 = hook.bookValuePerPerk();
        _buyExactIn(imdIn);
        uint256 bv1 = hook.bookValuePerPerk();
        assertGe(bv1, bv0);
        imd.transfer(address(hook), donation);
        uint256 bv2 = hook.bookValuePerPerk();
        assertGe(bv2, bv1);
        _sellExactIn(perk.balanceOf(address(this)) / 2);
        assertGe(hook.bookValuePerPerk(), bv2);
    }

    // ---------------------------------------------------------------------------------------------
    // Ask
    // ---------------------------------------------------------------------------------------------

    function test_askPaysTheIntakeAndTheCallerAndLeavesNoAllowance() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether); // float 5 IMD
        uint256 hookBefore = imd.balanceOf(address(hook));
        uint256 bvBefore = hook.bookValuePerPerk();

        vm.warp(1_800_000_000);
        vm.expectEmit(false, true, false, false, address(hook));
        emit PerkVaultHook.Asked(bytes32(0), stranger);
        vm.prank(stranger);
        bytes32 requestId = hook.ask();

        assertTrue(requestId != bytes32(0));
        assertEq(imd.balanceOf(address(intake)), 0.5 ether, "intake was paid other than 0.5 IMD");
        assertEq(imd.balanceOf(stranger), 0.1 ether, "caller was paid other than 0.1 IMD");
        assertEq(hookBefore - imd.balanceOf(address(hook)), 0.6 ether);
        assertEq(imd.allowance(address(hook), address(intake)), 0, "allowance left behind");
        assertEq(intake.calls(), 1);
        assertEq(intake.lastAction(), hook.ACTION());
        assertEq(keccak256(intake.lastBody()), BODY_HASH, "body differs from the brief");
        assertEq(intake.lastTarget(), address(0), "no callback");
        assertEq(intake.lastSelector(), bytes4(0), "no callback selector");
        assertEq(intake.lastAsset(), address(imd));
        assertEq(intake.lastAmount(), 0.5 ether);
        assertEq(intake.lastCaller(), address(hook));
        assertEq(hook.lastAsk(), 1_800_000_000);
        assertEq(hook.totalAsked(), 1);
        assertLt(hook.bookValuePerPerk(), bvBefore, "an ask spends float");
        address[] memory others = new address[](1);
        others[0] = stranger;
        _assertImdConserved(others);
    }

    function test_askRevertsUnderZeroPointSixAndPassesAtExactlyIt() public {
        imd.transfer(address(hook), 0.6 ether - 1);
        vm.expectRevert(abi.encodeWithSelector(PerkVaultHook.FloatTooSmall.selector, 0.6 ether - 1));
        hook.ask();
        assertEq(hook.totalAsked(), 0);
        assertEq(hook.lastAsk(), 0);
        imd.transfer(address(hook), 1);
        hook.ask();
        assertEq(hook.totalAsked(), 1);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_askCountsOnlyFloatNotTheBurnHalf() public {
        // A 1 IMD fee leaves 0.5 in the float; with 0.09 donated that is 0.59, too little.
        _addFullRangeLiquidity(1e24);
        _buyExactIn(100 ether); // fee 1: 0.5 burned, 0.5 float
        imd.transfer(address(hook), 0.09 ether);
        assertEq(hook.floatBalance(), 0.59 ether);
        vm.expectRevert(abi.encodeWithSelector(PerkVaultHook.FloatTooSmall.selector, 0.59 ether));
        hook.ask();
    }

    function test_askRevertsInsideSevenDaysThenWorks() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        vm.warp(1_800_000_000);
        hook.ask();
        vm.expectRevert(abi.encodeWithSelector(PerkVaultHook.AskTooSoon.selector, 1_800_000_000 + 7 days));
        hook.ask();
        vm.warp(1_800_000_000 + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(PerkVaultHook.AskTooSoon.selector, 1_800_000_000 + 7 days));
        hook.ask();
        vm.warp(1_800_000_000 + 7 days);
        hook.ask();
        assertEq(hook.totalAsked(), 2);
        assertEq(hook.lastAsk(), 1_800_000_000 + 7 days);
        assertEq(imd.balanceOf(address(intake)), 1 ether);
        assertEq(imd.balanceOf(address(this)) > 0, true);
    }

    function test_askRevertsWhenTheIntakeRefusesAndChangesNothing() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(1_000 ether);
        intake.setRefuse(true);
        uint256 hookBefore = imd.balanceOf(address(hook));
        vm.expectRevert("MockIntake: refused");
        hook.ask();
        assertEq(imd.balanceOf(address(hook)), hookBefore);
        assertEq(hook.lastAsk(), 0);
        assertEq(hook.totalAsked(), 0);
        assertEq(imd.allowance(address(hook), address(intake)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // IMD leaves the hook only by tender, burn and ask
    // ---------------------------------------------------------------------------------------------

    function testFuzz_imdLeavesOnlyByTenderBurnAndAsk(uint8[12] memory actions, uint256 seed) public {
        _addPerkOnlyLiquidity(1e24);
        vm.warp(1_800_000_000);
        uint256 tenderedOut;
        uint256 askedOut;
        uint256 donated;
        uint256 deadBefore = imd.balanceOf(DEAD);
        address asker = makeAddr("asker");
        for (uint256 i = 0; i < actions.length; i++) {
            uint256 a = actions[i] % 9;
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            if (a == 0) {
                _trySwap(!perkIsZero, -int256(bound(x, 100, 1e22)));
            } else if (a == 1) {
                _trySwap(!perkIsZero, int256(bound(x, 100, 1e20)));
            } else if (a == 2) {
                _trySwap(perkIsZero, -int256(bound(x, 100, perk.balanceOf(address(this)) / 4 + 100)));
            } else if (a == 3) {
                _trySwap(perkIsZero, int256(bound(x, 100, 1e20)));
            } else if (a == 4) {
                uint256 amount = bound(x, 1, perk.balanceOf(address(this)));
                try hook.tender(amount) returns (uint256 paid) {
                    tenderedOut += paid;
                } catch {}
            } else if (a == 5) {
                try hook.redeemPendingFees() {} catch {}
            } else if (a == 6) {
                hook.burn();
            } else if (a == 7) {
                uint256 d = bound(x, 0, 1e18);
                imd.transfer(address(hook), d);
                donated += d;
            } else {
                vm.warp(block.timestamp + 8 days);
                vm.prank(asker);
                try hook.ask() {
                    askedOut += 0.6 ether;
                } catch {}
            }
            // The burn halves never exceed the float halves (each is floor(fee/2) vs ceil(fee/2)).
            assertLe(hook.burnOwed() + hook.totalBurned(), hook.totalFloat(), "burn accounting drifted");
        }
        uint256 paidIn = hook.totalFloat() + hook.totalBurned() + hook.burnOwed() - hook.pendingFloat();
        uint256 burnedOut = imd.balanceOf(DEAD) - deadBefore;
        assertEq(burnedOut, hook.totalBurned());
        assertEq(
            imd.balanceOf(address(hook)),
            paidIn + donated - burnedOut - tenderedOut - askedOut,
            "IMD left the hook by another path"
        );
        assertEq(imd.balanceOf(address(intake)) + imd.balanceOf(asker), askedOut);
        address[] memory others = new address[](1);
        others[0] = asker;
        _assertImdConserved(others);
    }

    /// @dev The PoolManager wraps a hook's revert in ERC-7751 `WrappedError`.
    function _initRevert(address hook_, bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook_,
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev A swap that may fail for the pool's own reasons (price limit already reached, nothing
    /// to sell into) without failing the sequence.
    function _trySwap(bool zeroForOne, int256 amountSpecified) internal {
        try swapRouter.swap(
            key,
            SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne)),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {}
            catch {}
    }
}
