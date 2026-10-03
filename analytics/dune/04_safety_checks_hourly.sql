-- TORQUE · the two safety checks, hour by hour, since Robinhood Chain mainnet (or the last 90 days)
-- Check 1 · fresh price: Chainlink RHNVDA/USD printed within the last 12 hours.
--   Prints = AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt) on the feed's
--   aggregator 0xC9d1…C2a2 (behind proxy 0x379E…9F15), 8 decimals.
-- Check 2 · market agrees: the NVDA/USDG Uniswap v3 pool within 1.5% of Chainlink. On chain TORQUE uses the pool's
--   30-minute TWAP; here each hour takes the last swap's tick in that hour, carried forward, so treat it as a close
--   approximation of the on-chain check. Pool price (USDG per NVDA) = 1e12 / 1.0001^tick (USDG is token0, 6 dp; NVDA 18 dp).
with hours as (
  select h from unnest(sequence(
    date_trunc('hour', greatest(now() - interval '90' day, timestamp '2026-07-01 00:00')),
    date_trunc('hour', now()), interval '1' hour)) as t(h)
),
prints as (
  select block_time, bytearray_to_int256(topic1) / 1e8 as feed_price,
    from_unixtime(cast(bytearray_to_uint256(data) as double)) as updated_at
  from robinhood.logs
  where contract_address = 0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2
    and topic0 = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f
),
swaps as (
  select block_time, 1e12 / power(1.0001, cast(bytearray_to_int256(bytearray_substring(data, 129, 32)) as double)) as pool_price
  from robinhood.logs
  where contract_address = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3
    and topic0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67
),
feed_h as (select date_trunc('hour', block_time) as h, max_by(feed_price, block_time) as feed_price, max(updated_at) as updated_at, count(*) as prints from prints group by 1),
pool_h as (select date_trunc('hour', block_time) as h, max_by(pool_price, block_time) as pool_price, count(*) as swaps from swaps group by 1),
grid as (
  select hours.h,
    last_value(f.feed_price) ignore nulls over (order by hours.h rows between unbounded preceding and current row) as feed_price,
    last_value(f.updated_at) ignore nulls over (order by hours.h rows between unbounded preceding and current row) as last_print,
    coalesce(f.prints, 0) as prints,
    last_value(p.pool_price) ignore nulls over (order by hours.h rows between unbounded preceding and current row) as pool_price,
    coalesce(p.swaps, 0) as swaps
  from hours left join feed_h f on f.h = hours.h left join pool_h p on p.h = hours.h
)
select h as hour, feed_price, pool_price, prints, swaps,
  date_diff('minute', last_print, h + interval '1' hour) / 60.0 as feed_age_hours,
  abs(pool_price - feed_price) / feed_price * 1e4 as deviation_bps,
  150 as band_bps,
  date_diff('minute', last_print, h + interval '1' hour) <= 12 * 60 as fresh,
  abs(pool_price - feed_price) / feed_price * 1e4 <= 150 as pool_agrees,
  case
    when last_print is null or pool_price is null then 'no data'
    when date_diff('minute', last_print, h + interval '1' hour) > 12 * 60 then 'paused: feed quiet (over 12 h)'
    when abs(pool_price - feed_price) / feed_price * 1e4 > 150 then 'paused: pool off by over 1.5%'
    else 'open'
  end as torque_state,
  case when date_diff('minute', last_print, h + interval '1' hour) > 12 * 60 or abs(pool_price - feed_price) / feed_price * 1e4 > 150 then 0 else 1 end as open_flag
from grid
order by h
