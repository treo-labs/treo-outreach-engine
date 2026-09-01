-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — schema 001
--
-- Paste this WHOLE file into the Supabase SQL editor and press Run. Once.
-- Do not re-run it later; every change after this ships as its own
-- 0NN_*_update.sql file.
--
-- Nothing is selected when you paste — if you highlight part of the text,
-- ONLY the highlighted part runs. That is the usual cause of a half-built
-- schema. Click once in the editor, Ctrl-A, paste, Run.
--
-- Verification query is at the bottom.
-- ════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── campaigns ──────────────────────────────────────────────────────────
-- The campaign code (EX-08, HS-03, PRE-01) is the primary key on purpose:
-- it is what the app, the folder names and the history records all key on.
-- Renaming a code cascades to every child row.
create table if not exists campaigns (
  code         text primary key,
  name         text not null,
  brand        text not null default 'Treo Services',
  channel      text not null default 'Expandi'
                 check (channel in ('Expandi','HubSpot','Both')),
  act          text not null default 'IM'
                 check (act in ('IM','EMAIL','EMAIL + IM')),
  btag         text not null default 'SERV',
  aud          text not null default '',
  src          text not null default '',
  steps        int  not null default 4 check (steps between 1 and 50),
  cta          text not null default '',
  build_date   date,
  launch_date  date,
  end_date     date,
  status       text not null default 'Not started',
  note         text not null default '',
  parked       boolean not null default false,
  is_deleted   boolean not null default false,
  updated_at   timestamptz not null default now(),
  updated_by   text,
  created_at   timestamptz not null default now()
);
create index if not exists campaigns_launch_idx  on campaigns (launch_date);
create index if not exists campaigns_visible_idx on campaigns (is_deleted, parked);

-- ── the day-by-day plan ────────────────────────────────────────────────
-- row_key is built by the app as  date|campaign_ref|hash(action)  so the
-- same action loaded twice updates instead of duplicating.
create table if not exists schedule_actions (
  row_key      text primary key,
  action_date  date not null,
  campaign_ref text not null default '—',
  channel      text,
  action       text not null,
  priority     text not null default 'Medium',
  is_deleted   boolean not null default false,
  updated_at   timestamptz not null default now()
);
create index if not exists schedule_date_idx on schedule_actions (action_date);

-- ── webinars ───────────────────────────────────────────────────────────
create table if not exists webinars (
  slug         text primary key,
  name         text not null,
  brand        text,
  speaker      text,
  session_date date,
  session_time text,
  status       text,
  feeds        text,
  is_deleted   boolean not null default false,
  updated_at   timestamptz not null default now()
);

-- ── results: one row per campaign folder ───────────────────────────────
-- result_key is 'EX-08' for a campaign in the plan, or
-- 'folder:Metaltech Connect Campaign' for one that ran outside it.
create table if not exists campaign_results (
  result_key    text primary key,
  campaign_code text references campaigns (code) on update cascade on delete set null,
  folder        text not null default '',
  label         text not null default '',
  brand         text,
  act           text,
  ran_from      date,
  ran_to        date,
  meta          jsonb not null default '[]'::jsonb,
  files         jsonb not null default '[]'::jsonb,
  note          text not null default '',
  last_sync     timestamptz,
  is_deleted    boolean not null default false,
  updated_at    timestamptz not null default now(),
  updated_by    text
);
create index if not exists results_campaign_idx on campaign_results (campaign_code);

-- Long format, not a column per metric: the app's metric list grows
-- (positive replies, meetings, whatever comes next) and this way it grows
-- without a migration. is_manual marks a number typed off a screenshot —
-- a folder sync must never overwrite one.
create table if not exists campaign_metrics (
  result_key text not null references campaign_results (result_key)
               on update cascade on delete cascade,
  metric_key text not null,
  value      numeric,
  source     text,
  is_manual  boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (result_key, metric_key)
);

-- ── evidence screenshots (files live in Storage) ────────────────────────
create table if not exists campaign_shots (
  id           text primary key,
  result_key   text not null references campaign_results (result_key)
                 on update cascade on delete cascade,
  name         text not null,
  storage_path text not null,
  bytes        bigint,
  uploaded_at  timestamptz not null default now(),
  uploaded_by  text
);

-- ════════════════════════════════════════════════════════════════════════
-- Row level security. The anon key is public by design — these policies
-- are the actual protection. Signed-in staff read and write everything;
-- nobody who is not signed in sees a single row.
-- ════════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array['campaigns','schedule_actions','webinars',
                           'campaign_results','campaign_metrics','campaign_shots']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_read   on %I', t);
    execute format('drop policy if exists staff_insert on %I', t);
    execute format('drop policy if exists staff_update on %I', t);
    execute format('drop policy if exists staff_delete on %I', t);
    execute format('create policy staff_read   on %I for select to authenticated using (true)', t);
    execute format('create policy staff_insert on %I for insert to authenticated with check (true)', t);
    execute format('create policy staff_update on %I for update to authenticated using (true) with check (true)', t);
    execute format('create policy staff_delete on %I for delete to authenticated using (true)', t);
  end loop;
