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
manifest.webmanifest  makes it installable
sw.js                 offline cache
icon-192/512.png      app icons
netlify.toml          stops Netlify caching index.html and sw.js

The campaign data is hardcoded in index.html as CAMPAIGNS / SCHEDULE /
WEBINARS near the bottom of the <script> block. Edit there to update.
If you want the team editing status live instead, that's the point at
which it needs a Supabase backend — ask and I'll wire it.
