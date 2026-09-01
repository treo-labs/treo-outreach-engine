-- ════════════════════════════════════════════════════════════════════════
-- Treo Outreach Engine — update 002: lock access to Treo staff
--
-- Run this ONCE, after 001. Do not re-run 001.
--
-- Why: 001 granted read and write to anyone with a signed-in session. That
-- is fine when nobody outside the company can get a session. It is not fine
-- once the project URL and publishable key are public — and they are, in
-- index.html, which is the correct place for them. So the check moves to
-- where it belongs: the email address on the session.
--
-- After this, a session whose email is not on a Treo domain sees nothing
-- and can write nothing, whatever key it holds.
--
-- Add domains to the list below if Treo uses others.
-- ════════════════════════════════════════════════════════════════════════

create or replace function is_treo_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (auth.jwt() ->> 'email') ~* '@(treogroup\.co\.za|psconsult\.co\.za)$',
    false
  );
$$;

comment on function is_treo_staff() is
  'True when the current session belongs to a Treo email domain. Used by every RLS policy.';

do $$
declare t text;
begin
  foreach t in array array['campaigns','schedule_actions','webinars',
                           'campaign_results','campaign_metrics','campaign_shots']
  loop
    execute format('alter table %I enable row level security', t);
    -- replace the open policies from 001
    execute format('drop policy if exists staff_read   on %I', t);
    execute format('drop policy if exists staff_insert on %I', t);
    execute format('drop policy if exists staff_update on %I', t);
    execute format('drop policy if exists staff_delete on %I', t);
    execute format('create policy staff_read   on %I for select to authenticated using (is_treo_staff())', t);
    execute format('create policy staff_insert on %I for insert to authenticated with check (is_treo_staff())', t);
    execute format('create policy staff_update on %I for update to authenticated using (is_treo_staff()) with check (is_treo_staff())', t);
    execute format('create policy staff_delete on %I for delete to authenticated using (is_treo_staff())', t);
  end loop;
end $$;

-- Same for the evidence screenshots.
drop policy if exists evidence_read   on storage.objects;
drop policy if exists evidence_write  on storage.objects;
drop policy if exists evidence_update on storage.objects;
drop policy if exists evidence_delete on storage.objects;
create policy evidence_read   on storage.objects for select to authenticated
  using (bucket_id = 'campaign-evidence' and is_treo_staff());
create policy evidence_write  on storage.objects for insert to authenticated
  with check (bucket_id = 'campaign-evidence' and is_treo_staff());
create policy evidence_update on storage.objects for update to authenticated
  using (bucket_id = 'campaign-evidence' and is_treo_staff())
  with check (bucket_id = 'campaign-evidence' and is_treo_staff());
create policy evidence_delete on storage.objects for delete to authenticated
  using (bucket_id = 'campaign-evidence' and is_treo_staff());

-- ════════════════════════════════════════════════════════════════════════
-- VERIFICATION — run separately.
--
-- (a) The function exists and rejects an outsider. Expect: false, false, true.
--     (It reads the live session, so in the SQL editor all three are about
--      the regex, not about you.)
-- ════════════════════════════════════════════════════════════════════════
-- select 'someone@gmail.com'      ~* '@(treogroup\.co\.za|psconsult\.co\.za)$' as gmail_allowed,
--        'kelly@treogroup.co.za.evil.com' ~* '@(treogroup\.co\.za|psconsult\.co\.za)$' as lookalike_allowed,
--        'kelly@treogroup.co.za'  ~* '@(treogroup\.co\.za|psconsult\.co\.za)$' as treo_allowed;
--
-- (b) Every policy now carries the check. Expect 24 rows, all showing
--     is_treo_staff() in the qual or with_check column.
-- ════════════════════════════════════════════════════════════════════════
-- select tablename, policyname, qual, with_check
-- from pg_policies
-- where tablename in ('campaigns','schedule_actions','webinars',
--                     'campaign_results','campaign_metrics','campaign_shots')
-- order by tablename, policyname;
