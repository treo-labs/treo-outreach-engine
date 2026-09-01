TREO OUTREACH ENGINE — deploy to Netlify
========================================

1. Go to app.netlify.com → Sites → "Add new site" → "Deploy manually".
2. Drag THIS WHOLE FOLDER onto the drop zone.
   Drag the folder itself, not the files inside it and not a zip —
   dragging the wrong level gives "Page not found" at the root.
3. Netlify gives you a random URL. Change it under
   Site configuration → Change site name.
4. Open it, then Add to Home Screen on phone / Install on desktop —
   it runs full-screen and works offline.

WHEN YOU CHANGE index.html
--------------------------
Open sw.js and bump the cache name (treo-outreach-v1 → -v2).
If you skip this, anyone who already installed the app keeps the old
version forever. After deploying, tell them to hard-refresh once
(Ctrl-Shift-R, or pull-to-refresh twice on mobile).

WHAT'S IN HERE
--------------
index.html            the whole app — all data, styles and script inline
xlsx.full.min.js      spreadsheet reader, used by the History tab's Sync
supabase.js           Supabase client (+ 591.supabase.js, its one chunk)
sql/                  the schema to run in Supabase, once
SUPABASE-SETUP.md     the walkthrough for putting data in Supabase
manifest.webmanifest  makes it installable
sw.js                 offline cache
icon-192/512.png      app icons
netlify.toml          stops Netlify caching index.html and sw.js

The starting campaign data is in index.html as CAMPAIGNS_SEED /
PARKED_SEED / SCHEDULE / WEBINARS in the script block. That is the
fallback everyone gets before anything else is configured — the app is
editable in the browser (below), and shared through Supabase (below
that).

SUPABASE — SHARED DATA
---------------------
Optional, and off until configured. See SUPABASE-SETUP.md for the full
walkthrough. Short version:

  1. Create the project, run sql/001_outreach_schema.sql once.
  2. Turn on email sign-in (code, not password).
  3. Paste the project URL and anon public key into the two constants at
     the very top of index.html's script block.
  4. Open the app, click Cloud in the header, sign in, Sync now.

Local-first: this browser stays the working copy, Supabase is the shared
truth, Sync pulls then merges then pushes. Later edit wins per record,
except that a typed-in number is never dropped by a pull and deletes
travel so they don't come back.

NEVER put the service_role key in index.html. The anon key is public by
design; row level security is the protection.

EDITING CAMPAIGNS
-----------------
The Campaigns tab is editable in the browser. "+ New campaign" asks for
a type first — Expandi, HubSpot, pre-webinar or post-webinar — and that
sets the ID prefix (EX- / HS- / PRE- / PW-), the next free number, the
channel, the activity tag and a default step count. Everything after
that is editable: name, brand, tags, audience, list source, CTA, steps,
the three dates, status and notes.

Each campaign row has an Edit button. Inside the editor you can also:

  Park       take it out of the plan without losing it. Parked campaigns
             render nowhere and are listed under "Parked" at the bottom
             of the tab, one click from coming back.
  Duplicate  copy it with the next free ID — quickest way to make the
             next post-webinar campaign.
  Delete     two taps. Also removes that campaign's scheduled actions.

Weeks are worked out from the dates, not hardcoded. Give a campaign a
launch date in November and November appears. The list always runs at
least four weeks past today.

Every week collapses. Click the week header. A week whose Friday has
passed starts collapsed and is marked "done"; open or close any week and
the app remembers it.

FILTER AND SORT
---------------
Filter by brand, type, stage (upcoming / live / ended, from the dates),
status, launch-date range, and free text across ID, name, audience, list
source, CTA and notes. "By week" keeps the plan view; "Sortable list"
gives a table with every column sortable — click a header, click again
to reverse. The History tab has the same brand and type filters plus
sorting by reply rate, replies, list size and opens.

WHERE EDITS LIVE — READ THIS ONE
---------------------------------
Campaign edits are stored in that browser, not in index.html. They
survive reloads and redeploys of the same site, but they do not reach
anyone else, and a different machine sees the file's own list.

  Export campaigns  writes treo-campaigns.json
  Copy for Claude   copies the whole list as text to paste into a chat,
                    so it can be baked back into index.html properly
  Reset to file     discards this browser's edits (two taps)

So: edit freely day to day, and when the plan settles, Export or Copy
and have it written back into the file. That is what makes it shared.

If index.html's own campaign list changes, bump CAMP_SEED_VERSION near
the top of the script block. Campaigns nobody touched pick up the new
version; edited ones keep the edit; deleted ones stay deleted.

