// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title LunchUpgradeable
 * @notice Minimal shared base for lunch's UUPS-upgradeable contracts: two-step ownership, a reentrancy
 *         guard, and owner-gated upgrades — all on plain storage laid out here so every child shares the
 *         same stable prefix (OZ Initializable/UUPS use ERC-7201 namespaced slots, so no collision).
 *
 *         Upgrades are authorized by `owner` only. This deliberately concentrates power: the owner key
 *         can replace any of these contracts' logic. That is the accepted tradeoff of making them
 *         upgradeable — keep the owner key well secured.
 */
abstract contract LunchUpgradeable is Initializable, UUPSUpgradeable {
    address private _owner;
    address private _pendingOwner;
    uint256 private _entered; // 1 = not entered, 2 = entered

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ReentrantCall();
    error ZeroOwner();

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 2) revert ReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    function __LunchUpgradeable_init(address owner_) internal onlyInitializing {
        if (owner_ == address(0)) revert ZeroOwner();
        _owner = owner_;
        _entered = 1;
        emit OwnershipTransferred(address(0), owner_);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Start a two-step ownership transfer. Pass address(0) to cancel a pending one.
    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @notice The pending owner accepts ownership, completing the handoff.
    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert NotPendingOwner();
        address old = _owner;
        _owner = _pendingOwner;
        _pendingOwner = address(0);
        emit OwnershipTransferred(old, _owner);
    }

    /// @dev UUPS: only the owner may upgrade the implementation.
    error UpgradesFrozen();
    /// FROZEN: upgradeability permanently revoked. Every other owner power is retained.
    function _authorizeUpgrade(address) internal pure override { revert UpgradesFrozen(); }

    /// @dev Storage gap so children can add state without colliding on future base changes.
    uint256[47] private __gap;
}
