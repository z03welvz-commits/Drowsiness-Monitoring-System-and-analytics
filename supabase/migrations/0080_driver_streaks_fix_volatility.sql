-- ============================================================================
-- DDS — 0080_driver_streaks_fix_volatility
-- ----------------------------------------------------------------------------
-- dds_driver_streaks() (0078) was declared STABLE, but its body uses
-- CREATE TEMPORARY TABLE ... AS, which Postgres only permits in a VOLATILE
-- function ("CREATE TABLE AS is not allowed in a non-volatile function") —
-- confirmed live: every call failed with exactly this error. This matches
-- the pattern used elsewhere in this schema (dds_reresolve_all/dds_
-- minestat_reresolve_all also use a temp table and are correctly left at
-- the default VOLATILE, i.e. no STABLE/IMMUTABLE marker at all) — STABLE
-- was copied onto this one by mistake, since dds_resolve_name (a pure
-- read, no temp table) legitimately is STABLE. No other change: same
-- signature, same logic, same thresholds.
-- ============================================================================

create or replace function public.dds_driver_streaks(
  p_search     text default null,
  p_min_streak integer default 1,
  p_sort       text default 'streak_days',
  p_dir        text default 'desc',
  p_limit      integer default 50,
  p_offset     integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_sort   text := case when p_sort in ('streak_days','total_count','emp_no','name','run_end')
                        then p_sort else 'streak_days' end;
  v_dir    text := case when lower(coalesce(p_dir,'desc')) = 'asc' then 'asc' else 'desc' end;
  v_result jsonb;
  v_total  integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _driver_streak_rows on commit drop as
  with daily as (
    select emp_no, shift_date, sum(event_count) as day_total
    from public.events
    where emp_no is not null
    group by emp_no, shift_date
  ),
  qualifying as (
    select emp_no, shift_date,
           shift_date - (row_number() over (partition by emp_no order by shift_date))::int as grp
    from daily
    where day_total > 10
  ),
  runs as (
    select emp_no, min(shift_date) as run_start, max(shift_date) as run_end, count(*) as run_len
    from qualifying
    group by emp_no, grp
  ),
  latest_run as (
    select distinct on (emp_no) emp_no, run_start, run_end, run_len
    from runs
    order by emp_no, run_end desc
  ),
  totals as (
    select emp_no, sum(event_count) as total_count
    from public.events
    where emp_no is not null
    group by emp_no
  ),
  last_actions as (
    select distinct on (entity_id)
      entity_id, action_type, note, logged_by, created_at
    from public.entity_action_log
    where entity_type = 'driver'
    order by entity_id, created_at desc
  )
  select
    lr.emp_no,
    coalesce(d.full_name, lr.emp_no) as name,
    lr.run_start, lr.run_end, lr.run_len as streak_days,
    coalesce(t.total_count, 0) as total_count,
    coalesce(es.status, 'ok') as status,
    es.monitor_until,
    la.action_type as last_action_type,
    la.note as last_action_note,
    la.logged_by as last_action_by,
    la.created_at as last_action_at
  from latest_run lr
  left join public.drivers d on d.emp_no = lr.emp_no
  left join totals t on t.emp_no = lr.emp_no
  left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = lr.emp_no
  left join last_actions la on la.entity_id = lr.emp_no
  where lr.run_len >= greatest(coalesce(p_min_streak, 1), 1)
    and (
      p_search is null or p_search = ''
      or lr.emp_no ilike '%' || p_search || '%'
      or coalesce(d.full_name, '') ilike '%' || p_search || '%'
    );

  select count(*) into v_total from _driver_streak_rows;

  execute format(
    'select jsonb_agg(jsonb_build_object(
       ''empNo'', emp_no, ''name'', name,
       ''streakDays'', streak_days,
       ''runStart'', to_char(run_start, ''MM/DD/YYYY''),
       ''runEnd'', to_char(run_end, ''MM/DD/YYYY''),
       ''totalCount'', total_count,
       ''status'', status,
       ''monitorUntil'', to_char(monitor_until, ''YYYY-MM-DD''),
       ''lastAction'', case when last_action_type is null then null else jsonb_build_object(
         ''type'', last_action_type, ''note'', last_action_note, ''by'', last_action_by,
         ''at'', to_char(last_action_at at time zone ''utc'', ''YYYY-MM-DD"T"HH24:MI:SS.MS"Z'')
       ) end
     ))
     from (select * from _driver_streak_rows order by %I %s limit %s offset %s) s',
    v_sort, v_dir, v_limit, v_offset
  ) into v_result;

  return jsonb_build_object(
    'rows', coalesce(v_result, '[]'::jsonb),
    'total', v_total
  );
end;
$function$;
