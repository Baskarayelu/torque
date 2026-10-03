# TORQUE v1: specification

A long-only, knock-out leveraged position on NVDA, settled on Robinhood Chain mainnet. Margin, liquidity and payouts are all in USDG.

## Instrument

A trader posts `margin` USDG and picks leverage `L` from 2× to 5×.

| Quantity | Definition |
|---|---|
| fee | `margin × L × OPEN_FEE_BPS`, paid to the vault |
| notional `N` | `(margin − fee) × L` |
| borrow | `N − (margin − fee)`, lent by the vault |
| hedge | swap `N` USDG → `q` NVDA in the NVDA/USDG 0.05% Uniswap v3 pool |
| debt `D(t)` | `borrow × (1 + FINANCING_APR × Δt / 1yr)`, simple interest |
| financing level `F(t)` | `D(t) / q`, the NVDA price at which the position is worth zero |
| barrier `B(t)` | `F(t) × (1 + KO_BUFFER_BPS)` |

The position is worth `q × P − D(t)` and is never negative for the trader: **the most the trader can lose is the margin**. There are no margin calls.

**Full hedge.** Every open position is backed 1:1 by the `q` NVDA it bought. The market contract holds that NVDA. The vault's exposure is a loan of `D(t)` USDG secured by `q` NVDA. The vault is never short NVDA, which is why long-only works with a small vault. Shorts would need the vault to hold NVDA inventory and lend it out, so they are v2.

## Price safety checks

TORQUE reads one price, Chainlink's `RHNVDA / USD` on Robinhood Chain, and runs two safety checks on it before acting. They are internal checks of this leverage product. TORQUE does not publish a price, and nothing here is meant to be used by other protocols.

1. **Fresh feed.** `0 < answer`, `updatedAt ≤ now` and `now − updatedAt ≤ MAX_FEED_AGE` (12h).
2. **Pool agreement.** The NVDA/USDG pool's own 30-minute time-weighted average price must be within 1.5% of the feed answer. The average comes from Uniswap v3 `observe()`: the mean tick over 30 minutes, converted to USDG per NVDA. If the pool cannot serve the window, the check fails closed.

| Action | Fresh feed | Pool agreement |
|---|---|---|
| `open` | required | required |
| `deposit` / `mint` / `withdraw` / `redeem` | required | required |
| `knockOut` | required | required **unless the feed printed within the last 30 minutes** |
| `close` | not required | not required. It only ever succeeds if the vault is repaid in full |
| `withdraw` / `redeem` with **no open positions** | not required | not required. NAV is exactly idle cash, so LPs can always leave |
| `unwind` (emergency) | feed must be **dead** for 7 days | uses the pool average itself |

### Why both checks

I measured 601 rounds of `RHNVDA / USD` (`0x379EC4f7…9F15`, 2026-07-30 → 10-01):
- The feed is **deviation-only**: it updates on a move of about 0.5% (median move per update 0.53%) and has no weekday heartbeat. Quiet weekday gaps of 12–21h are normal.
- It **freezes from Friday ~20:00 UTC to Monday 00:00 UTC** (52h), and for 78h over a holiday weekend.
- The largest single update was 1.43%.

Because the feed only updates on movement, age alone cannot tell a quiet Tuesday from a Saturday:

| MAX_FEED_AGE | weekday time shut | weekend time shut |
|---|---|---|
| 6h | 19.7% | 89.7% |
| **12h** | **7.1%** | **78.2%** (from about Sat 08:00 UTC) |
| 24h | 2.3% | 55.1% |

With age alone, the product would stay open from Friday 20:00 to Saturday 08:00 UTC on a frozen Friday price while the token keeps trading in the pool. Several paths take value from LPs in that window:
- An LP withdraws at a mark that the market has already moved through.
- A depositor buys shares at a stale mark.
- Knock-out decisions are made against a price that no longer holds.

The pool check closes the window: as soon as the pool's 30-minute average moves more than 1.5% from the frozen print, opens, knock-outs and LP flows stop.

### Why 30 minutes and 1.5%

I rebuilt the pool's price path from 122,163 swaps (Fri 09-25 → Thu 10-01) and compared its 30-minute average with the feed every 5 minutes:

| Period | p50 | p95 | p99 | max |
|---|---|---|---|---|
| Weekday, in session | 0.13% | 0.38% | 0.54% | 1.35% |
| Weekend, feed frozen (09-26/27) | 0.35% | 0.48% | 0.51% | 0.51% |

