// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC-20 with an admin blocklist, the shape of the live IMD on Robinhood Chain: a
/// transfer to or from a blocked address reverts.
contract BlocklistERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor(string memory name_, string memory symbol_, uint256 supply) MockERC20(name_, symbol_, supply) {}

    function setBlocked(address account, bool on) external {
        blocked[account] = on;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "BlocklistERC20: blocked");
        super._transfer(from, to, amount);
    }
}

interface IReenter {
    function tender(uint256 amount) external returns (uint256);
}

/// @notice An ERC-20 that calls back into a target on every transfer to `attacker`, to probe the
/// vault's reentrancy guard.
contract ReenteringERC20 is MockERC20 {
    address public attacker;
    address public target;
    bool public reentered;
    bytes public lastReason;

    constructor(string memory name_, string memory symbol_, uint256 supply) MockERC20(name_, symbol_, supply) {}

    function arm(address attacker_, address target_) external {
        attacker = attacker_;
        target = target_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (to == attacker && target != address(0) && !reentered) {
            reentered = true;
            (bool ok, bytes memory reason) = target.call(abi.encodeCall(IReenter.tender, (1)));
            require(!ok, "reentrant tender went through");
            lastReason = reason;
        }
    }
}
