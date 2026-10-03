-- TORQUE · every stretch when check 1 (fresh price) would have paused opens: Chainlink silent for over 12 hours.
-- A pause starts 12 h after a print and ends at the next print. Same feed aggregator as 04.
with prints as (
  select from_unixtime(cast(bytearray_to_uint256(data) as double)) as updated_at
  from robinhood.logs
  where contract_address = 0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2
    and topic0 = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f
),
gaps as (
  select lag(updated_at) over (order by updated_at) as prev_print, updated_at as next_print from prints
  union all
  select max(updated_at), null from prints   -- the current gap, if the feed is quiet right now
)
select
  prev_print + interval '12' hour as paused_from,
  next_print as paused_until,
  date_diff('minute', prev_print + interval '12' hour, coalesce(next_print, now())) / 60.0 as hours_paused,
  date_diff('minute', prev_print, coalesce(next_print, now())) / 60.0 as feed_silent_hours,
  format_datetime(prev_print, 'EEEE HH:mm') || ' UTC' as last_print_before,
  case when next_print is null then 'ongoing' else 'ended' end as state
from gaps
where prev_print is not null
  and date_diff('minute', prev_print, coalesce(next_print, now())) > 12 * 60
order by paused_from desc
