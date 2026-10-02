# Adversarial pass (before mainnet)

The goal: drain the vault or get a free position. Each attack is a test that plays the attacker: `test/adversarial/Attacks.t.sol`, plus `test_fork_sandwichOpenIsUnprofitable` against the real Robinhood Chain pool. Each test asserts that the attack fails or that its gain is bounded.

## What broke, and was fixed before deployment

**A dead or permanently stale feed could lock LP money.**
- LP withdrawals required both price checks to pass.
- If the Chainlink NVDA feed stops updating (deprecation, delisting) or starts reverting, withdrawals were refused for good, even with every position closed and all USDG idle.
- A reverting feed also made `totalAssets()` revert, which bricked the vault.
- A position its owner abandoned could never be knocked out without a feed, so its loan was stuck too.

Fixes:
1. **No revert on a broken feed.** The feed is read with `try/catch`; a reverting or non-positive feed reads as "no price" (not fresh).
2. **LPs can always leave when no loans are open.** With no open positions, NAV is exactly idle cash, so withdrawals need no price check. While loans are open, both checks still apply.
3. **Emergency `unwind(id)` once the feed is dead.** It applies after `DEAD_FEED_AFTER = 7 days` without a usable print (the longest normal freeze measured is 78h). Anyone may unwind a position at the pool's 30-minute average less 1%. The vault is repaid first, the trader can claim the residual, and any shortfall is bad debt.
4. **A dead-feed clock for a reverting feed, which has no `updatedAt`.** `reportFeedDown()` starts the clock and any healthy read clears it, so a momentary glitch cannot open the unwind.

Tests:
- `test_attack_deadFeedCannotLockIdleLpFunds`
- `test_attack_staleFeedWithOpenPositionUnwindsAfterSevenDays`
- `test_attack_revertingFeedNeedsSevenDaysFromReport`
- `test_attack_staleDownReportClearedByActivity`
- `test_attack_unwindIntoCrashedSpotReverts`

**Residual:** if the feed glitched once, nobody touched the market afterwards, and much later it glitched again, the stale clock would let anyone unwind at the pool average less 1%. The worst case is a forced exit. The vault is repaid first and nothing can be stolen.

## What held

| Attack | Result |
|---|---|
| **Reentrancy on every external call.** The whole system runs on a USDG that calls back into sender and recipient on every transfer (ERC-777-style; real USDG and NVDA have no hooks). During `close`, the attacker re-enters `open`, `close`, `knockOut`, `claim`, then deposits into and redeems from the vault | All market re-entries revert (`nonReentrant`). The only point the attacker gets control is after the vault is repaid, so the vault round trip is priced fairly and can't profit. Knock-outs credit residuals instead of pushing them, so no callback ever happens mid-state. The swap callback only pays the real pool, and only during our own swap. **Check:** removing the guards from `open` and `close` makes the test fail (2 re-entries succeed) |
| **First-depositor inflation:** deposit 1 wei, donate 9 USDG, wait for a victim | Victim loses at most dust. The attacker can't redeem more than they put in; about half the donation stays behind because of the 6 virtual share decimals |
| **Donating up to the cap to block deposits** | Denial of service only: nothing is stolen, and the attacker leaves about half the donation behind. The deploy script now seeds the vault in the same run, so there is no window to be first |
| **Share rounding farm:** up to 40 deposit-and-redeem round trips, fuzzed | Never ends up with more USDG than it started with |
| **`mint()` rounding past the $20 cap** | Refused. The cap is checked in `maxDeposit` and again in `_deposit` |
| **Direct transfers of USDG or NVDA to the market** | Ignored by loan marks and NAV. Nobody can claim them, and a trader still receives only their own proceeds |
| **Donating USDG to the vault** | Accrues to existing LPs. It adds lending capacity, but open interest is still hard-capped |
| **Knock-out by crashing the pool's spot price** | `NotKnockable`: the trigger is Chainlink, not the pool |
| **Crashing spot under a legitimate knock-out to buy the forced sale cheap** | `Slippage`: the sale must fill within 1% of Chainlink, so it reverts instead of dumping |
| **Holding the pool's 30-minute average off the feed to block a knock-out** | Only delays it while the feed print is over 30 minutes old. The next Chainlink print lets it through. Moving a 30-minute average on a ~$3.5M pool costs far more than a $10 position is worth |
| **Sandwiching the hedge swap (mock pool)** | The trader's fill is at worst 1% off Chainlink, and front-runs beyond that revert. The vault's loan stays secured |
| **Sandwiching the hedge swap (real pool, fork)** | Front-running $1k, $10k or $100k before a victim's open loses the attacker about $1, $10 or $100 (roughly the pool fees). The victim's fill stays within 0.53% of Chainlink. Robinhood Chain also has no public mempool: the sequencer orders transactions first come, first served |
| **Opening into a crashed spot, then closing after it recovers** | The gain comes from the attacker's own dump, not the vault. The vault is repaid in full plus the fee |
| **Closing your own position into a crashed spot** | `Underwater`: a close that would short the vault reverts |
| **LP running ahead of a known loss in the same block:** a fresh print shows a gap, then withdraw before the knock-out | The exit is refused while the pool average lags. Once it agrees, NAV already carries the loss |
| **LP and trader as one account, all in one block** (deposit, open, close, withdraw) | Cannot come out ahead: the open fee is a cost |
| **Free position:** fuzzed margin and leverage, then immediate close | Borrow is always below notional, NVDA bought is always above 0, and an immediate round trip always costs the fee |
| **Double claim; closing someone else's position; calling the swap callback; `lend`; `setMarket`** | All refused |

## Residual risks, accepted and stated

- **Upstream trust:** Paxos can freeze an address and Robinhood can pause the NVDA token. Either would freeze the affected flows. These are trust assumptions on the token issuers.
- **Capacity griefing:** someone can fill the $30 open-interest cap with small positions and pay 10% APR to hold them. That denies service to other traders but steals nothing.
- **Exit lag after a weekend crash:** in the first minutes after the pool moves on a frozen feed, before the 30-minute average leaves the band, an LP can still withdraw at a mark that hasn't caught up. Exposure is bounded by idle cash and the cap. Adding spot price to the mark would open a flash-manipulation path for depositors, which is worse.
