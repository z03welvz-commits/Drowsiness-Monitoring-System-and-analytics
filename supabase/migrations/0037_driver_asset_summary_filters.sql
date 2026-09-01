-- Driver & Asset Monitoring: add real date-range/shift filters to the
-- event-summary RPCs, matching Alert Logs' filter row (From date/To
-- date/Shift), styled and wired the same way per user decision. Unlike
-- Alert Logs (one row per event), this table aggregates per driver/asset,
-- so p_from/p_to/p_shift narrow which underlying events count toward each
-- row's totals/event-code breakdown/status — not which rows appear.
--
-- New params appended after the existing ones would normally leave the
-- old 5-arg signature as a second overload (CREATE OR REPLACE only
-- replaces an exact parameter-list match) — dropped explicitly so
-- PostgREST has one unambiguous dds_driver_event_summary/
-- dds_asset_event_summary to route RPC calls to.
drop function if exists public.dds_driver_event_summary(text, text, text, integer, integer);
drop function if exists public.dds_asset_event_summary(text, text, text, integer, integer);

create or replace function public.dds_driver_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select
      coalesce(e.emp_no, 'UNSPECIFIED') as emp_no,
      coalesce(d.full_name, case when e.emp_no is null then 'Unspecified' else e.emp_no end) as emp_name,
      e.event_code,
      e.event_count,
      e.id as event_id
    from public.events e
    left join public.drivers d on d.emp_no = e.emp_no
    where (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or e.shift = p_shift)
  ),
  per_driver_code as (
    select emp_no, emp_name, event_code, sum(event_count) as code_count
    from base
    group by emp_no, emp_name, event_code
  ),
  codes_agg as (
    select emp_no, emp_name,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_driver_code
    group by emp_no, emp_name
  ),
  status_agg as (
    select b.emp_no,
      not exists (
        select 1 from base b2
        left join public.alert_cases c on c.event_id = b2.event_id
        where b2.emp_no = b.emp_no
          and (b2.event_code ilike '%sleep%' or b2.event_code ilike '%drowsi%')
          and c.status_value is null
      ) as done
    from (select distinct emp_no from base) b
  ),
  filtered as (
    select ca.emp_no, ca.emp_name, ca.codes, ca.total, coalesce(sa.done, true) as done
    from codes_agg ca
    left join status_agg sa on sa.emp_no = ca.emp_no
    where p_search is null or p_search = ''
       or ca.emp_name ilike '%' || p_search || '%'
       or ca.emp_no ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      emp_no
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empNo', emp_no, 'empName', emp_name, 'eventCodes', codes,
        'total', total, 'done', done
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text) to authenticated;

create or replace function public.dds_asset_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select asset_id, event_code, event_count, sync_seconds
    from public.events
    where (p_from is null or shift_date >= p_from)
      and (p_to   is null or shift_date <= p_to)
      and (p_shift is null or p_shift = '' or shift = p_shift)
  ),
  per_asset_code as (
    select asset_id, event_code, sum(event_count) as code_count
    from base
    group by asset_id, event_code
  ),
  codes_agg as (
    select asset_id,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_asset_code
    group by asset_id
  ),
  sync_agg as (
    select asset_id, avg(sync_seconds)::int as avg_sync_seconds
    from base
    where sync_seconds is not null
    group by asset_id
  ),
  filtered as (
    select ca.asset_id, ca.codes, ca.total, sy.avg_sync_seconds
    from codes_agg ca
    left join sync_agg sy on sy.asset_id = ca.asset_id
    where p_search is null or p_search = '' or ca.asset_id ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else case v_sort when 'asset_id' then asset_id end end asc nulls last,
      case when v_desc then case v_sort when 'asset_id' then asset_id end end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      asset_id
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assetId', asset_id, 'eventCodes', codes, 'total', total, 'avgSyncSeconds', avg_sync_seconds
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.dds_asset_event_summary(text, text, text, integer, integer, date, date, text) to authenticated;
