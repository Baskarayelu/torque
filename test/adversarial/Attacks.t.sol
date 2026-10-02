// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "../unit/Base.t.sol";
import {MockToken, MockFeed, MockPool, HookToken, ITransferHook} from "../mocks/Mocks.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";
import {ITorqueMarket, ITorqueVault} from "../../src/interfaces/ITorque.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal} from "../../src/interfaces/IExternal.sol";

/// @notice Adversarial pass: each test plays an attacker trying to drain the vault or get a free
///         position, and asserts the attack fails or is bounded. See research/ADVERSARIAL.md.
contract AttacksTest is Base {
    uint256 constant M = 2e6;
    uint256 constant L5 = 50_000;
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 2; i++) {
            address a = [attacker, victim][i];
            usdg.mint(a, 1_000e6);
            vm.startPrank(a);
            usdg.approve(address(vault), type(uint256).max);
            usdg.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ================================================================ 2. first depositor, share rounding

    /// Classic inflation: attacker deposits 1 wei, donates to blow up the share price, victim deposits.
    /// With 6 virtual share decimals and the $20 cap, the victim loses at most dust and the attacker profits nothing.
    function test_attack_firstDepositorInflation() public {
        vm.prank(attacker);
        vault.deposit(1, attacker);
        vm.prank(attacker);
        usdg.transfer(address(vault), 9e6); // donation: share price inflated 9,000,000x

        vm.prank(victim);
        uint256 shares = vault.deposit(10e6, victim);
        assertGt(shares, 0, "victim always gets shares");
        uint256 victimValue = vault.convertToAssets(shares);
        assertGe(victimValue, 10e6 - 10, "victim loses at most dust");

        uint256 before = usdg.balanceOf(attacker);
        uint256 aShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(aShares, attacker, attacker);
        uint256 got = usdg.balanceOf(attacker) - before;
        assertLe(got, 9e6 + 1, "attacker cannot take more than they put in");
    }

    /// Griefing variant: donate up to the cap so nobody else can deposit. Steals nothing, and about half the
    /// donation stays behind in the vault (virtual shares). Mitigation: the deploy script seeds the vault at once.
    function test_attack_donationFillsCap_isDosOnly() public {
        vm.prank(attacker);
        vault.deposit(1, attacker);
        vm.prank(attacker);
        usdg.transfer(address(vault), 20e6);
        assertEq(vault.maxDeposit(victim), 0);
        vm.prank(victim);
        vm.expectRevert();
        vault.deposit(1e6, victim);
        uint256 before = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();
        assertLe(usdg.balanceOf(attacker) - before, 20e6 + 1);
    }

    /// Round-trip farming: many tiny deposits and redemptions never return more than was paid in.
    function testFuzz_attack_roundingFarm(uint256 seedAmount, uint8 loops) public {
        depositLp(5e6);
        seedAmount = bound(seedAmount, 1, 3e6);
        loops = uint8(bound(loops, 1, 40));
        uint256 start = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        for (uint256 i; i < loops; i++) {
            uint256 sh = vault.deposit(seedAmount, attacker);
            vault.redeem(sh, attacker, attacker);
        }
        vm.stopPrank();
        assertLe(usdg.balanceOf(attacker), start, "no profit from rounding");
    }

    function test_attack_mintRoundingCannotCrossCap() public {
        depositLp(19_999_999);
        uint256 shares = vault.maxMint(attacker);
        vm.prank(attacker);
        if (shares > 0) vault.mint(shares, attacker);
        assertLe(vault.totalAssets(), 20e6);
        vm.prank(attacker);
        vm.expectRevert();
        vault.mint(2e6, attacker);
    }

    // ================================================================ 3. donations / direct transfers

    function test_attack_donationsToMarketCannotBeExtracted() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 navBefore = vault.totalAssets();
        uint256 markedBefore = market.markedDebt();

        vm.startPrank(attacker);
        usdg.transfer(address(market), 5e6);
        vm.stopPrank();
        nvda.mint(address(market), 1e18);

        assertEq(market.markedDebt(), markedBefore, "loan marks ignore stray balances");
        assertEq(vault.totalAssets(), navBefore, "NAV ignores donations to the market");
        uint256 before = usdg.balanceOf(attacker);
        vm.prank(attacker);
        market.claim();
        assertEq(usdg.balanceOf(attacker), before, "attacker has nothing to claim");
        vm.prank(alice);
        uint256 payout = market.close(id, 0);
        assertLt(payout, 2e6, "trader gets their own proceeds, not the donation");
    }

    function test_attack_donationToVaultOnlyHelpsLps() public {
        depositLp(10e6);
        uint256 lpShares = vault.balanceOf(lp);
        vm.prank(attacker);
        usdg.transfer(address(vault), 2e6);
        assertApproxEqAbs(vault.convertToAssets(lpShares), 12e6, 2, "donation accrues to existing LPs");
        // more lending capacity, but open interest is still hard-capped
        vm.prank(attacker);
        vm.expectRevert(ITorqueMarket.OpenInterestCap.selector);
        market.open(7e6, L5, 0);
    }

    // ================================================================ 4. knock-out at a manipulated tick

    /// Crashing the pool's spot price does nothing: the trigger is Chainlink, not the pool.
    function test_attack_spotCrashCannotTriggerKnockOut() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        pool.setPrice(P0 / 2);
        vm.prank(attacker);
        vm.expectRevert(ITorqueMarket.NotKnockable.selector);
        market.knockOut(id);
    }

    /// Feed legitimately at the barrier; attacker crashes spot first to buy the forced sale cheap.
    /// The sale must fill within 1% of Chainlink, so the knock-out reverts instead of dumping.
    function test_attack_crashSpotUnderAKnockOutReverts() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 b = market.barrierOf(id);
        vm.warp(block.timestamp + 1 hours);
        setPrice(b);
        vm.warp(block.timestamp + 31 minutes);
        pool.setPrice(b * 95 / 100); // attacker's front-run
        vm.prank(attacker);
        vm.expectRevert(ITorqueMarket.Slippage.selector);
        market.knockOut(id);
    }

    /// Holding the 30-minute average off the feed can only delay a knock-out while the feed print is older
    /// than 30 minutes; the next Chainlink print (the price moving) lets it through regardless.
    function test_attack_twapManipulationOnlyDelaysKnockOut() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        uint256 b = market.barrierOf(id);
        setPrice(b);
        pool.setPrice(b * 103 / 100); // attacker props the pool 3% above the feed
        vm.warp(block.timestamp + 45 minutes); // average now sits above the band, feed print 45 min old
        vm.expectRevert(ITorqueMarket.PoolPriceMismatch.selector);
        market.knockOut(id);
        feed.push(int256(b * 99 / 100 * 100)); // Chainlink prints again
        market.knockOut(id);
        assertEq(market.totalBadDebt(), 0);
    }

    // ================================================================ 5. sandwiching the hedge swap

    /// Pumping spot just under the 1% guard is the most a sandwich can take from an open: the trader's
    /// fill is at worst 1% off Chainlink, and the vault's loan is still fully secured.
    function test_attack_sandwichOpenBoundedAtOnePercent() public {
        depositLp(20e6);
        pool.setPrice(P0 * 10_099 / 10_000);
        vm.prank(victim);
        uint256 id = market.open(M, L5, 0);
        ITorqueMarket.Position memory p = market.getPosition(id);
        uint256 fill = uint256(p.notional) * 1e18 / p.q;
        assertLe(fill, P0 * 10_101 / 10_000, "fill no worse than ~1% over Chainlink");
        assertLt(market.barrierOf(id), P0 * 85 / 100, "vault's protection intact");

        pool.setPrice(P0 * 10_120 / 10_000);
        vm.prank(victim);
        vm.expectRevert(ITorqueMarket.Slippage.selector);
        market.open(M, L5, 0);
    }

    /// Opening into an attacker-crashed spot gives the trader more NVDA, but the value comes from the
    /// attacker's own dump, not the vault: the loan is secured either way and closing repays it in full.
    function test_attack_openIntoCrashedSpotDoesNotTouchVault() public {
        depositLp(20e6);
        uint256 navBefore = vault.totalAssets();
        pool.setPrice(P0 * 90 / 100);
        vm.prank(attacker);
        uint256 id = market.open(M, L5, 0);
        pool.setPrice(P0);
        vm.prank(attacker);
        market.close(id, 0);
        assertGe(vault.totalAssets(), navBefore + 9_000, "vault repaid in full plus fee");
        assertEq(market.totalBadDebt(), 0);
    }

    /// Closing your own position at a manipulated spot can only move money between you and the pool;
    /// a close that would short the vault reverts.
    function test_attack_closeAtCrashedSpotCannotShortVault() public {
        depositLp(20e6);
        uint256 id = openAs(attacker, M, L5);
        pool.setPrice(P0 * 70 / 100);
        vm.prank(attacker);
        vm.expectRevert(ITorqueMarket.Underwater.selector);
        market.close(id, 0);
    }

    // ================================================================ 6. ordering within one block

    /// A fresh Chainlink print reveals a gap. In the same block, an LP tries to withdraw before the
    /// knock-out lands. Either the exit is refused (pool average lags) or NAV already shows the loss.
    function test_attack_lpRunsAheadOfKnownLossSameBlock() public {
        depositLp(15e6);
        vm.prank(victim);
        vault.deposit(5e6, victim);
        uint256 id = openAs(alice, M, L5);
        uint256 lpShares = vault.balanceOf(lp);

        setPrice(P0 * 70 / 100); // gap: Chainlink prints 30% lower, pool spot follows, average lags
        vm.prank(lp);
        vm.expectRevert(ITorqueVault.PriceCheckFailed.selector);
        vault.redeem(lpShares, lp, lp);

        // after the average catches up, NAV already carries the loss; knock-out moves it by rounding only
        vm.warp(block.timestamp + 31 minutes);
        feed.push(int256(P0 * 70)); // P0 * 0.7, 8 decimals
        uint256 navMarked = vault.totalAssets();
        market.knockOut(id);
        assertGe(vault.totalAssets(), navMarked, "loss was already in NAV");
        assertGt(market.totalBadDebt(), 0);
    }

    /// One account as both LP and trader, everything in one block: deposit, open, close, withdraw.
    /// It cannot come out ahead.
    function test_attack_lpAndTraderSameBlockRoundTrip() public {
        depositLp(10e6);
        uint256 start = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 sh = vault.deposit(10e6, attacker);
        uint256 id = market.open(3e6, L5, 0);
        market.close(id, 0);
        vault.redeem(sh, attacker, attacker);
        vm.stopPrank();
        assertLe(usdg.balanceOf(attacker), start, "no free round trip");
    }

    // ================================================================ 7. free position

    function testFuzz_attack_noFreePosition(uint256 margin, uint256 lev) public {
        depositLp(20e6);
        margin = bound(margin, 1e6, 3e6);
        lev = bound(lev, 20_000, 50_000);
        uint256 start = usdg.balanceOf(attacker);
        vm.prank(attacker);
        uint256 id = market.open(margin, lev, 0);
        ITorqueMarket.Position memory p = market.getPosition(id);
        assertLt(p.principal, p.notional, "borrow always below notional");
        assertGt(p.q, 0);
        vm.prank(attacker);
        market.close(id, 0);
        assertLt(usdg.balanceOf(attacker), start, "an immediate round trip always costs the fee");
    }

    function test_attack_doubleClaim() public {
        depositLp(20e6);
        uint256 id = openAs(attacker, M, L5);
        vm.warp(block.timestamp + 1 hours);
        setPrice(market.barrierOf(id));
        vm.warp(block.timestamp + 31 minutes);
        market.knockOut(id);
        uint256 owed = market.claimable(attacker);
        assertGt(owed, 0);
        uint256 before = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        market.claim();
        market.claim();
        vm.stopPrank();
        assertEq(usdg.balanceOf(attacker) - before, owed);
    }

    function test_attack_cannotActOnOthersPositionsOrCallback() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.startPrank(attacker);
        vm.expectRevert(ITorqueMarket.NotOwner.selector);
        market.close(id, 0);
        vm.expectRevert(ITorqueMarket.Unauthorized.selector);
        market.uniswapV3SwapCallback(0, 1e18, "");
        vm.expectRevert(ITorqueVault.OnlyMarket.selector);
        vault.lend(1e6);
        vm.expectRevert(ITorqueVault.OnlyDeployer.selector);
        vault.setMarket(attacker);
        vm.stopPrank();
    }

    // ================================================================ 8. dead feed (found in this pass, fixed)

    /// Before the fix: a reverting feed bricked totalAssets and every withdrawal. Now NAV still reads,
    /// and with no open positions LPs can always leave.
    function test_attack_deadFeedCannotLockIdleLpFunds() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.prank(alice);
        market.close(id, 0);
        feed.kill(true);
        assertEq(vault.totalAssets(), usdg.balanceOf(address(vault)), "NAV readable with a dead feed");
        uint256 sh = vault.balanceOf(lp);
        vm.prank(lp);
        vault.redeem(sh, lp, lp);
        assertEq(vault.totalSupply(), 0);
    }

    /// With a position still open and the feed stale, the emergency unwind frees the loan after 7 days,
    /// never before: a 78-hour holiday freeze cannot trigger it.
    function test_attack_staleFeedWithOpenPositionUnwindsAfterSevenDays() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.warp(block.timestamp + 78 hours);
        vm.expectRevert(TorqueMarket.FeedNotDead.selector);
        market.unwind(id);

        vm.warp(block.timestamp + 7 days);
        uint256 debt = market.debtOf(id);
        market.unwind(id);
        assertEq(market.openPositionCount(), 0);
        assertEq(market.totalBadDebt(), 0);
        assertGt(market.claimable(alice), 0, "trader's residual is kept for them");
        uint256 sh = vault.balanceOf(lp);
        vm.prank(lp);
        vault.redeem(sh, lp, lp);
        assertGe(usdg.balanceOf(lp), 10_000e6 + debt - 7_960_000 - 5, "LP gets principal and interest back");
    }

    /// A reverting feed has no age. A glitch must not open the unwind at once: the clock starts when
    /// someone reports it down, resets if it recovers, and only 7 days of continuous failure unwinds.
    function test_attack_revertingFeedNeedsSevenDaysFromReport() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        feed.kill(true);
        vm.expectRevert(TorqueMarket.FeedNotDead.selector);
        market.unwind(id);
        market.reportFeedDown();
        vm.warp(block.timestamp + 3 days);
        feed.kill(false);
        market.reportFeedDown(); // feed recovered: clock resets
        assertEq(market.feedDownSince(), 0);
        feed.kill(true);
        market.reportFeedDown();
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(TorqueMarket.FeedNotDead.selector);
        market.unwind(id);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(vault.totalAssets() > 0, true, "NAV still readable while the feed reverts");
        market.unwind(id);
        assertEq(market.openPositionCount(), 0);
    }

    /// A stale report must not survive a recovery: any open, close or knock-out that reads a healthy
    /// feed clears the clock, so a later momentary glitch cannot open the unwind instantly.
    function test_attack_staleDownReportClearedByActivity() public {
        depositLp(20e6);
        feed.kill(true);
        market.reportFeedDown();
        feed.kill(false); // recovers; nobody calls reportFeedDown
        uint256 id = openAs(alice, M, L5); // ordinary activity reads a healthy print
        assertEq(market.feedDownSince(), 0);
        vm.warp(block.timestamp + 10 days);
        feed.push(int256(P0 * 100)); // feed alive and fresh
        feed.kill(true); // momentary glitch
        vm.expectRevert(TorqueMarket.FeedNotDead.selector);
        market.unwind(id);
    }

    /// The emergency unwind cannot be used to dump a position into a crashed spot.
    function test_attack_unwindIntoCrashedSpotReverts() public {
        depositLp(20e6);
        uint256 id = openAs(alice, M, L5);
        vm.warp(block.timestamp + 8 days);
        pool.setPrice(P0 * 90 / 100);
        vm.expectRevert(ITorqueMarket.Slippage.selector);
        market.unwind(id);
    }
}