end $$;

-- ── storage bucket for the screenshots ─────────────────────────────────
insert into storage.buckets (id, name, public)
values ('campaign-evidence', 'campaign-evidence', false)
on conflict (id) do nothing;

drop policy if exists evidence_read   on storage.objects;
drop policy if exists evidence_write  on storage.objects;
drop policy if exists evidence_update on storage.objects;
drop policy if exists evidence_delete on storage.objects;
create policy evidence_read   on storage.objects for select to authenticated
  using (bucket_id = 'campaign-evidence');
create policy evidence_write  on storage.objects for insert to authenticated
  with check (bucket_id = 'campaign-evidence');
create policy evidence_update on storage.objects for update to authenticated
  using (bucket_id = 'campaign-evidence') with check (bucket_id = 'campaign-evidence');
create policy evidence_delete on storage.objects for delete to authenticated
  using (bucket_id = 'campaign-evidence');

-- ════════════════════════════════════════════════════════════════════════
-- One flat view for anything reading this data from outside the app —
-- the Monday sales dashboard, a Metabase chart, a CSV export. Metrics are
-- pivoted back into columns and the rates are computed once, here, so two
-- readers can never disagree about what "reply rate" means.
-- ════════════════════════════════════════════════════════════════════════
create or replace view v_campaign_performance as
with m as (
  select result_key,
    max(value) filter (where metric_key = 'list')      as list_size,
    max(value) filter (where metric_key = 'invites')   as invites,
    max(value) filter (where metric_key = 'accepted')  as accepted,
    max(value) filter (where metric_key = 'msgs')      as messages,
    max(value) filter (where metric_key = 'replies')   as replies,
    max(value) filter (where metric_key = 'positive')  as positive_replies,
    max(value) filter (where metric_key = 'meetings')  as meetings,
    max(value) filter (where metric_key = 'delivered') as delivered,
    max(value) filter (where metric_key = 'opens')     as opens,
    max(value) filter (where metric_key = 'clicks')    as clicks,
    max(value) filter (where metric_key = 'unsubs')    as unsubscribes,
    max(value) filter (where metric_key = 'bounces')   as bounces
  from campaign_metrics
  group by result_key
)
select
  c.code, c.name, c.brand, c.channel, c.act, c.btag, c.status, c.parked,
  split_part(c.code, '-', 1) as campaign_type,
  c.build_date, c.launch_date, c.end_date,
  case when c.end_date    <  current_date then 'ended'
       when c.launch_date <= current_date then 'live'
       else 'upcoming' end as stage,
  r.result_key, r.folder, r.note as result_note, r.last_sync,
  m.list_size, m.invites, m.accepted, m.messages, m.replies,
  m.positive_replies, m.meetings,
  m.delivered, m.opens, m.clicks, m.unsubscribes, m.bounces,
  case when coalesce(m.invites,0) > 0
       then round(m.accepted / m.invites, 4) end as accept_rate,
  case when coalesce(m.messages, m.list_size, m.accepted, 0) > 0
       then round(m.replies / coalesce(m.messages, m.list_size, m.accepted), 4) end as reply_rate,
  case when coalesce(m.delivered,0) > 0
       then round(m.opens / m.delivered, 4) end as open_rate,
  case when coalesce(m.opens,0) > 0
       then round(m.clicks / m.opens, 4) end as click_to_open_rate
from campaigns c
left join campaign_results r on r.campaign_code = c.code and not r.is_deleted
left join m on m.result_key = r.result_key
where not c.is_deleted;

-- Records that ran outside the plan (no campaign code) still matter.
create or replace view v_unplanned_results as
select r.result_key, r.label, r.folder, r.brand, r.ran_from, r.ran_to, r.note,
       (select jsonb_object_agg(metric_key, value)
          from campaign_metrics cm where cm.result_key = r.result_key) as metrics
from campaign_results r
where r.campaign_code is null and not r.is_deleted;

-- ════════════════════════════════════════════════════════════════════════
-- VERIFICATION — run this on its own afterwards.
-- Expect: 6 rows, every one with rls_enabled = true and 4 policies.
-- The tables are empty until the app pushes to them; that is correct.
-- ════════════════════════════════════════════════════════════════════════
-- select c.relname                          as table_name,
--        c.relrowsecurity                   as rls_enabled,
--        (select count(*) from pg_policies p
--          where p.tablename = c.relname)    as policies
-- from pg_class c
-- join pg_namespace n on n.oid = c.relnamespace
-- where n.nspname = 'public' and c.relkind = 'r'
--   and c.relname in ('campaigns','schedule_actions','webinars',
--                     'campaign_results','campaign_metrics','campaign_shots')
-- order by 1;
