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

import {LunchUpgradeable} from "./base/LunchUpgradeable.sol";
import {LunchTokenPlain} from "./LunchTokenPlain.sol";

interface IDividendFeeder {
    function feed() external payable;
}

/// @notice ReferralSplitter sink: the hook pushes a referred coin's platform-ETH cut here at distribution
/// time. The splitter reserves the referral share and keeps the remainder as withdrawable platform balance.
interface IPlatformFeeSink {
    function onPlatformFeeETH(address token) external payable;
}

/**
 * @title LunchTaxHook (UUPS-upgradeable)
 * @notice Shared Uniswap V4 hook powering lunch's "tax launches" on NATIVE-ETH pools. ETH tax skimmed
 *         all-in-ETH per swap into a per-pool ERC-6909 balance; {distribute} credits a pull ledger and
 *         {claim} withdraws. Platform 20% hardcoded; the creator routes their 80% (mutable split, CTO).
 *
 *         UPGRADEABLE: this contract runs behind an ERC1967 proxy whose ADDRESS carries the V4 permission
 *         flags. It does NOT inherit BaseHook (whose constructor validates address(this) — impossible for
 *         a non-mined implementation); instead it implements the IHooks callbacks directly. `poolManager`
 *         is immutable in the implementation (same across upgrades); all mutable state lives in proxy
 *         storage. The owner can upgrade the logic — an accepted, deliberate power concentration.
 */
