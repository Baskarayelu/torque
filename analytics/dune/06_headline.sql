-- TORQUE · headline counters (one row)
with market_logs as (
  select * from robinhood.logs
  where contract_address = 0xbee6Da89F879B018Fea5d7A78311db720B9D8096 and block_number >= 78466999
)
select
  count_if(topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930) as positions_opened,
  count_if(topic0 = 0xf24c64885f2398a320c41d4eb1531c9b2440ba4e78edfc733536609a4a2a1b1b) as closed_by_owner,
  count_if(topic0 = 0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1) as knocked_out,
  count_if(topic0 = 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9) as unwound,
  coalesce(sum(case when topic0 in (0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1, 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9)
                    then bytearray_to_uint256(bytearray_substring(data, 129, 32)) / 1e6 end), 0) as bad_debt_usdg,
  coalesce(sum(case when topic0 = 0xf24c64885f2398a320c41d4eb1531c9b2440ba4e78edfc733536609a4a2a1b1b then bytearray_to_uint256(bytearray_substring(data, 33, 32)) / 1e6
                    when topic0 in (0x32928610ae4515b0845a78e226611bdaf52691367778e07f9d9f3faa121364a1, 0x28a10c6c577211762ca47232c292427a90d47b81ce8b28f2992df04231252af9) then bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e6 end), 0) as repaid_to_vault_usdg,
  sum(case when topic0 = 0x8c26c1650c61db2f5fa79b29d0d3bb5a4653167cb86ea9c8f0b3a369598da930 then bytearray_to_uint256(bytearray_substring(data, 97, 32)) / 1e6 end) as lent_total_usdg
from market_logs
