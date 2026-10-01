// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3, IUniswapV3SwapCallback} from "../../src/interfaces/IExternal.sol";

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Chainlink-style feed with 8 decimals whose rounds the test controls.
contract MockFeed is IAggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function push(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setRaw(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// @notice A constant-price Uniswap-v3-shaped pool. token0 = USDG, token1 = NVDA, like the real pool.
///         Quotes at `price6` (USDG per NVDA, 6 decimals) less `slipBps`, and mints its output so
///         liquidity never runs out. Payment is pulled through the v3 callback and checked.
contract MockPool {
    MockToken public immutable usdg;
    MockToken public immutable nvda;
    uint256 public price6;
    uint256 public slipBps;
    bool public observeBroken;

    // Uniswap-v3-style oracle: tick cumulative checkpoints.
    uint256[] internal cpTime;
    int256[] internal cpCum;
    int256[] internal cpTick;

    constructor(MockToken _usdg, MockToken _nvda) {
        usdg = _usdg;
        nvda = _nvda;
    }

    function token0() external view returns (address) {
        return address(usdg);
    }

    function token1() external view returns (address) {
        return address(nvda);
    }

    /// @notice Spot price for swaps, and the tick that accrues into the 30-minute average from now on.
    function setPrice(uint256 p6) external {
        price6 = p6;
        int256 tick = tickForPrice6(p6);
        if (cpTime.length == 0) {
            // as if the pool had sat at this price for a day, so the TWAP window is always available
            cpTime.push(block.timestamp - 1 days);
            cpCum.push(0);
            cpTick.push(tick);
        }
        uint256 n = cpTime.length - 1;
        int256 cum = cpCum[n] + cpTick[n] * int256(block.timestamp - cpTime[n]);
        if (cpTime[n] == block.timestamp) {
            cpTick[n] = tick;
        } else {
            cpTime.push(block.timestamp);
            cpCum.push(cum);
            cpTick.push(tick);
        }
    }

    function breakObserve(bool b) external {
        observeBroken = b;
    }

    function _cumAt(uint256 t) internal view returns (int256) {
        require(cpTime.length > 0 && t >= cpTime[0], "OLD");
        uint256 i = cpTime.length - 1;
        while (cpTime[i] > t) i--;
        return cpCum[i] + cpTick[i] * int256(t - cpTime[i]);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory cums, uint160[] memory spl) {
        require(!observeBroken, "OLD");
        cums = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; i++) {
            cums[i] = int56(_cumAt(block.timestamp - secondsAgos[i]));
        }
    }

    /// @notice Largest tick whose price (USDG per NVDA) is >= p6. Price falls as tick rises (USDG is token0).
    function tickForPrice6(uint256 p6) public pure returns (int256 tick) {
        int256 lo = -887_272;
        int256 hi = 887_272;
        while (lo < hi) {
            int256 mid = (lo + hi + 1) / 2;
            if (price6ForTick(mid) >= p6) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function price6ForTick(int256 tick) public pure returns (uint256) {
        uint256 a = tick < 0 ? uint256(-tick) : uint256(tick);
        uint256 r = 1e18;
        uint256 b = 1.0001e18;
        while (a > 0) {
            if (a & 1 == 1) r = Math.mulDiv(r, b, 1e18);
            a >>= 1;
            if (a > 0) b = Math.mulDiv(b, b, 1e18);
        }
        if (tick < 0) r = Math.mulDiv(1e18, 1e18, r);
        return Math.mulDiv(1e18, 1e18, r);
    }

    function setSlip(uint256 bps) external {
        slipBps = bps;
    }

    function quoteBuy(uint256 usdgIn) public view returns (uint256) {
        return usdgIn * 1e18 / price6 * (10_000 - slipBps) / 10_000;
    }

    function quoteSell(uint256 nvdaIn) public view returns (uint256) {
        return nvdaIn * price6 / 1e18 * (10_000 - slipBps) / 10_000;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-in only");
        uint256 amtIn = uint256(amountSpecified);
        if (zeroForOne) {
            uint256 out = quoteBuy(amtIn);
            nvda.mint(recipient, out);
            amount0 = int256(amtIn);
            amount1 = -int256(out);
            uint256 before = usdg.balanceOf(address(this));
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(usdg.balanceOf(address(this)) >= before + amtIn, "IIA");
        } else {
            uint256 out = quoteSell(amtIn);
            usdg.mint(recipient, out);
            amount0 = -int256(out);
            amount1 = int256(amtIn);
            uint256 before = nvda.balanceOf(address(this));
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(nvda.balanceOf(address(this)) >= before + amtIn, "IIA");
        }
    }
}