contract LunchTaxHook is IUnlockCallback, LunchUpgradeable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    // ─── caps (basis points; 1% = 100 bps) ───
    uint16 internal constant BPS = 10_000;
    uint16 public constant MAX_SIDE_BPS = 500; // 5% per side (10% max round-trip; buy and sell independent)
    uint16 public constant PLATFORM_BPS = 2000; // 20%, HARDCODED
    uint16 public constant CREATOR_POOL_BPS = BPS - PLATFORM_BPS; // 80%
    uint256 public constant MAX_SPLIT_RECIPIENTS = 20;
    uint24 public constant POOL_FEE = 3000; // required 0.30% LP fee (locker compounds it)

    uint24 internal constant FEE_DENOM = 1e6;

    // ─── on-chain auto-distribution (no keeper) ───
    // A rewards pool auto-distributes its accrued ETH tax to holders IN the swap itself (in before/afterSwap,
    // already inside the PoolManager lock — no separate unlock needed) once accruedEth crosses `autoThreshold`.
    // Trading is the trigger; {distribute} remains as an optional manual flush.
    uint256 internal constant DEFAULT_AUTO_THRESHOLD = 0.02 ether; // used when a rewards launch leaves it 0
    // Best-effort in-swap distribute gas floor. Skip (never revert the trade) unless the swapper left enough
    // that _distribute COMPLETES without OOG (so it can't detonate mid-split-loop) AND the trailing in-swap token
    // _update keeps its gas. That _update has TWO sequential MIN_NOTIFY_GAS(175k) floors (one per setBalance
    // notify) with the heavy new-holder setBalance between them, so its real peak need is ~255k (not one 175k) —
    // plus ~30k of swap-finalize/settle/take overhead after afterSwap returns. BASE therefore reserves ~500k:
    // the O(1) distribute (settle/take/platform/feed ≈ 175k) + that ~255k trailing peak + ~70k margin. PER_SPLIT
    // (28k) covers each creator-split recipient (cold SSTORE_SET 22.1k + a cold SLOAD 2.1k) with honest slack.
    // Under-provisioning would let a heavy (many-split / first-feed / full-exit-sell) swap hard-revert the trade
    // or silently skip distribution; over-provisioning only skips the auto-flush on low-gas swaps (holders still
    // get paid via claim()/manual distribute()), so we err high.
    uint256 internal constant AUTO_DISTRIBUTE_BASE = 500_000;
    uint256 internal constant AUTO_DISTRIBUTE_PER_SPLIT = 28_000;
    // Extra headroom reserved when a pool is referred: the in-swap distribute additionally makes one external
    // call into the ReferralSplitter (value transfer + two cold SSTOREs in _credit + an event ≈ 55k). Reserve
    // ~90k so a referred rewards pool's auto-flush completes; under-provisioning only SKIPS the auto-flush
    // (holders/referrer still get paid via claim/manual distribute) since the whole distribute is try/caught.
    uint256 internal constant AUTO_DISTRIBUTE_REF = 90_000;

    struct TaxConfig {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        bool configured;
        bool autoEnabled;       // in-swap auto-distribution on the threshold (set for rewards pools). Packs into
                                // the same slot as the fields above (a previously-zero byte -> upgrade-safe).
        // ── rewards (appended; upgrade-safe — old configs read these as 0/none) ──
        address rewardsTracker; // 0 = not a rewards pool; else the coin's DividendTracker (fed the slice)
        uint16 rewardsBps;      // slice of the CREATOR pool routed to holders (bps of the 80%); 0 = none
        uint80 autoThreshold;   // accrued-ETH (wei) that triggers the in-swap auto-distribute; packs with the
                                // two fields above into one appended slot. uint80 max ≈ 1.2e24 wei (1.2M ETH).
    }

    struct Split {
        address to;
        uint16 bps;
    }

    /// @notice The V4 PoolManager. Immutable in the implementation; identical across upgrades.
    IPoolManager public immutable poolManager;

    mapping(address => bool) public isLauncher;
    address public platform;
    address public admin;

    mapping(PoolId => TaxConfig) public config;
    mapping(PoolId => Split[]) internal creatorSplits;
    mapping(PoolId => uint256) public accruedEth;
    mapping(address => uint256) public owed;

    // ── referrals (APPENDED — upgrade-safe; old pools read refToken as 0 and behave exactly as before) ──
    /// @notice The ReferralSplitter that receives referred coins' platform-ETH cut. 0 = referrals off.
    /// Must be registered as an authorizedPayer on the splitter; if not, routing reverts and falls back
    /// to owed[platform] (see {_distribute}), so a misconfig can never strand fees.
    address public referralSplitter;
    /// @notice pool → token, set by the launcher at launch ONLY for coins launched with a referrer. A
    /// nonzero entry routes that pool's platform cut to {referralSplitter} keyed by this token; a zero
    /// entry (every existing coin, and every unreferred launch) keeps crediting owed[platform] unchanged.
    mapping(PoolId => address) public refToken;

    event PoolConfigured(PoolId indexed poolId, address indexed creator, uint16 buyBps, uint16 sellBps);
    event TaxAccrued(PoolId indexed poolId, bool isBuy, uint256 ethAmount);
    event TaxDistributed(PoolId indexed poolId, uint256 toCreatorPool, uint256 toPlatform);
    event Claimed(address indexed recipient, uint256 amount);
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
    event PoolReferred(PoolId indexed poolId, address indexed token);
    event ReferralRouted(PoolId indexed poolId, address indexed token, uint256 amount);

    error NothingAccrued();
    error EthTransferFailed();
    error NotLauncher();
    error AlreadyConfigured();
    error NotConfigured();
    error SideCapExceeded();
    error BadSplit();
    error BadSplitLength();
    error ZeroAddress();
    error NotEthPool();
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

    /// @param pm the V4 PoolManager, baked into the implementation bytecode (constant across upgrades).
    constructor(IPoolManager pm) {
        poolManager = pm;
        _disableInitializers();
    }

    /// @notice Proxy initializer. Owner is set atomically (the deployer never owns the live proxy), so the
    ///         launcher is authorized by the owner via {setLauncher} right after wiring — the hook is inert
    ///         until then (no launcher => nothing can initialize or configure a pool). admin defaults to owner.
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
        admin = admin_; // admin==0 is intentional: it disables CTO (setTokenCreator). See test_setAdmin_zeroDisablesCTO.
        emit AdminSet(admin_);
    }

    /// @notice Enable/point (or disable, with 0) referral routing. When set, referred pools' platform cut is
    /// pushed to this ReferralSplitter; unreferred pools are unaffected. The splitter must authorize this hook
    /// as a payer (setPayer). If it doesn't, {_distribute}'s try/catch falls back to owed[platform].
    function setReferralSplitter(address s) external onlyOwner {
        referralSplitter = s;
        emit ReferralSplitterSet(s);
    }

    /// @notice Launcher-only, called at launch for a coin that HAS a referrer: marks the pool so its platform
    /// cut routes to the splitter. The referrer itself is named in the splitter by the launcher (not here) — this
    /// only flips on routing. Guarded exactly like {configurePool} (must be the token's own launcher) and one-shot.
    function markReferred(PoolKey calldata key) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        address token = Currency.unwrap(key.currency1);
        if (LunchTokenPlain(token).launcher() != msg.sender) revert NotLauncher();
        PoolId id = key.toId();
        if (!config[id].configured) revert NotConfigured();
        if (refToken[id] == address(0)) {
            refToken[id] = token;
            emit PoolReferred(id, token);
        }
    }

    // ─────────────────────── pool configuration ───────────────────────

    struct ConfigParams {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        address rewardsTracker; // 0 for a normal tax launch; the coin's tracker for a rewards launch
        uint16 rewardsBps;      // slice of the creator pool to holders (<= BPS)
    }

    function _checkShape(PoolKey calldata key) internal view {
        if (!key.currency0.isAddressZero()) revert NotEthPool();
        if (key.fee != POOL_FEE) revert BadPoolFee();
        if (address(key.hooks) != address(this)) revert WrongHook();
    }

    function configurePool(PoolKey calldata key, ConfigParams calldata p) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        _checkShape(key);
        if (LunchTokenPlain(Currency.unwrap(key.currency1)).launcher() != msg.sender) revert NotLauncher();

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
            autoEnabled: rewards, // rewards pools auto-distribute to holders in-swap; plain pools do not
            rewardsTracker: p.rewardsTracker, rewardsBps: rewards ? p.rewardsBps : 0,
            autoThreshold: rewards ? uint80(DEFAULT_AUTO_THRESHOLD) : 0 // creator can retune via setAutoThreshold
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

    /// @notice Creator-only: retune how much of their tax pool flows to holders. The reward ASSET is fixed
    /// at launch (the tracker is immutable); only the size of the slice is adjustable. No-op if the pool
    /// wasn't launched with a tracker.
    function setRewardsBps(PoolId id, uint16 rewardsBps) external {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        if (msg.sender != c.creator) revert NotCreator();
        if (c.rewardsTracker == address(0) || rewardsBps > BPS) revert BadRewardsBps();
        c.rewardsBps = rewardsBps;
        emit RewardsBpsSet(id, rewardsBps);
    }

    /// @notice Creator-only: retune the accrued-ETH threshold that triggers the in-swap auto-distribution.
    /// Lower = more frequent (more responsive, more gas on the triggering swap); higher = less frequent. Must
    /// be nonzero (0 would auto-distribute on every swap). Only for rewards pools; {distribute} stays available.
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

    /// @dev V4 permissions for tooling; the proxy ADDRESS is what the PoolManager actually reads.
    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
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

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (!isLauncher[sender]) revert NotLauncher();
        if (LunchTokenPlain(Currency.unwrap(key.currency1)).launcher() != sender) revert NotLauncher();
        _checkShape(key);
        return this.beforeInitialize.selector;
    }

    /// @dev Skims the ETH tax when ETH is the SPECIFIED currency (exact-in buys / exact-out sells).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();

        if (params.zeroForOne != (params.amountSpecified < 0)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 ethAmt =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _taxOn(c, params.zeroForOne, ethAmt);
        if (fee == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // KNOWN LIMITATION (documented, bounded): the beforeSwap skim is on the REQUESTED amount, not the
        // filled amount; a severe partial fill (price limit / liquidity exhaustion) over-taxes, bounded
        // by the 10% cap. Inherent to collecting the tax in ETH on the specified leg.
        key.currency0.take(poolManager, address(this), fee, true);
        accruedEth[id] += fee;
        emit TaxAccrued(id, params.zeroForOne, fee);
        // NB: auto-distribution runs in afterSwap, not here — this leg's accrual is picked up there, keeping a
        // single distribution point per swap.
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Skims the ETH tax when ETH is the UNSPECIFIED currency (exact-in sells / exact-out buys).
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();

        // Accrue only on the afterSwap leg (ETH is the UNSPECIFIED currency: exact-in sells / exact-out buys).
        int128 feeReturn = 0;
        if (params.zeroForOne != (params.amountSpecified < 0)) {
            int128 ethDelta = delta.amount0();
            if (ethDelta != 0) {
                uint256 ethAmt = ethDelta < 0 ? uint256(-int256(ethDelta)) : uint256(int256(ethDelta));
                uint256 fee = _taxOn(c, params.zeroForOne, ethAmt);
                if (fee != 0) {
                    key.currency0.take(poolManager, address(this), fee, true);
                    accruedEth[id] += fee;
                    emit TaxAccrued(id, params.zeroForOne, fee);
                    feeReturn = fee.toInt128();
                }
            }
        }
        // In-swap auto-distribution (no keeper) — runs for EVERY swap, picking up whatever accrued (this leg or
        // the beforeSwap leg or prior swaps) and booking it to holders. Best-effort; never reverts the trade. NB:
        // it books over the holder set as it stands DURING afterSwap — the triggering swapper's own token balance
        // settles in the router AFTER this returns, so a fresh buyer is not yet a holder for the batch they fund.
        _maybeAutoDistribute(id, c);
        return (this.afterSwap.selector, feeReturn);
    }

    function _taxOn(TaxConfig storage c, bool zeroForOne, uint256 ethAmount) internal view returns (uint256) {
        uint256 bps = zeroForOne ? c.buyBps : c.sellBps;
        if (bps == 0 || ethAmount == 0) return 0;
        return FullMath.mulDiv(ethAmount, bps * 100, FEE_DENOM);
    }

    // ─────────────────────── distribution (Claim) ───────────────────────

    function distribute(PoolId id) external nonReentrant {
        TaxConfig storage c = config[id];
        if (!c.configured) revert NotConfigured();
        uint256 amount = accruedEth[id];
        if (amount == 0) revert NothingAccrued();
        accruedEth[id] = 0;
        poolManager.unlock(abi.encode(id, amount));
    }

    function claim() external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingAccrued();
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Claimed(msg.sender, amount);
    }

    /// @notice Manual distribute path: unlock, then run the shared {_distribute}. Kept as an optional flush;
    /// rewards pools also auto-distribute in-swap, so this is not required for holders to be paid.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolId id, uint256 amount) = abi.decode(data, (PoolId, uint256));
        _distribute(id, amount);
        return "";
    }

    /// @dev Convert `amount` of the pool's accrued ETH (held as the hook's ERC-6909 claim) into real ETH and
    /// split it (platform / rewards tracker / creator+splits). MUST run INSIDE the PoolManager lock — reached
    /// from {unlockCallback} (manual {distribute}) or directly from before/afterSwap (the in-swap auto path).
    /// The caller has already zeroed accruedEth[id]. On the in-swap auto path it is invoked through
    /// {autoDistribute} inside a try/catch, so any revert here (feed gas-floor, or a `pm.take` shortfall on a
    /// young pool) is caught and can never revert the trade.
    function _distribute(PoolId id, uint256 amount) internal {
        TaxConfig storage c = config[id];
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;

        eth.settle(poolManager, address(this), amount, true);
        poolManager.take(eth, address(this), amount);

        uint256 toPlatform = amount * PLATFORM_BPS / BPS;
        uint256 creatorPool = amount - toPlatform;
        if (toPlatform > 0) {
            address rtoken = refToken[id];
            address rs = referralSplitter;
            if (rtoken != address(0) && rs != address(0)) {
                // Referred coin: push the platform cut (real ETH, already taken above) to the splitter, which
                // reserves the referral share and keeps the rest as withdrawable platform balance. try/catch so a
                // splitter fault (or an un-authorized hook) can never brick distribution — it degrades to
                // owed[platform], identical to an unreferred coin.
                try IPlatformFeeSink(rs).onPlatformFeeETH{value: toPlatform}(rtoken) {
                    emit ReferralRouted(id, rtoken, toPlatform);
                } catch {
                    owed[platform] += toPlatform;
                }
            } else {
                owed[platform] += toPlatform;
            }
        }

        // Holder rewards come OUT of the creator pool (platform's 20% is untouched). Pushed to the coin's
        // tracker as native ETH and booked to holders. try/catch with a creator fallback so a tracker fault
        // can never brick the whole distribution.
        address tracker = c.rewardsTracker;
        if (tracker != address(0) && c.rewardsBps != 0 && creatorPool != 0) {
            uint256 toRewards = creatorPool * c.rewardsBps / BPS;
            if (toRewards != 0) {
                creatorPool -= toRewards;
                // gas floor so `distribute` can't be called with tuned gas to STARVE feed into the catch
                // and quietly divert the holders' slice to the creator. feed is cheap; honest calls exceed this.
                if (gasleft() < 100_000) revert InsufficientGasForFeed();
                try IDividendFeeder(tracker).feed{value: toRewards}() {
                    emit RewardsRouted(id, tracker, toRewards);
                } catch {
                    owed[c.creator] += toRewards; // fallback: pay the creator, never strand ETH
                }
            }
        }

        Split[] storage sp = creatorSplits[id];
        if (sp.length == 0) {
            if (creatorPool > 0) owed[c.creator] += creatorPool;
        } else {
            uint256 rem = creatorPool;
            uint256 last = sp.length - 1;
            for (uint256 i; i <= last; i++) {
                uint256 part = i == last ? rem : (creatorPool * sp[i].bps) / BPS;
                rem -= part;
                if (part > 0) owed[sp[i].to] += part;
            }
        }

        emit TaxDistributed(id, creatorPool, toPlatform);
    }

    /// @dev In-swap auto-distribution (no keeper). Called from afterSwap after accruing this swap's tax.
    /// Best-effort and can NEVER revert the trade: it skips when the pool isn't a rewards pool, when accrued ETH
    /// is below the threshold, or when the swapper didn't leave enough gas; and it isolates the distribution
    /// itself in a try/catch so an in-swap failure (see {autoDistribute}) degrades to "skipped, retried later".
    function _maybeAutoDistribute(PoolId id, TaxConfig storage c) internal {
        if (!c.autoEnabled) return;         // free (same slot as `configured`, already warm)
        uint256 acc = accruedEth[id];       // warm (just written by the accrual)
        if (acc < c.autoThreshold) return;
        // Only attempt when _distribute can run to completion AND leave the trailing token _update its floor.
        // Referred pools additionally push to the splitter, so reserve extra headroom for that external call.
        uint256 need = AUTO_DISTRIBUTE_BASE + creatorSplits[id].length * AUTO_DISTRIBUTE_PER_SPLIT;
        if (refToken[id] != address(0)) need += AUTO_DISTRIBUTE_REF;
        if (gasleft() < need) return;
        accruedEth[id] = 0;
        // Isolate the distribution. Its `pm.take` redeems this pool's accrued ETH claim for REAL ETH mid-swap,
        // but the current swap's incoming ETH has NOT settled yet — on a young/low-reserve pool the PoolManager's
        // physical ETH can momentarily be short and `take` reverts. Catching it lets the swap proceed and retries
        // the accrual on the next swap / a manual distribute(); accruedEth is restored because we zeroed it above.
        try this.autoDistribute(id, acc) {} catch { accruedEth[id] = acc; }
    }

    /// @dev External self-only wrapper so {_maybeAutoDistribute} can isolate an in-swap distribution failure in a
    /// try/catch (an internal call can't be caught; a revert here rolls this frame back atomically).
    function autoDistribute(PoolId id, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _distribute(id, amount);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }
}
