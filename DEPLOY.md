# Deploying the Outreach Engine

Two routes. Pick one.

---

## Route A — Netlify only, no GitHub (5 minutes)

Use this if you just want it live and you're happy to re-drag the folder
whenever it changes.

1. Go to **app.netlify.com** and sign in.
2. **Sites → Add new site → Deploy manually.**
3. Drag **this whole folder** onto the drop zone.
   Drag the *folder itself* — not the files inside it, not the zip.
   Dragging the wrong level gives "Page not found" at the root.
4. Netlify gives you a random URL like `dazzling-otter-4f9c.netlify.app`.
   Change it under **Site configuration → Change site name** —
   `treo-outreach.netlify.app` or similar.
5. Open it. On a phone: Share → Add to Home Screen. On desktop Chrome:
   the install icon in the address bar. It then runs full-screen and
   works offline.

To update later: drag the folder on again. Netlify replaces the site.

---

## Route B — GitHub + Netlify (auto-deploys on every change)

Worth it if more than one person will edit it, or you want a history of
changes. Once connected, every edit you save on GitHub goes live in about
a minute with no further steps.

### Step 1 — Put the files on GitHub

**Without the command line (recommended):**

1. Go to **github.com/new**.
2. Repository name: `treo-outreach-engine`
3. Set it to **Private** unless you want it public.
4. Do **not** tick "Add a README" — the folder already has files.
5. Click **Create repository**.
6. On the next screen click **uploading an existing file**.
7. Drag in every file from this folder:
   `index.html`, `manifest.webmanifest`, `sw.js`, `netlify.toml`,
   `icon-192.png`, `icon-512.png`, `apple-touch-icon.png`,
   `README.txt`, `DEPLOY.md`
   Upload the **files**, not the folder — GitHub should show them at the
   top level of the repo, not nested inside another directory.
8. Type a short message ("initial commit") and click **Commit changes**.

**With the command line**, if you'd rather:

```bash
cd treo-outreach-engine
git init
git add .
git commit -m "Treo Outreach Engine"
git branch -M main
git remote add origin https://github.com/YOUR-ORG/treo-outreach-engine.git
git push -u origin main
```

### Step 2 — Connect Netlify to the repo

1. **app.netlify.com → Sites → Add new site → Import an existing project.**
2. Choose **GitHub**. Authorise Netlify if it asks — if the repo is under
   a Treo organisation you may need an admin to approve the install.
3. Pick `treo-outreach-engine`.
4. Netlify asks for build settings. Leave them as they come:
   - **Build command:** *(empty)*
   - **Publish directory:** `.`
   There is no build step — this is plain HTML. If Netlify pre-fills a
   build command, delete it.
5. Click **Deploy**.
6. Rename the site under **Site configuration → Change site name**.

That's it. From now on, editing a file on GitHub (pencil icon → edit →
commit) redeploys the site automatically.

---

## The one thing that will bite you

**Every time you change `index.html`, bump the cache name in `sw.js`.**

Open `sw.js`, first line of code:

```js
const CACHE = "treo-outreach-v1";
```

Change it to `-v2`, then `-v3`, and so on. Commit both files together.

If you skip this, anyone who has already installed the app keeps seeing
the old version forever — the service worker serves its cached copy and
never checks. After deploying an update, tell people to hard-refresh once
(**Ctrl-Shift-R** on desktop, pull-to-refresh twice on mobile).

---

## Updating the campaign data

All the content lives in `index.html`. Near the bottom of the `<script>`
block you'll find three lists:

- `CAMPAIGNS` — one entry per campaign, matching the tracker spreadsheet
- `SCHEDULE` — the day-by-day send schedule
- `WEBINARS` — the five sessions

Edit the values there, bump the `sw.js` cache name, commit both.

If keeping those in sync with the spreadsheet by hand becomes annoying —
or you want the team updating status live rather than reading a fixed
page — that's the point at which it needs a Supabase backend. It's about
an hour of work; ask and I'll wire it.

---

## Custom domain (optional)

If you'd rather it lived at `outreach.treogroup.co.za`:

1. Netlify: **Domain management → Add a domain** → type it in.
2. Netlify shows you a CNAME record.
3. Whoever manages the `treogroup.co.za` DNS adds that record.
4. HTTPS is issued automatically within a few minutes.
