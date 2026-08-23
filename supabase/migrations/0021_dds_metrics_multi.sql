-- ============================================================================
-- DDS — 0021_dds_metrics_multi
-- ----------------------------------------------------------------------------
-- App.loadFromServer() (index.html) calls dds_metrics() up to SIX times per
-- signed-in page load — primary window, comparison baseline, 7d-current,
-- 7d-previous, month-current, month-previous — each its own network
-- round-trip, each re-running the same aggregation pipeline over
-- public.events independently. This adds dds_metrics_multi(), a thin
-- wrapper that accepts an ARRAY of window specs and returns their results
-- in one round-trip by simply looping dds_metrics() itself — not a
-- reimplementation of its ~200-line aggregation body, so there is zero risk
-- of the two functions silently drifting apart the way a hand-copied
-- second implementation could.
--
-- What this DOES fix: round-trip latency (6 sequential/parallel network
-- calls collapse to 1). What this does NOT fix: total database aggregation
-- work — Postgres still scans/aggregates public.events once per window,
-- just inside one function invocation instead of six separate ones. A
-- materialized daily-rollup table would be the next step if per-window
-- aggregation cost itself (not round-trip count) becomes the bottleneck as
-- event history grows — deliberately not attempted here; this migration is
-- scoped to the round-trip problem only.
--
-- dds_metrics() itself is UNTOUCHED — every existing caller keeps working
-- exactly as before. This is purely additive.
-- ============================================================================

create or replace function public.dds_metrics_multi(p_windows jsonb)
returns jsonb
language plpgsql
stable
security invoker            -- RLS still applies; this is not a bypass
set search_path = public
as $$
declare
  result jsonb := '[]'::jsonb;
  w jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if p_windows is null or jsonb_typeof(p_windows) <> 'array' then
    raise exception 'p_windows must be a JSON array' using errcode = '22023';
  end if;

  -- Each element: { "from": "YYYY-MM-DD"|null, "to": "YYYY-MM-DD"|null,
  -- "shift": "DAY"|"NIGHT"|null, "assetIds": [...]|null,
  -- "eventCodes": [...]|null, "actionableOnly": bool }. Same parameter
  -- names/shapes dds_metrics() itself takes, just camelCase JSON keys
  -- instead of positional p_* args, since this is called from a JS array
  -- of window objects, not individual RPC arguments. Order of `result` is
  -- guaranteed to match the order of `p_windows` (jsonb_agg over an
  -- explicitly ordinal for-loop, not a set-based query that could
  -- reorder) — the caller matches results back to windows by array index.
  for w in select * from jsonb_array_elements(p_windows)
  loop
    result := result || jsonb_build_array(
      public.dds_metrics(
        p_from            := nullif(w->>'from', '')::date,
        p_to              := nullif(w->>'to', '')::date,
        p_shift           := nullif(w->>'shift', ''),
        p_asset_ids       := case when w ? 'assetIds' and jsonb_typeof(w->'assetIds') = 'array'
                                   then (select array_agg(x) from jsonb_array_elements_text(w->'assetIds') x)
                                   else null end,
        p_event_codes     := case when w ? 'eventCodes' and jsonb_typeof(w->'eventCodes') = 'array'
                                   then (select array_agg(x) from jsonb_array_elements_text(w->'eventCodes') x)
                                   else null end,
        p_actionable_only := coalesce((w->>'actionableOnly')::boolean, false)
      )
    );
  end loop;

  return result;
end;
$$;

grant execute on function public.dds_metrics_multi(jsonb) to authenticated;
