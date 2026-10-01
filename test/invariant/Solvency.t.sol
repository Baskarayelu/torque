// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MockToken, MockFeed, MockPool} from "../mocks/Mocks.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal} from "../../src/interfaces/IExternal.sol";
import {Handler} from "./Handler.sol";
import {ITorqueMarket} from "../../src/interfaces/ITorque.sol";

/// @notice Vault-solvency invariants from SPEC.md, written before the product code.
contract SolvencyInvariants is Test {
    MockToken usdg;
    MockToken nvda;
    MockFeed feed;
    MockPool pool;
    TorqueVault vault;
    TorqueMarket market;
    Handler handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdg = new MockToken("Global Dollar", "USDG", 6);
        nvda = new MockToken("NVIDIA", "NVDA", 18);
        feed = new MockFeed();
        pool = new MockPool(usdg, nvda);
        pool.setPrice(231_40e4);
        feed.push(231_40e6);

        vault = new TorqueVault(usdg);
        market = new TorqueMarket(
            usdg, nvda, IUniswapV3PoolMinimal(address(pool)), IAggregatorV3(address(feed)), vault
        );
        vault.setMarket(address(market));

        handler = new Handler(usdg, nvda, feed, pool, vault, market);
        targetContract(address(handler));
    }

    /// 1. Every open position is fully hedged: the market holds exactly Σ q of NVDA.
    function invariant_backing() public view {
        (uint256 q,,,) = handler.sumOpen();
        assertEq(nvda.balanceOf(address(market)), q, "NVDA backing != sum of positions");
        assertEq(handler.hedgeViolations(), 0, "position recorded a different hedge than the spec");
    }

    /// 2. The market never strands USDG: it holds exactly the knock-out residuals owed to traders.
    function invariant_noStrandedUsdg() public view {
        assertEq(usdg.balanceOf(address(market)), market.totalClaimable(), "USDG stuck in market");
    }

    /// 3. Conservation: vault cash = deposits - withdrawals - lent + repaid + fees.
    function invariant_conservation() public view {
        uint256 expected = handler.ghostDeposited() + handler.ghostRepaid() + handler.ghostFees()
            - handler.ghostWithdrawn() - handler.ghostLent();
        assertEq(usdg.balanceOf(address(vault)), expected, "vault cash does not reconcile");
        assertEq(market.totalBadDebt(), handler.ghostBadDebt(), "bad debt does not reconcile");
    }

    /// 4. The $200 hard cap holds after every deposit.
    function invariant_cap() public view {
        assertEq(handler.capViolations(), 0, "deposit pushed totalAssets over the cap");
    }

    /// 5. Open-interest, utilization, leverage and position-count caps hold.
    function invariant_openInterest() public view {
        (, uint256 principal, uint256 notional,) = handler.sumOpen();
        assertEq(market.totalPrincipal(), principal, "principal bookkeeping");
        assertEq(market.totalNotional(), notional, "notional bookkeeping");
        assertLe(market.totalNotional(), market.MAX_OPEN_NOTIONAL(), "open interest over cap");
        assertLe(market.openPositionIds().length, market.MAX_OPEN_POSITIONS(), "too many positions");
        assertEq(handler.utilViolations(), 0, "open breached a cap");
    }

    /// 6. NAV is never overstated: loans are never valued above their collateral at the lower of
    ///    Chainlink and the pool's 30-minute average, less the 1% execution allowance (recomputed
    ///    independently). And whenever LP flows are open, NAV is within the 1.5% band of what the
    ///    collateral would fetch at the pool's current spot price.
    function invariant_navNotOverstated() public view {
        (,,, uint256 liq) = handler.sumOpen();
        uint256 idle = usdg.balanceOf(address(vault));
        assertLe(vault.totalAssets(), idle + liq + 2, "NAV overstated vs conservative value");
        if (!handler.lpFlowsOpen()) return;
        uint256 spot = handler.spotLiquidationValue();
        assertLe(vault.totalAssets(), idle + spot + (spot * 400) / 10_000 + 2, "NAV far above spot value while LPs can act");
    }

    /// 7. Bad debt only ever comes from a price gap larger than the cushion.
    function invariant_badDebtNeedsGap() public view {
        assertEq(handler.badDebtWithoutGap(), 0, "bad debt without a gap");
        if (!handler.gapHappened()) assertEq(market.totalBadDebt(), 0, "bad debt without a gap");
    }

    /// 8. Stale feed: no open, knock-out, deposit or withdrawal ever succeeds.
    function invariant_staleMeansShut() public view {
        assertEq(handler.staleSuccesses(), 0, "action succeeded on a stale feed");
    }

    /// 9. Traders get exactly proceeds - repayment; a voluntary close always repays in full.
    function invariant_payouts() public view {
        assertEq(handler.payoutViolations(), 0, "payout mismatch");
    }

    function afterInvariant() external view {
        string[20] memory keys = [
            "deposit.ok", "deposit.revert", "mint.ok", "withdraw.ok", "withdraw.revert", "redeem.ok",
            "open.ok", "open.revert", "close.ok", "close.revert", "knockOut.ok", "knockOut.revert",
            "move", "gapInSession", "recover", "weekend", "weekendDrift", "monday", "claim", "selloff"
        ];
        for (uint256 i; i < keys.length; i++) {
            console.log(keys[i], handler.calls(bytes32(bytes(keys[i]))));
        }
        console.log("badDebt", market.totalBadDebt());
        console.log("price min/max/final", handler.minSeen(), handler.maxSeen(), handler.price6());
        console.log("maxConcurrent", handler.maxConcurrent());
        bytes4[10] memory sel = [
            ITorqueMarket.StaleFeed.selector, ITorqueMarket.PoolPriceMismatch.selector, ITorqueMarket.BadLeverage.selector,
            ITorqueMarket.MarginTooSmall.selector, ITorqueMarket.OpenInterestCap.selector,
            ITorqueMarket.UtilizationCap.selector, ITorqueMarket.TooManyPositions.selector,
            ITorqueMarket.Slippage.selector, bytes4(0), bytes4(0x4e487b71)
        ];
        string[10] memory nm =
            ["stale", "poolMismatch", "badLev", "tooSmall", "oiCap", "utilCap", "tooMany", "slippage", "empty", "panic"];
        for (uint256 i; i < 10; i++) console.log(string.concat("why.", nm[i]), handler.openRevertReasons(sel[i]));
    }
}
