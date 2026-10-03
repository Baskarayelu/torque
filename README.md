# TORQUE: knock-out leverage on NVDA, settled in USDG on Robinhood Chain

**Robinhood Chain holds $700.7M of USDG. Only $1.51M of it is lent against stock tokens, and 96.6% of that is already borrowed** (block 78,677,903).

Read from Robinhood Chain mainnet at block 78,677,903 (2026-10-03 00:58 UTC):
- USDG `totalSupply` is $700.7M.
- Morpho Blue (`0x9D53…1010`) has 303 markets. 171 take a Robinhood Stock Token as collateral. The 167 of those that lend USDG hold $1,507,386 supplied and $1,456,597 borrowed (96.6%); the other 4 lend WETH.
- The largest NVDA market has $623,355 supplied and is 98.5% borrowed.
- Reproducible: [research/chain_snapshot.py](research/chain_snapshot.py) wrote [research/chain-snapshot-2026-10-03.json](research/chain-snapshot-2026-10-03.json) (an earlier read at block 78,338,439 is kept as [chain-snapshot-2026-10-02.json](research/chain-snapshot-2026-10-02.json); the figures move as markets do) from the market list in [research/](research/).

<!-- deployment:status -->
> **Status: live on Robinhood Chain mainnet.** TorqueMarket [`0xbee6Da89F879B018Fea5d7A78311db720B9D8096`](https://robinhoodchain.blockscout.com/address/0xbee6Da89F879B018Fea5d7A78311db720B9D8096) and TorqueVault [`0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf`](https://robinhoodchain.blockscout.com/address/0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf), deployed at block 78,466,999 on 2026-10-02 19:04 UTC and source-verified on Sourcify. Dashboard: [app.torque.0xo.in](https://app.torque.0xo.in). Docs: [https://torque.0xo.in/docs](https://torque.0xo.in/docs).
<!-- /deployment:status -->

People want leverage on stock tokens, but the dollars to fund it are not there. The demand is visible on-chain and the supply is maxed out. TORQUE brings its own USDG liquidity and a product shaped for retail:

> Pick NVDA, choose 2–5× leverage and pay in USDG. The most you can ever lose is what you put in. There are no margin calls, and every position is backed by real NVDA bought from the on-chain pool and protected by Chainlink's NVDA price.

**LP vault capped at $20 USDG for the buildathon.** TORQUE is built for Robinhood Chain mainnet with real USDG, which is the point. Robinhood testnet has no real Chainlink stock feeds and no stock pools, so a testnet version would prove nothing. At $20 the vault can lend up to $16: two $2 positions at 5× (about $10 of NVDA each), or four $1 positions at 5×.

---

## How it works

| Step | What happens on chain |
|---|---|
| Open | You post `margin` USDG. The LP vault lends the rest of `margin × leverage`. The whole notional is swapped into **real NVDA** in the NVDA/USDG Uniswap v3 pool and held by the contract. The fill must land within 1% of Chainlink's `RHNVDA / USD`. |
| Hold | Your debt accrues at 10% APR. Your **financing level** is the price at which the position is worth zero, `debt / NVDA held`. The **knock-out barrier** sits 5% above it. |
| Close | You sell your NVDA back into the pool. The vault is repaid first, in full, and you keep the rest. |
| Knock-out | If a fresh Chainlink price is at or below your barrier, anyone can knock the position out. The NVDA is sold, the vault is repaid, and whatever is left above the debt is yours to `claim()`. |

The trader's loss is capped at the margin. Every position is hedged 1:1 with real NVDA, so **the vault is a secured lender, never a naked counterparty**.

### USDG is the whole product, not an add-on

Paxos' USDG is the margin you post, the asset LPs deposit, the currency the vault lends, and the payout you receive. There is no other dollar in the system.

| | Robinhood Chain mainnet |
|---|---|
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| NVDA Stock Token | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| NVDA/USDG 0.05% pool (hedge venue) | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` |
| Chainlink `RHNVDA / USD` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |

## Keeping the LP vault solvent (the main design job)

This product fails if one-sided demand meets a frozen weekend price. The NVDA feed stops from Friday ~20:00 UTC to Monday 00:00 UTC, about 52 hours, while the token keeps trading in the pool. Each defence below is enforced in the contract.

| Risk | Defence |
|---|---|
| Vault ends up short NVDA | **Full delta hedge.** Every position's notional is bought as NVDA in the 0.05% pool at open, so the vault's exposure is a loan secured by real NVDA. |
| Too much exposure | **Hard caps:** vault ≤ **$20**, open notional ≤ **$30**, lending ≤ 80% of vault assets, leverage 2–5×. |
| Acting on a stale price | Two **safety checks inside TORQUE**. The feed must have printed within 12h, and the NVDA pool's own 30-minute average price must agree with it within 1.5%. If either fails, opens, knock-outs and LP flows stop. |
| The Friday-evening window | The feed is frozen but under 12h old, while the token trades on. The second check closes this: once the pool moves more than 1.5% from the frozen print, everything stops. |
| A lagging average holding up a knock-out | In a fast sell-off the 30-minute average trails the move. A Chainlink print from the last 30 minutes is trusted for knock-outs, so protective knock-outs are never held up. The strict alternative was tested and lets bad debt through. |
| Weekend gap through the barrier | **Explicit and tested.** Over the weekend nothing can be knocked out or opened, and a close that would not repay the vault reverts. On Monday the first fresh round triggers the knock-out: the trader loses the margin (never more), and LPs absorb exactly `debt − sale proceeds`. |
| LPs running ahead of a known loss | Loans are marked at the **lower** of Chainlink and the pool's 30-minute average, less 1%. A loss shows in NAV the moment either price shows it. Withdrawals are limited to idle cash. |
| Manipulated pool | Every swap must fill within 1% of Chainlink. Moving a 30-minute average means holding the pool off-market for most of half an hour. |
| A Paxos-frozen USDG address blocks a knock-out | Knock-out residuals are credited to the trader to `claim()`, never pushed, so no trader address can block a knock-out. |

How much of a drop a fresh 5× position survives with no loss to LPs:
- **About 19% in a single gap.** At 2× it is about 49%.
- **In normal trading, any single move of up to 3.7%** between feed updates at the full 1% slippage. The largest single update of the NVDA feed in 601 measured rounds was 1.43%.

The 1.5% band is calibrated on 122,163 real swaps:
- On weekdays the pool's 30-minute average sat within 0.54% of Chainlink 99% of the time (worst case 1.35%).
- Over the weekend of 09-26/27 it stayed within 0.51% of the frozen print.

There is **no owner, no pause and no upgrade path.** All parameters are constants. The only privileged call is a one-shot `setMarket` made once at deployment. Full detail is in [SPEC.md](SPEC.md).

## Evidence

| Suite | What it proves | Result |
|---|---|---|
| `test/invariant/` (written first) | 9 solvency invariants: full NVDA backing, cash conservation, the $20 cap, open-interest and utilization caps, NAV never overstated, **bad debt only after a real gap**, nothing unsafe succeeds when a safety check fails, exact payouts. The handler simulates weekends where the pool drifts away from a frozen feed and judges every action with its own independently computed geometric average | **9/9 pass**, 1,024 runs × 128 calls |
| `test/adversarial/` | An attacker's pass before mainnet ([research/ADVERSARIAL.md](research/ADVERSARIAL.md)). It covers reentrancy through a hook-calling token, first-depositor inflation, rounding farms, donations, knock-outs at a manipulated tick, sandwiching the hedge, same-block ordering, free positions, and a dead feed. **It found one real hole**: a dead price feed could have locked LP funds. It was fixed before deployment | **23/23 pass** |
| Planted-bug check | 25 deliberate bugs planted one at a time, such as: no buffer, knock-out on a stale feed, a skipped pool check, loans marked at face value, a flipped tick sign, a 10× band, the strict knock-out rule, no reentrancy guard, a dead-feed unwind with no wait | **24/25 caught** ([log](research/planted-bugs.log), run with `script/planted-bugs.sh`). The one survivor removes one of two duplicate cap checks and changes no behaviour; removing both is caught |
| `test/unit/` | Every path, including the full weekend gap, the Friday-evening divergence, a calm weekend closing on age, band edges, failing closed, and tick math | **32/32 pass**, including fuzz runs |
| `test/fork/` | Real mainnet USDG, NVDA, pool and Chainlink feed, plus a sandwich on the real pool ($1k / $10k / $100k front-runs lose about $1 / $10 / $100) | **6/6 pass** |
| LP backtest | The vault model run over every Chainlink NVDA print of the last 90 days ([research/LP_BACKTEST.md](research/LP_BACKTEST.md), `python3 research/lp_backtest.py`). 5x traders at 80% utilisation would have earned LPs +3.25% (14.1% a year) with no knock-outs; the worst 7-day fall was -11.3%. The window never tested the floor, so the report shows the gap sizes that would: at 5x, LP money is only lost past a single -20% gap | **+3.25% / 89 days, $0 bad debt** |

```bash
forge test                                              # unit + invariant
FOUNDRY_PROFILE=ci forge test                           # deeper invariant runs
RH_RPC_URL=<rpc> forge test --match-path "test/fork/*"  # against Robinhood Chain mainnet
```

## Prior art

On-chain, the existing route to leverage on stock tokens is borrowing USDG on Morpho against stock collateral and looping it. That supply is small ($1.51M at block 78,677,903) and 96.6% borrowed, so there is little left to borrow. Positions there can be liquidated in the usual lending-market way.

In this buildathon, two entries offer leverage on stock tokens. We read their code and checked their contracts on chain on 2026-10-01:

- **Gauntlet**, a PvP trading arena on Robinhood Chain.
  - The leveraged trading runs in an off-chain game: positions are priced by the operator's server from a seeded ETH price, and payouts are split between players.
  - Stock tokens are deposited into per-token vaults on Robinhood testnet. Withdrawals go through merkle claims, and no claim root had been posted.
  - TORQUE differs in **where leverage and settlement live**: on chain, against the real Chainlink NVDA price, real NVDA and real USDG.
- **Undertow**, a CME SPAN-style risk scanner with a vault that lends against the computed risk number.
  - Its testnet vault had no deposits or borrows, and the borrowed asset is a stablecoin the vault mints itself.
  - TORQUE differs in having **a used, solvent counterparty**: a real USDG LP vault whose loans are each secured by real NVDA.

## Limits, stated plainly

- **NVDA only, long only.** Shorts are v2. A short needs NVDA to sell, so the vault would have to hold NVDA inventory and take on price risk the long-only design avoids.
- **Buildathon caps:** the LP vault is capped at $20 USDG and open interest at $30. Both are enforced in the contract.
- **Calibration:** the 1.5% band and 30-minute window are based on one week of swaps that included one calm weekend. A weekend with a large pool move is modelled in the tests but has not been observed live.
- **Corporate actions are not handled.** NVDA's UI multiplier is 1.000775 today, inside the 1% fill guard, and a fork test confirms the feed prices one raw token. A split during an open position is out of scope.
- **Knock-outs need a caller.** There is no keeper reward in v1. Anyone can be the caller: [`script/knockout-watcher.sh`](script/knockout-watcher.sh) watches every position and, with `--send`, knocks out the eligible ones.
- **Dead feed:** if the feed has no usable print for 7 days, anyone may unwind positions at the pool's 30-minute average (vault repaid first). LPs can always withdraw when no positions are open.
- **No sequencer-uptime check:** no such feed is known on Robinhood Chain.
- **Not audited.**

## Fork rehearsal

`./script/rehearse-fork.sh up` forks Robinhood Chain mainnet locally with anvil, deploys TORQUE with the same `script/Deploy.s.sol`, seeds the vault with 15 USDG in that run and opens two positions from anvil's public test wallets. `python3 script/rehearse_scenario.py` then runs the whole lifecycle against the real USDG, NVDA, pool and Chainlink feed as forked, and logs every transaction: [research/fork-rehearsal-2026-10-02.log](research/fork-rehearsal-2026-10-02.log).

| Step | Result on the fork |
|---|---|
| LP fills the vault | Deposit to the $20 cap succeeds; one more cent is refused (`ERC4626ExceededMaxDeposit`) |
| Open $1 at 3× | Real NVDA bought in the forked pool; NVDA held equals NVDA owed, 1:1 |
| Close | Vault repaid in full; the trader receives the rest in USDG |
| Failed check | Feed replaced by a test feed at $195 (fork only): opens refused (`PoolPriceMismatch`), deposits refused (`PriceCheckFailed`) |
| Permissionless knock-out | A wallet that owns nothing knocks out #1 at its $197.44 knock-out level; the vault is repaid first; bad debt 0 |
| Claim | The owner claims the residual; nothing left owed |

The dashboard screenshots in [docs/screenshots/dashboard/](docs/screenshots/dashboard/) are from this fork, in a normal and a failed-check state.

<!-- deployment:deployments -->
## Deployments

| Robinhood Chain mainnet (4663) | Address |
|---|---|
| TorqueMarket | [`0xbee6Da89F879B018Fea5d7A78311db720B9D8096`](https://robinhoodchain.blockscout.com/address/0xbee6Da89F879B018Fea5d7A78311db720B9D8096) |
| TorqueVault (USDG LP) | [`0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf`](https://robinhoodchain.blockscout.com/address/0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf) |

Deployed at block 78,466,999 on 2026-10-02 19:04 UTC by `script/go-live.sh` (`script/Deploy.s.sol`) from [`0xA22B72d975d608Bd9Dd4945F4B28a4479A97967F`](https://robinhoodchain.blockscout.com/address/0xA22B72d975d608Bd9Dd4945F4B28a4479A97967F). Both contracts are an exact match on [Sourcify](https://repo.sourcify.dev/4663/0xbee6Da89F879B018Fea5d7A78311db720B9D8096) ([vault](https://repo.sourcify.dev/4663/0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf)).

| First transactions on mainnet | Tx |
|---|---|
| Deploy TorqueVault | [`0x43e4f58b…797001`](https://robinhoodchain.blockscout.com/tx/0x43e4f58b35e1dd181244b279099886df95b12bbd48a4373572ba954dda797001) |
| Deploy TorqueMarket | [`0x3401fe0c…7fbb47`](https://robinhoodchain.blockscout.com/tx/0x3401fe0c399aeaa264d8b0fc58a7b2f408ec8f2aabb1a17b6c85c052ae7fbb47) |
| Wire the vault to the market (one-shot `setMarket`) | [`0x58a5fd2c…615ee8`](https://robinhoodchain.blockscout.com/tx/0x58a5fd2c9129dd3d117ea73c1639b00e20ab58b2d538ac72fa31a13688615ee8) |
| Seed the vault with 15 USDG (same run) | [`0xfc3a0b3a…5a62eb`](https://robinhoodchain.blockscout.com/tx/0xfc3a0b3a4437a747c1004925b979e720945bc3e91ae5eaa062ff495f035a62eb) |
| Fill the vault to its $20 cap | [`0x6d401704…6e81f6`](https://robinhoodchain.blockscout.com/tx/0x6d401704fb3d4270da2340c8c9b3992848850190505f02e6b950daeebb6e81f6) |
| Open position #1: $2 at 5×, real NVDA bought in the pool | [`0x3a83b71d…bd2613`](https://robinhoodchain.blockscout.com/tx/0x3a83b71d6d51e6ef1317dc3d2d0f848b7b262dda6be64bf959d7df9bb6bd2613) |
| Close position #1: vault repaid in full, 1.98 USDG back to the trader | [`0xcf8a17fe…6d4315`](https://robinhoodchain.blockscout.com/tx/0xcf8a17fe9e5453e09fdb452c19d3a7deb8cad20b7ca1177210d823eb1b6d4315) |
<!-- /deployment:deployments -->
