// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// A dead-plain, immutable, fixed-supply ERC20 — no _update override, no transfer restrictions, no
// privileged functions, no mint/burn. All supply is minted once to the launcher at construction. The
// launched token being an ordinary ERC20 is the whole point of the hook-level tax design: wallets and
// aggregators (GMGN, Dexscreener) see unrestricted transfers, so nothing is flagged as a honeypot.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface ILunchLauncherBase {
    function baseTokenURI() external view returns (string memory);
}

contract LunchTokenPlain is ERC20 {
    address public immutable launcher;
    address public immutable creator;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address launcher_,
        address creator_
    ) ERC20(name_, symbol_) {
        require(totalSupply_ > 0, "supply=0");
        require(launcher_ != address(0), "launcher=0");
        launcher = launcher_;
        creator = creator_;
        _mint(launcher_, totalSupply_);
    }

    // NO initLimits, NO _update override, NO privileged functions of any kind — a pure, immutable,
    // fixed-supply ERC20 with unrestricted transfers from block 0. (launcher/creator are just public
    // getters, kept for constructor-signature parity + so the auto-verify cron can read them.)

    /// @notice Metadata for this coin: `<base><address>.json` (e.g. https://www.lunch.fun/t/0x8ec1….json),
    ///         resolving to JSON with description, image, banner and socials. Indexers (GMGN) read it.
    /// @dev    A `view` getter — it touches nothing in the transfer path, so the plain-ERC20 property
    ///         this contract exists to preserve is unchanged and honeypot simulators see the same
    ///         unrestricted buys/sells as before.
    ///
    ///         Stores no state. The address half derives from `address(this)` and the base is read from
    ///         the launcher rather than hardcoded, so a domain move is one owner call on the launcher
    ///         and repairs every coin at once — a baked-in constant would strand them all forever.
    ///         Profile edits stay off-chain and cost the creator no gas.
    ///
    ///         The launcher owner can only move where the JSON is fetched from; supply and transfers
    ///         stay untouchable. Never reverts: "" if no base is set or the launcher call fails.
    function tokenURI() external view returns (string memory) {
        try ILunchLauncherBase(launcher).baseTokenURI() returns (string memory base) {
            if (bytes(base).length == 0) return "";
            return string.concat(base, Strings.toHexString(address(this)), ".json");
        } catch {
            return "";
        }
    }
}
