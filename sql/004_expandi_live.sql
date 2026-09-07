-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 004: live Expandi numbers
--
-- Run this ONCE, after 001, 002 and 003. Do not re-run any of those.
-- Click once in the editor, Ctrl-A, paste, Run. Highlighting part of the
-- text runs only that part — the usual cause of a half-built table.
--
-- What this is for: the History tab currently waits for a folder with an
-- export in it. Expandi already knows these numbers and will post every
-- event as it happens. This stores those events and rolls them up into
-- campaign_metrics, which the app already reads — so the numbers appear
-- with no change to index.html.
--
-- Two things it is careful about:
--
--   1. A hand-typed number always wins. The roll-up only ever writes rows
--      with is_manual = false, and the app's eff() prefers manual. Nothing
--      you typed off a screenshot is at risk.
--
--   2. Webhooks cannot backfill. EX-01, EX-02, EX-04 and EX-09 have been
--      running since late August; events that already fired are gone. So
--      expandi_baseline holds the totals as they stand the day you switch
--      the hooks on, and the roll-up adds live events on top of it. Without
--      a baseline row a campaign simply counts from switch-on, which is
--      correct for anything launching later.
--
-- Verification queries are at the bottom.
-- ════════════════════════════════════════════════════════════════════════

-- ── the raw event log ──────────────────────────────────────────────────
-- Kept verbatim, one row per delivery, because a rolled-up number nobody
-- can trace back is exactly what this app exists to avoid. payload is the
-- whole body as Expandi sent it.
create table if not exists expandi_events (
  id            bigserial primary key,
  received_at   timestamptz not null default now(),

  -- normalised event name: contact_added | connection_sent |
  -- connection_accepted | replied | message_sent | tagged |
  -- campaign_finished | seat_idle | other
  event         text not null,
  raw_event     text,                    -- hook.event, verbatim

  -- "EX-04 · Webinar Invite: Traffic Management", straight from the body.
  campaign_instance text,

  -- The join. Expandi campaign names start with the same code this app
  -- keys on, so the link is free: EX-04, EX-06b, HS-05a, PRE-01, PW-02.
  -- Null when a campaign was named without one — those show up in the
  -- unlinked view below rather than being silently dropped.
  campaign_code text generated always as (
    substring(campaign_instance from '^[[:space:]]*([A-Za-z]{2,4}-[0-9]+[a-z]?)')
  ) stored,

  seat          text,                    -- hook.li_account_name
  li_account    bigint,
  contact_id    bigint,
  contact_tags  jsonb not null default '[]'::jsonb,
  fired_at      timestamptz,
  payload       jsonb not null
);

-- Expandi retries a failed delivery, and a retry is the same event. Two
-- rows for one thing would inflate every count, so the same event fired at
-- the same instant for the same contact can only land once. NULLS NOT
-- DISTINCT matters: without it Postgres treats null contact_id as unique
-- and account-level alerts would duplicate freely.
create unique index if not exists expandi_events_dedupe
  on expandi_events (raw_event, contact_id, fired_at) nulls not distinct;

create index if not exists expandi_events_code_idx  on expandi_events (campaign_code, event);
create index if not exists expandi_events_fired_idx on expandi_events (fired_at desc);

-- ── the pre-webhook baseline ───────────────────────────────────────────
-- One row per campaign per metric, read off Expandi's own campaign list on
-- the day the hooks go live. source is not decoration: it is how a reader
-- checks the number.
create table if not exists expandi_baseline (
  campaign_code text not null references campaigns (code)
                  on update cascade on delete cascade,
  metric_key    text not null check (metric_key in
                  ('list','invites','accepted','msgs','replies')),
  value         numeric not null check (value >= 0),
  as_of         timestamptz not null,
  source        text not null default '',
  updated_at    timestamptz not null default now(),
  primary key (campaign_code, metric_key)
);

comment on table expandi_baseline is
  'Campaign totals as at as_of, before webhooks existed. The roll-up adds events fired after as_of on top of these.';

