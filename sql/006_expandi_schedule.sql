-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 006: roll the live numbers up on a schedule
--
-- Run this ONCE, after 004 and 005. Click once in the editor, Ctrl-A,
-- paste, Run. Highlighting part of the text runs only that part.
--
-- What this is for: Expandi has been posting events into expandi_events
-- since the seven webhooks went live, but refresh_expandi_metrics() is what
-- turns them into the numbers the app reads — and until now somebody had to
-- run it by hand. This schedules it every hour, on the hour.
--
-- Nothing about the roll-up changes. It still writes only is_manual = false
-- rows, so every number you typed by hand is still untouchable.
--
-- BEFORE YOU RUN THIS: turn the scheduler on in the dashboard, because
-- enabling it from the SQL editor is not guaranteed to work on every
-- project. Either route does the job:
--   Integrations → Cron → Enable
--   Database → Extensions → search "pg_cron" → toggle on
-- STEP 1 below is then a no-op. If you skip this and STEP 1 fails with
-- "extension pg_cron is not available", nothing is broken — go and enable
-- it in the dashboard and run the file again.
--
-- Verification queries are at the bottom.
-- ════════════════════════════════════════════════════════════════════════


-- ── STEP 1: the scheduler ──────────────────────────────────────────────
create extension if not exists pg_cron;


-- ── STEP 2: a wrapper that can never break the schedule ────────────────
-- pg_cron records a failed job and moves on, but a job that throws every
-- hour fills run_details with noise and makes a real failure hard to spot.
-- This swallows the error, logs it, and lets the next run try again.
create table if not exists cron_log (
  id         bigserial primary key,
  ran_at     timestamptz not null default now(),
  job        text        not null,
  ok         boolean     not null,
  detail     text
);

alter table cron_log enable row level security;

drop policy if exists cron_log_read on cron_log;
create policy cron_log_read on cron_log
  for select using (is_treo_staff());

create or replace function run_expandi_refresh()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rows_written int;
begin
  select coalesce(sum(metrics_written), 0)
    into rows_written
    from refresh_expandi_metrics();

  insert into cron_log (job, ok, detail)
  values ('expandi_refresh', true, rows_written || ' metric rows written');

exception when others then
  insert into cron_log (job, ok, detail)
  values ('expandi_refresh', false, sqlerrm);
end;
$$;


-- ── STEP 3: schedule it hourly ─────────────────────────────────────────
-- unschedule first so re-running this file does not stack up duplicates
select cron.unschedule('expandi-refresh')
where exists (select 1 from cron.job where jobname = 'expandi-refresh');

select cron.schedule('expandi-refresh', '0 * * * *', $$select run_expandi_refresh();$$);


-- ── STEP 4: prove it works without waiting an hour ─────────────────────
select run_expandi_refresh();


-- ════════════════════════════════════════════════════════════════════════
-- VERIFY
--
-- (a) The job is scheduled and active. Expect one row, active = true.
-- ════════════════════════════════════════════════════════════════════════
-- select jobname, schedule, active from cron.job where jobname = 'expandi-refresh';
--
-- (b) The manual run in STEP 4 succeeded. Expect ok = true and a count.
--     "0 metric rows written" is correct when nothing new has fired.
-- ════════════════════════════════════════════════════════════════════════
-- select ran_at, ok, detail from cron_log order by id desc limit 10;
--
-- (c) After an hour or two: every run recorded, and none of them failing.
-- ════════════════════════════════════════════════════════════════════════
-- select date_trunc('hour', ran_at) as hour, ok, count(*), max(detail)
-- from cron_log where job = 'expandi_refresh'
-- group by 1, 2 order by 1 desc limit 24;
--
-- (d) pg_cron's own view of the same runs, if a run is missing above.
-- ════════════════════════════════════════════════════════════════════════
-- select start_time, status, return_message from cron.job_run_details
-- where jobid = (select jobid from cron.job where jobname = 'expandi-refresh')
-- order by start_time desc limit 10;
--
-- TO STOP IT: select cron.unschedule('expandi-refresh');
-- ════════════════════════════════════════════════════════════════════════
