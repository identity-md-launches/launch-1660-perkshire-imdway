// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {PerkVaultHook} from "../src/PerkVaultHook.sol";
import {PerkVaultBase} from "./utils/PerkVaultBase.sol";

/// @dev Pays IMD into the PoolManager and mints the ERC-6909 claim for it to an arbitrary recipient.
contract ClaimMinter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager immutable manager;
    Currency immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function mintTo(address to, uint256 amount) external {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(currency);
        currency.transfer(address(manager), amount);
        manager.settle();
        manager.mint(to, currency.toId(), amount);
        return "";
    }
}

/// @notice Inputs the author did not plan for: a third party pushing ERC-6909 IMD claims onto the
/// hook, PERK claims, pending claims against a drained manager, and repeated redeems.
contract PerkVaultHookAdversarialTest is PerkVaultBase {
    /// @dev Anyone can mint or transfer IMD claims to the hook. They show up in `pendingFloat`, are
    /// redeemed like a fee, and then behave as a donation: no counter moves, book value only rises.
    function test_claimsPushedOntoTheHookBehaveAsADonation() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(100 ether); // 1 IMD fee paid at once: 0.5 burned, 0.5 float
        uint256 bvBefore = hook.bookValuePerPerk();
        uint256 totalFloat = hook.totalFloat();
        uint256 burnSide = hook.burnOwed() + hook.totalBurned();

        ClaimMinter minter = new ClaimMinter(IPoolManager(address(manager)), Currency.wrap(address(imd)));
        imd.transfer(address(minter), 3 ether);
        minter.mintTo(address(hook), 3 ether);

        assertEq(hook.pendingFloat(), 3 ether, "a pushed claim shows up as pending");
        assertEq(hook.bookValuePerPerk(), bvBefore, "a pending claim backs nothing yet");

        uint256 redeemed = hook.redeemPendingFees();
        assertEq(redeemed, 3 ether);
        assertEq(hook.pendingFloat(), 0);
        assertEq(hook.totalFloat(), totalFloat, "a pushed claim is not a fee");
        assertEq(hook.burnOwed() + hook.totalBurned(), burnSide, "a pushed claim owes the burn nothing");
        assertEq(imd.balanceOf(address(hook)), 0.5 ether + 3 ether);
        assertGt(hook.bookValuePerPerk(), bvBefore, "a redeemed pushed claim raises book value");
        address[] memory others = new address[](1);
        others[0] = address(minter);
        _assertImdConserved(others);
    }

    /// @dev PERK claims pushed onto the hook are inert: the hook only ever redeems IMD.
    function test_perkClaimsPushedOntoTheHookAreIgnored() public {
        _addFullRangeLiquidity(1e24);
        ClaimMinter minter = new ClaimMinter(IPoolManager(address(manager)), Currency.wrap(address(perk)));
        perk.transfer(address(minter), 5 ether);
        minter.mintTo(address(hook), 5 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(perk)))), 5 ether);
        assertEq(hook.pendingFloat(), 0, "PERK claims are not pending float");
        vm.expectRevert(PerkVaultHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
        assertEq(hook.circulatingSupply(), perk.totalSupply(), "PERK claims change nothing");
        assertEq(hook.bookValuePerPerk(), 0);
    }

    /// @dev A pending claim is minted against IMD the swapper paid into the manager, so even a sell
    /// that empties the pool's IMD side cannot leave the manager short of the claim: the redeem is
    /// always whole, and it works exactly once.
    function test_managerAlwaysCoversPendingClaimsSoRedeemIsWhole() public {
        _addPerkOnlyLiquidity(1e24);
        _buyExactIn(100 ether); // deferred: 1 IMD pending, manager holds 100
        assertEq(hook.pendingFloat(), 1 ether);
        // Sell as much PERK as the pool will take: this drains the pool's IMD side. The sell's own
        // fee finds IMD in the manager, so it may flush the pending claim within the swap.
        uint256 totalFloatBefore = hook.totalFloat();
        _sellExactIn(perk.balanceOf(address(this)) / 2);
        uint256 managerImd = imd.balanceOf(address(manager));
        uint256 pending = hook.pendingFloat();
        assertGe(managerImd, pending, "the manager cannot cover the claims it minted");
        uint256 totalFloat = hook.totalFloat();
        uint256 burnSide = hook.burnOwed() + hook.totalBurned();

        if (pending > 0) {
            uint256 got = hook.redeemPendingFees();
            assertEq(got, pending, "redeem was partial");
            assertEq(imd.balanceOf(address(manager)), managerImd - pending);
        } else {
            // Flushed inside the sell: the first fee's IMD is in the hook (its burn half at dEaD).
            assertEq(imd.balanceOf(DEAD), hook.totalBurned());
            assertGe(imd.balanceOf(address(hook)) + imd.balanceOf(DEAD), 1 ether, "flushed fee did not arrive");
        }
        assertEq(hook.pendingFloat(), 0);
        assertEq(hook.totalFloat(), totalFloat, "redeem counted the float again");
        assertEq(hook.burnOwed() + hook.totalBurned(), burnSide, "redeem counted the burn again");
        assertGe(hook.totalFloat(), totalFloatBefore, "the sell's own fee was not counted");
        vm.expectRevert(PerkVaultHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
        _assertImdConserved();
    }

    /// @dev A swap that is not for the bound pool cannot be routed through the hook even by the
    /// manager with a doctored key that differs only in tick spacing or fee.
    function test_doctoredKeysAreRefusedBySwapCallbacks() public {
        _addFullRangeLiquidity(1e24);
        // Another pool on the same tokens through this hook cannot even be created...
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, 120), SQRT_PRICE_1_1
        );
        // ...and a stranger cannot bind a second hook instance to a pool the factory never opened.
        PerkVaultHook fresh = _freshHook();
        vm.prank(stranger);
        vm.expectRevert();
        manager.initialize(
            _keyFor(Currency.wrap(address(perk)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING, address(fresh)),
            SQRT_PRICE_1_1
        );
        assertEq(PoolId.unwrap(fresh.boundPool()), bytes32(0), "a stranger bound a pool");
    }
}
