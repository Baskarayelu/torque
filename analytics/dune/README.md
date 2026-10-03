# Dune queries for TORQUE (not yet run on Dune)

SQL for a Dune dashboard over Robinhood Chain mainnet (`robinhood.logs`). Each query decodes TorqueMarket, TorqueVault, the Chainlink RHNVDA/USD aggregator and the NVDA/USDG Uniswap v3 pool straight from raw logs by event signature, so no Dune decoding submission is needed.

| File | What it shows |
| --- | --- |
| `01_positions.sql` | Every position: opened, closed or knocked out, margin, leverage, NVDA bought, vault repaid, trader payout, P&L, both transaction hashes |
| `02_vault_over_time.sql` | Vault idle cash, lent principal, assets against the $20 cap, utilisation against the 80% limit |
| `03_hedge.sql` | NVDA held by the market against NVDA owed to positions, after every transaction |
| `04_safety_checks_hourly.sql` | Both safety checks hour by hour: feed age against 12 h, pool against Chainlink within 1.5%, and whether TORQUE was open |
| `05_pause_windows.sql` | Every stretch the feed was silent for over 12 hours, so opens would pause |
| `06_headline.sql` | Counters: positions opened, closed, knocked out, bad debt, repaid to the vault |

**Status:** written, not executed. On 10 September 2026 Dune's free plan became view-only (no query execution, no API), so these have not been run on Dune and are not linked from the submission. They need a paid Dune plan to run. Paste each into a new query on dune.com.

Notes: `04` approximates the on-chain 30-minute TWAP with the last swap tick of each hour. The `02` and `03` series are summed per transaction, because inside one transaction a swap can move tokens before the event that books it.
