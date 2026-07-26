// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// v4-core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LunchUpgradeable} from "./base/LunchUpgradeable.sol";
import {LunchTokenPlain} from "./LunchTokenPlain.sol";

/// @notice Quote-token dividend tracker sink (holder rewards paid in the QUOTE token). The hook transfers the
/// slice to the tracker, then calls feedToken(amount) so it books the deposit to holders.
interface IDividendFeederToken {
    function feedToken(uint256 amount) external;
}

/// @notice Referral sink for a QUOTE-token pool: the hook transfers the platform cut to the sink then notifies.
interface IPlatformFeeSinkToken {
    function onPlatformFeeToken(address token, address quote, uint256 amount) external;
}

/// @notice SwapRouter02 (Uniswap V3) — used to convert a claimer's accrued QUOTE fees into WETH at claim time,
/// so creators/platform/referrers are paid in ETH. Holder rewards are NOT converted (they stay in the quote).
interface ISwapRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title LunchTaxHookPair (UUPS-upgradeable)
 * @notice Sibling of LunchTaxHook for tax launches paired with a NON-ETH quote token (a Robinhood stock or
 *         USDG) instead of native ETH. Identical economics — buy/sell tax skimmed per swap, 20% platform /
 *         80% creator (mutable split + CTO), optional holder rewards + referral routing — but everything is
 *         denominated in the pool's QUOTE token, paid out via a per-(recipient, token) pull ledger.
 *
 *         KEY DIFFERENCE vs the ETH hook: the quote token is a normal ERC-20, so it may sort to EITHER
 *         currency0 OR currency1 of the pool (ETH is always currency0). Each pool records which side is the
 *         quote (`quoteIsC0`); the swap-leg + take/settle logic is parameterized on that. Payouts are ERC-20
 *         transfers (SafeERC20), not `call{value}`. Deployed behind its OWN mined ERC1967 proxy address (the
 *         address carries the V4 permission flags), so the live ETH hook + its pools are untouched.
 */
