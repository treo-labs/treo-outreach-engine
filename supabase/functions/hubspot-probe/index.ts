// ════════════════════════════════════════════════════════════════════════
// hubspot-probe — a read-only reconnaissance function.
//
// Purpose: find out what this HubSpot portal will actually give us before
// any pipeline is written against it. Three open questions:
//
//   1. Which API host answers for an EU-resident portal.
//   2. Whether an email engagement record carries a sequence reference —
//      this is what decides whether per-sequence email numbers come out
//      exact or approximate.
//   3. Which sequences endpoint path exists on this account.
//
// What it returns: host, path, HTTP status, and PROPERTY NAMES only.
// It never returns property values, contact data, or the token. The one
// exception is sequence names, which are the join key we need to read.
//
// Deploy with JWT verification OFF, then open in a browser:
//   https://bejxvsxlbwpsxkkygske.supabase.co/functions/v1/hubspot-probe?key=YOUR_EXPANDI_HOOK_KEY
//
// It reuses EXPANDI_HOOK_KEY as its gate so there is no new secret to make.
// Delete this function once the real feed is built — it exists to answer
// three questions, not to stay in production.
// ════════════════════════════════════════════════════════════════════════

const HOSTS = ["api.hubapi.com", "api.eu1.hubapi.com"];

const SEQUENCE_PATHS = [
  "/automation/v4/sequences?limit=5",
  "/automation/v3/sequences?limit=5",
  "/crm/v3/objects/sequences?limit=5",
];

// Property names we care about when scanning the email object.
const INTERESTING = /sequence|open|click|repl|bounce|status|direction|timestamp|subject|thread/i;

function token(): string {
  return Deno.env.get("HUBSPOT_TOKEN") || "";
}

async function call(host: string, path: string) {
  const started = Date.now();
  try {
    const r = await fetch(`https://${host}${path}`, {
      headers: {
        authorization: `Bearer ${token()}`,
        "content-type": "application/json",
      },
    });
    let body: unknown = null;
    try {
      body = await r.json();
    } catch {
      body = null;
    }
    return { host, path, status: r.status, ms: Date.now() - started, body };
  } catch (e) {
    return {
      host,
      path,
      status: 0,
      ms: Date.now() - started,
      error: String(e && (e as Error).message || e),
      body: null,
    };
  }
}

// Reduce a HubSpot error body to something safe and useful.
function why(body: any): string | undefined {
  if (!body) return undefined;
  const m = body.message || body.error || body.status;
  if (!m) return undefined;
  // HubSpot names missing scopes in the message — that is exactly what we
  // want to see, but strip anything that looks like a credential.
  return String(m).replace(/pat-[A-Za-z0-9-]+/g, "[redacted]").slice(0, 300);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // The gate. On a mismatch, say WHICH failure it was — is the secret
  // missing from this function's environment, or is the key in the URL the
  // wrong one? Lengths only, never values: enough to tell a truncated or
  // stale paste from an absent secret, without printing either.
  const gate = Deno.env.get("EXPANDI_HOOK_KEY") ?? "";
  const sent = url.searchParams.get("key") ?? "";
  if (sent !== gate) {
    return new Response(
      JSON.stringify({
        error: "key did not match",
        gate_secret_present: Boolean(gate),
        key_supplied: Boolean(sent),
        lengths_match: sent.length === gate.length,
        hint: !gate
          ? "EXPANDI_HOOK_KEY is not visible to this function. Check it is set in this project's Edge Function secrets, then redeploy."
          : !sent
          ? "No ?key= was supplied."
          : sent.length === gate.length
          ? "Same length, different value — likely the previous key, or a character changed."
          : "Different length — likely a truncated paste, a stray space, or the placeholder text.",
      }, null, 2),
      { status: 401, headers: { "content-type": "application/json" } },
    );
  }
  if (!token()) {
    return new Response(
      JSON.stringify({ error: "HUBSPOT_TOKEN is not set in this project's secrets" }, null, 2),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const out: Record<string, unknown> = {
    probed_at: new Date().toISOString(),
    token_present: true,
    token_length: token().length, // length only — never the value
  };

  // ── 1. which host answers ────────────────────────────────────────────
  const hostChecks = [];
  for (const h of HOSTS) {
    const r = await call(h, "/crm/v3/objects/contacts?limit=1&properties=hs_object_id");
    hostChecks.push({ host: h, status: r.status, ms: r.ms, note: why(r.body) });
  }
  out.hosts = hostChecks;

  const live = hostChecks.find((h) => h.status === 200)?.host;
  out.host_in_use = live || null;
  if (!live) {
    out.verdict = "No host returned 200. Check the token was pasted whole, and that the private app is not paused.";
    return new Response(JSON.stringify(out, null, 2), {
      headers: { "content-type": "application/json" },
    });
  }

  // ── 2. the email engagement object: does it name its sequence? ───────
  const props = await call(live, "/crm/v3/properties/emails");
  const emailProps: Record<string, unknown> = { status: props.status, note: why(props.body) };
  if (props.status === 200) {
    const all = ((props.body as any)?.results || []).map((p: any) => p.name).sort();
    emailProps.total = all.length;
    emailProps.sequence_related = all.filter((n: string) => /sequence/i.test(n));
    emailProps.interesting = all.filter((n: string) => INTERESTING.test(n));
  }
  out.email_properties = emailProps;

  // What a real email record actually carries — KEYS ONLY, no values.
  const one = await call(live, "/crm/v3/objects/emails?limit=1");
  const sample: Record<string, unknown> = { status: one.status, note: why(one.body) };
  if (one.status === 200) {
    const rec = ((one.body as any)?.results || [])[0];
    sample.records_returned = ((one.body as any)?.results || []).length;
    sample.property_keys_on_record = rec ? Object.keys(rec.properties || {}).sort() : [];
  }
  out.email_record_shape = sample;

  // ── 3. which sequences path exists ───────────────────────────────────
  const seqChecks = [];
  for (const p of SEQUENCE_PATHS) {
    const r = await call(live, p);
    const entry: Record<string, unknown> = { path: p, status: r.status, note: why(r.body) };
    if (r.status === 200) {
      const results = (r.body as any)?.results || [];
      entry.count_returned = results.length;
      // Sequence names are the join key — we need to see whether they lead
      // with a campaign code, so these are read deliberately.
      entry.names = results.map((s: any) => s.name || s.properties?.hs_name || "(unnamed)");
      entry.keys_on_first = results[0] ? Object.keys(results[0]).sort() : [];
    }
    seqChecks.push(entry);
  }
  out.sequences = seqChecks;

  // ── a plain-language read of the above ───────────────────────────────
  const seqOk = seqChecks.find((s) => s.status === 200);
  const emailOk = props.status === 200;
  const hasSeqLink = Array.isArray(emailProps.sequence_related) &&
    (emailProps.sequence_related as string[]).length > 0;

  out.verdict = [
    `Host: ${live}.`,
    emailOk
      ? (hasSeqLink
        ? `Email records DO carry a sequence reference — per-sequence email numbers can be exact.`
        : `Email records carry NO sequence property — per-sequence numbers will have to be approximated.`)
      : `Email properties unreadable (${props.status}) — the sales-email-read scope may not have been granted.`,
    seqOk
      ? `Sequences readable at ${seqOk.path}.`
      : `No sequences path returned 200 — check the automation.sequences.read scope.`,
  ].join(" ");

  return new Response(JSON.stringify(out, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
