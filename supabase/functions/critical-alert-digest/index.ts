// critical-alert-digest: scheduled Edge Function that emails everyone in
// alert_recipients a short summary of critical events (event_code ilike
// '%sleep%') logged since the last run, then advances the low-water mark.
//
// Why a digest, not one email per event: dds_ingest() processes rows in
// bulk, so a single import can add many qualifying events at once — a
// per-event email would flood the inbox. A short window (this function is
// meant to be invoked on a schedule, e.g. every 5 minutes, by
// .github/workflows/critical-alert-digest.yml) naturally batches without
// needing separate rate-limiting logic. If zero new events are found, this
// sends nothing — no empty digest emails.
//
// Why this has to be an Edge Function and not client-side code: nobody has
// the dashboard open when this needs to run (that is the whole problem it
// solves), and reading/writing alert_digest_state plus sending real email
// needs the service-role key, which must never run in a browser — same
// boundary invite-user's own header explains for its privileged operations.
//
// Auth model, deliberately different from invite-user: this function is
// invoked by a scheduled job, not a signed-in person, so there is no user
// JWT to verify and no per-caller authorization decision to make (unlike
// invite-user's admin-only check). The platform's own JWT gate is
// satisfied by sending the project's anon key as the caller's bearer token
// (see .github/workflows/critical-alert-digest.yml) — that only proves the
// caller holds a valid Supabase key for this project, not that it's a
// particular privileged user. All the real privileged work inside this
// function (reading/writing alert_digest_state, calling
// dds_critical_events_since, reading alert_recipients) uses this
// function's OWN service-role client, configured entirely from environment
// secrets, never from anything the caller sent.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

type CriticalEvent = {
  eventId: number;
  startTime: string;
  assetId: string | null;
  driverDisplayName: string | null;
  empNo: string | null;
  eventCode: string;
  eventCount: number;
  shift: string | null;
  shiftDate: string | null;
};

function renderDigestHtml(events: CriticalEvent[]): string {
  const rows = events
    .map((e) => {
      const driver = e.driverDisplayName ? escapeHtml(e.driverDisplayName) : "Unspecified";
      const when = new Date(e.startTime).toISOString().replace("T", " ").slice(0, 16) + " UTC";
      return `<tr>
        <td style="padding:6px 10px;border-bottom:1px solid #eee">${when}</td>
        <td style="padding:6px 10px;border-bottom:1px solid #eee">${escapeHtml(e.assetId || "—")}</td>
        <td style="padding:6px 10px;border-bottom:1px solid #eee">${driver}</td>
        <td style="padding:6px 10px;border-bottom:1px solid #eee">${escapeHtml(e.eventCode)}</td>
        <td style="padding:6px 10px;border-bottom:1px solid #eee;text-align:right">${e.eventCount}</td>
      </tr>`;
    })
    .join("");
  return `<div style="font-family:system-ui,sans-serif;color:#1a1a1a">
    <h2 style="margin:0 0 12px">${events.length} new critical drowsiness event${events.length === 1 ? "" : "s"}</h2>
    <table style="border-collapse:collapse;width:100%;max-width:640px">
      <thead>
        <tr style="text-align:left;background:#f5f5f5">
          <th style="padding:6px 10px">Time</th>
          <th style="padding:6px 10px">Asset</th>
          <th style="padding:6px 10px">Driver</th>
          <th style="padding:6px 10px">Alert</th>
          <th style="padding:6px 10px;text-align:right">Count</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  </div>`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  const fromAddress = Deno.env.get("ALERT_DIGEST_FROM") || "alerts@resend.dev";

  if (!resendApiKey) {
    return jsonResponse({ error: "MISSING_RESEND_API_KEY" }, 500);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: stateRow, error: stateErr } = await adminClient
    .from("alert_digest_state")
    .select("last_sent_at")
    .eq("id", true)
    .single();
  if (stateErr || !stateRow) {
    return jsonResponse({ error: "DIGEST_STATE_READ_FAILED", detail: stateErr?.message }, 500);
  }
  const since = stateRow.last_sent_at as string;
  const runStartedAt = new Date().toISOString();

  const { data: events, error: eventsErr } = await adminClient.rpc("dds_critical_events_since", {
    p_since: since,
  });
  if (eventsErr) {
    return jsonResponse({ error: "EVENTS_QUERY_FAILED", detail: eventsErr.message }, 500);
  }
  const eventList = (events || []) as CriticalEvent[];

  if (eventList.length === 0) {
    // Still advance the low-water mark to this run's start time, so a
    // quiet period doesn't leave p_since growing stale forever — the next
    // run only ever looks at genuinely new events, not a widening window.
    await adminClient.from("alert_digest_state").update({ last_sent_at: runStartedAt }).eq("id", true);
    return jsonResponse({ ok: true, sent: false, newEvents: 0 }, 200);
  }

  const { data: recipients, error: recipientsErr } = await adminClient
    .from("alert_recipients")
    .select("email")
    .eq("active", true);
  if (recipientsErr) {
    return jsonResponse({ error: "RECIPIENTS_QUERY_FAILED", detail: recipientsErr.message }, 500);
  }
  const toAddresses = (recipients || []).map((r) => r.email as string);

  if (toAddresses.length === 0) {
    // Real events exist, but nobody's configured to hear about them — a
    // silent no-op still advances the mark (nothing to retry) rather than
    // holding the window open and re-finding the same events next run.
    await adminClient.from("alert_digest_state").update({ last_sent_at: runStartedAt }).eq("id", true);
    return jsonResponse({ ok: true, sent: false, newEvents: eventList.length, reason: "NO_ACTIVE_RECIPIENTS" }, 200);
  }

  const emailRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromAddress,
      to: toAddresses,
      subject: `DDS: ${eventList.length} new critical drowsiness event${eventList.length === 1 ? "" : "s"}`,
      html: renderDigestHtml(eventList),
    }),
  });

  if (!emailRes.ok) {
    // Deliberately does NOT advance last_sent_at on a send failure — the
    // next run retries the same window rather than silently dropping
    // events a failed provider call never actually delivered.
    const detail = await emailRes.text();
    return jsonResponse({ error: "EMAIL_SEND_FAILED", status: emailRes.status, detail }, 502);
  }

  await adminClient.from("alert_digest_state").update({ last_sent_at: runStartedAt }).eq("id", true);

  return jsonResponse({ ok: true, sent: true, newEvents: eventList.length, recipients: toAddresses.length }, 200);
});