contract LunchTaxHookPair is IUnlockCallback, LunchUpgradeable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ─── caps (basis points; 1% = 100 bps) ───
    uint16 internal constant BPS = 10_000;
    uint16 public constant MAX_SIDE_BPS = 500; // 5% per side (10% max round-trip)
    uint16 public constant PLATFORM_BPS = 2000; // 20%, HARDCODED
    uint256 public constant MAX_SPLIT_RECIPIENTS = 20;
    uint24 public constant POOL_FEE = 3000; // required 0.30% LP fee (locker compounds it)
    uint24 internal constant FEE_DENOM = 1e6;

    uint256 internal constant DEFAULT_AUTO_THRESHOLD = 0; // rewards pools: creator retunes; 0 disables auto until set
    uint256 internal constant AUTO_DISTRIBUTE_BASE = 500_000;
    uint256 internal constant AUTO_DISTRIBUTE_PER_SPLIT = 28_000;
    uint256 internal constant AUTO_DISTRIBUTE_REF = 90_000;

    struct TaxConfig {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        bool configured;
        bool autoEnabled;
        bool quoteIsC0;         // true if the QUOTE token is currency0 (else currency1). Set at configure time.
        address quote;          // the pool's quote token (stock/USDG) — the currency tax is skimmed/paid in
        address rewardsTracker; // 0 = not a rewards pool; else the coin's quote-token DividendTracker
        uint16 rewardsBps;      // slice of the CREATOR pool routed to holders (bps of the 80%); 0 = none
        uint80 autoThreshold;   // accrued-quote (raw units) that triggers the in-swap auto-distribute
    }

    struct Split { address to; uint16 bps; }

    IPoolManager public immutable poolManager;

    mapping(address => bool) public isLauncher;
    address public platform;
    address public admin;

    mapping(PoolId => TaxConfig) public config;
    mapping(PoolId => Split[]) internal creatorSplits;
    mapping(PoolId => uint256) public accruedQuote;           // per-pool tax accrued, in the pool's quote token
    mapping(address => mapping(address => uint256)) public owed; // recipient => quoteToken => amount (pull ledger)

    address public referralSplitter;
    mapping(PoolId => address) public refToken;
    // Sink SNAPSHOT taken when a pool is marked referred, so a later change to `referralSplitter` can never
    // orphan an already-attributed pool (the launcher named the referrer in THIS sink; distribute funds it).
    mapping(PoolId => address) public poolRefSink;

    // ─── fees-in-ETH ───
    // Creators / platform / referrers are paid in WETH: their accrued QUOTE fees are converted at CLAIM time
    // via SwapRouter02 along `quoteToWethPath[quote]` (owner-configured, quote→…→WETH). If a quote has no path
    // configured — or the swap reverts (a dead stock with no ETH route) — claim FALLS BACK to paying the quote
    // token as-is, so a claim can never brick. Holder REWARDS are never converted (they stay in the quote).
    // Conversion is done at claim (not distribute) because distribute also runs IN-SWAP for rewards pools, and a
    // router swap there would re-enter the locked PoolManager. Safe with amountOutMinimum=0 on this chain: the
    // single-sequencer RH chain has no public mempool, so the quote→WETH swap can't be sandwiched.
    address public weth;
    address public swapRouter;
    mapping(address => bytes) public quoteToWethPath;   // quote token -> V3 path quote→…→WETH

    event PoolConfigured(PoolId indexed poolId, address indexed creator, uint16 buyBps, uint16 sellBps);
    event TaxAccrued(PoolId indexed poolId, bool isBuy, uint256 quoteAmount);
    event TaxDistributed(PoolId indexed poolId, uint256 toCreatorPool, uint256 toPlatform);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);
    event LauncherSet(address indexed launcher, bool allowed);
    event PlatformSet(address indexed platform);
    event AdminSet(address indexed admin);
    event RatesSet(PoolId indexed poolId, uint16 buyBps, uint16 sellBps);
    event CreatorSplitSet(PoolId indexed poolId, address indexed by, uint256 recipients);
    event TokenCreatorSet(PoolId indexed poolId, address indexed from, address indexed to);
    event RewardsBpsSet(PoolId indexed poolId, uint16 rewardsBps);
    event AutoThresholdSet(PoolId indexed poolId, uint80 threshold);
    event RewardsRouted(PoolId indexed poolId, address indexed tracker, uint256 amount);
    event ReferralSplitterSet(address indexed splitter);
    event SwapConfigSet(address indexed weth, address indexed router);
    event QuoteToWethPathSet(address indexed quote, bytes path);
    event PoolReferred(PoolId indexed poolId, address indexed token);
    event ReferralRouted(PoolId indexed poolId, address indexed token, uint256 amount);

    error NothingAccrued();
    error NotLauncher();
    error AlreadyConfigured();
    error NotConfigured();
    error SideCapExceeded();
    error BadSplit();
    error BadSplitLength();
    error ZeroAddress();
    error NotPairPool();
    error BadPoolFee();
    error WrongHook();
    error PoolNotInitialized();
    error NotCreator();
    error NotAdmin();
    error SameCreator();
    error NotPoolManager();
    error BadRewardsBps();
    error BadAutoThreshold();
    error InsufficientGasForFeed();
    error OnlySelf();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager pm) {
        poolManager = pm;
        _disableInitializers();
    }

    function initialize(address owner_, address platform_) external initializer {
        __LunchUpgradeable_init(owner_);
        if (platform_ == address(0)) revert ZeroAddress();
        platform = platform_;
        admin = owner_;
    }

    // ─────────────────────────── admin ───────────────────────────

    function setLauncher(address launcher, bool allowed) external onlyOwner {
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    function setPlatform(address platform_) external onlyOwner {
        if (platform_ == address(0)) revert ZeroAddress();
        platform = platform_;
        emit PlatformSet(platform_);
    }

    function setAdmin(address admin_) external onlyOwner {
        admin = admin_;
        emit AdminSet(admin_);
    }

    function setReferralSplitter(address s) external onlyOwner {
        referralSplitter = s;
        emit ReferralSplitterSet(s);
    }

    /// @notice Configure the WETH token + SwapRouter02 used to convert quote fees → ETH at claim time.
    function setSwapConfig(address weth_, address router_) external onlyOwner {
        weth = weth_;
        swapRouter = router_;
        emit SwapConfigSet(weth_, router_);
    }

    /// @notice Set the V3 swap path (quote→…→WETH) for converting a quote's fees to ETH at claim. Must start at
    /// `quote` and end at `weth`. Clearing it (or never setting it) makes that quote's fees pay out in the quote.
    function setQuoteToWethPath(address quote, bytes calldata path) external onlyOwner {
        require(
            path.length >= 43 && address(bytes20(path[0:20])) == quote
            && weth != address(0) && address(bytes20(path[path.length - 20:])) == weth,
            "bad path"
        );
        quoteToWethPath[quote] = path;
        emit QuoteToWethPathSet(quote, path);
    }

    /// @dev Identify the coin (the LunchTokenPlain minted by `launcher`) and the quote in a {coin,quote} pool,
    /// and validate the pool shape. Returns (coin, quote, quoteIsCurrency0).
    function _shape(PoolKey calldata key, address launcher)
        internal
        view
        returns (address coin, address quote, bool quoteIsC0)
    {
        if (key.fee != POOL_FEE) revert BadPoolFee();
        if (address(key.hooks) != address(this)) revert WrongHook();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0) || c1 == address(0)) revert NotPairPool(); // native ETH belongs to LunchTaxHook
        // The coin is whichever side is a LunchTokenPlain deployed by THIS launcher; the other is the quote.
        if (_isCoin(c1, launcher)) { coin = c1; quote = c0; quoteIsC0 = true; }
        else if (_isCoin(c0, launcher)) { coin = c0; quote = c1; quoteIsC0 = false; }
        else revert NotLauncher();
    }

    function _isCoin(address t, address launcher) internal view returns (bool) {
        try LunchTokenPlain(t).launcher() returns (address l) { return l == launcher; }
        catch { return false; }
    }

    function markReferred(PoolKey calldata key) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        (address coin,,) = _shape(key, msg.sender);
        PoolId id = key.toId();
        if (!config[id].configured) revert NotConfigured();
        if (refToken[id] == address(0)) {
            refToken[id] = coin;
            poolRefSink[id] = referralSplitter; // snapshot the sink now; distribute uses THIS, not the live pointer
            emit PoolReferred(id, coin);
        }
    }

    // ─────────────────────── pool configuration ───────────────────────

    struct ConfigParams {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        address rewardsTracker;
        uint16 rewardsBps;
    }

    function configurePool(PoolKey calldata key, ConfigParams calldata p) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        (, address quote, bool quoteIsC0) = _shape(key, msg.sender);

        PoolId id = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        if (sqrtP == 0) revert PoolNotInitialized();
        if (config[id].configured) revert AlreadyConfigured();
        if (p.creator == address(0)) revert ZeroAddress();
        if (p.buyBps > MAX_SIDE_BPS || p.sellBps > MAX_SIDE_BPS) revert SideCapExceeded();
        if (p.rewardsBps > BPS) revert BadRewardsBps();

        bool rewards = p.rewardsTracker != address(0);
        config[id] = TaxConfig({
            creator: p.creator, buyBps: p.buyBps, sellBps: p.sellBps, configured: true,
            autoEnabled: rewards, quoteIsC0: quoteIsC0, quote: quote,
            rewardsTracker: p.rewardsTracker, rewardsBps: rewards ? p.rewardsBps : 0,
            autoThreshold: uint80(DEFAULT_AUTO_THRESHOLD)
        });
        _storeSplit(id, p.recipients, p.splitBps);
        emit PoolConfigured(id, p.creator, p.buyBps, p.sellBps);
    }

    // ─────────────────── mutable fee routing (creator + CTO) ───────────────────

    function setRates(PoolId id, uint16 buyBps, uint16 sellBps) external {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        if (msg.sender != c.creator) revert NotCreator();
        if (buyBps > MAX_SIDE_BPS || sellBps > MAX_SIDE_BPS) revert SideCapExceeded();
        c.buyBps = buyBps;
        c.sellBps = sellBps;
        emit RatesSet(id, buyBps, sellBps);
    }

    function setRewardsBps(PoolId id, uint16 rewardsBps) external {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        if (msg.sender != c.creator) revert NotCreator();
        if (c.rewardsTracker == address(0) || rewardsBps > BPS) revert BadRewardsBps();
        c.rewardsBps = rewardsBps;
        emit RewardsBpsSet(id, rewardsBps);
    }

    function setAutoThreshold(PoolId id, uint80 threshold) external {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        if (msg.sender != c.creator) revert NotCreator();
        if (!c.autoEnabled || threshold == 0) revert BadAutoThreshold();
        c.autoThreshold = threshold;
        emit AutoThresholdSet(id, threshold);
    }

    function setCreatorSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps) external {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        if (msg.sender != c.creator) revert NotCreator();
        _storeSplit(id, recipients, bps);
        emit CreatorSplitSet(id, msg.sender, recipients.length);
    }

    function setTokenCreator(PoolId id, address newCreator) external {
        if (msg.sender != admin || admin == address(0)) revert NotAdmin();
        if (newCreator == address(0)) revert ZeroAddress();
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        address old = c.creator;
        if (newCreator == old) revert SameCreator();
        c.creator = newCreator;
        delete creatorSplits[id];
        emit TokenCreatorSet(id, old, newCreator);
    }

    function _storeSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps) internal {
        if (recipients.length != bps.length || recipients.length > MAX_SPLIT_RECIPIENTS) revert BadSplitLength();
        delete creatorSplits[id];
        if (recipients.length == 0) return;
        uint256 sum;
        for (uint256 i; i < recipients.length; i++) {
            if (recipients[i] == address(0) || bps[i] == 0) revert BadSplit();
            sum += bps[i];
            creatorSplits[id].push(Split({to: recipients[i], bps: bps[i]}));
        }
        if (sum != BPS) revert BadSplit();
    }

    function splitsOf(PoolId id) external view returns (Split[] memory) {
        return creatorSplits[id];
    }

    // ─────────────────────────── hook callbacks ───────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: true, afterInitialize: false,
            beforeAddLiquidity: false, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: true, beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: true, afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false, afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (!isLauncher[sender]) revert NotLauncher();
        _shape(key, sender); // validates shape + that one side is sender's coin
        return this.beforeInitialize.selector;
    }

    /// @dev The quote currency this pool taxes on (currency0 or currency1) as a Currency + its BalanceDelta side.
    function _quoteCurrency(PoolKey calldata key, bool quoteIsC0) internal pure returns (Currency) {
        return quoteIsC0 ? key.currency0 : key.currency1;
    }

    /// @dev Skims the quote-token tax when the QUOTE is the SPECIFIED currency of the swap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();

        // "currency0 is the specified currency" ⟺ zeroForOne == (amountSpecified<0). The quote is specified
        // in beforeSwap when the quote sits on the specified side.
        bool c0Specified = (params.zeroForOne == (params.amountSpecified < 0));
        bool quoteSpecified = c.quoteIsC0 ? c0Specified : !c0Specified;
        if (!quoteSpecified) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amt = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _taxOn(c, params.zeroForOne, amt);
        if (fee == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _quoteCurrency(key, c.quoteIsC0).take(poolManager, address(this), fee, true);
        accruedQuote[id] += fee;
        emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Skims the quote-token tax when the QUOTE is the UNSPECIFIED currency of the swap.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyPoolManager returns (bytes4, int128)
    {
        PoolId id = key.toId();
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();

        int128 feeReturn = 0;
        bool c0Specified = (params.zeroForOne == (params.amountSpecified < 0));
        bool quoteUnspecified = c.quoteIsC0 ? !c0Specified : c0Specified;
        if (quoteUnspecified) {
            int128 qDelta = c.quoteIsC0 ? delta.amount0() : delta.amount1();
            if (qDelta != 0) {
                uint256 amt = qDelta < 0 ? uint256(-int256(qDelta)) : uint256(int256(qDelta));
                uint256 fee = _taxOn(c, params.zeroForOne, amt);
                if (fee != 0) {
                    _quoteCurrency(key, c.quoteIsC0).take(poolManager, address(this), fee, true);
                    accruedQuote[id] += fee;
                    emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
                    feeReturn = fee.toInt128();
                }
            }
        }
        _maybeAutoDistribute(id, c);
        return (this.afterSwap.selector, feeReturn);
    }

    function _taxOn(TaxConfig storage c, bool zeroForOne, uint256 amount) internal view returns (uint256) {
        // zeroForOne is a "buy" (quote in → coin out) when the quote is currency0; when the quote is currency1
        // a zeroForOne swap spends the coin (a sell). So the buy/sell side depends on the quote's position.
        bool isBuy = c.quoteIsC0 ? zeroForOne : !zeroForOne;
        uint256 bps = isBuy ? c.buyBps : c.sellBps;
        if (bps == 0 || amount == 0) return 0;
        return FullMath.mulDiv(amount, bps * 100, FEE_DENOM);
    }

    // ─────────────────────── distribution (Claim) ───────────────────────

    function distribute(PoolId id) external nonReentrant {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        uint256 amount = accruedQuote[id];
        if (amount == 0) revert NothingAccrued();
        accruedQuote[id] = 0;
        poolManager.unlock(abi.encode(id, amount));
    }

    /// @notice Claim accrued fees for `token`. FEES ARE PAID IN ETH: if a quote→WETH path is configured for
    /// `token`, the owed quote is swapped to WETH via SwapRouter02 and the WETH is sent to the caller. If no
    /// path is set, or the swap reverts (a quote with no ETH route), it FALLS BACK to sending the quote token
    /// as-is — so a claim can never brick. (Holder rewards are claimed from the tracker, not here, and are
    /// never converted.) Returns (amountPaid, tokenPaid) so the caller knows whether it got WETH or the quote.
    function claim(address token) external nonReentrant returns (uint256 amountPaid, address tokenPaid) {
        uint256 amount = owed[msg.sender][token];
        if (amount == 0) revert NothingAccrued();
        owed[msg.sender][token] = 0;

        bytes memory path = quoteToWethPath[token];
        if (path.length >= 43 && swapRouter != address(0) && token != weth) {
            // Round-9 audit fix: the WHOLE approve+swap+approve-reset sequence is routed through a
            // try-wrapped external self-call — a bare `forceApprove` before the try block (the original
            // shape here) is NOT isolated: a paused/blacklist-capable quote token can make approve() itself
            // revert, not just transfer()/exactInput(), which would have reverted this entire claim() with
            // no fallback (exactly the class of bug already fixed for the identical pattern in
            // LunchDividendTrackerBasket._executeSwap and LunchPairReferralSink._convertToWeth).
            try this.convertToWeth(msg.sender, token, path, amount) returns (uint256 out) {
                emit Claimed(msg.sender, weth, out);
                return (out, weth);
            } catch {}
        }
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
        return (amount, token);
    }

    /// @dev External-self-only so {claim} can try/catch the ENTIRE approve+swap+approve-reset sequence, not
    /// just the swap call — a reverting approve() is exactly as recoverable as a reverting exactInput(). Takes
    /// `recipient` explicitly (never msg.sender, which would be address(this) under the self-call). //
    /// amountOutMinimum=0 is safe here: single-sequencer chain, no public mempool → no sandwich. The swap
    /// sends WETH straight to the claimer; on no-route/failure the caller falls back to the raw quote.
    function convertToWeth(address recipient, address token, bytes memory path, uint256 amount) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(token).forceApprove(swapRouter, amount);
        out = ISwapRouter02(swapRouter).exactInput(
            ISwapRouter02.ExactInputParams({ path: path, recipient: recipient, amountIn: amount, amountOutMinimum: 0 })
        );
        IERC20(token).forceApprove(swapRouter, 0);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolId id, uint256 amount) = abi.decode(data, (PoolId, uint256));
        _distribute(id, amount);
        return "";
    }

    /// @dev Redeem `amount` of the pool's accrued quote-token claim for real quote tokens and split it
    /// (platform / rewards / creator+splits), booking each to the pull ledger `owed[recipient][quote]`.
    function _distribute(PoolId id, uint256 amount) internal {
        TaxConfig storage c = config[id];
        address quote = c.quote;
        Currency qc = Currency.wrap(quote);

        qc.settle(poolManager, address(this), amount, true);
        poolManager.take(qc, address(this), amount);

        uint256 toPlatform = amount * PLATFORM_BPS / BPS;
        uint256 creatorPool = amount - toPlatform;

        if (toPlatform > 0) {
            address rtoken = refToken[id];
            address rs = poolRefSink[id]; // the sink snapshotted at markReferred — immune to a later re-point
            if (rtoken != address(0) && rs != address(0)) {
                // Gas floor (mirrors the rewards feed): stop a caller from supplying just enough gas to starve
                // the referral push into the catch and divert the referrer's reserved cut to the platform.
                if (gasleft() < 100_000) revert InsufficientGasForFeed();
                try this.pushReferral(rs, rtoken, quote, toPlatform) {
                    emit ReferralRouted(id, rtoken, toPlatform);
                } catch {
                    owed[platform][quote] += toPlatform;
                }
            } else {
                owed[platform][quote] += toPlatform;
            }
        }

        address tracker = c.rewardsTracker;
        if (tracker != address(0) && c.rewardsBps != 0 && creatorPool != 0) {
            uint256 toRewards = creatorPool * c.rewardsBps / BPS;
            if (toRewards != 0) {
                creatorPool -= toRewards;
                if (gasleft() < 100_000) revert InsufficientGasForFeed();
                try this.pushRewards(tracker, quote, toRewards) {
                    emit RewardsRouted(id, tracker, toRewards);
                } catch {
                    owed[c.creator][quote] += toRewards;
                }
            }
        }

        Split[] storage sp = creatorSplits[id];
        if (sp.length == 0) {
            if (creatorPool > 0) owed[c.creator][quote] += creatorPool;
        } else {
            uint256 rem = creatorPool;
            uint256 last = sp.length - 1;
            for (uint256 i; i <= last; i++) {
                uint256 part = i == last ? rem : (creatorPool * sp[i].bps) / BPS;
                rem -= part;
                if (part > 0) owed[sp[i].to][quote] += part;
            }
        }

        emit TaxDistributed(id, creatorPool, toPlatform);
    }

    /// @dev self-only external wrappers so a faulty tracker/splitter is isolated in a try/catch (an internal
    /// call can't be caught). They transfer the quote token then notify the sink.
    function pushReferral(address rs, address rtoken, address quote, uint256 amt) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(quote).safeTransfer(rs, amt);
        IPlatformFeeSinkToken(rs).onPlatformFeeToken(rtoken, quote, amt);
    }

    function pushRewards(address tracker, address quote, uint256 amt) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(quote).safeTransfer(tracker, amt);
        IDividendFeederToken(tracker).feedToken(amt);
    }

    function _maybeAutoDistribute(PoolId id, TaxConfig storage c) internal {
        if (!c.autoEnabled) return;
        uint256 acc = accruedQuote[id];
        if (c.autoThreshold == 0 || acc < c.autoThreshold) return;
        uint256 need = AUTO_DISTRIBUTE_BASE + creatorSplits[id].length * AUTO_DISTRIBUTE_PER_SPLIT;
        if (refToken[id] != address(0)) need += AUTO_DISTRIBUTE_REF;
        if (gasleft() < need) return;
        accruedQuote[id] = 0;
        // KNOWN, SAFE, SELF-HEALING GAP (found via fork test, not a security issue): autoDistribute's
        // poolManager.take() pulls REAL quote tokens out of the PoolManager, but V4 flash-accounting only
        // settles the CURRENT swapper's real payment at the very end of their unlock callback — AFTER this
        // hook callback returns. A freshly single-sided-seeded pool starts with ZERO real quote resident, so
        // the very FIRST swap that crosses the auto-threshold has nothing for take() to pull from and
        // reverts with ERC20InsufficientBalance. The try/catch below absorbs that: accruedQuote is restored,
        // no funds move, nothing is lost, and the very next qualifying swap succeeds once a prior swap's
        // real payment has landed in the pool. Manual distribute() is unaffected (it's always called
        // OUTSIDE any in-flight swap, once prior settlements have already landed) — see
        // test_auto_distribute_fires_inside_swap for the two-swap (cold-then-warm) proof.
        try this.autoDistribute(id, acc) {} catch { accruedQuote[id] = acc; }
    }

    function autoDistribute(PoolId id, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _distribute(id, amount);
    }
}
