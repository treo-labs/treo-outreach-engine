-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 005: pre-webhook baselines
--
-- Run this ONCE, after 004, and run it IMMEDIATELY BEFORE you create the
-- webhooks in Expandi. Order matters and the reason is in 004: webhooks
-- cannot backfill. Anything that fired before the hooks existed is gone,
-- so these rows carry each campaign's totals as at the moment below and
-- the roll-up adds live events on top.
--
-- ── The figures ──
-- Read off Expandi's own campaign list (Kyle Morrison's seat) at
-- 08 Sept 2026, 10:20 SAST. Every value is quoted in its source column so
-- anyone can check it against the same screen.
--
-- IF MORE THAN AN HOUR HAS PASSED, RE-READ THEM. These campaigns are live
-- and moving: EX-01 went from 2 of 5 connected to 3 of 5 overnight, and
-- EX-09 from 56 of 65 initiated to 62 of 65. A stale baseline is wrong by
-- a constant for the life of the campaign, which is the one error here
-- that never self-corrects.
--
-- ── Why some campaigns have fewer rows than others ──
-- EX-01, EX-02 and EX-04 are connector campaigns: Expandi reports
-- Initiated (= connection requests sent), Connected (= accepted) and
-- Replied, so they get invites / accepted / replies.
--
-- EX-09 is a messenger campaign to people who are ALREADY connections.
-- Expandi shows it "In Queue" rather than "Connected", and its Initiated
-- count is messages started, not invitations. So it gets list / msgs /
-- replies and deliberately NO invites or accepted rows — a zero there
-- would read as "nobody accepted" when the truth is "there was nothing to
-- accept". Null is not zero.
--
-- ── Not included, on purpose ──
-- EX-11 MetalTech Target Projects — created 07 Sept, 0 people, not running.
-- PRE-01 Pre-Webinar Reminder: METSIM Model Audits — sent BY HAND, not as
--   an Expandi campaign, so there is nothing to baseline and no events will
--   ever arrive for it. Its numbers are typed in through the app's Add
--   numbers form, and the roll-up never overwrites a hand-typed value
--   (is_manual = true wins), so they are safe there.
-- HS-03, HS-08 — email campaigns, so HubSpot's numbers, not Expandi's.
-- Calvin's seat — his eight campaigns are all outside the 18-campaign
--   plan ("Treo Group LinkedIn Page Follower Campaign", "CAS & Safety
--   Connection Builder" and so on), so none of them has a plan code to
--   baseline against. Once his seat's hooks are live they will surface in
--   v_expandi_unlinked, which is the correct place for them.
-- ════════════════════════════════════════════════════════════════════════

insert into expandi_baseline (campaign_code, metric_key, value, as_of, source) values

  -- EX-01 · Post-Webinar: CAS — Attendees  (connector, activated 02 Sep)
  ('EX-01','list',      5, '2026-09-08 10:20:00+02', 'Expandi campaign list: People in total 5'),
  ('EX-01','invites',   5, '2026-09-08 10:20:00+02', 'Expandi: Initiated 100%, 5 of 5'),
  ('EX-01','accepted',  3, '2026-09-08 10:20:00+02', 'Expandi: Connected 60%, 3 of 5'),
  ('EX-01','replies',   1, '2026-09-08 10:20:00+02', 'Expandi: Replied 20%, 1 of 5'),

  -- EX-02 · Post-Webinar: CAS — No-Shows  (connector, activated 02 Sep)
  ('EX-02','list',     11, '2026-09-08 10:20:00+02', 'Expandi campaign list: People in total 11'),
  ('EX-02','invites',  11, '2026-09-08 10:20:00+02', 'Expandi: Initiated 100%, 11 of 11'),
  ('EX-02','accepted',  4, '2026-09-08 10:20:00+02', 'Expandi: Connected 36.36%, 4 of 11'),
  ('EX-02','replies',   2, '2026-09-08 10:20:00+02', 'Expandi: Replied 18.18%, 2 of 11'),

  -- EX-04 · Webinar Invite: Traffic Management  (connector, activated 02 Sep)
  ('EX-04','list',      9, '2026-09-08 10:20:00+02', 'Expandi campaign list: People in total 9'),
  ('EX-04','invites',   9, '2026-09-08 10:20:00+02', 'Expandi: Initiated 100%, 9 of 9'),
  ('EX-04','accepted',  2, '2026-09-08 10:20:00+02', 'Expandi: Connected 22.22%, 2 of 9'),
  ('EX-04','replies',   1, '2026-09-08 10:20:00+02', 'Expandi: Replied 11.11%, 1 of 9'),

  -- EX-09 · MetalTech — Connected & Messaged (warm)  (messenger, activated 02 Sep)
  -- No invites/accepted rows: see the note above.
  ('EX-09','list',     65, '2026-09-08 10:20:00+02', 'Expandi campaign list: People in total 65'),
  ('EX-09','msgs',     62, '2026-09-08 10:20:00+02', 'Expandi: Initiated 95.38%, 62 of 65 (messages, not invites)'),
  ('EX-09','replies',   9, '2026-09-08 10:20:00+02', 'Expandi: Replied 13.85%, 9 of 65')

on conflict (campaign_code, metric_key) do update
  set value      = excluded.value,
      as_of      = excluded.as_of,
      source     = excluded.source,
      updated_at = now();

-- ════════════════════════════════════════════════════════════════════════
-- VERIFICATION — run these separately.
--
-- (a) Fifteen rows across four campaigns, and every campaign_code must
--     already exist in campaigns (the foreign key enforces it). If this
--     insert failed on a key violation, the campaign is not in the plan
--     table yet — check the code spelling against the Campaigns tab.
-- ════════════════════════════════════════════════════════════════════════
-- select campaign_code, count(*) as metrics, min(as_of) as as_of
-- from expandi_baseline group by 1 order by 1;
--
-- (b) What the app will show once the roll-up runs. Before any live event
--     arrives, value should equal baseline_value and live_events be 0.
-- ════════════════════════════════════════════════════════════════════════
-- select * from v_expandi_live order by campaign_code, metric_key;
-- select * from refresh_expandi_metrics();
