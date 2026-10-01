// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockToken, MockFeed, MockPool} from "../mocks/Mocks.sol";
import {TorqueVault} from "../../src/TorqueVault.sol";
import {TorqueMarket} from "../../src/TorqueMarket.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal} from "../../src/interfaces/IExternal.sol";

abstract contract Base is Test {
    MockToken usdg;
    MockToken nvda;
    MockFeed feed;
    MockPool pool;
    TorqueVault vault;
    TorqueMarket market;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant P0 = 231_40e4; // $231.40 in 6 decimals

    function setUp() public virtual {
        vm.warp(1_790_000_000); // Thu 2026-09-24
        usdg = new MockToken("Global Dollar", "USDG", 6);
        nvda = new MockToken("NVIDIA", "NVDA", 18);
        feed = new MockFeed();
        pool = new MockPool(usdg, nvda);
        setPrice(P0);

        vault = new TorqueVault(usdg);
        market = new TorqueMarket(usdg, nvda, IUniswapV3PoolMinimal(address(pool)), IAggregatorV3(address(feed)), vault);
        vault.setMarket(address(market));

        for (uint256 i; i < 3; i++) {
            address a = [lp, alice, bob][i];
            usdg.mint(a, 10_000e6);
            vm.startPrank(a);
            usdg.approve(address(vault), type(uint256).max);
            usdg.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Moves the pool and prints a fresh feed round at the same price.
    function setPrice(uint256 p6) internal {
        pool.setPrice(p6);
        feed.push(int256(p6 * 100));
    }

    function depositLp(uint256 amount) internal {
        vm.prank(lp);
        vault.deposit(amount, lp);
    }

    function openAs(address who, uint256 margin, uint256 lev) internal returns (uint256 id) {
        vm.prank(who);
        id = market.open(margin, lev, 0);
    }

    function freezeFeedFor(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
    }
}
