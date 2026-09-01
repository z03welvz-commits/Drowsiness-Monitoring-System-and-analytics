-- Driver & Asset Monitoring table redesign: per-driver / per-asset event
-- summary, sourced directly from events (grouped by emp_no / asset_id),
-- instead of the day-of-week weekly risk model — per user decision, the
-- primary goal is "drivers with their total count per event code, sortable
-- and filterable", not the consecutive-day risk pattern (that stays
-- available as dds_driver_asset_weekly for Summary page, untouched, and
-- may resurface later as a secondary/optional signal).
--
-- Search/sort/pagination conventions mirror dds_alert_logs (0016) so the
-- client's fetch plumbing stays consistent across pages.

create or replace function public.dds_driver_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0
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
  -- "Done" only once every critical/high-severity instance for this
  -- driver has a logged alert_cases action — mirrors
  -- dds_driver_alert_instances' allHighSeverityActioned so the table's
  -- Status column and the popup's own summary never disagree.
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

grant execute on function public.dds_driver_event_summary(text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- dds_asset_event_summary: same shape for the Assets tab (Asset No /
-- Event Code / Event Counts / Avg Sync Time). No status/done column —
-- the Assets tab has no bulk-edit, it's read-only history (per product
-- decision), so there's nothing to mark done/pending.
-- ---------------------------------------------------------------------
create or replace function public.dds_asset_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0
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

  with per_asset_code as (
    select asset_id, event_code, sum(event_count) as code_count
    from public.events
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
    from public.events
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

grant execute on function public.dds_asset_event_summary(text, text, text, integer, integer) to authenticated;
