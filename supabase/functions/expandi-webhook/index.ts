// ════════════════════════════════════════════════════════════════════════
// expandi-webhook — receives one Expandi event and files it.
//
// Deploy with JWT verification OFF. Expandi can only be given a URL; it
// cannot send an Authorization header, so a verified function would reject
// every delivery with a 401 and Expandi would show "failed" for all of them.
//   supabase functions deploy expandi-webhook --no-verify-jwt
// or in the dashboard: Edge Functions → expandi-webhook → Details →
// "Verify JWT with legacy secret" → off.
//
// Secrets it needs (Project Settings → Edge Functions → Secrets):
//   EXPANDI_HOOK_KEY   a long random string you invent. It goes in the
//                      webhook URL and is the only thing standing between
//                      this endpoint and the open internet.
//   SUPABASE_URL       already provided by the platform
//   SUPABASE_SERVICE_ROLE_KEY  already provided by the platform
//
// The URL to paste into Expandi, once per event per seat:
//   https://<project>.supabase.co/functions/v1/expandi-webhook
//     ?key=<EXPANDI_HOOK_KEY>&event=connection_accepted
//
// Why ?event= is in the URL when everything else comes from the body:
// Expandi's internal event names do not match the labels in its own UI —
// the hook created as "Connection request accepted" posts
// hook.event = "linked_in_messenger.campaign_new_contact". Reading the
// event off the URL means the mapping is set by whoever creates the hook
// and cannot drift when Expandi renames something internally. The campaign,
// seat, contact and tags all come from the body, which is the whole point:
// no per-campaign webhooks.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const EVENTS = new Set([
  "contact_added",
  "connection_sent",
  "connection_accepted",
  "replied",
  "message_sent",
  "tagged",
  "campaign_finished",
  "seat_idle",
]);

// Fallback only, for a hook created without ?event=. Expandi's names, as
// observed on Kyle's seat — extend as new ones show up rather than
// guessing at a pattern.
const RAW_MAP: Record<string, string> = {
  "linked_in_messenger.campaign_new_contact": "connection_accepted",
  "linked_in_messenger.message_sent": "message_sent",
  "linked_in_messenger.connection_request_sent": "connection_sent",
  "linked_in_messenger.contact_replied": "replied",
  "linked_in_messenger.contact_tagged": "tagged",
  "linked_in_messenger.campaign_finished": "campaign_finished",
};

// campaign_instance has been seen under messenger; check the other places
// it could reasonably sit rather than assuming one shape holds for every
// event type.
function findCampaign(b: any): string | null {
  const paths = [
    b?.messenger?.campaign_instance,
    b?.campaign_instance,
    b?.campaign?.name,
    b?.campaign_instance_contact?.campaign_instance,
    b?.connector?.campaign_instance,
  ];
  for (const p of paths) if (typeof p === "string" && p.trim()) return p.trim();
  return null;
}

function firstNumber(...vals: unknown[]): number | null {
  for (const v of vals) {
    const n = typeof v === "string" ? Number(v) : v;
    if (typeof n === "number" && Number.isFinite(n)) return n;
  }
  return null;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // ── the gate ──────────────────────────────────────────────────────────
  const expected = Deno.env.get("EXPANDI_HOOK_KEY") ?? "";
  if (!expected) {
    console.error("EXPANDI_HOOK_KEY is not set — refusing every delivery");
    return new Response("not configured", { status: 500 });
  }
  if (url.searchParams.get("key") !== expected) {
    return new Response("no", { status: 401 });
  }
  if (req.method !== "POST") {
    // Expandi's "Send test" is a POST. A GET here is a person in a browser.
    return new Response("expandi-webhook is up. It accepts POST.", { status: 405 });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response("body is not json", { status: 400 });
  }

  const rawEvent = body?.hook?.event ?? null;
  const tagged = url.searchParams.get("event");
  const event = (tagged && EVENTS.has(tagged) ? tagged : null)
    ?? RAW_MAP[rawEvent as string]
    ?? "other";

  const campaignInstance = findCampaign(body);
  const contactId = firstNumber(body?.contact?.id);
  const tags = Array.isArray(body?.contact?.tags) ? body.contact.tags : [];
  const firedRaw = body?.hook?.fired_datetime ?? null;
  const firedAt = firedRaw ? new Date(String(firedRaw).replace(" ", "T")) : null;

  const row = {
    event,
    raw_event: rawEvent,
    campaign_instance: campaignInstance,
    seat: body?.hook?.li_account_name ?? url.searchParams.get("seat") ?? null,
    li_account: firstNumber(body?.hook?.li_account),
    contact_id: contactId,
    contact_tags: tags,
    fired_at: firedAt && !isNaN(firedAt.valueOf()) ? firedAt.toISOString() : null,
    payload: body,
  };

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { error } = await db.from("expandi_events").insert(row);

  if (error) {
    // 23505 = the dedupe index did its job on a retry. That is a success
    // from Expandi's point of view; telling it otherwise makes it retry
    // forever.
    if (error.code === "23505") {
      return Response.json({ ok: true, duplicate: true, event }, { status: 200 });
    }
    console.error("insert failed", { code: error.code, message: error.message, event });
    // A real failure gets a 500 so Expandi retries and the event is not lost.
    return Response.json({ ok: false, error: error.message }, { status: 500 });
  }

  // Roll up straight away so the app is current on its next pull. At Treo's
  // volume (~150 events a week) this is cheap; if it ever isn't, move it to
  // a scheduled cron and have this function only insert.
  const { error: rollError } = await db.rpc("refresh_expandi_metrics");
  if (rollError) {
    // The event is safely stored, so this is not worth a retry — the next
    // event, or a manual call, will roll it up.
    console.error("roll-up failed (event is stored)", rollError.message);
  }

  return Response.json({
    ok: true,
    event,
    campaign: campaignInstance,
    linked: Boolean(campaignInstance),
    rolled_up: !rollError,
  }, { status: 200 });
});
