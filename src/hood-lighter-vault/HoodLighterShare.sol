// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Pooled-share receipt for HoodLighterVault — 1 share represents a proportional claim on
/// the vault's real 1x HOOD position on Lighter. Mint/burn restricted to the paired vault (set once
/// at deploy, immutable — no owner can be swapped in later to mint for free).
contract HoodLighterShare is ERC20 {
    address public immutable vault;

    error NotVault();

    constructor(address _vault) ERC20("HOOD", "HOOD") {
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
