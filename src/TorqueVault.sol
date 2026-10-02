// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITorqueMarket, ITorqueVault} from "./interfaces/ITorque.sol";

/// @title TorqueVault
/// @notice USDG liquidity that finances Torque NVDA positions. LPs earn the open fee and the
///         financing rate, and bear bad debt from price gaps through a knock-out barrier.
/// @dev    LP vault capped at $20 USDG for the buildathon, enforced here. LP flows are shut unless both
///         of Torque's price safety checks pass (fresh feed, and the pool's 30-minute average agrees),
///         and withdrawals are limited to idle cash. No owner, no pause, no upgrade.
contract TorqueVault is ERC4626, ITorqueVault {
    using SafeERC20 for IERC20;

    uint256 public constant VAULT_CAP = 20e6; // "LP vault capped at $20 USDG for the buildathon."

    address public immutable deployer;
    address public market;

    constructor(IERC20 usdg) ERC20("Torque NVDA LP", "tqNVDA-LP") ERC4626(usdg) {
        deployer = msg.sender;
    }

    /// @notice One-shot wiring at deployment; the vault can never be pointed at another market.
    function setMarket(address market_) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (market != address(0)) revert MarketAlreadySet();
        market = market_;
    }

    function lend(uint256 amount) external {
        if (msg.sender != market) revert OnlyMarket();
        IERC20(asset()).safeTransfer(market, amount);
    }

    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Idle cash plus loans marked at min(debt, NVDA collateral at the feed price less max slippage).
    function totalAssets() public view override returns (uint256) {
        uint256 assets = idle();
        if (market != address(0)) assets += ITorqueMarket(market).markedDebt();
        return assets;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (!_fresh()) return 0;
        uint256 assets = totalAssets();
        return assets >= VAULT_CAP ? 0 : VAULT_CAP - assets;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!_exitOpen()) return 0;
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), idle());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (!_exitOpen()) return 0;
        return Math.min(balanceOf(owner), _convertToShares(idle(), Math.Rounding.Floor));
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _requireFresh();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _requireFresh();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (!_exitOpen()) revert PriceCheckFailed();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (!_exitOpen()) revert PriceCheckFailed();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev The cap is enforced here as well as in maxDeposit, so mint() rounding cannot cross it.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (totalAssets() + assets > VAULT_CAP) revert CapExceeded();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev 6 extra share decimals make first-depositor inflation attacks uneconomic.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _fresh() internal view returns (bool) {
        return market != address(0) && ITorqueMarket(market).isPriceOk();
    }

    /// @dev Withdrawals need both price checks while loans are open (NAV depends on a price). With no
    ///      open positions NAV is exactly idle cash, so LPs can always leave, even if the feed is dead.
    function _exitOpen() internal view returns (bool) {
        if (market == address(0) || ITorqueMarket(market).openPositionCount() == 0) return true;
        return ITorqueMarket(market).isPriceOk();
    }

    function _requireFresh() internal view {
        if (!_fresh()) revert PriceCheckFailed();
    }
}
