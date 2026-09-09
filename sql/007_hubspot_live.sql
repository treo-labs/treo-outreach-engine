-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 007: live HubSpot email numbers
--
-- Run this ONCE, after 004, 005 and 006. Click once in the editor,
-- Ctrl-A, paste, Run. Highlighting part of the text runs only that part.
--
-- What this is for: the email half of the plan. HubSpot sequences send the
-- emails; each send is an email engagement record carrying hs_sequence_id
-- and its own open, click and reply counts. The hubspot-sync edge function
-- pulls those records in, this file rolls them up into campaign_metrics,
-- and the app reads them with no change to index.html — exactly how the
-- Expandi side works.
--
-- Two differences from Expandi, both in our favour:
--
--   1. No baselines needed. Webhooks cannot backfill, which is why 005
--      exists. HubSpot keeps the full history and hands it over on every
--      run, so the numbers are recomputed from scratch and self-heal.
--
--   2. The join is a lookup, not a name prefix. An email record names its
--      sequence by id, so hubspot_sequences maps id → campaign code. Any
--      sequence whose name starts with a code is matched automatically;
--      the rest are mapped by hand below.
--
-- What this file does NOT write: bounces and unsubscribes. The bounce
-- field on an email record turned out to carry SMTP status codes, and a
-- 250 means delivered, not bounced — so counting them would have put a
-- wrong number in the dashboard. The raw value is stored for later.
--
-- Verification queries are at the bottom.
-- ════════════════════════════════════════════════════════════════════════


-- ── the sequence → campaign map ─────────────────────────────────────────
-- One row per HubSpot sequence. campaign_code null means "seen, not
-- mapped" — those show up in v_hubspot_unmapped rather than vanishing.
create table if not exists hubspot_sequences (
  sequence_id   bigint primary key,
  name          text not null,
  campaign_code text references campaigns (code) on update cascade on delete set null,
  note          text not null default '',
  updated_at    timestamptz not null default now()
);

alter table hubspot_sequences enable row level security;
drop policy if exists hubspot_sequences_read  on hubspot_sequences;
drop policy if exists hubspot_sequences_write on hubspot_sequences;
create policy hubspot_sequences_read  on hubspot_sequences for select using (is_treo_staff());
create policy hubspot_sequences_write on hubspot_sequences for all    using (is_treo_staff());


-- ── the raw email log ──────────────────────────────────────────────────
-- One row per email engagement, keyed by HubSpot's own id so a re-run
-- updates rather than duplicates. Kept verbatim for the same reason the
-- Expandi event log is: a rolled-up number nobody can trace back is what
-- this app exists to avoid.
create table if not exists hubspot_email_events (
  hs_id        bigint primary key,
  sequence_id  bigint,
  sent_at      timestamptz,
  direction    text,
  status       text,
  open_count   int  not null default 0,
  click_count  int  not null default 0,
  reply_count  int  not null default 0,
  bounce_code  text,                       -- stored, deliberately not counted
  synced_at    timestamptz not null default now(),
  payload      jsonb not null default '{}'::jsonb
);

create index if not exists hs_events_seq_idx  on hubspot_email_events (sequence_id);
create index if not exists hs_events_sent_idx on hubspot_email_events (sent_at);

alter table hubspot_email_events enable row level security;
drop policy if exists hs_events_read  on hubspot_email_events;
drop policy if exists hs_events_write on hubspot_email_events;
create policy hs_events_read  on hubspot_email_events for select using (is_treo_staff());
create policy hs_events_write on hubspot_email_events for all    using (is_treo_staff());


-- ── the roll-up view ───────────────────────────────────────────────────
-- delivered / opens / clicks / replies count EMAILS, one per send — the
-- unique reading. Summing every open event instead would have reported
-- 100 opens on a 7-email sequence, which is tracking-pixel noise, not
-- performance.
create or replace view v_hubspot_live as
with agg as (
  select s.campaign_code,
         count(*)                                                        as emails,
         count(*) filter (where e.status ~* 'SENT|DELIVERED|PROCESSED')  as delivered,
         count(*) filter (where e.open_count  > 0)                       as opens,
         count(*) filter (where e.click_count > 0)                       as clicks,
         count(*) filter (where e.reply_count > 0)                       as replies,
         max(e.sent_at)                                                  as last_send
  from hubspot_email_events e
  join hubspot_sequences s on s.sequence_id = e.sequence_id
  where s.campaign_code is not null
  group by s.campaign_code
)
select a.campaign_code,
       m.metric_key,
       m.value,
       'HubSpot live — ' || a.emails || ' email' || case when a.emails = 1 then '' else 's' end
         || ', to ' || coalesce(to_char(a.last_send, 'DD Mon YYYY'), 'unknown') as source
from agg a
cross join lateral (values
  ('delivered', a.delivered),
  ('opens',     a.opens),
  ('clicks',    a.clicks),
  ('replies',   a.replies)
) as m(metric_key, value)
where m.value is not null;


