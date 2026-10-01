// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITorqueMarket {
    struct Position {
        address owner;
        uint128 q; // NVDA held for this position (18 decimals)
        uint128 principal; // USDG lent by the vault (6 decimals)
        uint128 notional; // USDG swapped into NVDA at open
        uint128 margin; // USDG posted by the trader, fee included
        uint64 openedAt;
    }

    event Opened(
        uint256 indexed id, address indexed owner, uint256 margin, uint256 leverageBps, uint256 q, uint256 principal
    );
    event Closed(uint256 indexed id, uint256 proceeds, uint256 repaid, uint256 payout);
    event KnockedOut(uint256 indexed id, uint256 price, uint256 proceeds, uint256 repaid, uint256 payout, uint256 badDebt);

    error StaleFeed();
    error PoolPriceMismatch();
    error BadLeverage();
    error MarginTooSmall();
    error OpenInterestCap();
    error UtilizationCap();
    error TooManyPositions();
    error Slippage();
    error NotOwner();
    error NotKnockable();
    error Underwater();
    error UnknownPosition();
    error Unauthorized();

    /// @notice Both safety checks: the feed is fresh and the pool's 30-minute average agrees with it.
    function isPriceOk() external view returns (bool);
    function oraclePrice() external view returns (uint256 price6, bool fresh);
    function poolTwapPrice() external view returns (uint256 price6);
    function priceStatus()
        external
        view
        returns (uint256 feedPrice6, uint256 feedAge, uint256 poolTwap6, uint256 deviationBps, bool feedFresh, bool poolAgrees);
    function markedDebt() external view returns (uint256);
    function debtOf(uint256 id) external view returns (uint256);
    function barrierOf(uint256 id) external view returns (uint256);
    function financingLevelOf(uint256 id) external view returns (uint256);
    function getPosition(uint256 id) external view returns (Position memory);
    function openPositionIds() external view returns (uint256[] memory);
    function totalPrincipal() external view returns (uint256);
    function totalNotional() external view returns (uint256);
    function totalBadDebt() external view returns (uint256);
    function totalClaimable() external view returns (uint256);
    function claimable(address owner) external view returns (uint256);

    function open(uint256 margin, uint256 leverageBps, uint256 minNvdaOut) external returns (uint256 id);
    function close(uint256 id, uint256 minPayout) external returns (uint256 payout);
    function knockOut(uint256 id) external returns (uint256 payout);
    function claim() external returns (uint256 amount);
}

interface ITorqueVault {
    error PriceCheckFailed();
    error OnlyMarket();
    error OnlyDeployer();
    error MarketAlreadySet();
    error CapExceeded();

    function lend(uint256 amount) external;
    function idle() external view returns (uint256);
    function market() external view returns (address);
}
