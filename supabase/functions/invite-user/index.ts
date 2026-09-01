// invite-user: admin-only Edge Function that invites a new person by
// email (real Supabase Auth invite, sends a real email) and immediately
// creates their profiles row so they appear in Access Management's
// pending list right away, before they ever open the email.
//
// Why this has to be an Edge Function and not client-side code: creating
// another person's auth.users account requires the Supabase service-role
// key, which bypasses every RLS policy — it must never run in a browser.
// This function holds that key server-side only and re-derives the
// caller's own admin status from their JWT before doing anything
// privileged, so a non-admin (or an unauthenticated request) can't use
// it to invite/escalate anyone.
//
// profiles RLS (0004_auth_profiles.sql, confirmed live):
//   profiles_insert_self only lets a user insert their OWN row, so the
//   normal client can never create someone else's profile — this
//   function uses the service-role client (which bypasses RLS) to do
//   that one privileged insert on the admin's behalf, then everything
//   else in Access Management (approve/reject/role-change) continues to
//   go through the regular RLS-checked client as before.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const ALLOWED_ROLES = ["admin", "oa", "b2b"];
const USERNAME_RE = /^[a-z0-9_]{3,20}$/;

// index.html is a static file served from disk today (file:// or a bare
// static host, confirmed by this session's own dev testing over
// http://localhost:PORT) with no fixed production origin pinned anywhere
// in this repo — unlike a same-origin API route, a browser calling this
// function cross-origin needs an explicit CORS allow, or the request
// never leaves the preflight stage (confirmed live: the first deploy of
// this function had no CORS headers at all and every browser call failed
// with a blocked-preflight error before reaching the handler).
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// profiles.username is UNIQUE (profiles_username_key) — two invitees with
// similar local-parts (e.g. j.ramie@a.com and j.ramie@b.com) would
// otherwise collide, and the person never picks their own username at
// invite time (unlike normal signup) to fix it themselves. A short random
// suffix keeps the insert collision-free without an extra existence-check
// round trip; the fixed budget below leaves room for it within the
// column's 20-char cap even for a long local-part.
function usernameFromEmail(email: string): string {
  const local = email.split("@")[0].toLowerCase().replace(/[^a-z0-9_]/g, "_");
  const suffix = "_" + Math.random().toString(36).slice(2, 6);
  const base = local.slice(0, 20 - suffix.length) || "user";
  return (base + suffix).padEnd(3, "0");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) {
    return jsonResponse({ error: "UNAUTHENTICATED" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  // Verify the caller's identity with a plain anon-key client scoped to
  // their JWT (does NOT bypass RLS) — this is the same trust boundary
  // profiles_update_admin already encodes: "an admin" means role='admin'
  // AND status='approved' in their own profiles row, re-checked here
  // rather than trusted from client-supplied input.
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data: userRes, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userRes?.user) {
    return jsonResponse({ error: "UNAUTHENTICATED" }, 401);
  }

  const { data: callerProfile, error: profileErr } = await callerClient
    .from("profiles")
    .select("role, status")
    .eq("user_id", userRes.user.id)
    .maybeSingle();
  if (profileErr) {
    return jsonResponse({ error: "PROFILE_LOOKUP_FAILED", detail: profileErr.message }, 500);
  }
  if (!callerProfile || callerProfile.role !== "admin" || callerProfile.status !== "approved") {
    return jsonResponse({ error: "FORBIDDEN", message: "Only an approved admin can invite users." }, 403);
  }

  let body: { email?: string; role?: string; redirectTo?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "INVALID_JSON" }, 400);
  }

  const email = (body.email || "").trim().toLowerCase();
  const role = body.role || "oa";
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return jsonResponse({ error: "INVALID_EMAIL" }, 400);
  }
  if (!ALLOWED_ROLES.includes(role)) {
    return jsonResponse({ error: "INVALID_ROLE" }, 400);
  }

  // Privileged client — service role, bypasses RLS. Only used for the two
  // operations that genuinely need it: inviting the auth user and
  // inserting a profiles row on someone else's behalf.
  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: inviteData, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
    email,
    body.redirectTo ? { redirectTo: body.redirectTo } : undefined,
  );
  if (inviteErr || !inviteData?.user) {
    // A duplicate invite (person already has an auth.users row) surfaces
    // here as a real Supabase Auth error — passed through rather than
    // papered over, so the admin sees exactly why it failed.
    return jsonResponse({ error: "INVITE_FAILED", detail: inviteErr?.message || "unknown error" }, 400);
  }

  const newUserId = inviteData.user.id;
  let username = usernameFromEmail(email);
  if (!USERNAME_RE.test(username)) username = "user_" + newUserId.slice(0, 8);

  const { error: insertErr } = await adminClient.from("profiles").insert({
    user_id: newUserId,
    username,
    display_name: email.split("@")[0],
    role,
    status: "pending",
  });
  if (insertErr) {
    // The auth invite already succeeded and can't be cleanly undone here
    // (deleting the auth user would also invalidate the email link
    // that's already been sent) — surfaced as a real error so the admin
    // knows to check Access Management once the person signs in; a
    // manual profiles insert or a retry of the invite email covers this
    // rare edge case rather than adding rollback complexity for it.
    return jsonResponse({
      error: "PROFILE_INSERT_FAILED",
      detail: insertErr.message,
      note: "The invite email was sent, but the profile row could not be created.",
    }, 500);
  }

  return jsonResponse({ ok: true, userId: newUserId, username, role, status: "pending" }, 200);
});
