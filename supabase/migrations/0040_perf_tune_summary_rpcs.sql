-- Every real-data table in the app (Overview/Analytics via dds_metrics,
-- Alert Logs via dds_alert_logs, Driver & Asset Monitoring via
-- dds_driver_event_summary/dds_asset_event_summary/dds_driver_asset_weekly)
-- felt slow to load. Measured live with EXPLAIN ANALYZE against the real
-- 98k-row events table (session role set to authenticated to pass each
-- function's own auth.uid() guard, then rolled back — read-only):
--
--   dds_metrics                 2829 ms  (temp read=38468 written=3971 blocks)
--   dds_alert_logs                346 ms  (temp read=1132  written=1132 blocks)
--   dds_driver_event_summary      520 ms  (temp read=1458  written=729  blocks)
--   dds_asset_event_summary      6090 ms  (temp read=241816 written=1068 blocks)
--   dds_driver_asset_weekly      6170 ms  (temp read=241816 written=1068 blocks)
--
-- The Driver & Asset Monitoring page fires the last three concurrently on
-- every nav, so that page alone was ~7.5s of combined query time before any
-- network/render overhead.
--
-- Root cause #1 (dominant): this project's work_mem is 2184kB (the default
-- for its compute tier). Every one of these functions does multi-column
-- GROUP BY / jsonb_agg over the full events set, which needs far more than
-- 2MB of working memory — so Postgres spills the hash/sort to disk (the
-- "temp read/written" blocks above), and disk-backed aggregation is what
-- actually burns the seconds. Re-running the same EXPLAIN ANALYZE with
-- work_mem bumped to 64MB in-session (SET LOCAL, rolled back, never a
-- persistent change) confirmed it:
--
--   dds_metrics                2829 -> 1828 ms  (temp spill gone)
--   dds_driver_event_summary    520 ->  494 ms  (temp spill gone, see #2)
--   dds_asset_event_summary    6090 ->  245 ms  (temp spill gone) — 24x
--   dds_driver_asset_weekly    6170 ->  487 ms  (temp spill gone) — 12x
--
-- Fixing this durably (not just for this session) means giving these
-- specific functions more working memory whenever THEY run, without
-- touching the instance-wide work_mem default that every connection and
-- every other query would inherit — raising that globally on a small
-- compute tier risks concurrent queries collectively exhausting RAM.
-- ALTER FUNCTION ... SET work_mem scopes the override to just these four
-- read-heavy reporting functions; every other query on the project keeps
-- the conservative 2184kB default.
alter function public.dds_metrics(date, date, text, text[], text[], boolean) set work_mem = '64MB';
alter function public.dds_alert_logs(date, date, text, text, text, integer, integer, text, text) set work_mem = '32MB';
alter function public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text) set work_mem = '64MB';
alter function public.dds_asset_event_summary(text, text, text, integer, integer, date, date, text) set work_mem = '64MB';
alter function public.dds_driver_asset_weekly(date, date) set work_mem = '64MB';

-- Root cause #2 (dds_driver_event_summary specifically, the one function
-- above whose time barely moved with more work_mem: 520 -> 494ms): its
-- status_agg CTE ran a correlated NOT EXISTS subquery once per distinct
-- emp_no (~2400 of them with no filter), each one re-scanning the entire
-- `base` CTE and re-joining alert_cases from scratch — an O(n_drivers *
-- n_events) access pattern in disguise as a "simple" correlated subquery.
-- Rewritten below as a single GROUP BY pass: bool_or() over a per-row
-- "is this an unresolved high-severity event" flag gives the exact same
-- done/not-done semantics (a driver is "done" iff zero of their sleep/
-- drowsiness events lack a logged status) in one aggregation instead of
-- one query per driver.
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
      coalesce(e.emp_no, 'UNSPECIFIED') as emp_no,
      coalesce(d.full_name, case when e.emp_no is null then 'Unspecified' else e.emp_no end) as emp_name,
      e.event_code,
      e.event_count,
      (
        (e.event_code ilike '%sleep%' or e.event_code ilike '%drowsi%')
        and c.status_value is null
      ) as is_unresolved_high_severity
    from public.events e
    left join public.drivers d on d.emp_no = e.emp_no
    left join public.alert_cases c on c.event_id = e.id
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

grant execute on function public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text) to authenticated;
