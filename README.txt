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
manifest.webmanifest  makes it installable
sw.js                 offline cache
icon-192/512.png      app icons
netlify.toml          stops Netlify caching index.html and sw.js

The campaign data is hardcoded in index.html as CAMPAIGNS / SCHEDULE /
WEBINARS near the bottom of the <script> block. Edit there to update.
If you want the team editing status live instead, that's the point at
which it needs a Supabase backend — ask and I'll wire it.

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

Nothing leaves the browser. The folder handle, the screenshots and the
numbers live in that browser's own storage, so a different machine
starts empty and needs its own "Choose folder…". "Export JSON" takes a
copy out; "Copy for Claude" copies a plain-text summary to paste into a
chat when you want the numbers written up.
