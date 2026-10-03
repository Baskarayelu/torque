-- TORQUE · every position, opened and closed (Robinhood Chain mainnet)
-- Raw logs of TorqueMarket, decoded by event signature, so no Dune decoding submission is needed.
--   Opened(uint256 indexed id, address indexed owner, uint256 margin, uint256 leverageBps, uint256 q, uint256 principal)
--   Closed(uint256 indexed id, uint256 proceeds, uint256 repaid, uint256 payout)
--   KnockedOut(uint256 indexed id, uint256 price, uint256 proceeds, uint256 repaid, uint256 payout, uint256 badDebt)
--   Unwound(uint256 indexed id, uint256 price, uint256 proceeds, uint256 repaid, uint256 payout, uint256 badDebt)
-- USDG has 6 decimals, NVDA 18; leverage is in basis points of 1x.
with market_logs as (
  select * from robinhood.logs
  where contract_address = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096
    and block_number >= 78466999
),
opened as (
  select
    bytearray_to_uint256(topic1) as id,
    bytearray_substring(topic2, 13, 20) as owner,
    block_time as opened_at,
    tx_hash as open_tx,
    bytearray_to_uint256(bytearray_substring(data, 1, 32)) / 1e6 as margin_usdg,
    bytearray_to_uint256(bytearray_substring(data, 33, 32)) / 1e4 as leverage,
    bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e18 as nvda,
    bytearray_to_uint256(bytearray_substring(data, 97, 32)) / 1e6 as borrowed_usdg
  from market_logs
  where topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930
),
ended as (
  select bytearray_to_uint256(topic1) as id, block_time as ended_at, tx_hash as end_tx, 'closed by owner' as how,
    bytearray_to_uint256(bytearray_substring(data, 1, 32)) / 1e6 as proceeds_usdg,
    bytearray_to_uint256(bytearray_substring(data, 33, 32)) / 1e6 as vault_repaid_usdg,
    bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e6 as trader_payout_usdg,
    0e0 as bad_debt_usdg
  from market_logs where topic0 = 0xf24c64885f2398a320c41d4eb1531c9b2440ba4e78edfc733536609a4a2a1b1b
  union all
  select bytearray_to_uint256(topic1), block_time, tx_hash,
    case when topic0 = 0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1 then 'knocked out' else 'unwound (dead feed)' end,
    bytearray_to_uint256(bytearray_substring(data, 33, 32)) / 1e6,
    bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e6,
    bytearray_to_uint256(bytearray_substring(data, 97, 32)) / 1e6,
    bytearray_to_uint256(bytearray_substring(data, 129, 32)) / 1e6
  from market_logs where topic0 in (0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1, 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9)
)
select
  o.id as position,
  o.owner,
  o.opened_at,
  o.margin_usdg,
  o.leverage,
  o.nvda,
  o.borrowed_usdg,
  coalesce(e.how, 'open') as status,
  e.ended_at,
  date_diff('minute', o.opened_at, coalesce(e.ended_at, now())) as minutes_held,
  e.proceeds_usdg,
  e.vault_repaid_usdg,
  e.vault_repaid_usdg - o.borrowed_usdg as vault_interest_usdg,
  e.trader_payout_usdg,
  e.trader_payout_usdg - o.margin_usdg as trader_pnl_usdg,
  e.bad_debt_usdg,
  o.open_tx,
  e.end_tx
from opened o left join ended e on e.id = o.id
order by o.id