-- ── anything HubSpot sent that we could not place ──────────────────────
-- Empty is good. A row here means a sequence has traffic but no mapping,
-- so its numbers are sitting in the database going nowhere.
create or replace view v_hubspot_unmapped as
select e.sequence_id,
       coalesce(s.name, '(unknown sequence)') as name,
       count(*)          as emails,
       min(e.sent_at)    as first_send,
       max(e.sent_at)    as last_send
from hubspot_email_events e
left join hubspot_sequences s on s.sequence_id = e.sequence_id
where s.campaign_code is null
group by e.sequence_id, s.name
order by count(*) desc;


-- ── the roll-up ────────────────────────────────────────────────────────
-- Same contract as refresh_expandi_metrics: writes only is_manual = false
-- rows, and the where clause means a hand-typed number is never touched.
create or replace function refresh_hubspot_metrics()
returns table (campaign_code text, metrics_written int)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- a results row for every campaign that has live email numbers,
  -- without disturbing folder or label on one that already exists
  insert into campaign_results (result_key, campaign_code, folder, label, last_sync, updated_by)
  select c.code, c.code, '', c.name, now(), 'hubspot-live'
  from campaigns c
  where not c.is_deleted
    and exists (select 1 from v_hubspot_live l where l.campaign_code = c.code)
  on conflict (result_key) do update
    set campaign_code = excluded.campaign_code,
        last_sync     = now(),
        updated_at    = now()
    where campaign_results.is_deleted = false;

  insert into campaign_metrics (result_key, metric_key, value, source, is_manual, updated_at)
  select l.campaign_code, l.metric_key, l.value, l.source, false, now()
  from v_hubspot_live l
  where exists (select 1 from campaign_results r where r.result_key = l.campaign_code)
  on conflict (result_key, metric_key) do update
    set value      = excluded.value,
        source     = excluded.source,
        updated_at = now()
    where campaign_metrics.is_manual = false;

  return query
    select l.campaign_code, count(*)::int
    from v_hubspot_live l
    group by l.campaign_code
    order by l.campaign_code;
end;
$$;


-- ── the nine campaigns these sequences represent ───────────────────────
-- Created here rather than in the app because the app adopts campaigns it
-- finds in Supabase on a pull, and typing nine records by hand is worse.
-- steps = 1 because the real step count is not in the API; correct it in
-- the app if you care. Dates are the first and last send seen in HubSpot.
insert into campaigns (code, name, brand, channel, act, btag, aud, src, steps,
                       cta, build_date, launch_date, end_date, status, note, updated_by)
values
 ('BAU-01','METSIM Software Information — Initial Outreach','METSIM','HubSpot','EMAIL','METSIM',
  'METSIM software enquiries and target contacts','HubSpot sequence 589668539',1,
  'Send METSIM software information',null,'2025-11-03','2026-09-01','Ended',
  'Ongoing account work, not part of the Q3–Q4 plan. Recorded here so the numbers exist somewhere. Ran Nov 2025 – Sep 2026.','007-hubspot'),

 ('BAU-02','METSIM Licence Renewal — Expired Licences','METSIM','HubSpot','EMAIL','METSIM',
  'Lapsed METSIM licence holders','HubSpot sequence 517183706',1,
  'Renew the licence',null,'2025-08-26','2025-09-08','Ended',
  'Ongoing account work. The same audience the parked HS-06 was written for — worth comparing before HS-06 is ever unparked.','007-hubspot'),

 ('BAU-03','METSIM — Quick Check-in','METSIM','HubSpot','EMAIL','METSIM',
  'METSIM contacts with no recent activity','HubSpot sequence 644403418',1,
  'Reopen the conversation',null,'2025-12-09','2025-12-12','Ended',
  'Ongoing account work. Worst performer of the nine — 17% open against a 40% benchmark. Worth reading before anything like it is sent again.','007-hubspot'),

 ('BAU-04','Deal Follow-ups (METSIM)','METSIM','HubSpot','EMAIL','METSIM',
  'Open METSIM deals awaiting a decision','HubSpot sequence 598616257',1,
  'Move the deal forward',null,'2025-11-10','2026-06-24','Ended',
  'Ongoing account work. Best reply rate of the nine at 47%, which is what a warm audience with a real deal attached looks like.','007-hubspot'),

 ('BAU-05','Re-engage Closed-Lost Deals (METSIM)','METSIM','HubSpot','EMAIL','METSIM',
  'Closed-lost METSIM deals','HubSpot sequence 844586192',1,
  'Reopen a scoping conversation',null,'2026-08-13','2026-08-20','Ended',
  'Ongoing account work. The email counterpart of EX-10 Closed-Lost Revival — compare the two when EX-10 has run.','007-hubspot'),

 ('BAU-06','Re-engage (METSIM Follow-ups)','METSIM','HubSpot','EMAIL','METSIM',
  'METSIM contacts gone quiet','HubSpot sequence 598109409',1,
  'Reopen the conversation',null,'2025-11-10','2025-11-10','Ended',
  'Ongoing account work. Sent in a single day, Nov 2025.','007-hubspot'),

 ('BAU-07','METSIM Licence Renewal — Upcoming','METSIM','HubSpot','EMAIL','METSIM',
  'METSIM licences approaching expiry','HubSpot sequence 519235806',1,
  'Renew before expiry',null,'2025-08-28','2025-09-02','Ended',
  'Ongoing account work. Seven emails carrying 100 recorded open events — the clearest example in the data of why unique opens are the number and raw open events are noise.','007-hubspot'),

 ('BAU-08','Webinar (METSIM)','METSIM','HubSpot','EMAIL','METSIM',
  'METSIM webinar audience','HubSpot sequence 813276358',1,
  'Register for the session',null,'2026-05-19','2026-05-29','Ended',
  'Ongoing account work. Named only "Webinar" in HubSpot, so which session it belongs to is a guess — worth renaming there.','007-hubspot')

