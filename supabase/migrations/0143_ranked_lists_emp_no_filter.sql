-- ============================================================================
-- DDS — 0143_ranked_lists_emp_no_filter
-- ----------------------------------------------------------------------------
-- Associative cross-filtering gap: selecting an asset already narrows BOTH
-- "Alerts by Unit" and "Alerts by Employee ID / Driver" (dds_asset_event_
-- summary()/dds_driver_event_summary() both already take p_asset_id, added
-- in 0104). Selecting an employee only ever reached dds_metrics() (p_emp_no,
-- added in 0142) — neither ranked-list RPC has an employee parameter at
-- all, so clicking a driver row narrowed the KPIs/trend/hourly/donut/sync
-- charts but left "Alerts by Unit" showing the unfiltered fleet-wide
-- ranking. Confirmed live: this was the one asymmetric cross-filter
-- dimension on the page. Both functions already read dds_case_records,
-- which carries emp_no_norm (already selected/used by
-- dds_driver_event_summary's own base CTE), so this is a same-shape
-- additive predicate, not a new join or aggregation.
--
-- CREATE OR REPLACE only replaces a function whose argument list matches
-- exactly — adding a parameter makes Postgres treat this as a distinct
-- overload rather than a replacement (same trap 0104/0142 already
-- document), so the old 12-arg signatures are dropped explicitly first.
-- ============================================================================
drop function if exists public.dds_asset_event_summary(text, text, text, integer, integer, date, date, text, text, text, integer, integer);
drop function if exists public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text, text, text, integer, integer);

create or replace function public.dds_asset_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null,
  p_event_code text default null,
  p_hour integer default null,
  p_sync_bucket integer default null,
  p_emp_no text default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '64MB'
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
    select r.asset_id, r.event_code, r.event_count, r.sync_seconds
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
      and (p_asset_id is null or r.asset_id = p_asset_id)
      and (p_event_code is null or r.event_code = p_event_code)
      and (p_hour is null or extract(hour from r.start_time)::int = p_hour)
      and (p_emp_no is null or r.emp_no_norm = p_emp_no)
      and (p_sync_bucket is null or (
             case
               when r.sync_seconds is null then null
               when r.sync_seconds < 10800 then 0
               when r.sync_seconds < 21600 then 1
               when r.sync_seconds < 28800 then 2
               when r.sync_seconds < 36000 then 3
               else 4
             end
           ) = p_sync_bucket)
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

create or replace function public.dds_driver_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null,
  p_event_code text default null,
  p_hour integer default null,
  p_sync_bucket integer default null,
  p_emp_no text default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '64MB'
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
      r.emp_no_norm as emp_no,
      coalesce(r.emp_name, case when r.emp_no is null then 'Unspecified' else r.emp_no end) as emp_name,
      r.event_code,
      r.event_count,
      r.is_unresolved_high_severity
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
      and (p_asset_id is null or r.asset_id = p_asset_id)
      and (p_event_code is null or r.event_code = p_event_code)
      and (p_hour is null or extract(hour from r.start_time)::int = p_hour)
      and (p_emp_no is null or r.emp_no_norm = p_emp_no)
      and (p_sync_bucket is null or (
             case
               when r.sync_seconds is null then null
               when r.sync_seconds < 10800 then 0
               when r.sync_seconds < 21600 then 1
               when r.sync_seconds < 28800 then 2
               when r.sync_seconds < 36000 then 3
               else 4
             end
           ) = p_sync_bucket)
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
    select emp_no, not bool_or(is_unresolved_high_severity) as done
    from base
    group by emp_no
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

revoke all on function public.dds_asset_event_summary from public;
grant execute on function public.dds_asset_event_summary to authenticated;
revoke all on function public.dds_driver_event_summary from public;
grant execute on function public.dds_driver_event_summary to authenticated;
