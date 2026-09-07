// ════════════════════════════════════════════════════════════════════════
// expandi-webhook — receives one Expandi event and files it.
//
// ── Deploy notes, both of which will otherwise cost you an afternoon ──
//
// 1. VERIFY JWT MUST BE OFF, and do not wrap this in withSupabase({auth:...}).
//    Expandi can only be given a URL. It sends no Authorization header and
//    no apikey, so anything that demands one rejects every delivery with a
//    401 and Expandi reports them all as failed. The gate here is the
//    ?key= secret in the URL instead.
//      CLI:       supabase functions deploy expandi-webhook --no-verify-jwt
//      Dashboard: Edge Functions → expandi-webhook → Details →
//                 "Verify JWT with legacy secret" → off
//
// 2. SECRETS (Project Settings → Edge Functions → Secrets):
//      EXPANDI_HOOK_KEY   a long random string you invent. It goes in the
//                         webhook URL and is the only thing between this
//                         endpoint and the open internet.
//    That is the only secret you need to add. The key that lets this
//    function write to the database already comes with the project —
//    see resolveServiceKey() below, which prefers SUPABASE_SECRET_KEYS and
//    falls back to the deprecated SUPABASE_SERVICE_ROLE_KEY. The function
//    logs which one it used on startup.
//
// ── The URL to paste into Expandi, once per event per seat ──
//   https://<project>.supabase.co/functions/v1/expandi-webhook
//     ?key=<EXPANDI_HOOK_KEY>&event=connection_accepted
//
// Leave Campaign on "Any campaign". The campaign, seat, contact and tags
// all come out of the request body, which is the whole point: no
// per-campaign webhooks, ever.
//
// Why ?event= is in the URL when everything else is read from the body:
// Expandi's internal event names do not match the labels in its own UI.
// The hook created as "Connection request accepted" posts
// hook.event = "linked_in_messenger.campaign_new_contact". Taking the event
// from the URL means the mapping is set by whoever creates the hook and
// cannot drift when Expandi renames something internally.
//
// No imports on purpose: two plain POSTs to PostgREST, so there is no
// library version to go stale in a dashboard-pasted function.
// ════════════════════════════════════════════════════════════════════════

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const HOOK_KEY = Deno.env.get("EXPANDI_HOOK_KEY") ?? "";

// Finding a key that can write to the database, in the order Supabase is
// heading. This project's Default secrets list offers:
//   SUPABASE_SECRET_KEYS      the current one — a JSON dictionary of keys
//   SUPABASE_SERVICE_ROLE_KEY the legacy one, still injected but flagged
//                             DEPRECATED, so it will go away eventually
// A custom SUPABASE_SECRET_KEY is honoured first in case you ever need to
// pin one by hand. Nothing here needs adding as a secret today.
function resolveServiceKey(): { key: string; source: string } {
  const explicit = Deno.env.get("SUPABASE_SECRET_KEY");
  if (explicit) return { key: explicit, source: "SUPABASE_SECRET_KEY (custom)" };

  // The plural one is documented as a JSON dictionary, and its exact shape
  // is Supabase's to change — so take any string value that looks like a
  // secret key rather than assuming a property name.
  const dict = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (dict) {
    try {
      const parsed = JSON.parse(dict);
      const found = typeof parsed === "string"
        ? parsed
        : Object.values(parsed ?? {}).find(
            (v) => typeof v === "string" && (v.startsWith("sb_secret_") || v.startsWith("eyJ")),
          );
      if (typeof found === "string" && found) {
        return { key: found, source: "SUPABASE_SECRET_KEYS" };
      }
      console.error("SUPABASE_SECRET_KEYS was present but held no recognisable key");
    } catch {
      console.error("SUPABASE_SECRET_KEYS was present but is not valid JSON");
    }
  }

  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return { key: legacy, source: "SUPABASE_SERVICE_ROLE_KEY (deprecated)" };

  return { key: "", source: "MISSING" };
}

const { key: SERVICE_KEY, source: KEY_SOURCE } = resolveServiceKey();

console.info("expandi-webhook up", {
  url: Boolean(SUPABASE_URL),
  key_source: KEY_SOURCE,
  gate: Boolean(HOOK_KEY),
});

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