/// ================================================================ 1. reentrancy
/// Runs the whole system on a hook-calling USDG. The attacker holds a position and, on every USDG it
/// receives or sends, tries to re-enter every state-changing function on the market and the vault.
contract ReentrancyAttacker is ITransferHook {
    TorqueMarket public market;
    TorqueVault public vault;
    HookToken public usdg;
    uint256 public attempts;
    uint256 public marketReentries; // must stay 0
    uint256 public positionId;
    bool public armed;
    uint256 public sharesGained;

    constructor(TorqueMarket m, TorqueVault v, HookToken u) {
        market = m;
        vault = v;
        usdg = u;
        u.approve(address(m), type(uint256).max);
        u.approve(address(v), type(uint256).max);
    }

    function openPosition(uint256 margin) external {
        positionId = market.open(margin, 50_000, 0);
    }

    function closePosition() external {
        armed = true;
        market.close(positionId, 0);
        armed = false;
    }

    function onTokenTransfer(address, address, uint256) external {
        if (!armed || msg.sender != address(usdg)) return;
        armed = false;
        attempts++;
        try market.open(1e6, 50_000, 0) { marketReentries++; } catch {}
        try market.close(positionId, 0) { marketReentries++; } catch {}
        try market.knockOut(positionId) { marketReentries++; } catch {}
        try market.claim() { marketReentries++; } catch {}
        // the vault has no lock of its own: re-entering it mid-close must still be priced fairly
        uint256 before = usdg.balanceOf(address(this));
        try vault.deposit(1e6, address(this)) returns (uint256 sh) {
            sharesGained = sh;
            try vault.redeem(sh, address(this), address(this)) {} catch {}
        } catch {}
        uint256 afterBal = usdg.balanceOf(address(this));
        require(afterBal <= before, "profited from re-entering the vault");
    }
}