-- ── the roll-up ────────────────────────────────────────────────────────
-- Counts distinct contacts, not events: Expandi can fire connection_sent
-- twice for one person across a re-run, and a person is one invite.
create or replace view v_expandi_live as
with counted as (
  select e.campaign_code as code,
         e.event,
         count(distinct e.contact_id) filter (
           where b.as_of is null or e.fired_at > b.as_of
         ) as n,
         max(e.fired_at) as last_at
  from expandi_events e
  left join expandi_baseline b
         on b.campaign_code = e.campaign_code
        and b.metric_key = case e.event
              when 'contact_added'       then 'list'
              when 'connection_sent'     then 'invites'
              when 'connection_accepted' then 'accepted'
              when 'message_sent'        then 'msgs'
              when 'replied'             then 'replies' end
  where e.campaign_code is not null
    and e.contact_id is not null
  group by 1, 2
),
mapped as (
  select code,
         case event
           when 'contact_added'       then 'list'
           when 'connection_sent'     then 'invites'
           when 'connection_accepted' then 'accepted'
           when 'message_sent'        then 'msgs'
           when 'replied'             then 'replies' end as metric_key,
         n, last_at
  from counted
)
select coalesce(m.code, b.campaign_code)      as campaign_code,
       coalesce(m.metric_key, b.metric_key)   as metric_key,
       coalesce(b.value, 0) + coalesce(m.n,0) as value,
       b.value                                as baseline_value,
       b.as_of                                as baseline_as_of,
       coalesce(m.n, 0)                       as live_events,
       m.last_at                              as last_event_at
from mapped m
full outer join expandi_baseline b
  on b.campaign_code = m.code and b.metric_key = m.metric_key
where coalesce(m.metric_key, b.metric_key) is not null;

comment on view v_expandi_live is
  'Per campaign per metric: baseline + live events, with both halves shown so any total can be taken apart.';

-- Campaign names Expandi sent that carry no code this app recognises.
-- Absence of a link is information — it is rendered, not hidden.
create or replace view v_expandi_unlinked as
select e.campaign_instance,
       e.campaign_code,
       (e.campaign_code is null) as no_code_in_name,
       (e.campaign_code is not null
         and not exists (select 1 from campaigns c where c.code = e.campaign_code))
         as code_not_in_plan,
       count(*)          as events,
       min(e.fired_at)   as first_seen,
       max(e.fired_at)   as last_seen
from expandi_events e
where e.campaign_code is null
   or not exists (select 1 from campaigns c where c.code = e.campaign_code)
group by 1, 2
order by max(e.fired_at) desc;

-- ── write the roll-up into the tables the app already reads ────────────
-- campaign_results gets a row per campaign (result_key = the code, which is
-- what index.html:1399 builds for a linked campaign), then campaign_metrics
-- gets the numbers with is_manual = false.
create or replace function refresh_expandi_metrics()
returns table (campaign_code text, metrics_written int)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  -- A result row must exist before metrics can hang off it. Only for codes
  -- that are actually in the plan; anything else stays in v_expandi_unlinked
  -- until someone decides what it is.
  insert into campaign_results (result_key, campaign_code, folder, label, last_sync, updated_by)
  select c.code, c.code, '', c.name, now(), 'expandi-live'
  from campaigns c
  where not c.is_deleted
    and exists (select 1 from v_expandi_live l where l.campaign_code = c.code)
  on conflict (result_key) do update
    set campaign_code = excluded.campaign_code,
        last_sync     = now(),
        updated_at    = now()
    where campaign_results.is_deleted = false;

  -- The numbers. A manual row is left exactly where it is.
  insert into campaign_metrics (result_key, metric_key, value, source, is_manual, updated_at)
  select l.campaign_code,
         l.metric_key,
         l.value,
         case when l.baseline_as_of is null
              then 'Expandi live · ' || to_char(now(), 'DD Mon HH24:MI')
              else 'Expandi live · ' || to_char(now(), 'DD Mon HH24:MI')
                   || ' (baseline ' || l.baseline_value::text
                   || ' as at ' || to_char(l.baseline_as_of, 'DD Mon') || ' + '
                   || l.live_events::text || ' since)' end,
         false,
         now()
  from v_expandi_live l
  where exists (select 1 from campaigns c where c.code = l.campaign_code and not c.is_deleted)
  on conflict (result_key, metric_key) do update
    set value      = excluded.value,
        source     = excluded.source,
        updated_at = now()
    where campaign_metrics.is_manual = false;

  return query
    select l.campaign_code, count(*)::int
    from v_expandi_live l
    where exists (select 1 from campaigns c where c.code = l.campaign_code and not c.is_deleted)
    group by l.campaign_code
    order by l.campaign_code;
