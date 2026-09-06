-- ============================================================================
-- DDS — 0061_drop_unused_columns
-- ----------------------------------------------------------------------------
-- Column-level cleanup, verified against BOTH index.html (grep for every
-- read/write path) AND the actual RPC bodies live in this database (not
-- assumed from local migration files, after 0058's dds_case_records outage
-- showed that assumption is unsafe) before any DROP was written.
--
-- dds_confirm_alias() writes driver_aliases.confirmed_by on every human
-- confirmation — this migration updates that function FIRST to stop
-- referencing the column, then drops it, so the function never errors on
-- its next call.
-- ============================================================================

-- ── imports: dead from day one — never written, never read ────────────────
alter table public.imports drop column if exists rejected_count;
alter table public.imports drop column if exists rejects;

-- ── imports.storage_key: written (a synthetic placeholder string), never
--    read back to retrieve a file — no download/retrieval path exists ─────
alter table public.imports drop column if exists storage_key;

-- ── drivers.merged_into: the "rehire pointer" — no merge-employee UI or
--    RPC exists anywhere; drop the FK-bearing column and its self-FK ──────
alter table public.drivers drop column if exists merged_into;

-- ── driver_aliases.confirmed_by: audit-only, never displayed. Update
--    dds_confirm_alias() first so it stops writing the column before the
--    column itself is dropped. ──────────────────────────────────────────
create or replace function public.dds_confirm_alias(
  p_raw_name text,
  p_emp_no   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  v_norm := public.dds_norm_name(p_raw_name);
  if v_norm is null then raise exception 'BLANK_NAME'; end if;

  if not exists (select 1 from public.drivers where emp_no = p_emp_no) then
    raise exception 'UNKNOWN_EMPLOYEE';
  end if;

  insert into public.driver_aliases (norm_name, raw_name, emp_no, tier, source)
  values (v_norm, p_raw_name, p_emp_no, 'human', 'human')
  on conflict (norm_name) do update
    set emp_no       = excluded.emp_no,
        raw_name     = excluded.raw_name,
        tier         = 'human',
        source       = 'human',
        updated_at   = now();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no);
end;
$$;

alter table public.driver_aliases drop column if exists confirmed_by;

-- ── minestat_shifts: 5 hour-tracking columns populated on every ingest,
--    never read by any chart/table/KPI or any other RPC ──────────────────
alter table public.minestat_shifts drop column if exists operating_hrs;
alter table public.minestat_shifts drop column if exists down_hrs;
alter table public.minestat_shifts drop column if exists delay_hrs;
alter table public.minestat_shifts drop column if exists standby_hrs;
alter table public.minestat_shifts drop column if exists total_hrs;

-- ── driver_asset_actions.actor_username: written by
--    dds_log_driver_asset_action() alongside actor_user_id, never read —
--    update the function first, then drop the column. The live function
--    has parameter DEFAULTS on p_action_is_other/p_remarks/p_source that
--    CREATE OR REPLACE cannot remove (42P13) — DROP first, then recreate
--    with matching defaults, so the signature parity is deliberate, not
--    dropped along with the unused column. ────────────────────────────────
drop function if exists public.dds_log_driver_asset_action(text, text, text, boolean, text, text);

create or replace function public.dds_log_driver_asset_action(
  p_entity_type text,
  p_entity_id   text,
  p_action_type text,
  p_action_is_other boolean default false,
  p_remarks     text default null,
  p_source      text default 'monitoring'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

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
$$;

alter table public.driver_asset_actions drop column if exists actor_username;