A 1.5% band refused nothing during normal trading in the sample, and it fires only when the pool really moves away from a frozen print. That weekend was calm (the pool stayed within 0.51% of Friday's close), so the check would not have fired. In that case the 12h age limit closes the product from Saturday ~08:00.

A 30-minute average is expensive to push. To move it 1.5%, an attacker has to hold the pool's price off-market for a large part of 30 minutes, against arbitrage, in a pool holding about $3.5M. A single-block manipulation of spot price does not move it.

### Why knock-outs trust a fresh print over a lagging average

A 30-minute average lags a fast move by design. In a sharp in-session sell-off, Chainlink prints below the barrier while the average still sits above it. A strict rule ("refuse knock-outs whenever the average disagrees") holds up exactly the knock-outs that protect LPs.

This is tested, not assumed. With the strict rule, the invariant suite fails `badDebtNeedsGap`, meaning LPs took bad debt with no gap in the price. The unit test `test_knockOut_fastSelloffNotBlockedByAverageLag` shows the case directly.

So a knock-out may proceed on a Chainlink print from the last 30 minutes even if the average disagrees. Older prints must agree with the pool. On weekends the print is always older than 30 minutes, so the frozen-feed protection is unchanged. Every knock-out sale also has to fill within 1% of the Chainlink price, or it reverts.

## Actions

| Action | Who | Outcome |
|---|---|---|
| `deposit` / `mint` | anyone | USDG into the vault, up to `VAULT_CAP` total assets |
| `withdraw` / `redeem` | LP | only up to the vault's **idle** USDG |
| `open` | anyone | the swap must deliver ≥ `N / P_feed × (1 − MAX_SLIPPAGE)` NVDA |
| `close` | position owner | sells `q` NVDA. **Reverts unless proceeds ≥ D(t)**, so the vault is always repaid in full. The trader keeps the rest and sets their own `minOut` |
| `knockOut` | anyone | requires `P_feed ≤ B(t)`. Sells `q` NVDA with `minOut = q × P_feed × (1 − MAX_SLIPPAGE)`. Repays `min(proceeds, D)`. The residual is credited to the trader to `claim()`; any shortfall is **bad debt** borne by LPs |
| `claim` | trader | withdraws knock-out residuals |
| `unwind` | anyone, only once the feed is dead (`DEAD_FEED_AFTER` = 7 days without a usable print) | sells `q` NVDA with `minOut = q × P_pool30m × (1 − MAX_SLIPPAGE)`, then repays the vault first, credits the residual and books any shortfall, exactly like a knock-out |
| `reportFeedDown` | anyone | starts the dead-feed clock for a feed that reverts or returns ≤ 0 (such a feed has no `updatedAt` to age). Any healthy read clears it: this call, `open`, `close` or `knockOut` |

### Why the emergency unwind exists

The adversarial pass found this hole: if the feed dies (deprecation, delisting, or a permanently reverting proxy), LP money must not be locked.
- A broken feed reads as "no price"; it never reverts.
- LPs can always exit when no positions are open.
- An abandoned position can be unwound once the feed has been dead for 7 days. The longest normal freeze measured is 78h, so a holiday weekend can never trigger it.

See [research/ADVERSARIAL.md](research/ADVERSARIAL.md).

### Why knock-out payouts are claimed, not pushed

Paxos can freeze a USDG address. If a knock-out pushed the residual straight to a frozen trader, the transfer would revert and the knock-out with it. The position would then stay open while the price kept falling, and LPs would carry the loss. Crediting the residual and letting the trader `claim()` it means no trader address can ever block a knock-out.

## Vault accounting

`totalAssets = idleUSDG + Σ mark_i`, where `mark_i = min(D_i(t), q_i × min(P_feed, P_pool30m) × (1 − MAX_SLIPPAGE))`.

Loans are marked at the lower of the feed and the pool's 30-minute average, less the full execution allowance. A loan that a gap has pushed underwater is written down as soon as either price shows it, before the knock-out lands, so an LP cannot withdraw at face value ahead of a known loss. A lagging feed never props NAV up while the market trades lower. LP flows are closed whenever either safety check fails.

## Weekend gap through the barrier (explicit, tested)

1. Friday evening: a position is open and the feed freezes. If NVDA moves more than 1.5% in the pool within the next 12 hours, the pool check shuts opens, knock-outs and LP flows (`PoolPriceMismatch` / `PriceCheckFailed`). Otherwise the 12h age limit shuts them from about Saturday 08:00.
2. Over the weekend NVDA trades lower in the pool. The feed still shows Friday's price.
   - `knockOut` and `open` revert.
   - `deposit` and `withdraw` revert.
   - `close` reverts with `Underwater` if the pool price no longer covers the debt.
3. Monday: the first fresh round is below `F`.
   - `knockOut` succeeds.
   - The trader receives 0 (margin lost, never more).
   - The vault receives the sale proceeds.
   - `badDebt = D − proceeds`. The loss was already in NAV from the moment a fresh price showed it.

A fresh position takes on no bad debt unless the Monday price is below `F / (1 − MAX_SLIPPAGE)`. That is a gap of about `1 − (1 − 1/L)/0.99` below entry: 19.2% at 5× and 49.5% at 2×, slightly less once financing has accrued.

## Caps (immutable, enforced on chain)

| Parameter | Value | Why |
|---|---|---|
| `VAULT_CAP` | **20 USDG** | **"LP vault capped at $20 USDG for the buildathon."** TORQUE deploys to mainnet with real USDG, which is the point: testnet has no real Chainlink stock feeds and no stock pools, so a testnet version would prove nothing. Checked in `maxDeposit`/`maxMint` and again in `_deposit` |
| `MAX_UTILIZATION_BPS` | 80% | total borrow ≤ 80% of vault assets, so the $20 vault lends at most $16: two $2 positions at 5× (each borrows $7.96 for $9.95 of NVDA), four $1 positions at 5×, or about $15 of margin at 2× |
| `MAX_OPEN_NOTIONAL` | 30 USDG | hard cap on open interest, 1.5× the vault. The NVDA hedge is at most ~0.13 NVDA, against a pool holding ~3,690 |
| `MAX_OPEN_POSITIONS` | 32 | bounds the valuation loop. With the caps above, at most 15 positions can exist (minimum notional is ~$2), so this is a backstop |
| leverage | 2×–5× | 5× keeps a ~19% weekend-gap cushion |
| `KO_BUFFER_BPS` | 5% | an in-session knock-out still repays in full after a single drop of up to **3.7%** between feed updates at the full 1% slippage (1.05 × 0.963 × 0.99 = 1.001). 3.8% is exactly break-even, and both are tested. The largest single feed update measured was 1.43%. The trader keeps the residual, so the wider buffer costs them little |
| `MAX_SLIPPAGE_BPS` | 1% | every swap must land within 1% of Chainlink |
| `TWAP_WINDOW` | 30 minutes | pool agreement window; also the recency that lets a fresh print drive a knock-out |
| `MAX_POOL_DEVIATION_BPS` | 1.5% | pool agreement band |
| `MAX_FEED_AGE` | 12h | see the table above |
| `DEAD_FEED_AFTER` | 7 days | emergency unwind threshold; more than 2× the longest normal freeze measured (78h) |
| `FINANCING_APR` | 10% | paid to LPs; the barrier ratchets up over time |
| `OPEN_FEE_BPS` | 0.10% of `margin × L` | paid to LPs |
| `MIN_MARGIN` | 1 USDG | no dust positions |

There is no owner, no pause and no upgradeability. The only privileged call is a one-shot `setMarket` from the deployer, used once at deployment. The deploy script seeds the vault in the same run, so nobody can be the first depositor in between.

## Invariants (written first, in `test/invariant/`)

1. **Backing:** the market's NVDA balance equals `Σ q_i` over open positions. Every position is hedged.
2. **No stranded USDG:** the market holds exactly the knock-out residuals owed to traders.
3. **Conservation:** vault USDG = deposits − withdrawals − principal lent + repayments + fees.
4. **Cap:** no deposit ever leaves `totalAssets > VAULT_CAP`.
5. **Open interest:** `Σ notional_open ≤ MAX_OPEN_NOTIONAL` and `principalOutstanding ≤ MAX_UTILIZATION × totalAssets` at every open.
6. **NAV never overstated:** loans are never valued above their collateral at the lower of the feed and the pool's 30-minute average, less 1%. This is recomputed independently. Whenever LP flows are open, NAV is also close to what the collateral would fetch at the pool's spot price.
7. **Bad debt needs a gap:** if no price gap larger than the cushion ever happened, `badDebt == 0`.
8. **Unsafe means shut:** no `open`, `deposit` or `withdraw` succeeds on a stale feed, or while the pool's 30-minute average is clearly outside the band. No `knockOut` succeeds on a stale feed, or on an older print the pool disagrees with. The handler judges this with its own geometric average, built from the mock pool's binary-search tick inverse, not with the market's conversion.
9. **Exact payouts:** every close or knock-out pays exactly proceeds − repayment, and a voluntary close always repays in full.

The handler simulates in-session moves, sell-offs, in-session gaps, and weekends. In a simulated weekend the feed freezes while the pool drifts, including the Friday-evening window when the feed is frozen but still under 12 hours old.

## Known limitations (stated, not hidden)

- **NVDA only, long only.** Shorts are v2 because they need NVDA inventory in the vault.
- **Corporate actions:** the token's UI multiplier is 1.000775 today, a 0.08% difference from raw units, inside the 1% execution guard. A fork test confirms the feed quotes the price of one raw token. A split during an open position is not handled; corporate-action handling is out of scope for this entry.
- **No sequencer-uptime feed** is checked. None is known on Robinhood Chain.
- **Knock-outs need a caller.** There is no keeper reward in v1. No keeper is running today: there are no open positions, so it would only spend gas, and we will not leave a wallet with real funds sending transactions unattended. Anyone can run `script/knockout-watcher.sh`.
- **The 1.5% band and 30-minute window** are calibrated on one week of data, including one calm weekend. A weekend with a large pool move has not been observed in the sample. The unit and invariant tests model one.
