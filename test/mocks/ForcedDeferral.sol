// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice A swapper that forces the hook to defer its fee at will: inside its own unlock it takes
/// the PoolManager's whole IMD balance, swaps, and only then settles everything it owes. When
/// `afterSwap` runs the manager holds no IMD, so the fee cannot be paid out and is minted as a
/// claim. The attacker gains nothing; the point is what the vault does in that window.
contract ForcedDeferral is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(
        PoolKey calldata key,
        Currency imd,
        Currency perk,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit
    ) external {
        manager.unlock(abi.encode(key, imd, perk, zeroForOne, amountSpecified, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, Currency imd, Currency perk, bool zeroForOne, int256 amountSpecified, uint160 limit) =
            abi.decode(data, (PoolKey, Currency, Currency, bool, int256, uint160));

        uint256 drained = imd.balanceOf(address(manager));
        if (drained > 0) manager.take(imd, address(this), drained);

        manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");

        int256 imdDelta = manager.currencyDelta(address(this), imd);
        if (imdDelta < 0) {
            manager.sync(imd);
            imd.transfer(address(manager), uint256(-imdDelta));
            manager.settle();
        } else if (imdDelta > 0) {
            manager.take(imd, address(this), uint256(imdDelta));
        }
        int256 perkDelta = manager.currencyDelta(address(this), perk);
        if (perkDelta < 0) {
            manager.sync(perk);
            perk.transfer(address(manager), uint256(-perkDelta));
            manager.settle();
        } else if (perkDelta > 0) {
            manager.take(perk, address(this), uint256(perkDelta));
        }
        return "";
    }
}
