# Research data behind TORQUE

These are snapshots and scripts behind the numbers in the README and SPEC. All data was read from Robinhood Chain mainnet (chain 4663).

| File | What it is |
|---|---|
| `morpho_stock_markets.py` | Lists every Morpho Blue market (`CreateMarket` events on `0x9D53…1010`, with retries and range splitting), then reads each market's loan token, collateral token and `market()` totals |
| `morpho_markets_2026-10-02.json` | Output of that script: 303 markets. 171 take a Robinhood Stock Token as collateral; they hold $1,238,779 of USDG supplied and $1,214,406 borrowed |
| `nvda_feed_rounds_2026-10-01.json` | 601 rounds of Chainlink `RHNVDA / USD` (`0x379EC4f7…9F15`), as `[roundId, price, updatedAt]` |
| `pool_twap_vs_feed.py` | Rebuilds the NVDA/USDG pool's 30-minute average from `Swap` events and compares it with the feed every 5 minutes |

An earlier scan for this project reported "$15 of stock-collateral lending". It was wrong: failed log requests silently returned nothing, so it saw 21 of the 303 markets. The script here retries every request and fails loudly instead.
