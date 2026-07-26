// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {HoodLighterShare} from "./HoodLighterShare.sol";
import {ISwapRouter02, IWETH} from "./interfaces/ISwapRouter02.sol";

/// @title HoodLighterVault — single-chain, on Robinhood Chain only
/// @notice Pooled vault backing hHOOD1x shares with a real 1x-leveraged HOOD position held on
/// Lighter. Deposits/redemptions are denominated in `depositToken` (USDG) — a stablecoin, so share
/// accounting is in stable USD terms. Users on Robinhood Chain hold ETH, so the vault also accepts
/// ETH directly (`mintWithETH`) and can pay out in ETH (`redeemToETH`), swapping ETH<->USDG through
/// Uniswap V3's SwapRouter02 at the edge and keeping the core USDG-denominated.
///
/// Trust model: the controller (an off-chain keeper operating a real Lighter account — unavoidable,
/// since Lighter's order book is matched off-chain) is trusted to open/close a real 1x HOOD position
/// and honestly report share/payout amounts. The contract bounds what that trust can cost:
///   - Deposits are escrowed here, not handed to the controller, until confirmMint.
///   - Redemption payouts are pulled FROM the controller only at confirm time.
///   - Every confirmation's implied share price is bounded vs the last (`maxPriceDeviationBps`).
///   - The ETH-payout slippage floor (`minEthOut`) is set BY THE USER at redeemToETH time, NOT by the
///     keeper — so the keeper cannot both fund and un-bound the USDG->ETH conversion.
///   - The ETH send never bricks: on failure the payout is re-wrapped and credited as claimable WETH
///     (`claimWeth`), so a contract-user that rejects ETH can't grief the keeper or the pool.
///
/// STATUS: passed an internal 5-lens adversarial fan-out audit (0 Critical / 0 High); fixes from that
/// audit are applied here. NOT yet professionally audited, NOT deployed. See ../README.md.
contract HoodLighterVault is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct PendingMint {
        address user;
        uint256 depositAmount;
        uint256 expiry;
    }

    struct PendingRedeem {
        address user;
        uint256 shareAmount;
        uint256 expiry;
        bool wantsEth; // true if redeemed via redeemToETH -> paid in native ETH
        uint256 minEthOut; // user-supplied slippage floor for the USDG->ETH swap (wantsEth only)
    }

    IERC20 public depositToken; // USDG
    HoodLighterShare public share;

    /// @dev Uniswap V3 SwapRouter02 + WETH on Robinhood Chain, for the ETH<->USDG edge swaps only.
    ISwapRouter02 public swapRouter;
    address public weth;
    /// @dev WETH/USDG pool fee tier to route through. Owner-settable to follow liquidity migration.
    /// Set in initialize() — inline defaults do NOT apply through a proxy.
    uint24 public swapPoolFee;

    /// @dev The keeper wallet. Owner-updatable. A centralization point; see header.
    address public controller;

    uint256 public requestTimeout;

    /// @dev Set once the first confirmation records a price; before that the deviation band has
    /// nothing to compare against and is skipped. Using an explicit flag (not `lastPrice != 0`)
    /// means a degenerate implied-price-of-0 can never silently re-disable the band.
    bool public priceBootstrapped;
    uint256 public lastPricePerShareE18;
    uint256 public maxPriceDeviationBps; // 10% default — set in initialize()

    /// Minimum DEPOSIT value in depositToken units (USDG, 6-dec). Gates mint / mintWithETH ONLY — below
    /// this, the keeper's bridge (Across, ~$2 min) + Lighter deposit (1 USDC min) can't process the
    /// amount, so sub-floor DEPOSITS are rejected up front. It deliberately does NOT gate redeem: a holder
    /// can always exit their full balance, with only truly-unconfirmable dust blocked by the separate
    /// confirmability guard in _createRedeem. Defaults to 0 (no floor); the owner sets the real value
    /// (e.g. 10e6 = $10) post-deploy via setMinDeposit.
    uint256 public minDeposit;

    uint256 public nextRequestId;
    mapping(uint256 => PendingMint) public pendingMints;
    mapping(uint256 => PendingRedeem) public pendingRedeems;
    mapping(uint256 => bool) public redeemReclaimAuthorized;
    /// @dev Claimable WETH credited when an ETH payout couldn't be PUSHED to the user (user rejects ETH).
    mapping(address => uint256) public wethOwed;
    /// @dev Claimable USDG credited when an ETH redeem's swap couldn't meet the user's minEthOut floor
    /// (settle the value rather than brick the request — see confirmRedeem).
    mapping(address => uint256) public usdgOwed;

    event ControllerSet(address controller);
    event MaxPriceDeviationSet(uint256 bps);
    event MinDepositSet(uint256 amount);
    event SwapPoolFeeSet(uint24 fee);
    event MintRequested(uint256 indexed requestId, address indexed user, uint256 depositAmount);
    event MintConfirmed(uint256 indexed requestId, address indexed user, uint256 sharesOut);
    event RedeemRequested(uint256 indexed requestId, address indexed user, uint256 shareAmount);
    event RedeemConfirmed(uint256 indexed requestId, address indexed user, uint256 payoutAmount, uint256 ethOut);
    event MintReclaimed(uint256 indexed requestId, address indexed user, uint256 depositAmount);
    event RedeemReclaimed(uint256 indexed requestId, address indexed user, uint256 shareAmount);
    event RedeemReclaimAuthorized(uint256 indexed requestId);
    event WethCredited(address indexed user, uint256 amount);
    event WethClaimed(address indexed user, uint256 amount);
    event UsdgCredited(address indexed user, uint256 amount);
    event UsdgClaimed(address indexed user, uint256 amount);
    event HoodonSet(address hoodon);
    event HoodonMint(address indexed to, uint256 hoodonIn, uint256 sharesOut);
    event HoodonWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotController();
    error UnknownRequest();
    error NotYourRequest();
    error NotYetExpired();
    error NotAuthorized();
    error AlreadyAuthorized();
    error PriceDeviationTooHigh(uint256 impliedPriceE18, uint256 lastPriceE18);
    error NotWeth();
    error TooHigh();
    error NothingOwed();
    error BelowMinimum();
    error DustRedeem();
    error HoodonNotSet();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // lock the implementation; only the proxy is initializable
    }

    function initialize(
        address _depositToken,
        address _controller,
        uint256 _requestTimeout,
        address _swapRouter,
        address _weth,
        address _owner
    ) external initializer {
        if (
            _depositToken == address(0) || _controller == address(0) || _swapRouter == address(0)
                || _weth == address(0)
        ) revert ZeroAddress();
        if (_requestTimeout == 0) revert ZeroAmount(); // a 0 timeout makes requests reclaimable next block
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        depositToken = IERC20(_depositToken);
        share = new HoodLighterShare(address(this)); // owned by the proxy, so it survives upgrades
        controller = _controller;
        requestTimeout = _requestTimeout;
        swapRouter = ISwapRouter02(_swapRouter);
        weth = _weth;
        swapPoolFee = 500; // inline defaults don't apply through a proxy — set here
        maxPriceDeviationBps = 1000;
        emit ControllerSet(_controller);
    }

    /// @dev UUPS upgrade authorization — owner-only. The owner can replace the implementation logic
    /// (a deliberate fixability/centralization tradeoff; intended to be renounced/frozen once mature).
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Only WETH may send ETH here (from withdraw() on the redeem-to-ETH path). ETH on
    /// mintWithETH comes in as that payable function's msg.value, not through receive.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }

    function setController(address _controller) external onlyOwner {
        if (_controller == address(0)) revert ZeroAddress();
        controller = _controller;
        emit ControllerSet(_controller);
    }

    function setMaxPriceDeviationBps(uint256 bps) external onlyOwner {
        // A 0% band is never valid: it freezes confirmations to an exact price and, via the redeem
        // confirmability guard, would reject any non-exact redeem. Require a real band in (0, 50%].
        if (bps == 0 || bps > 5000) revert TooHigh();
        maxPriceDeviationBps = bps;
        emit MaxPriceDeviationSet(bps);
    }

    /// Set the minimum DEPOSIT value (depositToken units, USDG 6-dec). e.g. 10e6 = $10. Gates mint /
    /// mintWithETH ONLY — it deliberately does NOT gate redeem, so a holder can always exit their full
    /// balance no matter how small (dust exits are bounded instead by the confirmability guard in
    /// _createRedeem, not this floor). Set too high it would block normal deposits, but that's
    /// owner-recoverable (just set it again) and can't touch existing funds, so no on-chain cap (which
    /// would be decimals-fragile) is imposed.
    function setMinDeposit(uint256 amount) external onlyOwner {
        minDeposit = amount;
        emit MinDepositSet(amount);
    }

    function setSwapPoolFee(uint24 fee) external onlyOwner {
        swapPoolFee = fee;
        emit SwapPoolFeeSet(fee);
    }

    // ──────────────────── HOODon collateral (V2, operator-only) ────────────────────
    //
    // A fast-inventory path for the operator to defend the HOOD/USDG pool peg when the Lighter backing
    // path (~15min bridge+margin+order) is too slow — e.g. the pool spikes far above the mark and there's
    // no pre-minted buffer left. HOODon (Ondo's real-share-backed Robinhood token) is INSTANT on-chain
    // collateral: the operator buys HOODon on its Robinhood-Chain pool, deposits it here, mints HOOD 1:1
    // in the SAME tx, and sells that HOOD into the rich pool. No keeper confirmation, no wait.
    //
    // Safety: (1) operator-only (controller) — never a public mint, so no external actor can inflate
    // supply; (2) 1 HOODon -> 1 HOOD share, a FIXED ratio (not a keeper-chosen price), so it can't be
    // gamed — 1 HOODon and 1 HOOD share are each ~one real-HOOD of exposure (shares track HOOD 1:1 by
    // design), and the operator must deposit REAL HOODon to mint; (3) the deposited HOODon is held here
    // as on-chain-verifiable backing for the freshly minted shares (supply up == backing up), so the
    // system stays solvent. The ~1% HOODon-vs-real basis is absorbed as small slack. withdrawHoodon lets
    // the operator pull HOODon back out to sell it (fund redemptions / rebalance) — a trusted action,
    // consistent with the keeper already custodying the Lighter backing off-chain.

    /// @notice Owner wires the HOODon token address (post-upgrade). One-time-ish config.
    function setHoodon(address _hoodon) external onlyOwner {
        if (_hoodon == address(0)) revert ZeroAddress();
        hoodon = _hoodon;
        emit HoodonSet(_hoodon);
    }

    /// @notice Operator deposits HOODon and mints HOOD 1:1 in the same tx (instant, fully backed).
    /// @param hoodonAmount amount of HOODon (18-dec) to deposit as backing; mints an equal share amount.
    function mintWithHoodon(uint256 hoodonAmount)
        external
        onlyController
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (hoodon == address(0)) revert HoodonNotSet();
        if (hoodonAmount == 0) revert ZeroAmount();
        // Pull real HOODon in as backing BEFORE minting (CEI). Mint shares against the ACTUAL received
        // amount (balance delta), NOT the requested amount, so a fee-on-transfer/rebasing token can never
        // mint more shares than backing that arrived — supply-up == backing-up holds unconditionally. Both
        // HOODon and the share are 18-dec, so the received delta maps 1:1 to shares.
        IERC20 h = IERC20(hoodon);
        uint256 balBefore = h.balanceOf(address(this));
        h.safeTransferFrom(msg.sender, address(this), hoodonAmount);
        uint256 received = h.balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();
        sharesOut = received;
        share.mint(msg.sender, sharesOut);
        emit HoodonMint(msg.sender, received, sharesOut);
    }

    /// @notice Operator withdraws HOODon backing (to sell for USDG when funding redemptions / rebalancing).
    /// Trusted action — the keeper is responsible for keeping total backing >= supply, same as it already
    /// does for the off-chain Lighter position.
    function withdrawHoodon(uint256 amount) external onlyController nonReentrant {
        if (hoodon == address(0)) revert HoodonNotSet();
        if (amount == 0) revert ZeroAmount();
        IERC20(hoodon).safeTransfer(msg.sender, amount);
        emit HoodonWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────── Mint ───────────────────────────────

    /// @notice Deposit `depositToken` (USDG) directly.
    function mint(uint256 amount) external nonReentrant returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert BelowMinimum();
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        return _createMint(msg.sender, amount);
    }

    /// @notice Deposit native ETH, swapped to USDG in-transaction, then treated like a USDG mint.
    /// `minUsdgOut` bounds the caller's OWN swap slippage. An unconfirmed ETH deposit is refunded as
    /// USDG (the swapped amount) via reclaimExpiredMint, not the original ETH.
    function mintWithETH(uint256 minUsdgOut) external payable nonReentrant returns (uint256 requestId) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 usdgOut = swapRouter.exactInputSingle{value: msg.value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(depositToken),
                fee: swapPoolFee,
                recipient: address(this),
                amountIn: msg.value,
                amountOutMinimum: minUsdgOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (usdgOut == 0) revert ZeroAmount();
        if (usdgOut < minDeposit) revert BelowMinimum();
        return _createMint(msg.sender, usdgOut);
    }

    function _createMint(address user, uint256 amount) internal returns (uint256 requestId) {
        requestId = nextRequestId++;
        pendingMints[requestId] =
            PendingMint({user: user, depositAmount: amount, expiry: block.timestamp + requestTimeout});
        emit MintRequested(requestId, user, amount);
    }

    /// @notice Controller confirms a mint after sizing the real Lighter position. Mints shares, then
    /// forwards the escrowed USDG to the controller to fund the position.
    function confirmMint(uint256 requestId, uint256 sharesOut) external onlyController nonReentrant {
        PendingMint memory p = pendingMints[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (sharesOut == 0) revert ZeroAmount();
        delete pendingMints[requestId];

        _checkAndUpdatePrice(p.depositAmount, sharesOut);

        share.mint(p.user, sharesOut);
        depositToken.safeTransfer(controller, p.depositAmount);
        emit MintConfirmed(requestId, p.user, sharesOut);
    }

    // ─────────────────────────────── Redeem ───────────────────────────────

    /// @notice Burn shares to redeem for USDG.
    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 requestId) {
        return _createRedeem(shareAmount, false, 0);
    }

    /// @notice Burn shares to redeem for native ETH. `minEthOut` is YOUR slippage floor for the
    /// USDG->ETH conversion that happens at confirm time — set it from a quote of what your shares are
    /// worth now; if the payout would convert to less ETH than this, confirm reverts and you can
    /// reclaim. This is what stops the keeper from setting its own (zero) floor and sandwiching you.
    function redeemToETH(uint256 shareAmount, uint256 minEthOut) external nonReentrant returns (uint256 requestId) {
        return _createRedeem(shareAmount, true, minEthOut);
    }

    function _createRedeem(uint256 shareAmount, bool wantsEth, uint256 minEthOut)
        internal
        returns (uint256 requestId)
    {
        if (shareAmount == 0) revert ZeroAmount();
        // Fail closed on redeems confirmRedeem could NEVER finalize — NOT a deposit floor. The fair payout
        // is valueUsdg (this redeem's share of the pool at the last price); paying it would run through
        // _checkAndUpdatePrice, which reverts if the implied price is zero or outside the deviation band.
        // If the fair payout itself can't clear that, the request would strand (payout 0 -> ZeroAmount;
        // any other -> PriceDeviationTooHigh), so we reject it here BEFORE burning shares. The check mirrors
        // the confirm-time band check for the FAIR FLOORED payout: guard-passes <=> confirmRedeem(id,
        // valueUsdg) succeeds (the reverse implication is impossible — identical mulDiv floors + band). It
        // is intentionally the SAFE side: a redeem it rejects could in principle still confirm at a
        // rounded-UP payout, but only for sub-micro-USDG value below the smallest 6-dec payout unit, so
        // nothing meaningful is trapped and no shares are burned. `minDeposit` deliberately does NOT gate
        // redeem: any holder always exits a balance whose fair payout is confirmable. Before the first mint
        // bootstraps a price there are no shares to burn, so the check is skipped.
        if (priceBootstrapped) {
            uint256 valueUsdg = Math.mulDiv(shareAmount, lastPricePerShareE18, 1e18);
            // impliedPrice floors to 0 whenever valueUsdg * 1e18 < shareAmount (implies unconfirmable).
            uint256 impliedPrice = Math.mulDiv(valueUsdg, 1e18, shareAmount);
            uint256 last = lastPricePerShareE18;
            uint256 diff = impliedPrice > last ? impliedPrice - last : last - impliedPrice;
            if (impliedPrice == 0 || diff * 10_000 > last * maxPriceDeviationBps) revert DustRedeem();
        }
        share.burn(msg.sender, shareAmount);

        requestId = nextRequestId++;
        pendingRedeems[requestId] = PendingRedeem({
            user: msg.sender,
            shareAmount: shareAmount,
            expiry: block.timestamp + requestTimeout,
            wantsEth: wantsEth,
            minEthOut: minEthOut
        });
        emit RedeemRequested(requestId, msg.sender, shareAmount);
    }

    /// @notice Controller confirms a redeem after closing that slice of the Lighter position. Pulls
    /// `payoutAmount` USDG from the controller. For a USDG redeem it goes straight to the user; for an
    /// ETH redeem it's swapped USDG->ETH (bounded by the USER's stored minEthOut) and pushed as native
    /// ETH — with a WETH-credit fallback if the push fails, so it can never brick.
    function confirmRedeem(uint256 requestId, uint256 payoutAmount) external onlyController nonReentrant {
        PendingRedeem memory p = pendingRedeems[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        delete pendingRedeems[requestId];
        delete redeemReclaimAuthorized[requestId]; // tidy: never leave a stale authorization

        _checkAndUpdatePrice(payoutAmount, p.shareAmount);

        uint256 ethOut = 0;
        if (p.wantsEth) {
            depositToken.safeTransferFrom(controller, address(this), payoutAmount);
            depositToken.forceApprove(address(swapRouter), payoutAmount);
            // ONLY the swap is inside try/catch: if it can't meet the user's minEthOut floor it reverts
            // and we settle claimable USDG. The post-swap ETH handling below is OUTSIDE the try on
            // purpose — a failure there (e.g. a nonstandard WETH) must revert the whole tx, never be
            // miscaught as a "swap failure" and mis-settled as USDG while the vault actually holds WETH.
            bool swapped;
            uint256 wethOut;
            try swapRouter.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(depositToken),
                    tokenOut: weth,
                    fee: swapPoolFee,
                    recipient: address(this),
                    amountIn: payoutAmount,
                    amountOutMinimum: p.minEthOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 _wethOut) {
                wethOut = _wethOut;
                swapped = true;
            } catch {
                // Unmeetable floor -> settle the full value as claimable USDG rather than brick the
                // request (a brick would be clearable only via a spammable owner attestation). Keeper
                // always finalizes; anti-sandwich preserved (an honest ETH fill still can't go < floor).
                depositToken.forceApprove(address(swapRouter), 0);
                usdgOwed[p.user] += payoutAmount;
                emit UsdgCredited(p.user, payoutAmount);
            }
            if (swapped) {
                IWETH(weth).withdraw(wethOut);
                (bool ok,) = p.user.call{value: wethOut}("");
                if (ok) {
                    ethOut = wethOut; // delivered as native ETH
                } else {
                    // User rejects raw ETH -> re-wrap and credit claimable WETH. Never brick.
                    IWETH(weth).deposit{value: wethOut}();
                    wethOwed[p.user] += wethOut;
                    emit WethCredited(p.user, wethOut);
                }
            }
        } else {
            depositToken.safeTransferFrom(controller, p.user, payoutAmount);
        }
        emit RedeemConfirmed(requestId, p.user, payoutAmount, ethOut);
    }

    /// @notice Claim WETH credited to you when an ETH payout couldn't be pushed (e.g. your contract
    /// rejects raw ETH). WETH is a plain ERC20 transfer, so this can't be blocked.
    function claimWeth() external nonReentrant {
        uint256 amt = wethOwed[msg.sender];
        if (amt == 0) revert NothingOwed();
        wethOwed[msg.sender] = 0;
        IERC20(weth).safeTransfer(msg.sender, amt);
        emit WethClaimed(msg.sender, amt);
    }

    /// @notice Claim USDG credited to you when an ETH redeem's swap couldn't meet your minEthOut floor
    /// (the value was settled in USDG instead of bricking the request).
    function claimUsdg() external nonReentrant {
        uint256 amt = usdgOwed[msg.sender];
        if (amt == 0) revert NothingOwed();
        usdgOwed[msg.sender] = 0;
        depositToken.safeTransfer(msg.sender, amt);
        emit UsdgClaimed(msg.sender, amt);
    }

    // ─────────────────────── Reclaim (stuck-request recovery) ───────────────────────

    /// @notice Recover a mint deposit the controller never confirmed. Safe unconditionally — this
    /// contract still holds the escrowed USDG. ETH deposits refund as the swapped USDG (see mintWithETH).
    function reclaimExpiredMint(uint256 requestId) external nonReentrant {
        PendingMint memory p = pendingMints[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (msg.sender != p.user) revert NotYourRequest();
        if (block.timestamp <= p.expiry) revert NotYetExpired();

        delete pendingMints[requestId];
        depositToken.safeTransfer(p.user, p.depositAmount);
        emit MintReclaimed(requestId, p.user, p.depositAmount);
    }

    /// @dev The vault cannot distinguish "controller never processed this redeem" (safe to re-mint)
    /// from "controller already closed the position off-chain, only the on-chain confirm got stuck"
    /// (unsafe). Gated behind an explicit owner attestation — see ../README.md.
    function authorizeRedeemReclaim(uint256 requestId) external onlyOwner {
        if (pendingRedeems[requestId].user == address(0)) revert UnknownRequest();
        if (redeemReclaimAuthorized[requestId]) revert AlreadyAuthorized();
        redeemReclaimAuthorized[requestId] = true;
        emit RedeemReclaimAuthorized(requestId);
    }

    /// @notice Re-mints the burned shares (works for USDG and ETH redeems alike). Requires expiry AND
    /// owner attestation.
    function reclaimExpiredRedeem(uint256 requestId) external nonReentrant {
        PendingRedeem memory p = pendingRedeems[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (msg.sender != p.user) revert NotYourRequest();
        if (block.timestamp <= p.expiry) revert NotYetExpired();
        if (!redeemReclaimAuthorized[requestId]) revert NotAuthorized();

        delete pendingRedeems[requestId];
        delete redeemReclaimAuthorized[requestId];
        share.mint(p.user, p.shareAmount);
        emit RedeemReclaimed(requestId, p.user, p.shareAmount);
    }

    /// @dev Bounds a confirmation's implied price against the last, either direction. Skipped only on
    /// the very first confirmation (`priceBootstrapped == false`). Rejects a zero implied price so the
    /// band can never be silently re-disabled.
    function _checkAndUpdatePrice(uint256 valueAmount, uint256 shareAmount) internal {
        uint256 impliedPriceE18 = Math.mulDiv(valueAmount, 1e18, shareAmount);
        if (impliedPriceE18 == 0) revert ZeroAmount();
        if (priceBootstrapped) {
            uint256 last = lastPricePerShareE18;
            uint256 diff = impliedPriceE18 > last ? impliedPriceE18 - last : last - impliedPriceE18;
            if (diff * 10_000 > last * maxPriceDeviationBps) {
                revert PriceDeviationTooHigh(impliedPriceE18, last);
            }
        }
        lastPricePerShareE18 = impliedPriceE18;
        priceBootstrapped = true;
    }

    // ─────────── V2 storage (HOODon collateral) — appended before __gap; gap 50 -> 49 ───────────
    /// @dev Ondo HOODon (real Robinhood-share-backed ERC20, 18-dec, on Robinhood Chain) accepted as
    /// INSTANT mint collateral by the operator, for fast pool-peg rebalancing when the Lighter backing
    /// path (~15min) is too slow. 0 until the owner wires it via setHoodon after the V2 upgrade.
    address public hoodon;

    /// @dev Reserved storage for future upgrades. NOTE: not strictly required here — this is the leaf
    /// contract and all upgradeable parents (Ownable/ReentrancyGuard/Initializable) use ERC-7201
    /// namespaced storage, so nothing can shift these slots. Kept as a defensive convention. UPGRADE
    /// RULE: always add new state variables IMMEDIATELY BEFORE this gap and decrement its size by the
    /// slots used — never append after it — so the two conventions can't collide across upgrades.
    uint256[49] private __gap;
}
