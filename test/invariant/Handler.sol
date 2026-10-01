// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockToken, MockFeed, MockPool} from "../mocks/Mocks.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";
import {ITorqueMarket} from "../../src/interfaces/ITorque.sol";

/// @notice Drives the vault and market through deposits, withdrawals, opens, closes, knock-outs,
///         in-session price moves, weekends with a frozen feed, and gaps.
///         Every expected value is recomputed here from SPEC.md formulas, independently of the
///         contracts, and violations are counted in ghost variables that the invariants assert are zero.
contract Handler is Test {
    // Spec mirror (SPEC.md). Kept separate from the contracts on purpose.
    uint256 constant CAP = 20e6;
    uint256 constant MAX_OPEN_NOTIONAL = 30e6;
    uint256 constant TWAP_WINDOW = 30 minutes;
    uint256 constant BAND_BPS = 150;
    /// Only states clearly outside the band (beyond tick rounding) are classified as "must refuse".
    uint256 constant AMBIGUITY_BPS = 2; // tick rounding only
    uint256 constant UTIL_BPS = 8_000;
    uint256 constant MAX_POSITIONS = 32;
    uint256 constant KO_BPS = 500;
    uint256 constant SLIP_BPS = 100;
    uint256 constant APR_BPS = 1_000;
    uint256 constant FEE_BPS = 10;
    uint256 constant MIN_MARGIN = 1e6;
    uint256 constant BPS = 10_000;
    uint256 constant YEAR = 365 days;
    /// A drop larger than this between two fresh prices may legitimately create bad debt (SPEC.md).
    uint256 constant SAFE_DROP_BPS = 370;
    uint256 constant MIN_PRICE = 40e6;
    uint256 constant MAX_PRICE = 600e6;

    MockToken public usdg;
    MockToken public nvda;
    MockFeed public feed;
    MockPool public pool;
    TorqueVault public vault;
    TorqueMarket public market;
    uint256 public maxFeedAge;

    address[] internal lps;
    address[] internal traders;

    // Ghost cash flows into and out of the vault.
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostLent;
    uint256 public ghostRepaid;
    uint256 public ghostFees;
    uint256 public ghostBadDebt;

    // Violation counters (all must stay zero).
    uint256 public capViolations;
    uint256 public utilViolations;
    uint256 public staleSuccesses; // succeeded while stale or while the pool clearly disagreed
    uint256 public payoutViolations;
    uint256 public hedgeViolations;
    uint256 public badDebtWithoutGap;

    bool public gapHappened;
    bool public weekend;
    uint256 public fridayPrice;
    uint256 public price6 = 231_40e4; // $231.40, as on 2026-10-01

    // Call counters, for the coverage report.
    mapping(bytes32 => uint256) public calls;
    mapping(bytes4 => uint256) public openRevertReasons;

    constructor(MockToken _usdg, MockToken _nvda, MockFeed _feed, MockPool _pool, TorqueVault _vault, TorqueMarket _market)
    {
        usdg = _usdg;
        nvda = _nvda;
        feed = _feed;
        pool = _pool;
        vault = _vault;
        market = _market;
        maxFeedAge = market.MAX_FEED_AGE();
        for (uint256 i; i < 3; i++) {
            address lp = makeAddr(string.concat("lp", vm.toString(i)));
            address tr = makeAddr(string.concat("trader", vm.toString(i)));
            lps.push(lp);
            traders.push(tr);
            usdg.mint(lp, 1_000_000e6);
            usdg.mint(tr, 1_000_000e6);
            vm.prank(lp);
            usdg.approve(address(vault), type(uint256).max);
            vm.prank(tr);
            usdg.approve(address(market), type(uint256).max);
        }
        histTime.push(block.timestamp - 1 days); // mirrors the mock pool's initial history
        histPrice.push(price6);
        // Start with a funded vault so positions can open from the first call.
        uint256 before = usdg.balanceOf(lps[0]);
        vm.prank(lps[0]);
        vault.deposit(15e6, lps[0]);
        ghostDeposited += before - usdg.balanceOf(lps[0]);
    }

    // ---------------------------------------------------------------- helpers

    /// True (skip) except roughly 1 in n calls. Hashing defeats the fuzzer's bias toward small seeds.
    function _roll(uint256 seed, uint256 n) internal pure returns (bool skip) {
        return uint256(keccak256(abi.encode(seed))) % n != 0;
    }

    function _fresh() internal view returns (bool) {
        uint256 t = feed.updatedAt();
        return feed.answer() > 0 && t <= block.timestamp && block.timestamp - t <= maxFeedAge;
    }

    // Independent record of the pool's spot price over time, for an arithmetic 30-minute average.
    uint256[] internal histTime;
    uint256[] internal histPrice;

    function _recordPool(uint256 p) internal {
        if (histTime.length > 0 && histTime[histTime.length - 1] == block.timestamp) {
            histPrice[histPrice.length - 1] = p;
        } else {
            histTime.push(block.timestamp);
            histPrice.push(p);
        }
    }

    /// Geometric 30-minute average, like Uniswap's: average the ticks, then convert. Uses the mock's own
    /// tick functions (a binary-search inverse), not the market's conversion.
    function _poolTwap() public view returns (uint256) {
        uint256 from = block.timestamp - TWAP_WINDOW;
        int256 acc;
        uint256 i = histTime.length - 1;
        uint256 end = block.timestamp;
        while (true) {
            uint256 st = histTime[i] > from ? histTime[i] : from;
            acc += pool.tickForPrice6(histPrice[i]) * int256(end - st);
            if (histTime[i] <= from || i == 0) break;
            end = histTime[i];
            i--;
        }
        int256 avg = acc / int256(TWAP_WINDOW);
        if (acc < 0 && acc % int256(TWAP_WINDOW) != 0) avg--;
        return pool.price6ForTick(avg);
    }

    /// The pool's 30-minute average is clearly outside the 1.5% band around the feed.
    function _clearlyDiverged() internal view returns (bool) {
        uint256 f = uint256(feed.answer()) / 100;
        uint256 t = _poolTwap();
        uint256 diff = t > f ? t - f : f - t;
        return diff * BPS > (BAND_BPS + AMBIGUITY_BPS) * f;
    }

    /// Opens and LP flows: refused when stale or when the pool clearly disagrees.
    function _mustRefuse() internal view returns (bool) {
        return !_fresh() || _clearlyDiverged();
    }

    /// Knock-outs: a feed printed within the last 30 minutes is trusted over a lagging average.
    function _mustRefuseKnock() internal view returns (bool) {
        if (!_fresh()) return true;
        if (block.timestamp - feed.updatedAt() <= TWAP_WINDOW) return false;
        return _clearlyDiverged();
    }

    function _debt(ITorqueMarket.Position memory p) internal view returns (uint256) {
        uint256 dt = block.timestamp - p.openedAt;
        uint256 num = uint256(p.principal) * APR_BPS * dt;
        uint256 den = BPS * YEAR;
        return p.principal + (num + den - 1) / den;
    }

    function _barrier(ITorqueMarket.Position memory p) internal view returns (uint256) {
        uint256 f = (_debt(p) * 1e18 + p.q - 1) / p.q;
        return (f * (BPS + KO_BPS) + BPS - 1) / BPS;
    }

    function _pickId(uint256 seed) internal view returns (bool ok, uint256 id) {
        uint256[] memory ids = market.openPositionIds();
        if (ids.length == 0) return (false, 0);
        return (true, ids[seed % ids.length]);
    }

    uint256 public minSeen = type(uint256).max;
    uint256 public maxSeen;
    uint256 public maxConcurrent;

    function _setPool(uint256 p) internal {
        pool.setPrice(p);
        _recordPool(p);
    }

    function _setPrice(uint256 p) internal {
        if (p < minSeen) minSeen = p;
        if (p > maxSeen) maxSeen = p;
        price6 = p;
        _setPool(p);
        feed.push(int256(p * 100)); // 6 -> 8 decimals
    }

    /// Keeper: knock out everything at or below its barrier while the feed is fresh.
    function _sweep() internal {
        if (_mustRefuseKnock()) return;
        uint256[] memory ids = market.openPositionIds();
        for (uint256 i; i < ids.length; i++) {
            ITorqueMarket.Position memory p = market.getPosition(ids[i]);
            if (price6 <= _barrier(p)) _knock(ids[i]);
        }
    }

    function _knock(uint256 id) internal {
        ITorqueMarket.Position memory p = market.getPosition(id);
        bool fresh = !_mustRefuseKnock();
        uint256 debt = _debt(p);
        uint256 proceeds = pool.quoteSell(p.q);
        uint256 repaid = proceeds < debt ? proceeds : debt;
        uint256 payout = proceeds - repaid;
        uint256 bad = debt - repaid;
        uint256 ownerBefore = market.claimable(p.owner);
        try market.knockOut(id) returns (uint256 got) {
            if (!fresh) staleSuccesses++;
            if (got != payout || market.claimable(p.owner) - ownerBefore != payout) payoutViolations++;
            ghostRepaid += repaid;
            ghostBadDebt += bad;
            if (bad > 0 && !gapHappened) badDebtWithoutGap++;
            calls["knockOut.ok"]++;
        } catch {
            calls["knockOut.revert"]++;
        }
    }

    // ---------------------------------------------------------------- LP actions

    function deposit(uint256 actor, uint256 amount) external {
        address lp = lps[actor % lps.length];
        amount = bound(amount, 1, 25e6);
        bool fresh = !_mustRefuse();
        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp);
        try vault.deposit(amount, lp) {
            if (!fresh) staleSuccesses++;
            ghostDeposited += before - usdg.balanceOf(lp);
            if (vault.totalAssets() > CAP) capViolations++;
            calls["deposit.ok"]++;
        } catch {
            calls["deposit.revert"]++;
        }
    }

    function mint(uint256 actor, uint256 shares) external {
        address lp = lps[actor % lps.length];
        shares = bound(shares, 1, 25e6 * 1e6);
        bool fresh = !_mustRefuse();
        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp);
        try vault.mint(shares, lp) {
            if (!fresh) staleSuccesses++;
            ghostDeposited += before - usdg.balanceOf(lp);
            if (vault.totalAssets() > CAP) capViolations++;
            calls["mint.ok"]++;
        } catch {
            calls["mint.revert"]++;
        }
    }

    function withdraw(uint256 actor, uint256 amount) external {
        address lp = lps[actor % lps.length];
        amount = bound(amount, 1, 25e6);
        bool fresh = !_mustRefuse();
        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp);
        try vault.withdraw(amount, lp, lp) {
            if (!fresh) staleSuccesses++;
            ghostWithdrawn += usdg.balanceOf(lp) - before;
            calls["withdraw.ok"]++;
        } catch {
            calls["withdraw.revert"]++;
        }
    }

    function redeem(uint256 actor, uint256 shares) external {
        address lp = lps[actor % lps.length];
        shares = bound(shares, 1, vault.balanceOf(lp) + 1);
        bool fresh = !_mustRefuse();
        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp);
        try vault.redeem(shares, lp, lp) {
            if (!fresh) staleSuccesses++;
            ghostWithdrawn += usdg.balanceOf(lp) - before;
            calls["redeem.ok"]++;
        } catch {
            calls["redeem.revert"]++;
        }
    }

    // ---------------------------------------------------------------- trader actions

    function open(uint256 actor, uint256 margin, uint256 leverageBps) external {
        address tr = traders[actor % traders.length];
        margin = bound(margin, MIN_MARGIN / 2, 5e6);
        leverageBps = bound(leverageBps, 15_000, 55_000);
        bool fresh = !_mustRefuse();

        uint256 gross = margin * leverageBps / BPS;
        uint256 fee = gross * FEE_BPS / BPS;
        uint256 equity = margin - fee;
        uint256 notional = equity * leverageBps / BPS;
        uint256 borrow = notional - equity;
        uint256 assetsBefore = vault.totalAssets();
        uint256 principalBefore = market.totalPrincipal();
        uint256 expectedQ = pool.quoteBuy(notional);

        vm.prank(tr);
        try market.open(margin, leverageBps, 0) returns (uint256 id) {
            if (!fresh) staleSuccesses++;
            ITorqueMarket.Position memory p = market.getPosition(id);
            if (p.q != expectedQ || p.principal != borrow || p.notional != notional) hedgeViolations++;
            if (leverageBps < 20_000 || leverageBps > 50_000 || margin < MIN_MARGIN) utilViolations++;
            if ((principalBefore + borrow) * BPS > UTIL_BPS * assetsBefore) utilViolations++;
            if (market.totalNotional() > MAX_OPEN_NOTIONAL) utilViolations++;
            if (market.openPositionIds().length > MAX_POSITIONS) utilViolations++;
            ghostFees += fee;
            ghostLent += borrow;
            if (market.openPositionIds().length > maxConcurrent) maxConcurrent = market.openPositionIds().length;
            calls["open.ok"]++;
        } catch (bytes memory err) {
            calls["open.revert"]++;
            openRevertReasons[bytes4(err)]++;
        }
    }

    function close(uint256 seed) external {
        if (_roll(seed, 8)) return; // traders mostly hold
        (bool ok, uint256 id) = _pickId(seed / 8);
        if (!ok) return;
        ITorqueMarket.Position memory p = market.getPosition(id);
        uint256 debt = _debt(p);
        uint256 proceeds = pool.quoteSell(p.q);
        uint256 before = usdg.balanceOf(p.owner);
        vm.prank(p.owner);
        try market.close(id, 0) returns (uint256 got) {
            // A voluntary close must always repay the vault in full.
            if (proceeds < debt) payoutViolations++;
            uint256 payout = proceeds - debt;
            if (got != payout || usdg.balanceOf(p.owner) - before != payout) payoutViolations++;
            ghostRepaid += debt;
            calls["close.ok"]++;
        } catch {
            calls["close.revert"]++;
        }
    }

    function claim(uint256 actor) external {
        address tr = traders[actor % traders.length];
        uint256 owed = market.claimable(tr);
        uint256 before = usdg.balanceOf(tr);
        vm.prank(tr);
        market.claim();
        if (usdg.balanceOf(tr) - before != owed) payoutViolations++;
        calls["claim"]++;
    }

    function knockOut(uint256 seed) external {
        (bool ok, uint256 id) = _pickId(seed);
        if (!ok) return;
        _knock(id);
    }

    // ---------------------------------------------------------------- market environment

    /// Normal in-session move between two fresh feed rounds, then the keeper sweeps.
    function moveInSession(int256 bps) external {
        if (weekend) return;
        bps = bound(bps, -200, 200);
        uint256 p = price6 * uint256(int256(BPS) + bps) / BPS;
        if (p < MIN_PRICE || p > MAX_PRICE) return;
        vm.warp(block.timestamp + 5 minutes);
        _setPrice(p);
        _sweep();
        calls["move"]++;
    }

    /// A sudden move bigger than the cushion between two fresh rounds: a gap, by definition.
    function gapInSession(uint256 seed, uint256 dropBps) external {
        if (weekend || _roll(seed, 10)) return; // rare by design
        dropBps = bound(dropBps, SAFE_DROP_BPS + 1, 4_000);
        uint256 p = price6 * (BPS - dropBps) / BPS;
        if (p < MIN_PRICE) return;
        gapHappened = true;
        vm.warp(block.timestamp + 5 minutes);
        _setPrice(p);
        calls["gapInSession"]++;
    }

    /// An in-session sell-off: several normal-sized drops, each printed by the feed and swept by the keeper.
    /// No gap, so the 5% barrier buffer must keep every knock-out free of bad debt.
    function selloff(uint256 steps, uint256 stepBps) external {
        if (weekend || price6 < 180e6) return; // sell-offs start from a normal price level
        steps = bound(steps, 2, 30);
        stepBps = bound(stepBps, 50, 200);
        for (uint256 i; i < steps; i++) {
            uint256 p = price6 * (BPS - stepBps) / BPS;
            if (p < MIN_PRICE) break;
            vm.warp(block.timestamp + 5 minutes);
            _setPrice(p);
            _sweep();
        }
        calls["selloff"]++;
    }

    /// While the feed is frozen, try to knock out anything whose barrier the stale price would cross.
    function knockOutDuringWeekend(uint256 seed) external {
        if (!weekend) return;
        (bool ok, uint256 id) = _pickId(seed);
        if (!ok) return;
        _knock(id);
    }

    /// The market recovers in normal in-session steps.
    function recover(uint256 bps) external {
        if (weekend || price6 >= 231_40e4) return;
        bps = bound(bps, 1, 400); // pulls the price back toward $231 so sell-offs have room to fall
        vm.warp(block.timestamp + 5 minutes);
        _setPrice(price6 * (BPS + bps) / BPS);
        _sweep();
        calls["recover"]++;
    }

    function passTime(uint256 dt, bool heartbeat) external {
        if (weekend) return;
        dt = bound(dt, 1 minutes, 2 hours);
        vm.warp(block.timestamp + dt);
        if (heartbeat) _setPrice(price6);
        _sweep();
        calls["passTime"]++;
    }

    function setPoolSlip(uint256 bps) external {
        pool.setSlip(bound(bps, 0, SLIP_BPS));
    }

    /// Friday close: the feed stops updating.
    function startWeekend(uint256 seed) external {
        if (weekend || _roll(seed, 6)) return; // weekends are rarer than trading steps
        weekend = true;
        fridayPrice = price6;
        vm.warp(block.timestamp + 1 hours); // Friday evening: frozen feed, still under 12h old
        calls["weekend"]++;
    }

    /// The token keeps trading in the pool over the weekend; the feed stays frozen.
    function weekendDrift(int256 bps) external {
        if (!weekend) return;
        bps = bound(bps, -800, 800);
        uint256 p = price6 * uint256(int256(BPS) + bps) / BPS;
        if (p < MIN_PRICE || p > MAX_PRICE) return;
        price6 = p;
        _setPool(p);
        vm.warp(block.timestamp + 20 minutes + (uint256(int256(bps < 0 ? -bps : bps)) % 4) * 1 hours);
        calls["weekendDrift"]++;
    }

    /// Monday: the first fresh round prints wherever the market now is.
    function endWeekend(uint256 seed) external {
        if (!weekend || _roll(seed, 3)) return;
        weekend = false;
        if (price6 * BPS < fridayPrice * (BPS - SAFE_DROP_BPS)) gapHappened = true;
        vm.warp(block.timestamp + 1 hours);
        _setPrice(price6);
        _sweep();
        calls["monday"]++;
    }

    // ---------------------------------------------------------------- views for invariants

    function sumOpen() external view returns (uint256 q, uint256 principal, uint256 notional, uint256 liqValue) {
        uint256[] memory ids = market.openPositionIds();
        for (uint256 i; i < ids.length; i++) {
            ITorqueMarket.Position memory p = market.getPosition(ids[i]);
            q += p.q;
            principal += p.principal;
            notional += p.notional;
            uint256 d = _debt(p);
            uint256 f = uint256(feed.answer()) / 100;
            uint256 t = _poolTwap();
            uint256 px = t < f ? t : f;
            uint256 v = p.q * px / 1e18 * (BPS - SLIP_BPS) / BPS;
            liqValue += d < v ? d : v;
        }
    }

    function isFreshNow() external view returns (bool) {
        return _fresh();
    }

    function lpFlowsOpen() external view returns (bool) {
        return !_mustRefuse();
    }

    /// Value of open loans if every position were sold at the pool's current spot price.
    function spotLiquidationValue() external view returns (uint256 v) {
        uint256[] memory ids = market.openPositionIds();
        for (uint256 i; i < ids.length; i++) {
            ITorqueMarket.Position memory p = market.getPosition(ids[i]);
            uint256 d = _debt(p);
            uint256 x = pool.quoteSell(p.q);
            v += d < x ? d : x;
        }
    }
}
