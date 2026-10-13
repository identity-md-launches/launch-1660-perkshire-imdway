// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The IdentityMD oracle `Intake`, as a paying consumer calls it.
/// @dev Copied from the `oracle-consumer` reference. `request` pulls exactly `amount` of `asset`
/// from the caller (an ERC-20 approval of exactly that amount must precede it) and returns the
/// intake's request id. A callback of `(address(0), bytes4(0))` asks for no delivery on chain.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);
}
