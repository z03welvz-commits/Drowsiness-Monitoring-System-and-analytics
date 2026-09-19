-- ============================================================================
-- DDS — 0151_edit_lock_guard_write_rpcs
-- ----------------------------------------------------------------------------
-- Follow-up to 0149/0150. Every write RPC in the app gains one line —
-- `perform public.dds_require_edit_lock();` — immediately after its
-- existing `if auth.uid() is null then raise exception 'UNAUTHENTICATED'
-- ...; end if;` guard. This is the RPC-layer half of the two-layer
-- enforcement 0149's header explains: 0150 closed the direct-REST-bypass
-- path via RLS; this closes the "through the API, but skip the lock" path,
-- since a SECURITY DEFINER function's own writes run as its owner and are
-- never subject to RLS regardless of what 0150 changed on the underlying
-- tables.
--
-- Every function body below was pulled from this database's CURRENT live
-- definition via pg_get_functiondef() immediately before writing this
-- migration, not copied from any earlier migration file — several of these
-- functions have been redefined multiple times across this project's
-- history (dds_ingest's own lineage across 0001/0015/0019/0032 is the
-- documented example), so reissuing from a stale file would risk silently
-- reverting an unrelated later fix. Nothing else about any of these
-- functions changes — same signature, same logic, same return shape.
-- ============================================================================

create or replace function public.dds_attribution_conflicts_resolve(p_id bigint, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.emp_no_attribution_conflicts%rowtype;
  v_chosen_emp_no text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if p_choice not in ('operator', 'minestat') then
    raise exception 'INVALID_CHOICE';
  end if;

  select * into v_row from public.emp_no_attribution_conflicts where id = p_id;
  if v_row.id is null then
    raise exception 'UNKNOWN_CONFLICT';
  end if;

  v_chosen_emp_no := case when p_choice = 'operator' then v_row.operator_emp_no else v_row.minestat_emp_no end;

  update public.events
     set emp_no = v_chosen_emp_no
   where id = v_row.event_id;

  update public.emp_no_attribution_conflicts
     set state = 'resolved', resolution = p_choice, resolved_by = auth.uid(), resolved_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'eventId', v_row.event_id, 'chosenEmpNo', v_chosen_emp_no);
end;
$function$;

create or replace function public.dds_backfill_emp_no_from_minestat(p_limit integer DEFAULT 2000)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows      integer := 0;
  v_conflicts integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  with candidates as (
    select e.id, s.emp_no
    from public.events e
    join public.minestat_shift_operator_status s
      on s.asset_id   = e.asset_id
     and s.shift_date = e.shift_date
     and s.shift      = e.shift
    where e.emp_no is null
      and not s.is_ambiguous
      and s.emp_no is not null
    limit p_limit
  ),
  upd as (
    update public.events e
       set emp_no = c.emp_no
      from candidates c
     where e.id = c.id
    returning 1
  )
  select count(*) into v_rows from upd;

  insert into public.emp_no_attribution_conflicts (
    event_id, asset_id, shift_date, shift, operator_emp_no, minestat_emp_no
  )
  select e.id, e.asset_id, e.shift_date, e.shift, e.emp_no, s.emp_no
  from public.events e
  join public.minestat_shift_operator_status s
    on s.asset_id   = e.asset_id
   and s.shift_date = e.shift_date
   and s.shift      = e.shift
  where e.emp_no is not null
    and not s.is_ambiguous
    and s.emp_no is not null
    and s.emp_no <> e.emp_no
    and not exists (
      select 1 from public.emp_no_attribution_conflicts c
       where c.event_id = e.id and c.minestat_emp_no = s.emp_no
    )
  limit p_limit
  on conflict (event_id) do update
    set asset_id        = excluded.asset_id,
        shift_date      = excluded.shift_date,
        shift           = excluded.shift,
        operator_emp_no = excluded.operator_emp_no,
        minestat_emp_no = excluded.minestat_emp_no,
        detected_at     = now();
  get diagnostics v_conflicts = row_count;

  select count(*) into v_remaining
  from public.events e
  where e.emp_no is null
    and exists (
      select 1 from public.minestat_shift_operator_status s
       where s.asset_id = e.asset_id and s.shift_date = e.shift_date
         and s.shift = e.shift and not s.is_ambiguous and s.emp_no is not null
    );

  return jsonb_build_object(
    'rowsUpdated', v_rows,
    'rowsRemaining', v_remaining,
    'conflictsDetected', v_conflicts
  );
