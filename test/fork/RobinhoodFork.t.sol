// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";
import {ITorqueMarket} from "../../src/interfaces/ITorque.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal} from "../../src/interfaces/IExternal.sol";

/// @notice Runs Torque against real Robinhood Chain mainnet state: Paxos USDG, the NVDA Stock Token,
///         the NVDA/USDG 0.05% Uniswap v3 pool and Chainlink's RHNVDA / USD feed.
///         Run with: RH_RPC_URL=<rpc> forge test --match-path test/fork/*
contract RobinhoodForkTest is Test {
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant NVDA = IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    IUniswapV3PoolMinimal constant POOL = IUniswapV3PoolMinimal(0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3);
    IAggregatorV3 constant FEED = IAggregatorV3(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);
    address constant USDG_WHALE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010; // Morpho Blue, ~$470M USDG

    TorqueVault vault;
    TorqueMarket market;
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("RH_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        vault = new TorqueVault(USDG);
        market = new TorqueMarket(USDG, NVDA, POOL, FEED, vault);
        vault.setMarket(address(market));

        vm.startPrank(USDG_WHALE);
        USDG.transfer(lp, 20e6);
        USDG.transfer(alice, 10e6);
        vm.stopPrank();
        vm.prank(lp);
        USDG.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        USDG.approve(address(market), type(uint256).max);
    }

    function _requireFreshFeed() internal {
        if (!market.isPriceOk()) {
            // The real feed is frozen at this block (weekend or a quiet spell). Refresh it at the
            // same answer so the trading path can still be exercised; staleness has its own test.
            (uint80 r, int256 a,,,) = FEED.latestRoundData();
            vm.mockCall(
                address(FEED),
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r, a, block.timestamp, block.timestamp, r)
            );
            console.log("feed was stale at fork block; mocked updatedAt = now");
        }
    }

    function test_fork_realFeedAndPoolAgree() public view {
        (uint256 feed6, uint256 age, uint256 twap6, uint256 devBps, bool fresh, bool agrees) = market.priceStatus();
        console.log("Chainlink NVDA (USDG 6dp):", feed6, "age (s):", age);
        console.log("Pool 30-min average      :", twap6, "deviation bps:", devBps);
        console.log("fresh / agrees:", fresh, agrees);
        assertGt(feed6, 50e6);
        assertLt(feed6, 2_000e6);
        assertGt(twap6, 0, "real pool serves a 30-minute average");
    }

    /// The tick conversion against the real pool's own sqrtPriceX96 at its current tick.
    function test_fork_tickMathMatchesRealPoolSpot() public {
        (uint160 sqrtP, int24 tick,,,,,) = IPoolSlot0(address(POOL)).slot0();
        // spot USDG(6dp) per NVDA from sqrtPriceX96: price = 1e18 * 2^192 / sqrtP^2 (USDG is token0)
        uint256 ratioX192 = uint256(sqrtP) * uint256(sqrtP);
        uint256 spot6 = (uint256(1e18) << 96) / (ratioX192 >> 96);
        uint256 fromTick = ExposedMarket.tickToPrice6(market, tick);
        console.log("spot from sqrtPrice:", spot6, "from tick:", fromTick);
        assertApproxEqRel(fromTick, spot6, 0.0002e18, "within two ticks' rounding");
    }

    function test_fork_openAndCloseThroughRealPool() public {
        _requireFreshFeed();
        vm.prank(lp);
        vault.deposit(20e6, lp);
        assertEq(vault.totalAssets(), 20e6);

        vm.prank(alice);
        uint256 id = market.open(2e6, 50_000, 0); // $2 at 5x: $9.95 of real NVDA bought
        ITorqueMarket.Position memory p = market.getPosition(id);
        (uint256 p6,) = market.oraclePrice();
        uint256 fillPrice = uint256(p.notional) * 1e18 / p.q;
        console.log("oracle", p6, "fill", fillPrice);
        assertApproxEqRel(fillPrice, p6, 0.01e18, "real fill within 1% of Chainlink");
        assertEq(NVDA.balanceOf(address(market)), p.q, "real NVDA held as the hedge");
        console.log("barrier", market.barrierOf(id));

        uint256 before = USDG.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.close(id, 0);
        console.log("round-trip payout on $2 margin:", payout);
        assertEq(USDG.balanceOf(alice) - before, payout);
        // round trip costs the 0.10% open fee on notional plus pool fees and impact on ~$10
        assertGt(payout, 1.96e6);
        assertEq(NVDA.balanceOf(address(market)), 0);
        assertEq(market.totalBadDebt(), 0);
        assertGe(vault.totalAssets(), 20e6, "LPs kept the fee");
    }

    function test_fork_knockOutThroughRealPool() public {
        _requireFreshFeed();
        vm.prank(lp);
        vault.deposit(20e6, lp);
        vm.prank(alice);
        uint256 id = market.open(2e6, 50_000, 0);
        uint256 barrier = market.barrierOf(id);

        // Chainlink prints at the barrier (an in-session sell-off); the real pool is still higher,
        // so the hedge sells above the oracle-derived minimum and the vault is repaid in full.
        (uint80 r,,,,) = FEED.latestRoundData();
        vm.mockCall(
            address(FEED),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r + 1, int256(barrier * 100), block.timestamp, block.timestamp, r + 1)
        );
        uint256 payout = market.knockOut(id);
        assertEq(market.totalBadDebt(), 0);
        assertGt(payout, 0);
        assertEq(market.claimable(alice), payout);
        vm.prank(alice);
        market.claim();
        assertEq(USDG.balanceOf(address(market)), 0);
        assertEq(NVDA.balanceOf(address(market)), 0);
    }

    function test_fork_staleFeedShutsTheProduct() public {
        _requireFreshFeed();
        vm.prank(lp);
        vault.deposit(10e6, lp);
        vm.clearMockedCalls();
        (,,, uint256 updatedAt,) = FEED.latestRoundData();
        vm.warp(updatedAt + market.MAX_FEED_AGE() + 1);
        assertFalse(market.isPriceOk());
        vm.prank(alice);
        vm.expectRevert(ITorqueMarket.StaleFeed.selector);
        market.open(2e6, 50_000, 0);
        assertEq(vault.maxDeposit(lp), 0);
        assertEq(vault.maxWithdraw(lp), 0);
    }
}

interface IPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// Reads the market's internal tick conversion through a throwaway subclass deployed in the fork.
library ExposedMarket {
    function tickToPrice6(TorqueMarket m, int24 tick) internal returns (uint256) {
        TickProbe probe = new TickProbe(m);
        return probe.price(tick);
    }
}

contract TickProbe is TorqueMarket {
    constructor(TorqueMarket m) TorqueMarket(m.usdg(), m.nvda(), m.pool(), m.feed(), m.vault()) {}

    function price(int24 tick) external view returns (uint256) {
        return _tickToPrice6(tick);
    }
}
