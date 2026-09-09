// ════════════════════════════════════════════════════════════════════════
// hubspot-sync — pull HubSpot sequence emails in, then roll them up.
//
// Runs on a schedule. Each run re-reads the full history from HubSpot and
// upserts by HubSpot's own email id, so it is idempotent and self-healing:
// running it twice changes nothing, a missed run costs nothing, and a
// correction made in HubSpot lands on the next pass. That is the advantage
// HubSpot has over the Expandi webhooks, which can only ever report what
// happened while they were switched on.
//
// Secrets needed (this project's Edge Function secrets):
//   HUBSPOT_TOKEN   the private app token
//   SYNC_KEY        the gate for this endpoint — invent one
//   the Supabase service key is picked up automatically, as in
//   expandi-webhook
//
// Deploy with JWT verification OFF, then:
//   .../functions/v1/hubspot-sync?key=SYNC_KEY
//
// Optional: &pages=100 to scan deeper than the default.
// ════════════════════════════════════════════════════════════════════════

const HOST = "api.hubapi.com";
const PAGE = 100;                 // HubSpot search maximum
const DEFAULT_PAGES = 60;         // 6000 emails — plenty of headroom
const CHUNK = 250;                // rows per upsert request

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

const PROPS = [
  "hs_sequence_id",
  "hs_timestamp",
  "hs_email_direction",
  "hs_email_status",
  "hs_email_post_send_status",
  "hs_email_open_count",
  "hs_email_click_count",
  "hs_email_reply_count",
  "hs_email_bounce_error_detail_status_code",
];

// Same key resolution as expandi-webhook: the current secret-keys format
// first, then the deprecated service-role variable that is still injected.
function resolveServiceKey(): { key: string; source: string } {
  const explicit = Deno.env.get("SUPABASE_SECRET_KEY");
  if (explicit) return { key: explicit, source: "SUPABASE_SECRET_KEY" };

  const dict = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (dict) {
    try {
      const parsed = JSON.parse(dict);
      for (const v of Object.values(parsed)) {
        const s = String(v);
        if (s.startsWith("sb_secret_") || s.startsWith("eyJ")) {
          return { key: s, source: "SUPABASE_SECRET_KEYS" };
        }
      }
    } catch { /* not JSON — fall through */ }
  }

  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return { key: legacy, source: "SUPABASE_SERVICE_ROLE_KEY (deprecated)" };

  return { key: "", source: "MISSING" };
}

const num = (v: unknown) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

const idOrNull = (v: unknown) => {
  const s = String(v ?? "").trim();
  return /^\d+$/.test(s) ? s : null;
};

function clean(m: unknown): string | undefined {
  if (!m) return undefined;
  return String(m).replace(/pat-[A-Za-z0-9-]+/g, "[redacted]").slice(0, 240);
}

async function hubspot(path: string, body?: unknown) {
  const r = await fetch(`https://${HOST}${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      authorization: `Bearer ${Deno.env.get("HUBSPOT_TOKEN") ?? ""}`,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j: any = null;
  try { j = await r.json(); } catch { /* non-JSON */ }
  return { status: r.status, body: j };
}

async function supa(path: string, init: RequestInit, key: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    ...init,
    headers: {
      apikey: key,
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const text = await r.text();
  return { status: r.status, text: text.slice(0, 500) };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Trimmed both sides — a secret pasted into a dashboard field very often
  // carries a trailing newline, and that is not worth debugging twice.
  const gate = (Deno.env.get("SYNC_KEY") ?? "").trim();
  const sent = (url.searchParams.get("key") ?? "").trim();
  if (!gate || sent !== gate) {
    return new Response(JSON.stringify({
      error: "key did not match",
      gate_secret_present: Boolean(gate),
      gate_secret_length: gate.length,
      key_supplied_length: sent.length,
    }, null, 2), { status: 401, headers: { "content-type": "application/json" } });
  }

  const svc = resolveServiceKey();
  const out: Record<string, unknown> = {
    ran_at: new Date().toISOString(),
    service_key_source: svc.source,
  };

  if (!Deno.env.get("HUBSPOT_TOKEN")) {
    out.error = "HUBSPOT_TOKEN is not set in this project's secrets";
    return new Response(JSON.stringify(out, null, 2),
      { status: 500, headers: { "content-type": "application/json" } });
  }
  if (!svc.key || !SUPABASE_URL) {
    out.error = "no Supabase service key available to this function";
    return new Response(JSON.stringify(out, null, 2),
      { status: 500, headers: { "content-type": "application/json" } });
  }

  const maxPages = Math.min(Math.max(num(url.searchParams.get("pages")) || DEFAULT_PAGES, 1), 200);

  // ── pull every email that belongs to a sequence ──────────────────────
  const rows: Record<string, unknown>[] = [];
  let after: string | undefined;
  let pages = 0, truncated = false;

  while (pages < maxPages) {
    const r = await hubspot("/crm/v3/objects/emails/search", {
      filterGroups: [{ filters: [{ propertyName: "hs_sequence_id", operator: "HAS_PROPERTY" }] }],
      properties: PROPS,
      limit: PAGE,
      after,
    });

    if (r.status !== 200) {
      out.hubspot_error = `search returned ${r.status}: ${clean(r.body?.message) ?? ""}`;
      break;
    }
    if (pages === 0) out.total_in_hubspot = r.body?.total ?? null;

    for (const rec of (r.body?.results ?? [])) {
      const p = rec.properties ?? {};
      rows.push({
        hs_id: rec.id,
        sequence_id: idOrNull(p.hs_sequence_id),
        sent_at: p.hs_timestamp ?? null,
        direction: p.hs_email_direction ?? null,
        status: p.hs_email_post_send_status ?? p.hs_email_status ?? null,
        open_count: num(p.hs_email_open_count),
        click_count: num(p.hs_email_click_count),
        reply_count: num(p.hs_email_reply_count),
        bounce_code: p.hs_email_bounce_error_detail_status_code ?? null,
        synced_at: new Date().toISOString(),
        payload: p,
      });
    }

    pages++;
    after = r.body?.paging?.next?.after;
    if (!after) break;
    if (pages >= maxPages) truncated = true;
    await new Promise((res) => setTimeout(res, 120));   // stay under the rate limit
  }

  out.scan = { pages, emails_read: rows.length, truncated };

  // ── upsert, in chunks ────────────────────────────────────────────────
  let written = 0;
  const writeErrors: string[] = [];
  for (let i = 0; i < rows.length; i += CHUNK) {
    const slice = rows.slice(i, i + CHUNK);
    const r = await supa("/hubspot_email_events?on_conflict=hs_id", {
      method: "POST",
      body: JSON.stringify(slice),
      headers: { prefer: "resolution=merge-duplicates,return=minimal" },
    }, svc.key);
    if (r.status >= 300) writeErrors.push(`rows ${i}-${i + slice.length}: ${r.status} ${r.text}`);
    else written += slice.length;
  }
  out.upserted = written;
  if (writeErrors.length) out.write_errors = writeErrors.slice(0, 5);

  // ── roll up into campaign_metrics ────────────────────────────────────
  const roll = await supa("/rpc/refresh_hubspot_metrics", { method: "POST", body: "{}" }, svc.key);
  out.rollup = { status: roll.status, result: roll.text };

  // ── anything that could not be placed ────────────────────────────────
  const un = await supa("/v_hubspot_unmapped?select=sequence_id,name,emails", { method: "GET" }, svc.key);
  out.unmapped = { status: un.status, rows: un.text };

  return new Response(JSON.stringify(out, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
