# Westside church of Christ — website & members app

Everything for the Westside church of Christ (Newberry, FL) online presence lives in this
repo and deploys to **GitHub Pages** at **westsidenewberrychurchofchrist.com**.

It is four things in one repo:

| Path | URL | What it is |
|------|-----|------------|
| `index.html` | `/` | The public one-page church website |
| `app/` | `/app/` | **Members app** — login, directory, photos, map (Supabase-backed) |
| `wishlist/` | `/wishlist/` | Feature-voting page for members (Google Apps Script backend) |
| `roadmap/` | `/roadmap/` | Internal members-app roadmap (unlisted, `noindex`) |

The **Members** dropdown in the site nav links to Portal (`/app/`), Wishlist, and Roadmap.

---

## 1. Public website (`index.html`)

A static one-page site (Inter font, navy/gold theme, dark-mode toggle, SEO + JSON-LD).
Common edits:
- **Service / Bible-class times** — the "Join Us in Worship & Study" schedule in the hero.
- **Phone & email** — the Contact section (`#contact`).
- **Beliefs** — the "What We Believe" section (`#beliefs`).
- **Photos** — swap the hero building photo in `assets/img/`.
- Styles in `assets/css/style.css` (bump the `?v=` in `index.html` when you change it to bust caches).
- Nav dropdown + theme toggle logic in `assets/js/main.js`.

---

## 2. Members app (`app/`)

A static single-page app (`app/index.html`) backed by **Supabase** (hosted database, auth,
and file storage). No server to run — the browser talks to Supabase directly, and Supabase's
row-level security decides what each person can see.

### Features
- **Sign in** with Google (one tap) or a passwordless email link.
- **Approval gating** — new sign-ins start *pending*; only an admin-approved member sees the directory.
- **Roles** — `member` / `admin`. Admins approve members and can export/back up all data.
- **Profiles** — name, photo, household/family, phone, address, birthday.
- **Directory** — searchable, groupable by family, with avatars (initials fallback).
- **Member map** — addresses are geocoded on save and plotted on a Leaflet/OpenStreetMap map.
- **Quick actions** — tap to call, email, or open an address in the maps app.
- **Onboarding** — a "complete your profile" nudge on first login.
- **Self-service** — members can download their data (JSON) or permanently delete their account.
- **Admin** — pending-approvals panel + "Export members (CSV)" and "Download backup (JSON)".
- Privacy policy at `app/privacy.html`.

### Configuration (in `app/index.html`, top of the `<script>`)
```js
const SUPA_URL = "https://hpdikwatyhnctfhrrslh.supabase.co";
const SUPA_KEY = "sb_publishable_…";   // the PUBLISHABLE (anon) key — safe to be public
```
Both are meant to be public; security comes from the database rules, not from hiding these.
**Never put the Supabase *secret* key, the SMTP app password, or the Google client secret in
this repo.** Those live only in the Supabase dashboard / Google Cloud console (see below).

### Where the moving parts live (all under Joe's accounts)
- **Supabase** — project **"Westside"** in the **CloudKindness** org. Database, auth, storage.
- **Auth emails** — sent via custom SMTP (Gmail): sender "Westside church of Christ"
  `<josephwcook@gmail.com>`, host `smtp.gmail.com:465`, using a Gmail **app password**
  (Supabase → Authentication → Emails → SMTP Settings). Rotate the app password in Google if needed.
- **Google sign-in** — an OAuth Web client in Google Cloud project "My First Project"
  (Google Auth Platform, published to production). Its **callback URL** is
  `https://hpdikwatyhnctfhrrslh.supabase.co/auth/v1/callback`. Client id/secret are pasted into
  Supabase → Authentication → Providers → Google.
- **Auth URLs** — Supabase → Authentication → URL Configuration: Site URL is the church domain,
  redirect allow-list is `https://westsidenewberrychurchofchrist.com/**`.

### Database schema (Supabase → SQL Editor)
One table, `public.profiles`, one row per member (keyed to the auth user):

| Column | Notes |
|--------|-------|
| `id` (uuid, PK) | references `auth.users(id)` **on delete cascade** |
| `full_name`, `email`, `phone`, `family`, `address` | text |
| `birthday` | date |
| `photo_url` | public URL of the uploaded avatar |
| `lat`, `lng` | geocoded coordinates for the map |
| `role` | `member` \| `admin` (default `member`) |
| `status` | `pending` \| `approved` \| `denied` (default `pending`) |
| `created_at` | timestamptz |

Plus:
- **Storage bucket** `avatars` (public read; members can upload/replace only their own folder).
- **Helper functions** `is_approved(uid)`, `is_admin(uid)` — `SECURITY DEFINER`, used by policies.
- **Trigger** `handle_new_user()` — auto-creates a profile on sign-up; makes
  `josephwcook@gmail.com` an approved admin, everyone else pending.
- **Trigger** `guard_profile_privileges()` — stops non-admins from changing their own role/status.
- **RPC** `delete_own_account()` — lets a member delete only their own account (cascades to profile).
- **RLS policies** — read your own row always; read everyone only if you're approved; update your
  own row (members) or any row (admins).

To **rebuild the database from scratch**, run the migrations in `docs/migrations.sql`
(committed alongside this README), in order.

### Rebuilding / extending
Each new feature follows the same pattern: add columns or a table + RLS policies in the SQL
editor, then read/write them from `app/index.html` with the `sb` Supabase client. See the
roadmap (`/roadmap/`) for the planned feature list and phases.

---

## 3. Feature wishlist (`wishlist/`)

`wishlist/index.html` lets members vote Yes/No (plus a must-have star) on possible features.
Backend is a **Google Apps Script** web app (`wishlist/backend.gs`) that stores submissions in a
"Westside App Wishlist" Google Sheet, returns live vote counts, and (optionally) emails/texts a
notification. The deployed script URL is set as `SCRIPT_URL` in `wishlist/index.html`.

---

## 4. Roadmap (`roadmap/`)

`roadmap/index.html` is the internal members-app roadmap — phases, per-phase remaining counts,
and check-off tracking (saved per device). Marked `noindex`; linked only from the Members dropdown.

---

## Keeping Supabase awake

Free Supabase projects pause after ~7 days of inactivity. `.github/workflows/keep-supabase-awake.yml`
pings the project **daily** (and can be run by hand from the repo's Actions tab) to prevent that.
If it ever pauses anyway, open the Supabase dashboard → the Westside project → **Restore project**
(data is preserved).

---

## Admin how-to (for Joe)

- **Approve a new member** — sign in at `/app/` as the admin; new sign-ins appear under
  **Pending approvals**; click **Approve** (or **Deny**).
- **Back up member data** — in the app's admin panel, **Export members (CSV)** or
  **Download backup (JSON)**. Do this periodically; keep a copy off-device.
- **Add another admin** — in Supabase SQL editor:
  `update public.profiles set role='admin', status='approved' where email='someone@example.com';`
- **If Supabase is paused** — Supabase dashboard → Restore project.
- **Rotate the email app password** — generate a new Gmail app password, update it in
  Supabase → Authentication → Emails → SMTP Settings.

---

## Run locally
```bash
python3 -m http.server 8000 --directory .
# open http://localhost:8000
```
(The members app talks to the live Supabase project even when served locally; Google/email sign-in
redirects are configured for the production domain.)

## Deploy
Push to `main`. GitHub Pages serves the repo root; `.nojekyll` keeps asset folders intact;
`CNAME` holds the custom domain.