end;
$function$;

create or replace function public.dds_bulk_log_case_action(p_event_ids bigint[], p_action_type text, p_action_is_other boolean, p_action_date date, p_status_value text, p_remarks text DEFAULT NULL::text, p_status_is_other boolean DEFAULT NULL::boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_updated int;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if p_event_ids is null or array_length(p_event_ids, 1) is null then
    raise exception 'NO_EVENT_IDS' using errcode = '22023';
  end if;

  insert into public.alert_cases (
    event_id, action_type, action_is_other, action_date, status_value, status_is_other, remarks, updated_by
  )
  select ev, p_action_type, coalesce(p_action_is_other, false), p_action_date,
         p_status_value, coalesce(p_status_is_other, false), p_remarks, v_uid
  from unnest(p_event_ids) as ev
  on conflict (event_id) do update set
    action_type     = coalesce(excluded.action_type, public.alert_cases.action_type),
    action_is_other = coalesce(excluded.action_is_other, public.alert_cases.action_is_other),
    action_date     = coalesce(excluded.action_date, public.alert_cases.action_date),
    status_value    = coalesce(excluded.status_value, public.alert_cases.status_value),
    status_is_other = coalesce(excluded.status_is_other, public.alert_cases.status_is_other),
    remarks         = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by      = excluded.updated_by,
    updated_at      = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

create or replace function public.dds_bulk_log_case_action_by_driver(p_emp_nos text[], p_include_unspecified boolean, p_from date, p_to date, p_shift text, p_action_type text, p_action_is_other boolean, p_action_date date, p_status_value text, p_remarks text DEFAULT NULL::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_updated int;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if (p_emp_nos is null or array_length(p_emp_nos, 1) is null) and not coalesce(p_include_unspecified, false) then
    raise exception 'NO_DRIVERS' using errcode = '22023';
  end if;

  with target_events as (
    select e.id
    from public.events e
    where (
        (p_emp_nos is not null and e.emp_no = any(p_emp_nos))
        or (coalesce(p_include_unspecified, false) and e.emp_no is null)
      )
      and (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or e.shift = p_shift)
  )
  insert into public.alert_cases (event_id, action_type, action_is_other, action_date, status_value, remarks, updated_by)
  select te.id, p_action_type, coalesce(p_action_is_other, false), p_action_date, p_status_value, p_remarks, v_uid
  from target_events te
  on conflict (event_id) do update set
    action_type     = coalesce(excluded.action_type, public.alert_cases.action_type),
    action_is_other = coalesce(excluded.action_is_other, public.alert_cases.action_is_other),
    action_date     = coalesce(excluded.action_date, public.alert_cases.action_date),
    status_value    = coalesce(excluded.status_value, public.alert_cases.status_value),
    remarks         = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by      = excluded.updated_by,
    updated_at      = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

create or replace function public.dds_complete_import(p_import_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  update public.imports
     set status = 'complete',
         completed_at = now(),
         error = null
   where id = p_import_id;
end;
$function$;

create or replace function public.dds_fail_import(p_import_id uuid, p_error text DEFAULT NULL::text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  update public.imports
     set status = 'failed',
         error  = left(coalesce(p_error, 'Sync failed'), 200)
   where id = p_import_id;
end;
$function$;

create or replace function public.dds_ignore_review(p_review_id bigint)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  update public.import_name_review
     set state = 'ignored', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$function$;

create or replace function public.dds_ingest_resolved(p_import_id uuid, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if not exists (select 1 from public.imports where id = p_import_id) then
    raise exception 'UNKNOWN_IMPORT';
  end if;

  drop table if exists _rchunk;
  create temporary table _rchunk on commit drop as
  select
    (r->>'start_time')::timestamp  as start_time,
    (r->>'update_time')::timestamp as update_time,
    case when nullif(r->>'end_time', '') is not null
      then (r->>'end_time')::timestamp end as end_time,
    trim(r->>'asset_id')           as asset_id,
    r->>'event_code'               as event_code,
    coalesce((r->>'event_count')::integer, 0) as event_count,
    nullif(r->>'operator', '')     as operator,
    nullif(r->>'emp_no', '')       as emp_no,
    nullif(r->>'shift', '')        as shift,
    case when nullif(r->>'shift_date', '') is not null
      then (r->>'shift_date')::date end as shift_date,
    (r->>'actionable')::boolean    as actionable,
    (r->>'sync_seconds')::integer  as sync_seconds,
    nullif(r->>'tier', '')         as tier,
    (r->>'distance')::integer      as distance,
    coalesce(r->'candidates', '[]'::jsonb) as candidates
  from jsonb_array_elements(p_rows) r;

  insert into public.events (
    import_id, update_time, start_time, end_time,
    asset_id, event_code, event_count, operator, emp_no,
    shift, shift_date, actionable, sync_seconds
  )
  select
    p_import_id, c.update_time, c.start_time, c.end_time,
    c.asset_id, c.event_code, c.event_count, c.operator, c.emp_no,
    c.shift, c.shift_date, c.actionable, c.sync_seconds
  from _rchunk c
  on conflict (asset_id, start_time, event_code) do nothing;

  get diagnostics v_inserted = row_count;

  insert into public.import_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, n.raw_name, n.norm_name, n.tier, n.distance, n.candidates, n.row_count
  from (
    select public.dds_norm_name(c.operator) as norm_name,
           min(c.operator)   as raw_name,
           min(c.tier)       as tier,
           min(c.distance)   as distance,
           (array_agg(c.candidates order by c.ord))[1] as candidates,
           count(*)::integer as row_count
    from (
      select *, row_number() over () as ord from _rchunk
    ) c
    where c.emp_no is null
      and c.operator is not null
      and public.dds_norm_name(c.operator) is not null
    group by public.dds_norm_name(c.operator)
  ) n
  on conflict (import_id, norm_name) do update
    set row_count  = public.import_name_review.row_count + excluded.row_count,
        candidates = excluded.candidates,
        tier       = excluded.tier,
        distance   = excluded.distance;

  update public.imports
     set row_count = row_count + v_inserted,
         unresolved_count = (
           select coalesce(sum(row_count), 0) from public.import_name_review
            where import_id = p_import_id and state = 'open'
         ),
         status = 'processing'
   where id = p_import_id;

  return v_inserted;
end;
$function$;

create or replace function public.dds_log_driver_asset_action(p_entity_type text, p_entity_id text, p_action_type text, p_action_is_other boolean DEFAULT false, p_remarks text DEFAULT NULL::text, p_source text DEFAULT 'monitoring'::text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  insert into public.driver_asset_actions (
    entity_type, entity_id, action_type, action_is_other, remarks,
    source, actor_user_id
  ) values (
    p_entity_type, p_entity_id, p_action_type, coalesce(p_action_is_other, false), p_remarks,
    coalesce(p_source, 'monitoring'), auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$function$;

create or replace function public.dds_log_entity_action(p_entity_type text, p_entity_id text, p_action_type text, p_action_other_text text, p_note text, p_logged_by text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid;
  v_status text;
  v_monitor_until date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  if p_entity_type not in ('driver', 'asset') then
    raise exception 'INVALID_ENTITY_TYPE' using errcode = '22023';
  end if;

  if p_action_type not in (
    'Counseled', 'Suspended', 'Reassigned', 'Cleared',
    'Spare 3 Days', 'Monitor', 'Continue', 'Other',
    'Spare', 'Replace'
  ) then
    raise exception 'INVALID_ACTION_TYPE' using errcode = '22023';
  end if;

  if coalesce(trim(p_logged_by), '') = '' then
    raise exception 'LOGGED_BY_REQUIRED' using errcode = '22023';
  end if;

  insert into public.entity_action_log (
    entity_type, entity_id, action_type, action_other_text, note,
    logged_by, actor_user_id
  ) values (
    p_entity_type, p_entity_id, p_action_type, p_action_other_text, p_note,
    trim(p_logged_by), auth.uid()
  )
  returning id into v_id;

  if p_action_type = 'Cleared' then
    delete from public.entity_status
    where entity_type = p_entity_type and entity_id = p_entity_id;
  else
    if p_action_type = 'Spare 3 Days' then
      v_status := 'monitoring';
      v_monitor_until := current_date + 3;
    elsif p_action_type in ('Monitor', 'Continue') then
      v_status := 'monitoring';
      v_monitor_until := current_date + 14;
    else
      v_status := 'actioned';
      v_monitor_until := null;
    end if;

    insert into public.entity_status (entity_type, entity_id, status, monitor_until, updated_by)
    values (p_entity_type, p_entity_id, v_status, v_monitor_until, auth.uid())
    on conflict (entity_type, entity_id)
    do update set status = excluded.status,
                  monitor_until = excluded.monitor_until,
                  updated_at = now(),
                  updated_by = excluded.updated_by;
  end if;

  return v_id;
end;
$function$;

create or replace function public.dds_minestat_ignore_review(p_review_id bigint)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name into v_norm from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  update public.minestat_name_review
     set state = 'ignored', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();
  return true;
end;
$function$;

create or replace function public.dds_minestat_ingest_resolved(p_import_id uuid, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if not exists (select 1 from public.imports where id = p_import_id) then
    raise exception 'UNKNOWN_IMPORT';
  end if;

  drop table if exists _rmchunk;
  create temporary table _rmchunk on commit drop as
  select
    trim(r->>'asset_id')                as asset_id,
    (r->>'shift_date')::date            as shift_date,
    upper(trim(r->>'shift'))            as shift,
    nullif(trim(r->>'last_name'), '')   as last_name,
    nullif(trim(r->>'first_name'), '')  as first_name,
    nullif(trim(r->>'middle_name'), '') as middle_name,
    coalesce((r->>'operating_hrs')::numeric, 0) as operating_hrs,
    coalesce((r->>'down_hrs')::numeric, 0)      as down_hrs,
    coalesce((r->>'delay_hrs')::numeric, 0)     as delay_hrs,
    coalesce((r->>'standby_hrs')::numeric, 0)   as standby_hrs,
    coalesce((r->>'total_hrs')::numeric, 0)     as total_hrs,
    nullif(r->>'emp_no', '')            as emp_no,
    nullif(r->>'tier', '')              as tier,
    (r->>'distance')::integer           as distance,
    coalesce(r->'candidates', '[]'::jsonb) as candidates,
    (upper(coalesce(nullif(trim(r->>'last_name'), ''), ''))   = 'NO OPERATOR'
     and upper(coalesce(nullif(trim(r->>'first_name'), ''), '')) = 'EQUIPMENT DOWN'
     and upper(coalesce(nullif(trim(r->>'middle_name'), ''), '')) = 'OR STANDBY') as no_operator,
    row_number() over () as ord
  from jsonb_array_elements(p_rows) r;

  drop table if exists _rmdeduped;
  create temporary table _rmdeduped on commit drop as
  select distinct on (m.asset_id, m.shift_date, m.shift,
                       public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name))
    m.*
  from _rmchunk m
  order by m.asset_id, m.shift_date, m.shift,
           public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name),
           m.ord desc;

  insert into public.minestat_shifts (
    asset_id, shift_date, shift, last_name, first_name, middle_name,
    operating_hrs, down_hrs, delay_hrs, standby_hrs, total_hrs,
    emp_no, tier, distance, candidates, import_id, updated_at
  )
  select
    m.asset_id, m.shift_date, m.shift, m.last_name, m.first_name, m.middle_name,
    m.operating_hrs, m.down_hrs, m.delay_hrs, m.standby_hrs, m.total_hrs,
    case when m.no_operator then null else m.emp_no end,
    case when m.no_operator then 'no_operator' else m.tier end,
    m.distance, m.candidates,
    p_import_id, now()
  from _rmdeduped m
  on conflict (asset_id, shift_date, shift, operator_key) do update
    set last_name     = excluded.last_name,
        first_name    = excluded.first_name,
        middle_name   = excluded.middle_name,
        operating_hrs = excluded.operating_hrs,
        down_hrs      = excluded.down_hrs,
        delay_hrs     = excluded.delay_hrs,
        standby_hrs   = excluded.standby_hrs,
        total_hrs     = excluded.total_hrs,
        emp_no        = excluded.emp_no,
        tier          = excluded.tier,
        distance      = excluded.distance,
        candidates    = excluded.candidates,
        import_id     = excluded.import_id,
        updated_at    = now();

  get diagnostics v_inserted = row_count;

  insert into public.minestat_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, n.raw_name, n.norm_name, n.tier, n.distance, n.candidates, n.row_count
  from (
    select public.dds_norm_name(
             coalesce(m.last_name, '') || ', ' ||
             trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
           ) as norm_name,
           min(coalesce(m.last_name, '') || ', ' ||
               trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))) as raw_name,
           min(m.tier)       as tier,
           min(m.distance)   as distance,
           (array_agg(m.candidates order by m.ord))[1] as candidates,
           count(*)::integer as row_count
    from _rmchunk m
    where m.no_operator = false
      and m.emp_no is null
      and public.dds_norm_name(
            coalesce(m.last_name, '') || ', ' ||
            trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
          ) is not null
    group by public.dds_norm_name(
               coalesce(m.last_name, '') || ', ' ||
               trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
             )
  ) n
  on conflict (import_id, norm_name) do update
    set row_count  = public.minestat_name_review.row_count + excluded.row_count,
        candidates = excluded.candidates,
        tier       = excluded.tier,
        distance   = excluded.distance;

  update public.imports
     set row_count = row_count + v_inserted,
         unresolved_count = (
           select coalesce(sum(row_count), 0) from public.minestat_name_review
            where import_id = p_import_id and state = 'open'
         ),
         status = 'processing'
   where id = p_import_id;

  return v_inserted;
end;
$function$;

create or replace function public.dds_minestat_reopen_review(p_review_id bigint, p_clear_alias boolean DEFAULT true)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name into v_norm from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  if p_clear_alias then
    delete from public.driver_aliases where norm_name = v_norm;
    update public.minestat_shifts
       set emp_no = null, tier = null, updated_at = now()
     where public.dds_norm_name(
             coalesce(last_name, '') || ', ' ||
             trim(coalesce(first_name, '') || ' ' || coalesce(middle_name, ''))
           ) = v_norm;
  end if;

  update public.minestat_name_review
     set state = 'open', resolved_by = null, resolved_at = null
   where norm_name = v_norm and state <> 'open';

  perform public.dds_minestat_refresh_unresolved_counts();
  return true;
end;
$function$;

create or replace function public.dds_minestat_reresolve_all(p_limit integer DEFAULT 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_resolved    integer := 0;
  v_checked     integer := 0;
  v_still_open  integer := 0;
  v_remaining   integer := 0;
  v_limit       integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from (
    select id, norm_name, raw_name
    from public.minestat_name_review
    where state = 'open'
    order by id
    limit v_limit
  ) rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r;

  select count(*) into v_checked from _reresolved;

  with newly_resolved as (
    select * from _reresolved where emp_no is not null
  ),
  shifts_updated as (
    update public.minestat_shifts ms
       set emp_no = nr.emp_no, tier = nr.tier, distance = nr.distance,
           candidates = coalesce(nr.candidates, '[]'::jsonb), updated_at = now()
      from newly_resolved nr
     where ms.emp_no is null
       and public.dds_norm_name(
             coalesce(ms.last_name, '') || ', ' ||
             trim(coalesce(ms.first_name, '') || ' ' || coalesce(ms.middle_name, ''))
           ) = nr.norm_name
    returning 1
  ),
  review_closed as (
    update public.minestat_name_review rv
       set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
      from newly_resolved nr
     where rv.id = nr.review_id
       and rv.state = 'open'
    returning 1
  )
  select count(*) into v_resolved from review_closed;

  update public.minestat_name_review rv
     set tier = r.tier, distance = r.distance,
         candidates = coalesce(r.candidates, '[]'::jsonb)
    from _reresolved r
   where rv.id = r.review_id
     and r.emp_no is null
     and rv.state = 'open';
  get diagnostics v_still_open = row_count;

  select count(*) into v_remaining from public.minestat_name_review where state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',       v_checked,
    'resolved',      v_resolved,
    'stillOpen',     v_still_open,
    'remainingOpen', v_remaining
  );
end;
$function$;

create or replace function public.dds_minestat_resolve_review(p_review_id bigint, p_emp_no text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_norm text;
  v_raw  text;
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name, raw_name into v_norm, v_raw
  from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  perform public.dds_confirm_alias(coalesce(v_raw, v_norm), p_emp_no);

  update public.minestat_shifts
     set emp_no = p_emp_no, tier = 'human', updated_at = now()
   where emp_no is null
     and public.dds_norm_name(
           coalesce(last_name, '') || ', ' ||
           trim(coalesce(first_name, '') || ' ' || coalesce(middle_name, ''))
         ) = v_norm;
  get diagnostics v_rows = row_count;

  update public.minestat_name_review
     set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no, 'rowsUpdated', v_rows);
end;
$function$;

create or replace function public.dds_reopen_review(p_review_id bigint, p_clear_alias boolean DEFAULT true)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  if p_clear_alias then
    delete from public.driver_aliases where norm_name = v_norm;
    update public.events set emp_no = null
     where operator is not null and public.dds_norm_name(operator) = v_norm;
  end if;

  update public.import_name_review
     set state = 'open', resolved_by = null, resolved_at = null
   where norm_name = v_norm and state <> 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$function$;

create or replace function public.dds_reresolve_all(p_limit integer DEFAULT 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_resolved    integer := 0;
  v_checked     integer := 0;
  v_still_open  integer := 0;
  v_remaining   integer := 0;
  v_limit       integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from (
    select id, norm_name, raw_name
    from public.import_name_review
    where state = 'open'
    order by id
    limit v_limit
  ) rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r;

  select count(*) into v_checked from _reresolved;

  with newly_resolved as (
    select * from _reresolved where emp_no is not null
  ),
  events_updated as (
    update public.events e
       set emp_no = nr.emp_no
      from newly_resolved nr
     where e.emp_no is null
       and e.operator is not null
       and public.dds_norm_name(e.operator) = nr.norm_name
    returning 1
  ),
  review_closed as (
    update public.import_name_review rv
       set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
      from newly_resolved nr
     where rv.id = nr.review_id
       and rv.state = 'open'
    returning 1
  )
  select count(*) into v_resolved from review_closed;

  update public.import_name_review rv
     set tier = r.tier, distance = r.distance,
         candidates = coalesce(r.candidates, '[]'::jsonb)
    from _reresolved r
   where rv.id = r.review_id
     and r.emp_no is null
     and rv.state = 'open';
  get diagnostics v_still_open = row_count;

  select count(*) into v_remaining from public.import_name_review where state = 'open';

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',       v_checked,
    'resolved',      v_resolved,
    'stillOpen',     v_still_open,
    'remainingOpen', v_remaining
  );
end;
$function$;

create or replace function public.dds_reset_fleet_data()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_counts jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select jsonb_build_object(
    'imports',                  (select count(*) from public.imports),
    'events',                   (select count(*) from public.events),
    'alertCases',                (select count(*) from public.alert_cases),
    'importNameReview',          (select count(*) from public.import_name_review),
    'minestatNameReview',        (select count(*) from public.minestat_name_review),
    'empNoAttributionConflicts', (select count(*) from public.emp_no_attribution_conflicts),
    'contributingFactors',       (select count(*) from public.contributing_factors),
    'driverAssetActions',        (select count(*) from public.driver_asset_actions),
    'driverMaster',              (select count(*) from public.driver_master),
    'drivers',                   (select count(*) from public.drivers),
    'driverAliases',             (select count(*) from public.driver_aliases),
    'minestatShifts',            (select count(*) from public.minestat_shifts),
    'entityStatus',              (select count(*) from public.entity_status),
    'entityActionLog',           (select count(*) from public.entity_action_log)
  ) into v_counts;

  truncate table
    public.imports,
    public.driver_master,
    public.contributing_factors,
    public.driver_asset_actions
    cascade;

  truncate table public.minestat_shifts cascade;

  truncate table
    public.entity_status,
    public.entity_action_log
    cascade;

  truncate table
    public.drivers,
    public.driver_aliases,
    public.driver_alias_log
    cascade;

  return v_counts;
end;
$function$;

create or replace function public.dds_resolve_review(p_review_id bigint, p_emp_no text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_norm text;
  v_raw  text;
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  select norm_name, raw_name into v_norm, v_raw
  from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  perform public.dds_confirm_alias(coalesce(v_raw, v_norm), p_emp_no);

  update public.events
     set emp_no = p_emp_no
   where emp_no is null
     and operator is not null
     and public.dds_norm_name(operator) = v_norm;
  get diagnostics v_rows = row_count;

  update public.import_name_review
     set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no, 'rowsUpdated', v_rows);
end;
$function$;

create or replace function public.dds_update_event_resolved(p_event_id bigint, p_start_time timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_update_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_asset_id text DEFAULT NULL::text, p_event_code text DEFAULT NULL::text, p_event_count integer DEFAULT NULL::integer, p_operator text DEFAULT NULL::text, p_emp_no text DEFAULT NULL::text, p_shift text DEFAULT NULL::text, p_shift_date date DEFAULT NULL::date, p_actionable boolean DEFAULT NULL::boolean, p_sync_seconds integer DEFAULT NULL::integer, p_tier text DEFAULT NULL::text, p_distance integer DEFAULT NULL::integer, p_candidates jsonb DEFAULT '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_asset_id      text;
  v_event_code    text;
  v_event_count   integer;
  v_update_time   timestamp;
  v_operator      text;
  v_import_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if not exists (select 1 from public.events where id = p_event_id) then
    raise exception 'EVENT_NOT_FOUND' using errcode = '22023';
  end if;
  if p_start_time is null then
    raise exception 'START_TIME_REQUIRED' using errcode = '22023';
  end if;

  v_asset_id := nullif(trim(coalesce(p_asset_id, '')), '');
  v_event_code := nullif(trim(coalesce(p_event_code, '')), '');
  if v_asset_id is null then
    raise exception 'ASSET_ID_REQUIRED' using errcode = '22023';
  end if;
  if v_event_code is null then
    raise exception 'EVENT_CODE_REQUIRED' using errcode = '22023';
  end if;
  v_event_count := greatest(coalesce(p_event_count, 0), 0);
  v_update_time := coalesce(p_update_time, p_start_time);
  v_operator := nullif(trim(coalesce(p_operator, '')), '');

  select import_id into v_import_id from public.events where id = p_event_id;

  update public.events
     set start_time   = p_start_time,
         end_time      = p_end_time,
         update_time   = v_update_time,
         asset_id      = v_asset_id,
         event_code    = v_event_code,
         event_count   = v_event_count,
         operator      = v_operator,
         emp_no        = p_emp_no,
         shift         = p_shift,
         shift_date    = p_shift_date,
         actionable    = p_actionable,
         sync_seconds  = p_sync_seconds
   where id = p_event_id;

  if v_operator is not null and p_emp_no is null and v_import_id is not null
     and public.dds_norm_name(v_operator) is not null then
    insert into public.import_name_review (
      import_id, raw_name, norm_name, tier, distance, candidates, row_count
    )
    values (
      v_import_id, v_operator, public.dds_norm_name(v_operator),
      coalesce(p_tier, 'none'), p_distance, coalesce(p_candidates, '[]'::jsonb), 1
    )
    on conflict (import_id, norm_name) do update
      set row_count  = public.import_name_review.row_count + 1,
          candidates = excluded.candidates,
          tier       = excluded.tier,
          distance   = excluded.distance;

    perform public.dds_refresh_unresolved_counts();
  end if;

  return jsonb_build_object('updated', 1);
exception
  when unique_violation then
    raise exception 'DUPLICATE_EVENT' using errcode = '23505',
      message = 'Another event already exists with this asset, start time, and event code.';
end;
$function$;

create or replace function public.dds_upsert_drivers(p_rows jsonb, p_deactivate boolean DEFAULT true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_seen        text[];
  v_inserted    integer := 0;
  v_updated     integer := 0;
  v_deactivated integer := 0;
  v_skipped     integer := 0;
  v_aliased     integer := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();

  drop table if exists _incoming;
  create temporary table _incoming (
    emp_no text primary key, full_name text, status text, details jsonb
  ) on commit drop;

  insert into _incoming (emp_no, full_name, status, details)
  select distinct on (trim(r ->> 'emp_no'))
         trim(r ->> 'emp_no'),
         trim(r ->> 'name'),
         coalesce(nullif(trim(r ->> 'status'), ''), 'active'),
         coalesce(r -> 'details', '{}'::jsonb)
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality as t(r, ord)
  where nullif(trim(r ->> 'emp_no'), '') is not null
    and nullif(trim(r ->> 'name'), '')   is not null
  order by trim(r ->> 'emp_no'), t.ord desc;

  select count(*) into v_skipped
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where nullif(trim(r ->> 'emp_no'), '') is null
     or nullif(trim(r ->> 'name'), '')   is null;

  if (select count(*) from _incoming) = 0 then
    raise exception 'EMPTY_ROSTER';
  end if;

  select array_agg(emp_no) into v_seen from _incoming;

  with up as (
    insert into public.drivers as d (emp_no, full_name, status, details, uploaded_by)
    select i.emp_no, i.full_name,
           case when i.status in ('active', 'inactive') then i.status else 'active' end,
           i.details, auth.uid()
    from _incoming i
    on conflict (emp_no) do update
      set full_name  = excluded.full_name,
          status     = excluded.status,
          details    = excluded.details,
          updated_at = now()
    returning (xmax = 0) as was_insert
  )
  select count(*) filter (where was_insert),
         count(*) filter (where not was_insert)
  into v_inserted, v_updated
  from up;

  if p_deactivate then
    update public.drivers
       set status = 'inactive', updated_at = now()
     where status = 'active'
       and not (emp_no = any(v_seen));
    get diagnostics v_deactivated = row_count;
  end if;

  with seeded as (
    insert into public.driver_aliases as a (norm_name, raw_name, emp_no, tier, source)
    select public.dds_norm_name(i.full_name), i.full_name, i.emp_no, 'seed', 'seed'
    from _incoming i
    where public.dds_norm_name(i.full_name) is not null
    on conflict (norm_name) do update
      set emp_no     = excluded.emp_no,
          raw_name   = excluded.raw_name,
          updated_at = now()
      where a.source <> 'human'
    returning 1
  )
  select count(*) into v_aliased from seeded;

  return jsonb_build_object(
    'inserted',    v_inserted,
    'updated',     v_updated,
    'deactivated', v_deactivated,
    'skipped',     v_skipped,
    'aliasesSeeded', v_aliased,
    'total',       v_inserted + v_updated
  );
end;
$function$;
