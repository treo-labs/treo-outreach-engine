# Putting the Outreach Engine on Supabase

Until now the app kept everything in your browser. Your edits never reached
Calvin, and a second laptop saw the file's own list. This puts the data in
one place so the app is the same wherever it is opened.

The app still works with no Supabase at all — it just stays local. Nothing
below is required to keep using it.

Work through this in order. Each step says what success looks like.

---

## 1 — Create the project

supabase.com → **New project**, on the Treo team account.

- Name: `treo-outreach-engine`
- Region: **Frankfurt (eu-central-1)**. There is no South African region,
  and EU data residency is the easiest answer to a POPIA question.
- Database password: generate one and put it in the password manager. You
  will not need it for this app, but you will need it one day.

**Success:** the project dashboard opens and stops saying "setting up".
Takes a couple of minutes.

---

## 2 — Run the schema, once

Left sidebar → **SQL Editor** → **+** for a new query.

Open `sql/001_outreach_schema.sql`, select all of it, paste it into the
editor, press **Run**.

Two things that catch people here:

- If any text is **selected** in the editor, Supabase runs only the
  selection. Click once in the editor, Ctrl-A, paste, and nothing is
  selected.
- A "Potential issues detected" dialog may appear — it fires on any file
  containing a `drop`. This file drops policies before recreating them, on
  purpose, so it can be re-run safely. **Run without RLS** is the correct
  button. It does not disable anything; it just skips Supabase's warning.

**Success:** "Success. No rows returned."

Then paste the verification query — it is at the bottom of the file,
commented out. Uncomment it, run it on its own.

**Success:** six rows, every one showing `rls_enabled = true` and
`policies = 4`. The tables are empty at this point. That is correct — the
app has not pushed anything yet.

---

## 3 — Turn on email sign-in

**Authentication** → **Sign In / Providers** → Email: **on**.

- **Confirm email: off.** The app signs people in with a six-digit code,
  and the code is the verification. Leaving confirm on emails everybody
  twice.
- Password settings do not matter here — nobody sets a password.
- **Anonymous sign-ins: off.** Every change should have a name against it.

**Authentication** → **URL Configuration** → Site URL: the deployed app
address, e.g. `https://treo-outreach.netlify.app`. Set this before the
first sign-in test.

**Success:** Email shows as enabled in the providers list.

---

## 4 — Give the app the keys

**Settings** → **API**. Two values:

- **Project URL** — `https://xxxxxxxxxxxx.supabase.co`. Just that. Not the
  REST endpoint with `/rest/v1/` on the end — the client adds that itself,
  and pasting it produces requests to `/rest/v1/rest/v1/…` that 404 with an
  unhelpful error. The app strips it now, but know why.
- The **public** key — either the new `sb_publishable_…` or the older anon
  key starting `eyJ`. Both work.

Put them in the two constants at the very top of the script block in
`index.html`:

```js
const SUPABASE_URL  = "https://xxxxxxxxxxxx.supabase.co";
const SUPABASE_ANON = "eyJhbGciOi...";
```

Then bump `CACHE` in `sw.js` and redeploy. Everyone gets the connection
without doing anything.

To try it before committing to the file: open the app, click **Cloud** in
the header, and paste the two values in there instead. That configures
only your browser, which is the right way to test.

**The public key is public by design.** It goes in the page, it appears in
view-source, and that is fine — row level security is what protects the
data. But read step 5a: "protected by RLS" only means something once the
policies check *who* you are, which is what 002 fixes.

The **secret** key (`sb_secret_…`, formerly `service_role`) is the
opposite: it bypasses every policy. It must never go into the app, a
commit, or a message. The app refuses it if pasted.

**Success:** the Cloud button in the header shows `Cloud ○` — configured,
not yet signed in.

---

## 5 — Sign in and push

Click **Cloud** → enter your Treo email → **Send code** → type the
six-digit code from the email → **Verify and sign in**.

**Success:** the header reads `Cloud ●` in green.

Now **Sync now**. The log tells you what moved.

**Success:** something like *pushed 24 campaigns · pushed 43 scheduled
actions · pushed 5 webinars · pushed 3 results and 16 metrics · uploaded 1
screenshot*.

Check it landed: Supabase → **Table Editor** → `campaigns`. You should see
every campaign, including the parked METSIM ones with `parked = true`.

