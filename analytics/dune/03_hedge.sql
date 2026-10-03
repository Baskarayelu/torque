-- TORQUE · hedge against notional: NVDA the market holds vs NVDA its positions are owed
-- Held = running sum of NVDA token transfers into / out of TorqueMarket.
-- Owed = q of open positions (Opened adds q; the position's close / knock-out / unwind removes it).
-- Solvency needs held >= owed at every step; the last column says whether it held.
with nvda_moves as (
  select block_time, block_number, tx_index,
    case when bytearray_substring(topic2, 13, 20) = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096 then 1 else -1 end
      * bytearray_to_uint256(data) / 1e18 as d_held,
    0e0 as d_owed
  from robinhood.logs
  where contract_address = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
    and topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
    and block_number >= 78466999
    and (bytearray_substring(topic1, 13, 20) = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096
      or bytearray_substring(topic2, 13, 20) = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096)
),
market_logs as (
  select * from robinhood.logs
  where contract_address = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096 and block_number >= 78466999
),
opened as (
  select bytearray_to_uint256(topic1) as id, bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e18 as q
  from market_logs where topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930
),
owed_moves as (
  select l.block_time, l.block_number, l.tx_index, 0e0 as d_held,
    case when l.topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930 then o.q else -o.q end as d_owed
  from market_logs l join opened o on o.id = bytearray_to_uint256(l.topic1)
  where l.topic0 in (0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930, 0xf24c64885f2398a320c41d4eb1531c9b2440ba4e78edfc733536609a4a2a1b1b,
                     0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1, 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9)
),
per_tx as (
  -- solvency is judged at the end of each transaction: inside one, a swap can move tokens before the event that books it
  select min(block_time) as block_time, block_number, tx_index, sum(d_held) as d_held, sum(d_owed) as d_owed
  from (select * from nvda_moves union all select * from owed_moves)
  group by block_number, tx_index
),
series as (
  select block_time, block_number, tx_index,
    sum(d_held) over (order by block_number, tx_index) as nvda_held,
    sum(d_owed) over (order by block_number, tx_index) as nvda_owed
  from per_tx
)
select block_time, nvda_held, nvda_owed, nvda_held - nvda_owed as surplus,
  case when nvda_held + 1e-12 >= nvda_owed then 'hedged 1:1' else 'SHORT' end as hedge
from series
order by block_number, tx_index
