# Research data behind TORQUE

These are snapshots and scripts behind the numbers in the README and SPEC. All data was read from Robinhood Chain mainnet (chain 4663).

| File | What it is |
|---|---|
| `morpho_stock_markets.py` | Lists every Morpho Blue market (`CreateMarket` events on `0x9D53…1010`, with retries and range splitting), then reads each market's loan token, collateral token and `market()` totals |
| `morpho_markets_2026-10-02.json` | Output of that script: 303 markets. 171 take a Robinhood Stock Token as collateral; 167 of those lend USDG and the other 4 lend WETH |
| `chain_snapshot.py` | Reads USDG `totalSupply` and the 167 USDG markets' `market()` totals at one block |
| `chain-snapshot-2026-10-03.json` | Its output at block 78,677,903 (2026-10-03 00:58 UTC): $700.7M USDG; $1,507,386 lent and $1,456,597 borrowed (96.6%); the largest NVDA market $623,355 lent, 98.5% borrowed. These are the numbers on the README, landing page, videos and social assets, always shown with the block |
| `chain-snapshot-2026-10-02.json` | An earlier read at block 78,338,439 (2026-10-02 15:28 UTC): $700.1M; $1.24M lent, 98.1% borrowed; NVDA market 100%. Kept to show the figures move |
| `nvda_feed_rounds_2026-10-01.json` | 601 rounds of Chainlink `RHNVDA / USD` (`0x379EC4f7…9F15`), as `[roundId, price, updatedAt]` |
| `pool_twap_vs_feed.py` | Rebuilds the NVDA/USDG pool's 30-minute average from `Swap` events and compares it with the feed every 5 minutes |

An earlier scan for this project reported "$15 of stock-collateral lending". It was wrong: failed log requests silently returned nothing, so it saw 21 of the 303 markets. The script here retries every request and fails loudly instead.