---

## 5a — Lock it to Treo staff (do not skip)

Run `sql/002_lock_to_treo.sql` in the SQL editor, once.

`001` granted read and write to anyone with a signed-in session. That is
safe only while nobody outside the company can get a session — and the
project URL and publishable key live in `index.html`, which is where they
belong and where anyone can read them. So the check has to be on the
identity, not on the key. After `002`, a session whose email is not on
`treogroup.co.za` or `psconsult.co.za` sees nothing and writes nothing,
whatever key it holds.

Then turn off self-signup: **Authentication → Sign In / Providers →**
switch **Allow new users to sign up** OFF. Accounts get created by
invitation only, from Authentication → Users. The app no longer asks
Supabase to create accounts either.

**Success:** the verification queries at the bottom of `002` show a Treo
address allowed, a gmail address refused, and 24 policies carrying the
check.

If Treo uses other email domains, add them to the regex in `002` and
re-run it — it is written to be re-run safely.

## 6 — Add the rest of the team

**Authentication** → **Users** → **Add user** → **Send invitation**.

Invitation only — the app cannot create accounts, by design. Someone
opening the app with an uninvited address is told to ask for an invite
rather than being let in.

Anyone invited on a Treo domain can read and write everything. That is
deliberate for a team this size; narrowing it further is a policy change
on each table, not a rebuild.

---

## How sync behaves

Local-first. Your browser stays the working copy, Supabase is the shared
truth, and **Sync now** pulls, merges, then pushes.

The merge rule, per record: **the later edit wins.** So two people editing
the same campaign in the same hour means one of them quietly loses. For a
team of two or three working on different campaigns this is fine; if it
starts biting, that is the signal to add proper conflict handling rather
than to work around it.

Two deliberate exceptions:

- **Deletes travel.** Deleting a campaign marks it deleted rather than
  removing the row, so the delete reaches everyone instead of the campaign
  reappearing on the next sync from someone else's browser.
- **Typed numbers are never dropped by a pull.** A number you read off a
  screenshot cannot be re-derived, so on conflict yours wins, and a
  colleague's typed value only fills a gap where you have nothing. This is
  the one place the last-write-wins rule is deliberately broken.

**What syncs:** campaigns, the day-by-day plan, webinars, campaign results,
every metric, and the evidence screenshots into the `campaign-evidence`
bucket.

**What stays local, on purpose:** which weeks you have collapsed, and which
folder you picked for the folder sync. Those are yours, not the team's.

---

## Deploying with GitHub

The app is static files, so this is the whole pipeline:

1. Push this folder to a GitHub repo — `treo-outreach-engine`.
2. Netlify → **Add new site** → **Import an existing project** → pick the
   repo. No build command, publish directory `/`.
3. Every push to `main` redeploys.

Two rules that will save you a confused half hour:

- **Bump `CACHE` in `sw.js` on every `index.html` change.** Installed PWAs
  serve the cached copy forever otherwise, and you will swear the deploy
  did not work.
- **Do not commit the service_role key.** The anon key in `index.html` is
  fine. If a service_role key ever lands in a commit, rotate it in
  Supabase → Settings → API rather than just deleting the line — git
  remembers.

---

## Reading this data from the sales dashboard

The schema ships two views built for exactly that:

- `v_campaign_performance` — one row per campaign with the metrics pivoted
  into columns and accept rate, reply rate, open rate and click-to-open
  computed in SQL. Both apps then get the same numbers by construction,
  rather than each doing its own arithmetic and disagreeing.
- `v_unplanned_results` — campaigns that ran outside the plan, like the
  Metaltech connect campaign from July.

If the dashboard lives in a different Supabase project it needs read access
to this one; the simplest route is a scheduled job that copies
`v_campaign_performance` across. If you point both apps at the same
project, the dashboard just selects from the view.

One thing to settle before wiring it up: the sales dashboard's Stage 1 and
2 KPIs (`prospect.*`, `engaged.reply_rate`) are currently owned by the
Master Weekly Log spreadsheet. If campaign data starts feeding them too,
they have two owners and will drift. Either this becomes the owner and the
spreadsheet stops carrying them, or campaign results live in their own
section of the dashboard and leave the KPIs alone. Worth a five-minute
conversation with Calvin, not a guess.
