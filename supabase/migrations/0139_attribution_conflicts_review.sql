-- ============================================================================
-- DDS — 0139_attribution_conflicts_review
-- ----------------------------------------------------------------------------
-- Gap analysis finding: dds_backfill_emp_no_from_minestat() already detects
-- when the DDS-reported operator and MineStat's shift roster disagree about
-- who ran an asset, logging it to emp_no_attribution_conflicts — but that
-- table has never had a UI. 6 live, unresolved conflicts exist right now
-- with no way for anyone to see or resolve them, meaning the driver
-- currently credited for those specific alerts may be wrong.
--
-- Adds resolution tracking to the existing table (state/resolution/
-- resolved_by/resolved_at, matching import_name_review's own naming) and
-- two RPCs, following the exact list/resolve conventions already used by
-- dds_minestat_name_review_list()/dds_minestat_resolve_review():
--   - dds_attribution_conflicts_list(p_state, p_limit, p_offset): paged,
--     joined with driver names for both candidates.
--   - dds_attribution_conflicts_resolve(p_id, p_choice): p_choice is
--     'operator' or 'minestat' — sets that event's emp_no to the chosen
--     value and marks the conflict resolved.
-- ============================================================================

alter table public.emp_no_attribution_conflicts
  add column if not exists state text not null default 'open',
  add column if not exists resolution text,
  add column if not exists resolved_by uuid,
  add column if not exists resolved_at timestamptz;

alter table public.emp_no_attribution_conflicts
  drop constraint if exists emp_no_attribution_conflicts_state_check;
alter table public.emp_no_attribution_conflicts
  add constraint emp_no_attribution_conflicts_state_check check (state in ('open','resolved'));

alter table public.emp_no_attribution_conflicts
  drop constraint if exists emp_no_attribution_conflicts_resolution_check;
alter table public.emp_no_attribution_conflicts
  add constraint emp_no_attribution_conflicts_resolution_check check (resolution is null or resolution in ('operator','minestat'));

create or replace function public.dds_attribution_conflicts_list(
  p_state text default 'open',
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with scoped as (
    select * from public.emp_no_attribution_conflicts
     where p_state is null or p_state = 'all' or state = p_state
  ),
  total as (select count(*) as n from scoped),
  paged as (
    select * from scoped order by detected_at desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'eventId', p.event_id, 'assetId', p.asset_id,
        'shiftDate', to_char(p.shift_date, 'MM/DD/YYYY'), 'shift', p.shift,
        'operatorEmpNo', p.operator_emp_no, 'operatorName', coalesce(d1.full_name, p.operator_emp_no),
        'minestatEmpNo', p.minestat_emp_no, 'minestatName', coalesce(d2.full_name, p.minestat_emp_no),
        'state', p.state, 'resolution', p.resolution,
        'resolvedAt', to_char(p.resolved_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'detectedAt', to_char(p.detected_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) order by p.detected_at desc)
      from paged p
      left join public.drivers d1 on d1.emp_no = p.operator_emp_no
      left join public.drivers d2 on d2.emp_no = p.minestat_emp_no
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

create or replace function public.dds_attribution_conflicts_resolve(
  p_id bigint,
  p_choice text
)
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
