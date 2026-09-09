// ════════════════════════════════════════════════════════════════════════
// hubspot-probe (pass 2) — compute the real numbers, write nothing.
//
// Pass 1 established that an email engagement carries hs_sequence_id, and
// that the funnel fields exist. This pass actually aggregates them, so the
// numbers can be eyeballed against HubSpot's own sequence screens BEFORE a
// pipeline is built on them. It is still strictly read-only: no database
// writes, no HubSpot writes.
//
// Secrets (this project's Edge Function secrets):
//   HUBSPOT_TOKEN   the private app token
//   PROBE_KEY       the gate for this throwaway function
//
// Deploy with JWT verification OFF, then open:
//   .../functions/v1/hubspot-probe?key=PROBE_KEY
//
// Optional: &pages=40 to scan more (default 25 pages x 100 = 2500 emails).
// ════════════════════════════════════════════════════════════════════════

const HOST = "api.hubapi.com";
const PAGE = 100;                  // HubSpot search maximum
const DEFAULT_PAGES = 25;

// The funnel, by the names pass 1 found on the object.
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

function tok() { return Deno.env.get("HUBSPOT_TOKEN") ?? ""; }

async function hs(path: string, body?: unknown) {
  const r = await fetch(`https://${HOST}${path}`, {
    method: body ? "POST" : "GET",
    headers: { authorization: `Bearer ${tok()}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j: any = null;
  try { j = await r.json(); } catch { /* non-JSON body */ }
  return { status: r.status, body: j };
}

function clean(m: unknown): string | undefined {
  if (!m) return undefined;
  return String(m).replace(/pat-[A-Za-z0-9-]+/g, "[redacted]").slice(0, 240);
}

const num = (v: unknown) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const gate = (Deno.env.get("PROBE_KEY") ?? "").trim();
  const sent = (url.searchParams.get("key") ?? "").trim();
  if (!gate || sent !== gate) {
    return new Response(JSON.stringify({
      error: "key did not match",
      gate_secret_present: Boolean(gate),
      gate_secret_length: gate.length,
      key_supplied_length: sent.length,
    }, null, 2), { status: 401, headers: { "content-type": "application/json" } });
  }
  if (!tok()) {
    return new Response(JSON.stringify({ error: "HUBSPOT_TOKEN not set" }, null, 2),
      { status: 500, headers: { "content-type": "application/json" } });
  }

  const maxPages = Math.min(Math.max(num(url.searchParams.get("pages")) || DEFAULT_PAGES, 1), 100);
  const out: Record<string, unknown> = { probed_at: new Date().toISOString(), host: HOST };

  // ── 1. nail down the sequences path (pass 1 got a 400, not a 403) ─────
  // A 400 meant "authorised but you sent me nonsense", so try the shapes
  // v4 might actually want.
  const seqTries = [
    "/automation/v4/sequences",
    "/automation/v4/sequences?count=5",
    "/automation/v4/sequences?after=0&count=5",
  ];
  const seqOut = [];
  for (const p of seqTries) {
    const r = await hs(p);
    const e: Record<string, unknown> = { path: p, status: r.status, note: clean(r.body?.message) };
    if (r.status === 200) {
      const rs = r.body?.results ?? [];
      e.count = rs.length;
      // Sequence names are the join key — read deliberately.
      e.names = rs.map((s: any) => ({ id: String(s.id ?? s.sequenceId ?? ""), name: s.name ?? "(unnamed)" }));
    }
    seqOut.push(e);
    if (r.status === 200) break;
  }
  out.sequences_endpoint = seqOut;

  // ── 2. every email that belongs to a sequence, aggregated ─────────────
  type Agg = {
    emails: number; outbound: number;
    sent: number; opened: number; clicked: number; replied: number; bounced: number;
    open_events: number; click_events: number; reply_events: number;
    statuses: Record<string, number>;
    first?: string; last?: string;
  };
  const per: Record<string, Agg> = {};
  const blank = (): Agg => ({
    emails: 0, outbound: 0, sent: 0, opened: 0, clicked: 0, replied: 0, bounced: 0,
    open_events: 0, click_events: 0, reply_events: 0, statuses: {},
  });

  let after: string | undefined;
  let pages = 0, scanned = 0, truncated = false;
  let searchNote: string | undefined;

  while (pages < maxPages) {
    const r = await hs("/crm/v3/objects/emails/search", {
      filterGroups: [{ filters: [{ propertyName: "hs_sequence_id", operator: "HAS_PROPERTY" }] }],
      properties: PROPS,
      limit: PAGE,
      after,
    });
    if (r.status !== 200) { searchNote = `search returned ${r.status}: ${clean(r.body?.message) ?? ""}`; break; }

    const results = r.body?.results ?? [];
    if (pages === 0) out.total_matching_in_hubspot = r.body?.total ?? null;

    for (const rec of results) {
      const p = rec.properties ?? {};
      const sid = String(p.hs_sequence_id ?? "unknown");
      const a = (per[sid] ??= blank());

      a.emails++;
      scanned++;

      const dir = String(p.hs_email_direction ?? "");
      if (/OUTGOING|EMAIL$/i.test(dir) || dir === "") a.outbound++;

      const st = String(p.hs_email_post_send_status ?? p.hs_email_status ?? "UNKNOWN");
      a.statuses[st] = (a.statuses[st] ?? 0) + 1;
      if (/SENT|DELIVERED|PROCESSED/i.test(st)) a.sent++;
      if (/BOUNC|FAIL|DROPPED|ERROR/i.test(st) || p.hs_email_bounce_error_detail_status_code) a.bounced++;

      const o = num(p.hs_email_open_count), c = num(p.hs_email_click_count), rp = num(p.hs_email_reply_count);
      if (o > 0) a.opened++;
      if (c > 0) a.clicked++;
      if (rp > 0) a.replied++;
      a.open_events += o; a.click_events += c; a.reply_events += rp;

      const ts = p.hs_timestamp ? String(p.hs_timestamp) : undefined;
      if (ts) {
        if (!a.first || ts < a.first) a.first = ts;
        if (!a.last || ts > a.last) a.last = ts;
      }
    }

    pages++;
    after = r.body?.paging?.next?.after;
    if (!after) break;
    if (pages >= maxPages) truncated = true;
    await new Promise((r) => setTimeout(r, 120));   // stay under the rate limit
  }

  out.scan = { pages, emails_scanned: scanned, truncated, note: searchNote };

  // Order by volume so the big sequences are readable first.
  out.per_sequence = Object.entries(per)
    .sort((a, b) => b[1].emails - a[1].emails)
    .map(([sequence_id, a]) => ({
      sequence_id,
      emails: a.emails,
      delivered: a.sent,
      bounced: a.bounced,
      opened_emails: a.opened,
      clicked_emails: a.clicked,
      replied_emails: a.replied,
      open_events: a.open_events,
      click_events: a.click_events,
      reply_events: a.reply_events,
      open_rate: a.sent ? +(a.opened / a.sent).toFixed(3) : null,
      click_to_open: a.opened ? +(a.clicked / a.opened).toFixed(3) : null,
      reply_rate: a.sent ? +(a.replied / a.sent).toFixed(3) : null,
      first_send: a.first,
      last_send: a.last,
      statuses: a.statuses,
    }));

  out.reading = [
    "delivered / opened_emails / clicked_emails / replied_emails count EMAILS, one per send —",
    "that is the 'unique' reading, and what a sequence report usually shows.",
    "open_events / click_events sum every open and click, so they run higher.",
    "Compare a couple of these against HubSpot's own sequence performance screen",
    "before any of it is written into the app.",
  ].join(" ");

  return new Response(JSON.stringify(out, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
