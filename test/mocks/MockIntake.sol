// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/IIntake.sol";

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A stand-in for the IdentityMD Intake: records the request it was given and pulls exactly
/// `amount` of `asset` from the caller, as the live one does. Etched at the live Intake's address in
/// tests.
contract MockIntake is IIntake {
    uint256 public calls;
    bytes32 public lastAction;
    bytes public lastBody;
    address public lastTarget;
    bytes4 public lastSelector;
    address public lastAsset;
    uint256 public lastAmount;
    address public lastCaller;
    /// @dev Etched code has no constructor-set storage, so the price is a constant.
    uint256 public constant price = 0.5 ether;
    bool public refuse;

    function setRefuse(bool on) external {
        refuse = on;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(!refuse, "MockIntake: refused");
        require(asset != address(0), "ActionNotSold");
        require(amount == price, "MockIntake: wrong price");
        require(IERC20Pull(asset).transferFrom(msg.sender, address(this), amount), "MockIntake: pull failed");
        calls += 1;
        lastAction = action;
        lastBody = body;
        lastTarget = callback.target;
        lastSelector = callback.selector;
        lastAsset = asset;
        lastAmount = amount;
        lastCaller = msg.sender;
        requestId = keccak256(abi.encode(calls, msg.sender, body));
    }
}
