// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {ITorqueMarket, ITorqueVault} from "../../src/interfaces/ITorque.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";

/// Scale: the LP vault is capped at $20 USDG, so it can lend at most $16 (80%).
/// The reference position is $2 of margin at 5x: fee 0.01, notional 9.95, borrow 7.96.
contract TorqueTest is Base {
    uint256 constant M = 2e6;
    uint256 constant L5 = 50_000;

    // ------------------------------------------------------------------ open

    function test_open_hedgesFullNotionalAndBorrowsTheRest() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);

        ITorqueMarket.Position memory p = market.getPosition(id);
        assertEq(p.notional, 9_950_000);
        assertEq(p.principal, 7_960_000);
        assertEq(p.q, pool.quoteBuy(9_950_000));
        assertEq(nvda.balanceOf(address(market)), p.q, "hedge held by market");
        assertEq(usdg.balanceOf(address(market)), 0);
        assertEq(usdg.balanceOf(address(vault)), 20e6 - 7_960_000 + 10_000, "lent 7.96, earned 0.01 fee");
        assertLt(market.barrierOf(id), P0 * 85 / 100);
        assertGt(market.barrierOf(id), P0 * 83 / 100);
    }

    function test_open_rejectsBadLeverageAndDust() public {
        depositLp(20e6);
        vm.startPrank(alice);
        vm.expectRevert(ITorqueMarket.BadLeverage.selector);
        market.open(M, 19_999, 0);
        vm.expectRevert(ITorqueMarket.BadLeverage.selector);
        market.open(M, 50_001, 0);
        vm.expectRevert(ITorqueMarket.MarginTooSmall.selector);
        market.open(0.99e6, 20_000, 0);
        vm.stopPrank();
    }

    function test_open_enforcesOpenInterestCap() public {
        depositLp(20e6);
        openAs(alice, 7.5e6, 20_000); // notional ~14.97, borrow ~7.48
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.OpenInterestCap.selector);
        market.open(8e6, 20_000, 0); // open notional would pass $30 while borrowing stays under $16
    }

    function test_open_enforcesUtilizationCap() public {
        depositLp(5e6); // 80% of 5 = 4 of lending capacity
        openAs(alice, 1e6, L5); // borrows 3.98
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.UtilizationCap.selector);
        market.open(1e6, 20_000, 0);
    }

    function test_open_twentyDollarVaultCapacity() public {
        depositLp(20e6);
        // four $1 positions at 5x borrow 3.98 each = 15.92 of the $16 capacity
        for (uint256 i; i < 4; i++) {
            openAs(alice, 1e6, L5);
        }
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.UtilizationCap.selector);
        market.open(1e6, L5, 0);
    }

    function test_open_revertsWhenPoolIsOffChainlinkByMoreThanOnePercent() public {
        depositLp(20e6);
        pool.setSlip(0);
        pool.setPrice(P0 * 1012 / 1000); // spot 1.2% rich: TWAP still agrees, the fill guard catches it
        vm.prank(alice);
        vm.expectRevert(ITorqueMarket.Slippage.selector);
        market.open(M, L5, 0);
    }

    function test_open_respectsTraderMinOut() public {
        depositLp(20e6);
        uint256 expected = pool.quoteBuy(9_950_000);
        vm.prank(alice);
        vm.expectRevert(ITorqueMarket.Slippage.selector);
        market.open(M, L5, expected + 1);
    }

    // ------------------------------------------------------------------ close

    function test_close_inProfitRepaysVaultAndPaysTrader() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.warp(block.timestamp + 1 days);
        setPrice(P0 * 110 / 100);
        uint256 debt = market.debtOf(id);
        uint256 q = market.getPosition(id).q;
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.close(id, 0);
        assertEq(payout, pool.quoteSell(q) - debt);
        assertEq(usdg.balanceOf(alice) - before, payout);
        assertGt(payout, 2.96e6, "~ +50% on margin at 5x on a +10% move, less fee and financing");
        assertEq(market.openPositionIds().length, 0);
        assertEq(nvda.balanceOf(address(market)), 0);
    }

    function test_close_onlyOwner() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.NotOwner.selector);
        market.close(id, 0);
    }

    function test_close_worksOnStaleFeedIfVaultRepaidInFull() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        freezeFeedFor(30 hours);
        assertFalse(market.isPriceOk());
        pool.setPrice(P0 * 95 / 100);
        vm.prank(alice);
        uint256 payout = market.close(id, 0);
        assertGt(payout, 0);
        assertEq(market.totalBadDebt(), 0);
    }

    // ------------------------------------------------------------------ knock-out

    function test_knockOut_atBarrierRepaysVaultInFullAndCreditsResidual() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.warp(block.timestamp + 1 hours); // a sell-off over an hour, so the 30-minute average has caught up
        setPrice(market.barrierOf(id));
        vm.warp(block.timestamp + 31 minutes);
        uint256 debt = market.debtOf(id);
        vm.prank(keeper);
        uint256 payout = market.knockOut(id);

        assertEq(market.totalBadDebt(), 0, "no bad debt on an in-session knock-out");
        assertGt(payout, 0, "trader keeps the residual above the financing level");
        assertEq(market.claimable(alice), payout);
        assertEq(usdg.balanceOf(address(market)), payout);
        assertGe(usdg.balanceOf(address(vault)), 20e6 - 7_960_000 + 10_000 + debt - 1);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertEq(usdg.balanceOf(alice) - before, payout);
        assertEq(usdg.balanceOf(address(market)), 0);
    }

    /// A fast in-session crash: Chainlink has just printed below the barrier, the pool's 30-minute
    /// average still lags above it. The knock-out must still go through (feed updated < 30 min ago).
    function test_knockOut_fastSelloffNotBlockedByAverageLag() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        setPrice(market.barrierOf(id)); // -16% in one go; the TWAP has not moved yet
        (,,, uint256 devBps,, bool agrees) = market.priceStatus();
        assertFalse(agrees, "average lags spot by more than the band");
        assertGt(devBps, 150);
        market.knockOut(id);
        assertEq(market.totalBadDebt(), 0);
    }

    function test_knockOut_rejectsAboveBarrier() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        setPrice(market.barrierOf(id) + 1);
        vm.expectRevert(ITorqueMarket.NotKnockable.selector);
        market.knockOut(id);
    }

    /// Price lands 3.7% below the barrier in one round and the pool fills 1% worse than Chainlink:
    /// the vault is still repaid in full. (1.05 x 0.963 x 0.99 = 1.001)
    function test_knockOut_bufferAbsorbsOneLargeRoundPlusSlippage() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        setPrice(market.barrierOf(id) * 963 / 1000);
        pool.setSlip(100);
        market.knockOut(id);
        assertEq(market.totalBadDebt(), 0);
    }

    /// 3.8% below the barrier with the full 1% slippage is the break-even point.
    function test_knockOut_bufferEdgeIsJustUnder3Point8Percent() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        setPrice(market.barrierOf(id) * 962 / 1000);
        pool.setSlip(100);
        market.knockOut(id);
        assertLt(market.totalBadDebt(), 100, "dust only (< 0.0001 USDG)");
    }

    function test_knockOut_financingRatchetsBarrierUpOverTime() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 b0 = market.barrierOf(id);
        vm.warp(block.timestamp + 365 days);
        uint256 b1 = market.barrierOf(id);
        assertApproxEqRel(b1, b0 * 110 / 100, 0.001e18);
    }

    // ------------------------------------------------------------------ pool cross-check

    /// The window the 12h staleness limit alone left open: Friday evening, feed frozen but under 12h old,
    /// NVDA trading lower in the pool. Opening against the stale, favourable price is refused, and so
    /// are knock-outs and LP flows, once the pool's 30-minute average leaves the 1.5% band.
    function test_poolCheck_fridayEveningDivergenceShutsEverything() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);

        freezeFeedFor(1 hours); // Friday 21:00, feed frozen at Friday's close
        pool.setPrice(P0 * 96 / 100); // token trades 4% lower in the pool
        vm.warp(block.timestamp + 40 minutes); // the 30-minute average now sits fully at -4%
        (, uint256 age,, uint256 devBps, bool feedFresh, bool agrees) = market.priceStatus();
        assertTrue(feedFresh, "feed is under 12h old, so staleness alone would allow trading");
        assertLt(age, 12 hours);
        assertGt(devBps, 150);
        assertFalse(agrees);

        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.PoolPriceMismatch.selector);
        market.open(M, L5, 0);
        vm.expectRevert(ITorqueMarket.PoolPriceMismatch.selector);
        market.knockOut(id);
        vm.prank(lp);
        vm.expectRevert(ITorqueVault.PriceCheckFailed.selector);
        vault.withdraw(1e6, lp, lp);
        vm.prank(lp);
        vm.expectRevert(ITorqueVault.PriceCheckFailed.selector);
        vault.deposit(1e6, lp);
        assertEq(vault.maxWithdraw(lp), 0);
    }

    /// Friday evening, feed frozen at Friday's close, NVDA 22% lower in the pool: the vault must value
    /// the loan at the pool's 30-minute average, not at the stale print, so NAV shows the loss at once.
    function test_poolCheck_markUsesLowerOfFeedAndPoolAverage() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 q = market.getPosition(id).q;
        freezeFeedFor(1 hours);
        pool.setPrice(P0 * 78 / 100);
        vm.warp(block.timestamp + 40 minutes);
        uint256 twap = market.poolTwapPrice();
        assertLt(twap, P0 * 79 / 100);
        uint256 expectedMark = q * twap / 1e18 * 99 / 100;
        assertLt(expectedMark, market.debtOf(id), "loan is underwater at the pool price");
        assertEq(vault.totalAssets(), vault.idle() + expectedMark, "NAV marks the loan at the pool average");
    }

    /// A calm weekend (like 09-26/27, when the pool stayed within 0.51% of the frozen feed): the pool
    /// check passes, and the 12h staleness limit is what closes the product.
    function test_poolCheck_calmWeekendClosesOnAgeOnly() public {
        depositLp(20e6);
        freezeFeedFor(1 hours);
        pool.setPrice(P0 * 9950 / 10_000); // -0.5%
        vm.warp(block.timestamp + 40 minutes);
        assertTrue(market.isPriceOk());
        openAs(bob, 1e6, 20_000);

        freezeFeedFor(11 hours); // Saturday ~08:40, feed > 12h old
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.StaleFeed.selector);
        market.open(1e6, 20_000, 0);
    }

    function test_poolCheck_bandEdges() public {
        depositLp(20e6);
        pool.setPrice(P0 * 10_140 / 10_000); // +1.4%: inside the band
        vm.warp(block.timestamp + 31 minutes);
        feed.push(int256(P0 * 100)); // fresh feed, unchanged
        (,,, uint256 devIn,, bool agreesIn) = market.priceStatus();
        assertTrue(agreesIn);
        assertLe(devIn, 150);

        pool.setPrice(P0 * 10_160 / 10_000); // +1.6%: outside
        vm.warp(block.timestamp + 31 minutes);
        feed.push(int256(P0 * 100));
        (,,, uint256 devOut,, bool agreesOut) = market.priceStatus();
        assertFalse(agreesOut);
        assertGt(devOut, 150);
    }

    function test_poolCheck_failsClosedIfPoolCannotServeTheAverage() public {
        depositLp(20e6);
        pool.breakObserve(true);
        assertEq(market.poolTwapPrice(), 0);
        assertFalse(market.isPriceOk());
        vm.prank(alice);
        vm.expectRevert(ITorqueMarket.PoolPriceMismatch.selector);
        market.open(M, L5, 0);
    }

    /// Negative ticks never occur for NVDA in this pool (USDG is token0), but the conversion must still be
    /// right on both sides of zero: tick 0 is ratio 1, and +/-1 tick is a 0.01% step either way.
    function test_poolCheck_tickMathBothSigns() public {
        TickProbe probe = new TickProbe(market);
        assertEq(probe.price(0), 1e18);
        assertApproxEqAbs(probe.price(-1), 1.0001e18, 1);
        assertApproxEqAbs(probe.price(1), 999_900_009_999_000_099, 1e3);
        assertApproxEqRel(probe.price(-200_000) * probe.price(200_000) / 1e18, 1e18, 1e9);
    }

    function test_poolCheck_tickMathMatchesPrice() public view {
        uint256 twap = market.poolTwapPrice();
        assertApproxEqRel(twap, P0, 0.0001e18, "tick average converts back to the spot price within 0.01%");
    }

    // ------------------------------------------------------------------ the weekend gap (SPEC.md)

    function test_weekendGapThroughBarrier_explicitBehaviour() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 debt0 = market.debtOf(id);
        uint256 navFriday = vault.totalAssets();

        // 1. Friday close: the feed freezes. The token keeps trading 25% lower over the weekend.
        freezeFeedFor(13 hours);
        assertFalse(market.isPriceOk());
        pool.setPrice(P0 * 75 / 100);

        // 2. Weekend: knock-out, opens and LP flows refuse; close refuses because the vault would not be repaid.
        vm.expectRevert(ITorqueMarket.StaleFeed.selector);
        market.knockOut(id);
        vm.prank(bob);
        vm.expectRevert(ITorqueMarket.StaleFeed.selector);
        market.open(M, 20_000, 0);
        vm.prank(lp);
        vm.expectRevert(ITorqueVault.PriceCheckFailed.selector);
        vault.withdraw(1e6, lp, lp);
        vm.prank(lp);
        vm.expectRevert(ITorqueVault.PriceCheckFailed.selector);
        vault.deposit(1e6, lp);
        vm.prank(alice);
        vm.expectRevert(ITorqueMarket.Underwater.selector);
        market.close(id, 0);

        // 3. Monday: the first fresh round prints 25% lower, below the financing level.
        vm.warp(block.timestamp + 39 hours);
        setPrice(P0 * 75 / 100);
        assertTrue(market.isPriceOk());
        uint256 q = market.getPosition(id).q;
        uint256 debt = market.debtOf(id);
        assertLt(vault.totalAssets(), navFriday, "loss marked as soon as a fresh price shows it");

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 navBefore = vault.totalAssets();
        vm.prank(keeper);
        uint256 payout = market.knockOut(id);

        uint256 proceeds = pool.quoteSell(q);
        assertEq(payout, 0, "trader loses the margin, never more");
        assertEq(usdg.balanceOf(alice), aliceBefore);
        assertEq(market.totalBadDebt(), debt - proceeds, "bad debt = debt - proceeds");
        assertGt(debt, debt0);
        assertGe(vault.totalAssets(), navBefore, "mark was conservative: knock-out can only move NAV up");
        assertEq(vault.totalAssets(), 20e6 + 10_000 - 7_960_000 + proceeds);
    }

    // ------------------------------------------------------------------ vault

    function test_vault_hardCapAt20() public {
        depositLp(15e6);
        assertEq(vault.maxDeposit(lp), 5e6);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IERC4626Errors.ERC4626ExceededMaxDeposit.selector, lp, 6e6, 5e6));
        vault.deposit(6e6, lp);
        depositLp(5e6);
        assertEq(vault.totalAssets(), 20e6);
        assertEq(vault.maxDeposit(lp), 0);
        assertEq(vault.maxMint(lp), 0);
        assertEq(vault.VAULT_CAP(), 20e6);
    }

    function test_vault_withdrawLimitedToIdleCash() public {
        depositLp(20e6);
        openAs(alice, M, L5);
        assertEq(vault.maxWithdraw(lp), usdg.balanceOf(address(vault)));
        uint256 idle = vault.idle();
        vm.prank(lp);
        vm.expectRevert();
        vault.withdraw(idle + 1, lp, lp);
        vm.prank(lp);
        vault.withdraw(idle, lp, lp);
    }

    function test_vault_lpEarnsFeeAndFinancing() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.warp(block.timestamp + 30 days);
        setPrice(P0);
        vm.prank(alice);
        market.close(id, 0);
        // fee 0.01 + 30 days of 10% APR on 7.96 = 0.065425
        assertApproxEqAbs(vault.totalAssets(), 20e6 + 10_000 + 65_425, 2);
    }

    function test_vault_onlyMarketCanBorrow() public {
        depositLp(20e6);
        vm.expectRevert(ITorqueVault.OnlyMarket.selector);
        vault.lend(1e6);
    }

    function test_vault_setMarketIsOneShot() public {
        vm.expectRevert(ITorqueVault.MarketAlreadySet.selector);
        vault.setMarket(address(1));
        TorqueVault v2 = new TorqueVault(usdg);
        vm.prank(alice);
        vm.expectRevert(ITorqueVault.OnlyDeployer.selector);
        v2.setMarket(address(1));
    }

    function test_callbackRejectsOutsiders() public {
        vm.expectRevert(ITorqueMarket.Unauthorized.selector);
        market.uniswapV3SwapCallback(1, 0, "");
        vm.prank(address(pool));
        vm.expectRevert(ITorqueMarket.Unauthorized.selector);
        market.uniswapV3SwapCallback(1, 0, "");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_openThenExit(uint256 margin, uint256 lev, uint256 movePct, bool up) public {
        depositLp(20e6);
        margin = bound(margin, 1e6, 3e6);
        lev = bound(lev, 20_000, 50_000);
        movePct = bound(movePct, 0, 60);
        uint256 id = openAs(alice, margin, lev);
        uint256 debt = market.debtOf(id);
        uint256 q = market.getPosition(id).q;
        uint256 p = up ? P0 * (100 + movePct) / 100 : P0 * (100 - movePct) / 100;
        setPrice(p);
        uint256 proceeds = pool.quoteSell(q);
        uint256 before = usdg.balanceOf(alice);

        if (p <= market.barrierOf(id)) {
            market.knockOut(id);
            assertEq(market.claimable(alice), proceeds > debt ? proceeds - debt : 0);
            assertEq(market.totalBadDebt(), proceeds < debt ? debt - proceeds : 0);
        } else {
            vm.prank(alice);
            uint256 payout = market.close(id, 0);
            assertEq(payout, proceeds - debt);
            assertEq(usdg.balanceOf(alice) - before, payout);
            assertEq(market.totalBadDebt(), 0);
        }
    }

    /// The tick conversion against the mock's independent inverse across the whole plausible range.
    function testFuzz_tickMath(uint256 p6) public {
        p6 = bound(p6, 1e6, 100_000e6);
        pool.setPrice(p6);
        vm.warp(block.timestamp + 31 minutes);
        assertApproxEqRel(market.poolTwapPrice(), p6, 0.0001e18);
    }
}

contract TickProbe is TorqueMarket {
    constructor(TorqueMarket m) TorqueMarket(m.usdg(), m.nvda(), m.pool(), m.feed(), m.vault()) {}

    function price(int56 tick) external view returns (uint256) {
        return _tickToPrice6(tick);
    }
}

interface IERC4626Errors {
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
}