REPLIES TAB — ANSWERING THE PEOPLE WHO REPLY
--------------------------------------------
Campaigns produce replies and replies go stale. This tab is the list of
people who answered and rated interested, one card each, with the thread
they wrote above the draft going back to them.

Getting the leads in. Expandi's inbox has no export and no "add to lead
list", and its contact list is virtualised so scraping the page misses
most of it. So the tab carries a console snippet instead:

  1. Open the Expandi inbox and set the filters you want — replied,
     interest rating interested, whichever tags.
  2. Replies tab → Import from Expandi → Copy console snippet.
  3. In Expandi press F12, Console, paste, Enter.
  4. Click any one contact. The snippet borrows the auth header off the
     page's own API call, then reads every contact and every thread in the
     filtered list and downloads expandi-replies.json.
  5. Paste that file's contents into the box and press Import.

The snippet never sends anything anywhere — it reads the same endpoints
the inbox reads and writes a file. Your access token stays in the browser.

Import is safe to repeat. Leads are keyed on the LinkedIn /in/ slug, so a
second import of the same person updates their details and thread rather
than duplicating them, and a draft you have already written is never
overwritten. The box also accepts a raw capture array or a threads-only
object, so an older console capture still loads.

THE CLASH CHECK — WHY THIS TAB IS NOT JUST A LIST
--------------------------------------------------
The app already holds every campaign and its dates. So when a lead comes
in carrying the Expandi campaign they were enrolled in, the tab can match
it against the plan and tell you whether that sequence is still running.

A lead in a live sequence is called out at the top of the tab and on their
own card, in red. Pause or remove them from the campaign before you answer
by hand — otherwise your message and an automated step land on the same
person in the same week, which is the single fastest way to make a warm
lead go cold.

A lead whose campaign has ended is marked safe to write to.

DRAFTS
------
A lead arrives with whatever draft was written for it. Edit any draft in
the box; it saves as you type. Where there is no draft, "Insert template"
drops the opening pattern for that lead's brand — METSIM, Treo Tech or
Treo Services — so someone can write without waiting on a chat. A template
is a starting point, not a message: what makes these land is answering
what the person actually said, which is what the thread above the box is
there for.

"Before sending" notes in grey are claims in the draft that need checking
first — a licence record, a price, a product change. Do not send those
until you have the answer.

Session date and recording link at the top of the tab fill every [DATE]
and [LINK] placeholder at the moment you press Copy draft, so one webinar
date typed once covers the whole batch.

Copy for Claude takes every unanswered lead, with their threads and
current drafts, as text to paste into a chat when you want the drafts
written or rewritten properly.

Reply leads sync through Supabase like everything else, once
sql/003_reply_leads.sql has been run. Same contract: later edit wins,
deletes travel.

HISTORY TAB — HOW SYNC WORKS
----------------------------
Keep one folder per campaign inside your Campaigns folder:

  Campaigns/
    EX-08 MetalTech Connect/
      expandi-export.xlsx        ← any .xlsx / .xls / .csv
      Overview.png               ← any screenshots
      Chart Stats.png
    HS-03 Traffic Management/
      hubspot-email-performance.csv

Put the campaign ID in the folder name and the app matches it to the
plan automatically. Without an ID it still appears, as an unassigned
folder you can bind to a campaign from "Assign & edit".

On the History tab: "Choose folder…" once (Chrome or Edge on desktop),
then "Sync campaigns" whenever a campaign ends. Every sync re-reads
every spreadsheet, picks up new screenshots and refreshes the numbers.
The browser remembers the folder, so it is one click after the first
time. Safari and Firefox have no folder memory — there it falls back to
a one-off folder picker, which still works, just not remembered.

What sync reads out of a spreadsheet:
  - a label next to a number ("Replies", 43) anywhere on any sheet
  - a summary row of numbers under matching column headers
  - a contact list with yes/no columns — it counts the yeses
  - the row count, as the list size

What it can't read is a screenshot. Those are filed as evidence against
the campaign; open "Edit numbers" and the screenshots sit above the
input boxes so you can read the figures straight off them. Anything you
type is kept and never overwritten by a later sync — a dot next to a
number means it was typed rather than read from a file.

The folder handle stays in this browser and is never shared — a
different machine needs its own "Choose folder…". The numbers and the
screenshots do reach the team once Supabase is configured. Without it,
"Export JSON" takes a copy out and "Copy for Claude" copies a plain-text
summary to paste into a chat.
