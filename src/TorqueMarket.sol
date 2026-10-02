// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal, IUniswapV3SwapCallback} from "./interfaces/IExternal.sol";
import {ITorqueMarket, ITorqueVault} from "./interfaces/ITorque.sol";

/// @title TorqueMarket
/// @notice Long-only knock-out leverage on NVDA, settled in USDG.
///         Each position is hedged 1:1: its leveraged notional is swapped into NVDA in the
///         NVDA/USDG Uniswap v3 pool and held here. The vault lends the difference and is repaid
///         first on exit. The trader can never lose more than their margin.
/// @dev    See SPEC.md. No owner, no pause, no upgrade. All parameters are constants.
contract TorqueMarket is ITorqueMarket, IUniswapV3SwapCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant MAX_OPEN_NOTIONAL = 30e6; // 1.5x the $20 vault cap
    uint256 public constant MAX_UTILIZATION_BPS = 8_000;
    uint256 public constant MAX_OPEN_POSITIONS = 32;
    uint256 public constant MIN_LEVERAGE_BPS = 20_000;
    uint256 public constant MAX_LEVERAGE_BPS = 50_000;
    uint256 public constant KO_BUFFER_BPS = 500;
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    uint256 public constant FINANCING_APR_BPS = 1_000;
    uint256 public constant OPEN_FEE_BPS = 10;
    uint256 public constant MIN_MARGIN = 1e6;
    uint256 public constant MAX_FEED_AGE = 12 hours;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint256 public constant MAX_POOL_DEVIATION_BPS = 150;
    /// After this long without a usable feed print, anyone may unwind positions at the pool's 30-minute
    /// average so LP funds can never be locked by a dead feed. The longest normal freeze measured is 78h.
    uint256 public constant DEAD_FEED_AFTER = 7 days;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    IERC20 public immutable usdg;
    IERC20 public immutable nvda;
    IUniswapV3PoolMinimal public immutable pool;
    IAggregatorV3 public immutable feed;
    ITorqueVault public immutable vault;
    bool internal immutable usdgIsToken0;
    uint256 internal immutable feedUnit; // 10 ** feed decimals

    uint256 public totalPrincipal;
    uint256 public totalNotional;
    uint256 public totalBadDebt;
    uint256 public totalClaimable;
    uint256 public nextId = 1;
    /// When a reverting or non-positive feed was first reported (0 = feed working). A broken feed has no
    /// updatedAt to age, so the dead-feed clock for it starts here.
    uint256 public feedDownSince;

    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256) public claimable;
    uint256[] internal _openIds;
    mapping(uint256 => uint256) internal _indexPlusOne;
    bool internal _swapping;

    error PartialFill();
    error BadConfig();
    error FeedNotDead();

    event Claimed(address indexed owner, uint256 amount);
    event Unwound(uint256 indexed id, uint256 price, uint256 proceeds, uint256 repaid, uint256 payout, uint256 badDebt);

    constructor(IERC20 usdg_, IERC20 nvda_, IUniswapV3PoolMinimal pool_, IAggregatorV3 feed_, ITorqueVault vault_) {
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        bool zeroIsUsdg = t0 == address(usdg_) && t1 == address(nvda_);
        if (!zeroIsUsdg && !(t0 == address(nvda_) && t1 == address(usdg_))) revert BadConfig();
        if (IERC20Metadata(address(usdg_)).decimals() != 6 || IERC20Metadata(address(nvda_)).decimals() != 18) {
            revert BadConfig();
        }
        if (IERC4626(address(vault_)).asset() != address(usdg_)) revert BadConfig();
        usdg = usdg_;
        nvda = nvda_;
        pool = pool_;
        feed = feed_;
        vault = vault_;
        usdgIsToken0 = zeroIsUsdg;
        feedUnit = 10 ** feed_.decimals();
    }

    // ------------------------------------------------------------------ views

    /// @notice NVDA price in USDG units (6 decimals) per whole NVDA token, and whether it is fresh.
    function oraclePrice() public view returns (uint256 price6, bool fresh) {
        uint256 age;
        (price6, age) = _readFeed();
        fresh = price6 > 0 && age <= MAX_FEED_AGE;
    }

    /// @dev A reverting or non-positive feed reads as "no price" (0, max age); it never reverts.
    function _readFeed() internal view returns (uint256 price6, uint256 age) {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer > 0) price6 = uint256(answer) * 1e6 / feedUnit;
            age = updatedAt <= block.timestamp ? block.timestamp - updatedAt : type(uint256).max;
            if (price6 == 0) age = type(uint256).max;
        } catch {
            return (0, type(uint256).max);
        }
    }

    /// @notice NVDA price from the hedge pool's own 30-minute time-weighted average tick, in USDG
    ///         (6 decimals) per whole NVDA. Returns 0 if the pool cannot serve the window.
    function poolTwapPrice() public view returns (uint256 price6) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int56 window = int56(uint56(TWAP_WINDOW));
            int56 avg = delta / window;
            if (delta < 0 && delta % window != 0) avg--; // round toward negative infinity
            price6 = _tickToPrice6(avg);
        } catch {
            price6 = 0;
        }
    }

    /// @notice Torque's two price safety checks and the numbers behind them.
    function priceStatus()
        public
        view
        returns (uint256 feedPrice6, uint256 feedAge, uint256 poolTwap6, uint256 deviationBps, bool feedFresh, bool poolAgrees)
    {
        (feedPrice6, feedAge) = _readFeed();
        feedFresh = feedPrice6 > 0 && feedAge <= MAX_FEED_AGE;
        poolTwap6 = poolTwapPrice();
        if (feedPrice6 > 0 && poolTwap6 > 0) {
            uint256 diff = poolTwap6 > feedPrice6 ? poolTwap6 - feedPrice6 : feedPrice6 - poolTwap6;
            deviationBps = diff * BPS / feedPrice6;
            poolAgrees = diff * BPS <= MAX_POOL_DEVIATION_BPS * feedPrice6;
        }
    }

    function isPriceOk() public view returns (bool) {
        (,,,, bool feedFresh, bool poolAgrees) = priceStatus();
        return feedFresh && poolAgrees;
    }

    function debtOf(uint256 id) public view returns (uint256) {
        return _debt(_get(id));
    }

    /// @notice NVDA price at which the position is worth zero.
    function financingLevelOf(uint256 id) public view returns (uint256) {
        Position memory p = _get(id);
        return Math.mulDiv(_debt(p), 1e18, p.q, Math.Rounding.Ceil);
    }

    /// @notice NVDA price at or below which anyone may knock the position out.
    function barrierOf(uint256 id) public view returns (uint256) {
        Position memory p = _get(id);
        return _barrier(_debt(p), p.q);
    }

    /// @notice Loans marked at min(debt, collateral at the lower of Chainlink and the pool's 30-minute
    ///         average, less max slippage). Conservative on purpose: a lagging or frozen feed never
    ///         props NAV up while the market trades lower.
    function markedDebt() external view returns (uint256 marked) {
        uint256 n = _openIds.length;
        if (n == 0) return 0; // no loans: NAV is idle cash, no price needed
        (uint256 price6,) = oraclePrice();
        uint256 twap6 = poolTwapPrice();
        if (twap6 < price6) price6 = twap6;
        for (uint256 i; i < n; i++) {
            Position memory p = _positions[_openIds[i]];
            uint256 debt = _debt(p);
            uint256 value = _minOut(p.q, price6);
            marked += debt < value ? debt : value;
        }
    }

    function getPosition(uint256 id) external view returns (Position memory) {
        return _get(id);
    }

    function openPositionIds() external view returns (uint256[] memory) {
        return _openIds;
    }

    function openPositionCount() external view returns (uint256) {
        return _openIds.length;
    }

    /// @notice What an open with these inputs would do at the current feed price (before slippage).
    function quoteOpen(uint256 margin, uint256 leverageBps)
        external
        view
        returns (uint256 fee, uint256 notional, uint256 borrow, uint256 estQ, uint256 estBarrier)
    {
        (fee, notional, borrow) = _sizes(margin, leverageBps);
        (uint256 price6,) = oraclePrice();
        if (price6 == 0) return (fee, notional, borrow, 0, 0);
        estQ = notional * 1e18 / price6;
        if (estQ > 0) estBarrier = _barrier(borrow, estQ);
    }

    // ------------------------------------------------------------------ trader actions

    function open(uint256 margin, uint256 leverageBps, uint256 minNvdaOut) external nonReentrant returns (uint256 id) {
        uint256 price6 = _checkedPrice();
        if (feedDownSince != 0) feedDownSince = 0; // a healthy print just read: clear any dead-feed clock
        if (leverageBps < MIN_LEVERAGE_BPS || leverageBps > MAX_LEVERAGE_BPS) revert BadLeverage();
        if (margin < MIN_MARGIN) revert MarginTooSmall();
        if (_openIds.length >= MAX_OPEN_POSITIONS) revert TooManyPositions();

        (uint256 fee, uint256 notional, uint256 borrow) = _sizes(margin, leverageBps);
        if (totalNotional + notional > MAX_OPEN_NOTIONAL) revert OpenInterestCap();
        uint256 assets = IERC4626(address(vault)).totalAssets();
        if ((totalPrincipal + borrow) * BPS > MAX_UTILIZATION_BPS * assets) revert UtilizationCap();

        usdg.safeTransferFrom(msg.sender, address(this), margin);
        usdg.safeTransfer(address(vault), fee);
        vault.lend(borrow);

        uint256 q = _swap(true, notional);
        if (q < minNvdaOut || q < notional * 1e18 / price6 * (BPS - MAX_SLIPPAGE_BPS) / BPS) revert Slippage();

        id = nextId++;
        _positions[id] = Position({
            owner: msg.sender,
            q: q.toUint128(),
            principal: borrow.toUint128(),
            notional: notional.toUint128(),
            margin: margin.toUint128(),
            openedAt: uint64(block.timestamp)
        });
        _openIds.push(id);
        _indexPlusOne[id] = _openIds.length;
        totalPrincipal += borrow;
        totalNotional += notional;

        emit Opened(id, msg.sender, margin, leverageBps, q, borrow);
    }

    /// @notice Exit at the pool price. Works on a stale feed, but only if the vault is repaid in full.
    function close(uint256 id, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        Position memory p = _get(id);
        if (p.owner != msg.sender) revert NotOwner();
        _clearFeedDownIfHealthy();
        uint256 debt = _debt(p);
        _remove(id, p);

        uint256 proceeds = _swap(false, p.q);
        if (proceeds < debt) revert Underwater();
        payout = proceeds - debt;
        if (payout < minPayout) revert Slippage();

        usdg.safeTransfer(address(vault), debt);
        if (payout > 0) usdg.safeTransfer(p.owner, payout);
        emit Closed(id, proceeds, debt, payout);
    }

    /// @notice Anyone may knock out a position once a fresh feed price is at or below its barrier.
    ///         The vault is repaid first; any residual is credited to the trader to claim.
    function knockOut(uint256 id) external nonReentrant returns (uint256 payout) {
        (uint256 price6, uint256 feedAge,,, bool feedFresh, bool poolAgrees) = priceStatus();
        if (!feedFresh) revert StaleFeed();
        // A Chainlink print from the last 30 minutes is trusted over a lagging 30-minute pool average,
        // so a fast in-session sell-off cannot hold up a knock-out. An older print must agree with the pool.
        if (!poolAgrees && feedAge > TWAP_WINDOW) revert PoolPriceMismatch();
        if (feedDownSince != 0) feedDownSince = 0;
        Position memory p = _get(id);
        uint256 debt = _debt(p);
        if (price6 > _barrier(debt, p.q)) revert NotKnockable();
        _remove(id, p);

        uint256 proceeds = _swap(false, p.q);
        if (proceeds < _minOut(p.q, price6)) revert Slippage();

        uint256 repaid = proceeds < debt ? proceeds : debt;
        payout = proceeds - repaid;
        uint256 badDebt = debt - repaid;
        totalBadDebt += badDebt;

        usdg.safeTransfer(address(vault), repaid);
        if (payout > 0) {
            claimable[p.owner] += payout;
            totalClaimable += payout;
        }
        emit KnockedOut(id, price6, proceeds, repaid, payout, badDebt);
    }

    /// @notice Emergency exit for a dead feed (no usable print for DEAD_FEED_AFTER). Anyone may unwind any
    ///         position at the pool's 30-minute average less max slippage. The vault is repaid first, the
    ///         residual is credited to the trader to claim, and any shortfall is bad debt.
    function unwind(uint256 id) external nonReentrant returns (uint256 payout) {
        if (!isFeedDead()) revert FeedNotDead();
        uint256 twap6 = poolTwapPrice();
        if (twap6 == 0) revert PoolPriceMismatch();
        Position memory p = _get(id);
        uint256 debt = _debt(p);
        _remove(id, p);

        uint256 proceeds = _swap(false, p.q);
        if (proceeds < _minOut(p.q, twap6)) revert Slippage();

        uint256 repaid = proceeds < debt ? proceeds : debt;
        payout = proceeds - repaid;
        uint256 badDebt = debt - repaid;
        totalBadDebt += badDebt;

        usdg.safeTransfer(address(vault), repaid);
        if (payout > 0) {
            claimable[p.owner] += payout;
            totalClaimable += payout;
        }
        emit Unwound(id, twap6, proceeds, repaid, payout, badDebt);
    }

    /// @notice True once the feed has gone DEAD_FEED_AFTER without a usable print: either its last print is
    ///         that old, or it has been reverting/non-positive since a report at least that long ago.
    function isFeedDead() public view returns (bool) {
        (uint256 price6, uint256 age) = _readFeed();
        if (price6 > 0) return age > DEAD_FEED_AFTER;
        return feedDownSince != 0 && block.timestamp - feedDownSince > DEAD_FEED_AFTER;
    }

    /// @notice Anyone may start (or clear) the dead-feed clock for a feed that reverts or returns <= 0.
    function reportFeedDown() external {
        (uint256 price6,) = _readFeed();
        if (price6 > 0) feedDownSince = 0;
        else if (feedDownSince == 0) feedDownSince = block.timestamp;
    }

    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        if (amount > 0) usdg.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------ swap

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(pool) || !_swapping) revert Unauthorized();
        if (amount0Delta > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Exact-input swap through the hedge pool. Reverts unless the full input is consumed.
    function _swap(bool buyNvda, uint256 amountIn) internal returns (uint256 amountOut) {
        bool zeroForOne = buyNvda == usdgIsToken0;
        _swapping = true;
        (int256 a0, int256 a1) = pool.swap(
            address(this),
            zeroForOne,
            amountIn.toInt256(),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            ""
        );
        _swapping = false;
        (int256 paid, int256 got) = zeroForOne ? (a0, a1) : (a1, a0);
        if (paid != amountIn.toInt256() || got > 0) revert PartialFill();
        amountOut = uint256(-got);
    }

    // ------------------------------------------------------------------ internals

    function _clearFeedDownIfHealthy() internal {
        if (feedDownSince == 0) return;
        (uint256 price6,) = _readFeed();
        if (price6 > 0) feedDownSince = 0;
    }

    /// @dev Both safety checks: a fresh feed, and agreement with the pool's 30-minute average.
    function _checkedPrice() internal view returns (uint256 price6) {
        (uint256 feedPrice6,,,, bool feedFresh, bool poolAgrees) = priceStatus();
        if (!feedFresh) revert StaleFeed();
        if (!poolAgrees) revert PoolPriceMismatch();
        return feedPrice6;
    }

    /// @dev Pool tick to USDG (6 decimals) per whole NVDA (18 decimals).
    ///      ratio = 1.0001^tick = token1 raw / token0 raw, computed in 1e18 fixed point.
    function _tickToPrice6(int56 tick) internal view returns (uint256) {
        uint256 absTick = tick < 0 ? uint256(uint56(-tick)) : uint256(uint56(tick));
        if (absTick > 887_272) return 0;
        uint256 r = _pow1e18(1.0001e18, absTick);
        if (tick < 0) r = Math.mulDiv(1e18, 1e18, r);
        // USDG token0: ratio = nvdaRaw / usdgRaw, so 1e18 nvdaRaw costs 1e18 / ratio usdgRaw.
        // USDG token1: ratio = usdgRaw / nvdaRaw, so 1e18 nvdaRaw costs 1e18 * ratio usdgRaw.
        return usdgIsToken0 ? Math.mulDiv(1e18, 1e18, r) : r;
    }

    /// @dev base^exp for a 1e18 fixed-point base, by repeated squaring with 512-bit intermediates.
    function _pow1e18(uint256 base, uint256 exp) internal pure returns (uint256 r) {
        r = 1e18;
        while (exp > 0) {
            if (exp & 1 == 1) r = Math.mulDiv(r, base, 1e18);
            exp >>= 1;
            if (exp > 0) base = Math.mulDiv(base, base, 1e18);
        }
    }

    function _sizes(uint256 margin, uint256 leverageBps)
        internal
        pure
        returns (uint256 fee, uint256 notional, uint256 borrow)
    {
        fee = margin * leverageBps / BPS * OPEN_FEE_BPS / BPS;
        uint256 equity = margin - fee;
        notional = equity * leverageBps / BPS;
        borrow = notional - equity;
    }

    function _debt(Position memory p) internal view returns (uint256) {
        uint256 dt = block.timestamp - p.openedAt;
        return p.principal + Math.mulDiv(p.principal, FINANCING_APR_BPS * dt, BPS * YEAR, Math.Rounding.Ceil);
    }

    function _barrier(uint256 debt, uint256 q) internal pure returns (uint256) {
        uint256 level = Math.mulDiv(debt, 1e18, q, Math.Rounding.Ceil);
        return Math.mulDiv(level, BPS + KO_BUFFER_BPS, BPS, Math.Rounding.Ceil);
    }

    function _minOut(uint256 q, uint256 price6) internal pure returns (uint256) {
        return q * price6 / 1e18 * (BPS - MAX_SLIPPAGE_BPS) / BPS;
    }

    function _get(uint256 id) internal view returns (Position memory p) {
        p = _positions[id];
        if (p.owner == address(0)) revert UnknownPosition();
    }

    function _remove(uint256 id, Position memory p) internal {
        uint256 idx = _indexPlusOne[id] - 1;
        uint256 last = _openIds[_openIds.length - 1];
        _openIds[idx] = last;
        _indexPlusOne[last] = idx + 1;
        _openIds.pop();
        delete _indexPlusOne[id];
        delete _positions[id];
        totalPrincipal -= p.principal;
        totalNotional -= p.notional;
    }
}
