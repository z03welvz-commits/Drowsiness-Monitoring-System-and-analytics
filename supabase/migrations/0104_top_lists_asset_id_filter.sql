-- Analytics' Asset ID filter dropdown only ever reached dds_metrics()
-- (KPIs/charts/donut/recent alerts) — Top Assets by Alerts and Top
-- Employees by Alerts (dds_asset_event_summary()/dds_driver_event_summary())
-- had no per-asset filter parameter at all, a gap this page's own
-- renderActiveFilterChip() comment already documented as a known,
-- structural limitation. Per direct instruction ("ensure all in this page
-- are affected by the filters"), closes it: both RPCs are already built
-- from public.dds_case_records, which carries asset_id, so this is a
-- purely additive p_asset_id parameter plus one filter clause on each.
--
-- CREATE OR REPLACE only replaces a function whose argument list matches
-- exactly — adding a new parameter makes Postgres treat this as a distinct
-- overload rather than a replacement, silently leaving the old 8-arg
-- version in place alongside the new 9-arg one (confirmed live: both
-- existed after the first apply of this migration). The old overload is
-- dropped explicitly first so exactly one version of each function exists.
drop function if exists public.dds_asset_event_summary(text, text, text, integer, integer, date, date, text);
drop function if exists public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text);

create or replace function public.dds_asset_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null
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
  p_asset_id text default null
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
