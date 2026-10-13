// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IIntake} from "./IIntake.sol";

/// @title PerkVaultHook
/// @notice The Uniswap v4 hook of the Perkshire IMDway (PERK) / IMD pool, and the project's
/// Retained Earnings Vault. Every swap in the one pool it is bound to pays 1% of the IMD the pool
/// moves, in IMD, to this contract. Half of each fee is owed to the burn (sent to 0x…dEaD, the
/// buyback) and half stays here as the insurance float. Any holder may tender PERK to the float at
/// book value; once a week anyone may have the float buy one answer from the IdentityMD oracle.
///
/// @dev No owner, admin, pause, setter or upgrade. Every parameter is a constant or an immutable.
///
/// The fee logic (simulation of IMD-specified swaps, return deltas, deferral as ERC-6909 claims,
/// permissionless redemption, the five permission bits) is launch #1330's `RnnnFeeHook` at commit
/// 7001624, unchanged except that the fee recipient is this contract. What is new is:
/// - **Binding.** `beforeInitialize` admits exactly one pool: initialized by the launch factory,
///   with currencies exactly PERK and IMD, the launch LP fee (12500, static), and only while no
///   pool is bound yet. Everything else reverts, so this hook can never serve a second pool.
/// - **Burn.** Half of every fee, rounded down, is added to `burnOwed`. Whenever the hook holds IMD
///   (after a fee, after a redeem, before a tender or an ask, or on `burn()`) it sends
///   `min(burnOwed, balance)` to 0x…dEaD. If IMD refuses the transfer the amount stays owed and
///   nothing reverts.
/// - **Tender.** `tender(amount)` burns the caller's PERK and pays `amount * float / circulating`
///   IMD, rounded down, where float is the hook's IMD less `burnOwed` and circulating is the supply
///   less what 0x…dEaD already holds. Book value per PERK never falls on a tender.
/// - **Ask.** `ask()` buys one oracle answer (the Chairman's weekly report) through the Intake for
///   0.5 IMD and pays its caller 0.1 IMD, at most once every 7 days, only while the float holds at
///   least 0.6 IMD. No callback is requested: the answer is read from the oracle's own records.
///
/// IMD leaves this contract through exactly three paths: a tender payout, the burn, and an ask.
contract PerkVaultHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Fee on the IMD side of every swap, in basis points: 100 = 1%.
    uint256 public constant FEE_BPS = 100;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The LP fee the bound pool must open at: the launch policy's 1.25%.
    uint24 public constant POOL_FEE = 12_500;

    /// @notice Where burned IMD and tendered PERK go.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice The IdentityMD oracle Intake (version 2) on Robinhood Chain, which `ask()` pays.
    IIntake public constant INTAKE = IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);

    /// @notice The action `ask()` buys: `bytes32("oracle.request@oracle-1")`, right-padded.
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");

    /// @notice What one answer costs, in IMD.
    uint256 public constant ASK_PRICE = 0.5 ether;

    /// @notice What the caller of `ask()` is paid for triggering it, in IMD.
    uint256 public constant ASK_REWARD = 0.1 ether;

    /// @notice The float an ask needs: the price plus the caller's reward.
    uint256 public constant ASK_MINIMUM = ASK_PRICE + ASK_REWARD;

    /// @notice The shortest interval between two asks.
    uint256 public constant ASK_INTERVAL = 7 days;

    /// @notice The request body `ask()` sends, byte for byte: the Chairman's weekly report asks
    /// how much IMD reached 0x…dEaD on Robinhood Chain in the past week.
    string public constant BODY =
        '{"v":1,"question":"What is the sum of the value field of the Transfer events of the token 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127 (IMD, 18 decimals) whose to is 0x000000000000000000000000000000000000dEaD on Robinhood Chain (chain id 4663) in the window, in base units?","chainId":4663,"window":{"hours":168},"answerType":"uint256","evidence":"chain","panelSize":5,"quorum":4,"validForSeconds":86400}';

    /// @dev Transient slot holding, between `beforeSwap` and `afterSwap` of one swap, the fee that
    /// `beforeSwap` credited to the hook on the specified side. Zero outside that window.
    bytes32 internal constant SPECIFIED_FEE_SLOT = keccak256("RnnnFeeHook.specifiedFee");

    // ---------------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves. Set once.
    IPoolManager public immutable poolManager;

    /// @notice The PERK token. Set once.
    Currency public immutable perk;

    /// @notice The IMD token (the pool's paired currency). The fee is taken on this side only.
    Currency public immutable imd;

    /// @notice The launch factory: the only address that may initialize the bound pool.
    address public immutable factory;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    /// @notice The id of the one pool this hook serves; zero until the factory opens it.
    PoolId public boundPool;

    /// @notice IMD credited to the float over all time (half of every fee, paid or deferred).
    uint256 public totalFloat;

    /// @notice IMD owed to the burn and not yet sent to 0x…dEaD.
    uint256 public burnOwed;

    /// @notice IMD sent to 0x…dEaD by the burn over all time.
    uint256 public totalBurned;

    /// @notice When `ask()` last ran; zero before the first ask.
    uint256 public lastAsk;

    /// @notice How many answers `ask()` has bought.
    uint256 public totalAsked;

    /// @notice PERK tendered and burned over all time.
    uint256 public totalTendered;

    /// @dev Reentrancy lock for the vault's entry points.
    uint256 private _locked = 1;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice The factory opened the pool this hook serves.
    event PoolBound(PoolId indexed poolId, int24 tickSpacing);

    /// @notice A fee was taken for a swap: `toBurn` was added to `burnOwed` and `toFloat` to
    /// `totalFloat`. `paidNow` says whether the IMD reached the hook within the swap or was left
    /// pending as an ERC-6909 claim.
    event FloatCollected(PoolId indexed poolId, uint256 amount, uint256 toBurn, uint256 toFloat, bool paidNow);

    /// @notice Pending fees held as ERC-6909 claims were transferred to the hook, as IMD.
    event PendingFeesRedeemed(address indexed caller, uint256 amount);

    /// @notice IMD was sent to 0x…dEaD.
    event Burned(uint256 amount);

    /// @notice A holder tendered PERK to the float.
    event Tendered(address indexed holder, uint256 perkAmount, uint256 imdPaid);

    /// @notice The float bought one oracle answer.
    event Asked(bytes32 indexed requestId, address indexed caller);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error NotPoolManager();
    error NotSelf();
    error HookNotImplemented();
    error ZeroAddress();
    error NothingToRedeem();
    /// @dev Carries a simulated swap's result out of `simulateSwap`; it is never a failure.
    error Simulated(int256 delta);
    error SimulationDidNotRevert();
    error NotFactory();
    error WrongCurrencies();
    error WrongFee();
    error AlreadyBound();
    error NotBoundPool();
    error ZeroPayout();
    error NoCirculatingSupply();
    error AskTooSoon(uint256 nextAskAt);
    error FloatTooSmall(uint256 available);
    error TransferFailed();
    error Reentrancy();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param perk_ The PERK token the factory deployed just before this hook.
    /// @param imd_ The IMD ERC-20 the launch pool pairs with.
    /// @param factory_ The launch factory, the only address allowed to open the pool.
    /// @dev The constructor stores values and validates its own address; it calls no other contract.
    constructor(IPoolManager poolManager_, address perk_, address imd_, address factory_) {
        if (
            address(poolManager_) == address(0) || perk_ == address(0) || imd_ == address(0) || factory_ == address(0)
                || perk_ == imd_
        ) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        perk = Currency.wrap(perk_);
        imd = Currency.wrap(imd_);
        factory = factory_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements. The hook address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees already taken but not yet transferred to the hook, held as ERC-6909 claims on
    /// IMD inside the PoolManager. Half of this is already in `burnOwed`, half in `totalFloat`.
    function pendingFloat() public view returns (uint256) {
        return poolManager.balanceOf(address(this), imd.toId());
    }

    /// @notice The IMD backing tenders right now: the hook's IMD balance less what the burn is owed.
    /// Pending claims do not count until they are redeemed.
    function floatBalance() public view returns (uint256) {
        uint256 balance = imd.balanceOfSelf();
        return balance > burnOwed ? balance - burnOwed : 0;
    }

    /// @notice PERK not yet burned: the total supply less what 0x…dEaD holds.
    function circulatingSupply() public view returns (uint256) {
        return _totalSupply() - perk.balanceOf(DEAD);
    }

    /// @notice Book value per PERK, in IMD with 18 decimals: the float over the circulating supply.
    function bookValuePerPerk() external view returns (uint256) {
        uint256 circulating = circulatingSupply();
        if (circulating == 0) return 0;
        return floatBalance() * 1e18 / circulating;
    }

    /// @notice The fee the hook takes for an IMD amount of `imdAmount`.
    function feeFor(uint256 imdAmount) public pure returns (uint256) {
        return imdAmount * FEE_BPS / BPS_DENOMINATOR;
    }

    /// @notice The IMD `tender(amount)` would pay right now, before the burn it runs first.
    function quoteTender(uint256 amount) external view returns (uint256) {
        uint256 circulating = circulatingSupply();
        if (circulating == 0) return 0;
        return amount * floatBalance() / circulating;
    }

    // ---------------------------------------------------------------------------------------------
    // The vault: burn, tender, ask (permissionless)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends what the burn is owed, as far as the hook's IMD balance covers it, to 0x…dEaD.
    /// Anyone may call it; it also runs after every fee and redeem and before every tender and ask.
    function burn() external nonReentrant returns (uint256 amount) {
        return _burn();
    }

    /// @notice Tenders `amount` PERK to the float at book value. The PERK goes to 0x…dEaD and the
    /// caller receives `amount * float / circulating` IMD, rounded down. Reverts if that is zero.
    function tender(uint256 amount) external nonReentrant returns (uint256 payout) {
        _burn();
        uint256 circulating = circulatingSupply();
        if (circulating == 0) revert NoCirculatingSupply();
        payout = amount * floatBalance() / circulating;
        if (payout == 0) revert ZeroPayout();
        // Burn first, pay second: the tendered PERK is out of circulation before any IMD moves.
        _safeTransferFrom(perk, msg.sender, DEAD, amount);
        totalTendered += amount;
        _safeTransfer(imd, msg.sender, payout);
        emit Tendered(msg.sender, amount, payout);
    }

    /// @notice Buys one oracle answer (the Chairman's weekly report) with 0.5 IMD of the float and
    /// pays the caller 0.1 IMD for triggering it. Anyone may call it, at most once every 7 days,
    /// and only while the float holds at least 0.6 IMD.
    function ask() external nonReentrant returns (bytes32 requestId) {
        if (lastAsk != 0 && block.timestamp < lastAsk + ASK_INTERVAL) revert AskTooSoon(lastAsk + ASK_INTERVAL);
        _burn();
        uint256 available = floatBalance();
        if (available < ASK_MINIMUM) revert FloatTooSmall(available);
        lastAsk = block.timestamp;
        totalAsked += 1;
        _approve(imd, address(INTAKE), ASK_PRICE);
        requestId = INTAKE.request(
            ACTION, bytes(BODY), IIntake.Callback(address(0), bytes4(0)), Currency.unwrap(imd), ASK_PRICE
        );
        // The intake pulls exactly the price; nothing stays approved to it.
        if (_allowance(imd, address(INTAKE)) != 0) _approve(imd, address(INTAKE), 0);
        _safeTransfer(imd, msg.sender, ASK_REWARD);
        emit Asked(requestId, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Pending fee redemption (permissionless)
    // ---------------------------------------------------------------------------------------------

    /// @notice Transfers pending fees to the hook, as IMD, then runs the burn. Anyone may call it.
    /// Transfers as much of the pending amount as the PoolManager's IMD balance covers.
    /// @return amount The IMD amount transferred to the hook.
    function redeemPendingFees() external nonReentrant returns (uint256 amount) {
        amount = _redeemable();
        if (amount == 0) revert NothingToRedeem();
        poolManager.unlock(abi.encode(msg.sender));
        _burn();
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Reached only through `redeemPendingFees`: the PoolManager calls back whoever unlocked it,
    /// and this hook is the only caller that unlocks it on its own behalf. The data carries the
    /// address that called `redeemPendingFees`, used for the event only; the amount is re-read.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = _redeemable();
        if (amount == 0) revert NothingToRedeem();
        _payPending(amount, abi.decode(data, (address)));
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Swap simulation (self-call only; always reverts)
    // ---------------------------------------------------------------------------------------------

    /// @notice Runs `params` on the pool and reverts with the resulting delta. Only the hook itself
    /// may call it, from `beforeSwap`, while the PoolManager is unlocked. It never completes, so it
    /// changes nothing and is not a privileged entry point: it has no effect for any caller.
    function simulateSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert NotSelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert Simulated(BalanceDelta.unwrap(delta));
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Binds the one pool this hook serves. Admits only: the launch factory as initializer,
    /// currencies exactly PERK and IMD, the launch LP fee (static 12500), and only while no pool is
    /// bound. Tick spacing is whatever the factory chose. Every other initialization reverts.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        bool perkImd = key.currency0 == perk && key.currency1 == imd;
        bool imdPerk = key.currency0 == imd && key.currency1 == perk;
        if (!(perkImd || imdPerk)) revert WrongCurrencies();
        if (key.fee.isDynamicFee() || key.fee != POOL_FEE) revert WrongFee();
        if (PoolId.unwrap(boundPool) != bytes32(0)) revert AlreadyBound();
        PoolId id = key.toId();
        boundPool = id;
        emit PoolBound(id, key.tickSpacing);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev When IMD is the specified currency, simulates the swap to learn how much IMD the pool
    /// will move, and returns a specified-delta of +fee on that amount: the pool trades
    /// `amountSpecified` adjusted by the fee and the fee is credited to the hook. The LP fee is never
    /// overridden (the third return value is 0 and dynamic-fee pools are refused at initialization).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireBound(key);
        if (_specifiedCurrency(key, params) == imd) {
            uint256 fee = _quoteSpecifiedFee(key, params);
            _setSpecifiedFee(fee);
            if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Reads the fee `beforeSwap` credited when IMD was specified (so the two always agree and
    /// the hook's delta nets to zero); otherwise computes it from the pool's IMD delta and returns it
    /// as the unspecified delta. Then pays it out or records it as a pending claim, splits it between
    /// the burn and the float, and runs the burn.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _requireBound(key);
        uint256 fee;
        int128 hookDeltaUnspecified;
        if (_specifiedCurrency(key, params) == imd) {
            fee = _consumeSpecifiedFee();
        } else {
            fee = feeFor(_imdMoved(key, delta));
            hookDeltaUnspecified = fee.toInt128();
        }
        if (fee > 0) {
            _collect(key, fee);
            _burn();
        }
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: the vault
    // ---------------------------------------------------------------------------------------------

    /// @dev Sends `min(burnOwed, balance)` IMD to 0x…dEaD. If IMD refuses the transfer, nothing
    /// changes and nothing reverts: the amount stays owed for a later attempt.
    function _burn() internal returns (uint256 amount) {
        uint256 owed = burnOwed;
        if (owed == 0) return 0;
        uint256 balance = imd.balanceOfSelf();
        amount = owed < balance ? owed : balance;
        if (amount == 0) return 0;
        if (!_tryTransfer(imd, DEAD, amount)) return 0;
        burnOwed = owed - amount;
        totalBurned += amount;
        emit Burned(amount);
    }

    /// @dev Splits a fee the hook has just taken (paid or deferred) between the burn and the float.
    /// Called exactly once per fee, at the moment it is taken, so nothing is ever counted twice.
    function _account(PoolKey calldata key, uint256 fee, bool paidNow) internal {
        uint256 toBurn = fee / 2;
        uint256 toFloat = fee - toBurn;
        burnOwed += toBurn;
        totalFloat += toFloat;
        emit FloatCollected(key.toId(), fee, toBurn, toFloat, paidNow);
    }

    function _requireBound(PoolKey calldata key) internal view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(boundPool)) revert NotBoundPool();
    }

    function _totalSupply() internal view returns (uint256 supply) {
        (bool ok, bytes memory data) = Currency.unwrap(perk).staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) revert TransferFailed();
        supply = abi.decode(data, (uint256));
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: fee quoting for IMD-specified swaps
    // ---------------------------------------------------------------------------------------------

    /// @dev The fee for a swap whose specified currency is IMD, from a simulation of the swap.
    /// Simulates the amount the pool would trade on a full fill: the trader's IMD less the full fee
    /// on an exact-input buy, the trader's IMD plus the full fee on an exact-output sell. If the pool
    /// moves exactly that amount the request fills in full and the fee is 1% of the specified
    /// amount; otherwise the pool stopped early (price limit or no more liquidity), the real swap
    /// will move the same IMD amount whatever the fee deducted, and the fee is 1% of that amount.
    function _quoteSpecifiedFee(PoolKey calldata key, SwapParams calldata params) internal returns (uint256) {
        uint256 specified = _abs(params.amountSpecified);
        uint256 fullFee = feeFor(specified);
        int256 amountToSwap =
            params.amountSpecified < 0 ? -(specified - fullFee).toInt256() : (specified + fullFee).toInt256();
        uint256 moved = _simulate(key, SwapParams(params.zeroForOne, amountToSwap, params.sqrtPriceLimitX96));
        if (moved == _abs(amountToSwap)) return fullFee;
        return feeFor(moved);
    }

    /// @dev Runs `params` on the pool inside a call that always reverts, and returns the IMD amount
    /// the pool moved. Any other revert of the simulated swap (an exceeded price limit, for one) is
    /// the same revert the real swap would hit, and is passed through unchanged.
    function _simulate(PoolKey calldata key, SwapParams memory params) internal returns (uint256) {
        try this.simulateSwap(key, params) {
            revert SimulationDidNotRevert();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == Simulated.selector) {
                int256 raw;
                assembly ("memory-safe") {
                    raw := mload(add(reason, 36))
                }
                return _imdMoved(key, BalanceDelta.wrap(raw));
            }
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _setSpecifiedFee(uint256 fee) internal {
        bytes32 slot = SPECIFIED_FEE_SLOT;
        assembly ("memory-safe") {
            tstore(slot, fee)
        }
    }

    function _consumeSpecifiedFee() internal returns (uint256 fee) {
        bytes32 slot = SPECIFIED_FEE_SLOT;
        assembly ("memory-safe") {
            fee := tload(slot)
            tstore(slot, 0)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: settlement
    // ---------------------------------------------------------------------------------------------

    /// @dev Settles a fee credit of `fee` IMD that the PoolManager owes (or is about to owe) this
    /// hook for the current swap. Takes it into the hook directly when the manager's IMD balance
    /// covers it and the token accepts the transfer, and flushes any older pending claims when the
    /// balance covers those too. Otherwise records the fee as an ERC-6909 claim the hook holds, so a
    /// transfer the IMD token refuses defers the fee instead of blocking the swap. Either way the
    /// fee is split between the burn and the float here, once.
    function _collect(PoolKey calldata key, uint256 fee) internal {
        uint256 available = imd.balanceOf(address(poolManager));
        if (available >= fee && _tryPay(fee)) {
            _account(key, fee, true);
            uint256 pending = pendingFloat();
            if (pending > 0 && available - fee >= pending && _tryPay(pending)) {
                poolManager.burn(address(this), imd.toId(), pending);
                emit PendingFeesRedeemed(address(this), pending);
            }
        } else {
            poolManager.mint(address(this), imd.toId(), fee);
            _account(key, fee, false);
        }
    }

    /// @dev Transfers `amount` IMD from the PoolManager to the hook against the hook's delta.
    /// Returns false, with nothing changed, if the IMD token refused the transfer.
    function _tryPay(uint256 amount) internal returns (bool) {
        try poolManager.take(imd, address(this), amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Burns `amount` of the hook's IMD claims and transfers that IMD to the hook.
    function _payPending(uint256 amount, address caller) internal {
        poolManager.burn(address(this), imd.toId(), amount);
        poolManager.take(imd, address(this), amount);
        emit PendingFeesRedeemed(caller, amount);
    }

    /// @dev The pending amount the PoolManager's IMD balance can pay right now.
    function _redeemable() internal view returns (uint256) {
        uint256 pending = pendingFloat();
        uint256 available = imd.balanceOf(address(poolManager));
        return pending < available ? pending : available;
    }

    /// @dev The currency `params.amountSpecified` is denominated in: the input for exact-input
    /// swaps, the output for exact-output swaps.
    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params) internal pure returns (Currency) {
        return (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;
    }

    /// @dev The absolute IMD amount in a pool delta.
    function _imdMoved(PoolKey calldata key, BalanceDelta delta) internal view returns (uint256) {
        return _abs(int256(key.currency0 == imd ? delta.amount0() : delta.amount1()));
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: ERC-20 calls that tolerate tokens returning nothing
    // ---------------------------------------------------------------------------------------------

    /// @dev `transfer` that returns false instead of reverting when the token refuses.
    function _tryTransfer(Currency token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) =
            Currency.unwrap(token).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        return ok && (data.length == 0 || abi.decode(data, (bool))) && Currency.unwrap(token).code.length > 0;
    }

    function _safeTransfer(Currency token, address to, uint256 amount) internal {
        if (!_tryTransfer(token, to, amount)) revert TransferFailed();
    }

    function _safeTransferFrom(Currency token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = Currency.unwrap(token)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        if (!(ok && (data.length == 0 || abi.decode(data, (bool))) && Currency.unwrap(token).code.length > 0)) {
            revert TransferFailed();
        }
    }

    function _approve(Currency token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            Currency.unwrap(token).call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!(ok && (data.length == 0 || abi.decode(data, (bool))))) revert TransferFailed();
    }

    function _allowance(Currency token, address spender) internal view returns (uint256) {
        (bool ok, bytes memory data) = Currency.unwrap(token)
            .staticcall(abi.encodeWithSignature("allowance(address,address)", address(this), spender));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
