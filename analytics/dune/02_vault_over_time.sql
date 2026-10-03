-- TORQUE · LP vault over time: idle cash, lent, utilisation (Robinhood Chain mainnet)
-- Idle cash = USDG held by TorqueVault (running sum of its USDG transfers).
-- Lent = principal of open positions (Opened adds it; Closed / KnockedOut / Unwound remove it).
-- totalAssets on chain also accrues interest on open loans; this series shows principal, so it can sit a few cents below.
with usdg_moves as (
  select block_time, block_number, tx_index,
    case when bytearray_substring(topic2, 13, 20) = 0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf then 1 else -1 end
      * bytearray_to_uint256(data) / 1e6 as d_idle,
    0e0 as d_lent
  from robinhood.logs
  where contract_address = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
    and topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
    and block_number >= 78466999
    and (bytearray_substring(topic1, 13, 20) = 0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf
      or bytearray_substring(topic2, 13, 20) = 0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf)
),
market_logs as (
  select * from robinhood.logs
  where contract_address = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096 and block_number >= 78466999
),
opened as (
  select bytearray_to_uint256(topic1) as id, bytearray_to_uint256(bytearray_substring(data, 97, 32)) / 1e6 as principal
  from market_logs where topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930
),
lent_moves as (
  select l.block_time, l.block_number, l.tx_index, 0e0 as d_idle,
    case when l.topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930 then o.principal else -o.principal end as d_lent
  from market_logs l join opened o on o.id = bytearray_to_uint256(l.topic1)
  where l.topic0 in (0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930, 0xf24c64885f2398a320c41d4eb1531c9b2440ba4e78edfc733536609a4a2a1b1b,
                     0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1, 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9)
),
per_tx as (
  -- solvency is judged at the end of each transaction: inside one, a swap can move tokens before the event that books it
  select min(block_time) as block_time, block_number, tx_index, sum(d_idle) as d_idle, sum(d_lent) as d_lent
  from (select * from usdg_moves union all select * from lent_moves)
  group by block_number, tx_index
),
series as (
  select block_time, block_number, tx_index,
    sum(d_idle) over (order by block_number, tx_index) as idle_usdg,
    sum(d_lent) over (order by block_number, tx_index) as lent_usdg
  from per_tx
)
select block_time, idle_usdg, lent_usdg, idle_usdg + lent_usdg as assets_usdg, 20 as cap_usdg,
  case when idle_usdg + lent_usdg > 0 then lent_usdg / (idle_usdg + lent_usdg) else 0 end as utilisation,
  0.8 as utilisation_cap
from series
order by block_number, tx_index
