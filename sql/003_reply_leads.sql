-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 003: reply leads
--
-- Run this ONCE, after 001 and 002. Do not re-run either of those.
--
-- Click once in the editor, Ctrl-A, paste, Run. If you highlight part of
-- the text, only the highlighted part runs — that is the usual cause of a
-- half-built table.
--
-- What this is for: the people who answer a campaign. Expandi's inbox has
-- no export, so the app pulls them out of the page with a console snippet
-- and keeps them here: who replied, what they wrote, the draft going back,
-- and whether they are sitting in a sequence that is still firing at them.
--
-- Verification query is at the bottom.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists reply_leads (
  -- the LinkedIn public identifier (the /in/ slug), which survives a name
  -- change and a re-import. Falls back to a slug of the name.
  lead_key          text primary key,
  name              text not null default '',
  first_name        text not null default '',
  job_title         text not null default '',
  company           text not null default '',
  industry          text not null default '',
  profile_link      text not null default '',
  email             text,

  -- Expandi's own opportunity tags, kept verbatim. The app derives the
  -- brand from the campaign first and these second, because a contact can
  -- carry three tags and have had only one conversation.
  tags              jsonb not null default '[]'::jsonb,
  brand             text  not null default 'Treo Services',

  -- where they came from, and whether that sequence is still running.
  -- campaign_code is soft: an Expandi campaign name will not always match
  -- something in the plan, and a lead is still worth having when it does not.
  expandi_campaign  text not null default '',
  campaign_code     text references campaigns (code) on update cascade on delete set null,
  campaign_active   boolean not null default false,

  last_reply_at     timestamptz,

  -- the conversation, as [{at, f: 'us'|'them', b: text}]. Read, never
  -- queried, so jsonb rather than a child table.
  thread            jsonb not null default '[]'::jsonb,

  draft             text not null default '',
  verify            text not null default '',   -- what to check before sending
  note              text not null default '',
  sent              boolean not null default false,
  sent_at           timestamptz,

  is_deleted        boolean not null default false,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  created_at        timestamptz not null default now()
);

create index if not exists reply_leads_campaign_idx on reply_leads (campaign_code);
create index if not exists reply_leads_open_idx     on reply_leads (is_deleted, sent, last_reply_at desc);
create index if not exists reply_leads_brand_idx    on reply_leads (brand);

-- Same protection as everything else: signed in, and on a Treo domain.
alter table reply_leads enable row level security;
drop policy if exists staff_read   on reply_leads;
drop policy if exists staff_insert on reply_leads;
drop policy if exists staff_update on reply_leads;
drop policy if exists staff_delete on reply_leads;
create policy staff_read   on reply_leads for select to authenticated using (is_treo_staff());
create policy staff_insert on reply_leads for insert to authenticated with check (is_treo_staff());
create policy staff_update on reply_leads for update to authenticated using (is_treo_staff()) with check (is_treo_staff());
create policy staff_delete on reply_leads for delete to authenticated using (is_treo_staff());

-- ════════════════════════════════════════════════════════════════════════
-- One flat view for anything reading this from outside the app. The thread
-- is left out on purpose: it is long, and a dashboard wants the counts.
-- ════════════════════════════════════════════════════════════════════════
create or replace view v_reply_leads as
select
  l.lead_key, l.name, l.job_title, l.company, l.industry, l.brand,
  l.profile_link, l.tags,
  l.expandi_campaign, l.campaign_code, c.name as campaign_name,
  l.campaign_active,
  l.last_reply_at,
  (current_date - l.last_reply_at::date)          as days_since_reply,
  jsonb_array_length(l.thread)                    as message_count,
  (l.draft <> '')                                 as has_draft,
  (l.verify <> '')                                as needs_check,
  l.sent, l.sent_at,
  case when l.sent then 'answered'
       when l.campaign_active then 'in a live sequence'
       when (current_date - l.last_reply_at::date) > 7 then 'overdue'
       else 'waiting' end                         as state
from reply_leads l
left join campaigns c on c.code = l.campaign_code
where not l.is_deleted;

-- ════════════════════════════════════════════════════════════════════════
-- VERIFICATION — run these separately.
--
-- (a) Table and policies. Expect one row, rls_enabled = true, policies = 4.
-- ════════════════════════════════════════════════════════════════════════
-- select c.relname as table_name, c.relrowsecurity as rls_enabled,
--        (select count(*) from pg_policies p where p.tablename = c.relname) as policies
-- from pg_class c join pg_namespace n on n.oid = c.relnamespace
-- where n.nspname = 'public' and c.relname = 'reply_leads';
--
-- (b) After the first Sync, this should list everyone still unanswered,
--     oldest first — the same order the Replies tab shows them in.
-- ════════════════════════════════════════════════════════════════════════
-- select name, company, brand, state, days_since_reply
-- from v_reply_leads where not sent order by last_reply_at;