contract ReentrancyTest is Test {
    function test_attack_reentrancyThroughHookTokenFails() public {
        vm.warp(1_790_000_000);
        HookToken usdg = new HookToken("Global Dollar", "USDG", 6);
        MockToken nvda = new MockToken("NVIDIA", "NVDA", 18);
        MockFeed feed = new MockFeed();
        MockPool pool = new MockPool(usdg, nvda);
        pool.setPrice(231_40e4);
        feed.push(231_40e6);
        TorqueVault vault = new TorqueVault(usdg);
        TorqueMarket market =
            new TorqueMarket(usdg, nvda, IUniswapV3PoolMinimal(address(pool)), IAggregatorV3(address(feed)), vault);
        vault.setMarket(address(market));

        address lp = makeAddr("lp");
        usdg.mint(lp, 20e6);
        vm.startPrank(lp);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(15e6, lp);
        vm.stopPrank();

        ReentrancyAttacker a = new ReentrancyAttacker(market, vault, usdg);
        usdg.mint(address(a), 10e6);
        a.openPosition(2e6);
        usdg.setHook(address(a), true);
        uint256 navBefore = vault.totalAssets();
        a.closePosition();

        assertEq(a.attempts(), 1, "hook fired during close");
        assertEq(a.marketReentries(), 0, "every market re-entry reverted");
        assertGe(vault.totalAssets(), navBefore, "vault not drained");
        assertEq(usdg.balanceOf(address(market)), market.totalClaimable());
    }
}