// Fallback only, for a hook created without ?event=. These are Expandi's
// own names as observed on Kyle's seat — extend the list as new ones turn
// up rather than guessing at a pattern.
const RAW_MAP: Record<string, string> = {
  "linked_in_messenger.campaign_new_contact": "connection_accepted",
  "linked_in_messenger.message_sent": "message_sent",
  "linked_in_messenger.connection_request_sent": "connection_sent",
  "linked_in_messenger.contact_replied": "replied",
  "linked_in_messenger.contact_tagged": "tagged",
  "linked_in_messenger.campaign_finished": "campaign_finished",
};

// campaign_instance has been seen under messenger. Check the other places
// it could reasonably sit rather than assuming one shape holds for every
// event type.
function findCampaign(b: Record<string, any>): string | null {
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

function num(v: unknown): number | null {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

function pgHeaders() {
  return {
    "Content-Type": "application/json",
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
  };
}

Deno.serve(async (req) => {
  if (!SUPABASE_URL || !SERVICE_KEY || !HOOK_KEY) {
    console.error("not configured — check the secrets listed at the top of this file");
    return new Response("not configured", { status: 500 });
  }

  const url = new URL(req.url);
  if (url.searchParams.get("key") !== HOOK_KEY) {
    return new Response("no", { status: 401 });
  }
  if (req.method !== "POST") {
    // Expandi's "Send test" is a POST. A GET is a person checking it is up.
    return new Response("expandi-webhook is up. It accepts POST.", { status: 405 });
  }

  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return new Response("body is not json", { status: 400 });
  }

  const rawEvent = body?.hook?.event ?? null;
  const tagged = url.searchParams.get("event");
  const event =
    (tagged && EVENTS.has(tagged) ? tagged : null) ??
    RAW_MAP[rawEvent as string] ??
    "other";

  const firedRaw = body?.hook?.fired_datetime ?? null;
  const fired = firedRaw ? new Date(String(firedRaw).replace(" ", "T")) : null;
  const campaignInstance = findCampaign(body);

  const row = {
    event,
    raw_event: rawEvent,
    campaign_instance: campaignInstance,
    seat: body?.hook?.li_account_name ?? url.searchParams.get("seat") ?? null,
    li_account: num(body?.hook?.li_account),
    contact_id: num(body?.contact?.id),
    contact_tags: Array.isArray(body?.contact?.tags) ? body.contact.tags : [],
    fired_at: fired && !isNaN(fired.valueOf()) ? fired.toISOString() : null,
    payload: body,
  };

  const ins = await fetch(`${SUPABASE_URL}/rest/v1/expandi_events`, {
    method: "POST",
    headers: { ...pgHeaders(), Prefer: "return=minimal" },
    body: JSON.stringify(row),
  });

  if (!ins.ok) {
    const detail = await ins.text();
    // 23505 = the dedupe index did its job on an Expandi retry. That is a
    // success from Expandi's side; saying otherwise makes it retry forever.
    if (ins.status === 409 || detail.includes("23505")) {
      return Response.json({ ok: true, duplicate: true, event }, { status: 200 });
    }
    console.error("insert failed", ins.status, detail);
    // A real failure gets a 500 so Expandi retries and nothing is lost.
    return Response.json({ ok: false, status: ins.status, detail }, { status: 500 });
  }

  // Roll up immediately so the app is current on its next pull. At ~150
  // events a week this is cheap; if it ever isn't, move it to a cron and
  // let this function only insert.
  const roll = await fetch(`${SUPABASE_URL}/rest/v1/rpc/refresh_expandi_metrics`, {
    method: "POST",
    headers: pgHeaders(),
    body: "{}",
  });
  if (!roll.ok) {
    // The event is stored, so this is not worth a retry — the next event,
    // or a manual call, will roll it up.
    console.error("roll-up failed (event is safely stored)", roll.status, await roll.text());
  }

  return Response.json(
    {
      ok: true,
      event,
      campaign: campaignInstance,
      linked: Boolean(campaignInstance),
      rolled_up: roll.ok,
    },
    { status: 200 },
  );
});