end;
$fn$;

comment on function refresh_expandi_metrics() is
  'Rolls expandi_events + expandi_baseline into campaign_results/campaign_metrics. Never touches a row with is_manual = true.';

revoke all on function refresh_expandi_metrics() from public;
grant execute on function refresh_expandi_metrics() to authenticated, service_role;

-- ── RLS, same rule as every other table ────────────────────────────────
-- The webhook writes with the service role, which bypasses RLS. Staff can
-- read the log to check a number; nobody else sees anything.
alter table expandi_events   enable row level security;
alter table expandi_baseline enable row level security;

drop policy if exists staff_read   on expandi_events;
drop policy if exists staff_insert on expandi_events;
drop policy if exists staff_delete on expandi_events;
create policy staff_read   on expandi_events for select to authenticated using (is_treo_staff());
create policy staff_insert on expandi_events for insert to authenticated with check (is_treo_staff());
create policy staff_delete on expandi_events for delete to authenticated using (is_treo_staff());

drop policy if exists staff_read   on expandi_baseline;
drop policy if exists staff_insert on expandi_baseline;
drop policy if exists staff_update on expandi_baseline;
drop policy if exists staff_delete on expandi_baseline;
create policy staff_read   on expandi_baseline for select to authenticated using (is_treo_staff());
create policy staff_insert on expandi_baseline for insert to authenticated with check (is_treo_staff());
create policy staff_update on expandi_baseline for update to authenticated using (is_treo_staff()) with check (is_treo_staff());
create policy staff_delete on expandi_baseline for delete to authenticated using (is_treo_staff());

-- ════════════════════════════════════════════════════════════════════════
-- VERIFICATION — run these separately, in order.
--
-- (a) The two tables exist and are protected.
--     Expect 2 rows, rls_enabled = true, policies 3 and 4.
-- ════════════════════════════════════════════════════════════════════════
-- select c.relname as table_name, c.relrowsecurity as rls_enabled,
--        (select count(*) from pg_policies p where p.tablename = c.relname) as policies
-- from pg_class c join pg_namespace n on n.oid = c.relnamespace
-- where n.nspname = 'public'
--   and c.relname in ('expandi_events','expandi_baseline') order by 1;
--
-- (b) The code comes out of a campaign name correctly.
--     Expect: EX-04, EX-06b, HS-05a, PRE-01, PW-02, and one null.
-- ════════════════════════════════════════════════════════════════════════
-- select n, substring(n from '^[[:space:]]*([A-Za-z]{2,4}-[0-9]+[a-z]?)') as code
-- from (values ('EX-04 · Webinar Invite: Traffic Management'),
--              ('EX-06b ISO 45001 Webinar — General Safety Audience'),
--              ('HS-05a Opted-in Safety DB'),
--              ('PRE-01 · Pre-Webinar Reminder: METSIM Model Audits'),
--              ('PW-02 Post-Webinar: Traffic Management'),
--              ('Metaltech connect campaign')) v(n);
--
-- (c) After the first events arrive: what came in, and what it rolled into.
-- ════════════════════════════════════════════════════════════════════════
-- select campaign_code, event, count(*) from expandi_events group by 1,2 order by 1,2;
-- select * from v_expandi_live order by campaign_code, metric_key;
-- select * from refresh_expandi_metrics();
--
-- (d) Anything Expandi sent that this app could not place. Empty is good;
--     rows here mean a campaign was renamed or launched without its code.
-- ════════════════════════════════════════════════════════════════════════
-- select * from v_expandi_unlinked;