on conflict (code) do nothing;


-- ── the mapping itself ─────────────────────────────────────────────────
insert into hubspot_sequences (sequence_id, name, campaign_code, note) values
 (589668539,'METSIM Software Information - Initial Outreach','BAU-01',''),
 (517183706,'Metsim License Renewal (Expired Licenses)','BAU-02',''),
 (644403418,'METSIM | Quick check-in','BAU-03',''),
 (598616257,'Deal Follow-ups (METSIM)','BAU-04',''),
 (844586192,'Re-engage Closed-Lost Deals (METSIM)','BAU-05',''),
 (598109409,'Re-engage (METSIM Follow-ups)','BAU-06',''),
 (519235806,'Metsim License Renewal (Upcoming, not expired yet)','BAU-07',''),
 (813276358,'Webinar','BAU-08',''),
 (855418090,'HS-08: Metaltech - Metal Accounting Focus → Demo Booking','HS-08','Named with its code, so it would have matched automatically.'),
 (512407775,'(unidentified)',null,'Two emails, Aug 2025. Not in the sequence list HubSpot returns — left unmapped rather than guessed.'),
 (813735109,'(unidentified)',null,'Two emails, May 2026. Not in the sequence list HubSpot returns — left unmapped rather than guessed.'),
 -- sequences with no traffic yet, mapped so they work the day they send
 (636344539,'Strat Sale',null,'No sends recorded yet.'),
 (650035416,'Introduction to METSIM® for Non-Metsim users (draft)',null,'Draft.'),
 (844840176,'Safety Managers Engagement',null,'No sends recorded yet. Map to HS-05a if that is what it becomes.'),
 (856181947,'MetalTech Target Projects, Sep 2026',null,'No sends recorded yet.')
on conflict (sequence_id) do update
  set name          = excluded.name,
      campaign_code = coalesce(excluded.campaign_code, hubspot_sequences.campaign_code),
      updated_at    = now();


-- ── roll both feeds up on the one schedule ─────────────────────────────
-- 006 scheduled run_expandi_refresh() hourly. Point the same job at both
-- so there is one job to reason about, not two.
create or replace function run_refresh_all()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ex int;
  hs int;
begin
  select coalesce(sum(metrics_written), 0) into ex from refresh_expandi_metrics();
  select coalesce(sum(metrics_written), 0) into hs from refresh_hubspot_metrics();
  insert into cron_log (job, ok, detail)
  values ('refresh_all', true, ex || ' Expandi rows, ' || hs || ' HubSpot rows');
exception when others then
  insert into cron_log (job, ok, detail)
  values ('refresh_all', false, sqlerrm);
end;
$$;

select cron.schedule('expandi-refresh', '0 * * * *', $$select run_refresh_all();$$);


-- ── prove it without waiting an hour ───────────────────────────────────
select run_refresh_all();


-- ════════════════════════════════════════════════════════════════════════
-- VERIFY
--
-- (a) The job now runs both. Expect one row, and a detail naming both.
-- ════════════════════════════════════════════════════════════════════════
-- select ran_at, ok, detail from cron_log order by id desc limit 5;
--
-- (b) The nine campaigns exist. Expect 9 rows.
-- ════════════════════════════════════════════════════════════════════════
-- select code, name, launch_date, end_date from campaigns
-- where code like 'BAU-%' order by code;
--
-- (c) Nothing yet — hubspot_email_events is empty until the edge function
--     has run for the first time. After it has, this is the whole picture:
-- ════════════════════════════════════════════════════════════════════════
-- select s.campaign_code, s.name, count(*) as emails
-- from hubspot_email_events e
-- join hubspot_sequences s on s.sequence_id = e.sequence_id
-- group by 1, 2 order by 3 desc;
--
-- select * from v_hubspot_live order by campaign_code, metric_key;
--
-- (d) Anything HubSpot sent that could not be placed. The two
--     unidentified ids will show here, which is correct.
-- ════════════════════════════════════════════════════════════════════════
-- select * from v_hubspot_unmapped;
--
-- TO MAP A SEQUENCE LATER (after renaming it in HubSpot, say):
--   update hubspot_sequences set campaign_code = 'PW-02' where sequence_id = 123;
--   select run_refresh_all();
-- ════════════════════════════════════════════════════════════════════════
