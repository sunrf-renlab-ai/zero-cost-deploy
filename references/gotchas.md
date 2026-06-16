# Catalog of gotchas

Each entry below is real — these blocked a deploy, sometimes for hours. If a future deploy hits the same symptom, the fix is right here.

---

## Supabase

### `tls error (EOF)` on `supabase db push`

**Symptom:** `supabase db push --linked` fails with timeout or TLS error within ~5 seconds.

**Cause:** Your network blocks direct TCP to `db.<ref>.supabase.co:5432`. Common with:
- Clash / Mihomo in TUN+fakeip mode (DNS returns `198.18.0.0/15`)
- Corporate firewall blocking non-HTTPS ports
- ISP transparent proxies

**Fix:** Use `scripts/supabase-push-migration.sh` (Management API over HTTPS). Get a PAT at `supabase.com/dashboard/account/tokens`. Migration runs through `api.supabase.com` instead.

---

### "Site URL mismatch" on OAuth callback

**Symptom:** After clicking "Sign in with Google/GitHub", redirect lands on Supabase error page: "Site URL mismatch".

**Cause:** Supabase Auth requires your production URL to be added to **Authentication → URL Configuration** before it'll redirect there.

**Fix:**
1. Project → Authentication → URL Configuration
2. Site URL: your production origin (no trailing slash)
3. Redirect URLs: add wildcards for preview deploys (`https://yourapp-*-yourorg.vercel.app/**`)

---

### Project paused (free tier inactivity)

**Symptom:** All Supabase requests return 503 or hang. Dashboard shows "This project is paused."

**Cause:** No HTTP request for 7+ days on free tier.

**Fix:**
1. One-time: Click **Resume project** in dashboard.
2. Prevention: GitHub Actions cron pinging `/auth/v1/health` every couple of days.

---

### `sb_publishable_*` keys rejected by old SDK

**Symptom:** `Invalid API key` or `Invalid JWT` errors from supabase-js, despite the key being correct.

**Cause:** SDK predates the 2026 key format change. Old versions expect JWT.

**Fix:** `bun add @supabase/supabase-js@latest` (and `@supabase/ssr@latest` if using).

---

## Upstash

### Region picker won't accept input

**Symptom:** Trying to create a Redis DB in the console; region dropdown doesn't update when you click options, or your selection gets reverted on form submit.

**Cause:** React combobox uses internal state that ignores synthetic events. Browser extensions or osascript-driven JS can't reliably select.

**Fix:** Use `scripts/upstash-create-redis.sh` with the Management API. Skip the UI entirely.

---

### 429 with `Monthly request limit exceeded`

**Symptom:** REST endpoint suddenly returns 429s for all commands.

**Cause:** Free tier is 500,000 commands / month (changed 2025-03-12 from the old 10K/day model). Each Redis command counts; pipelines count N for N commands inside.

**Fix:**
- Short-term: wait for the monthly reset (start of your billing month — not UTC midnight daily).
- Long-term: cache aggressively, batch reads, or upgrade ($0.20 / 100K commands on Pro).

---

## Render

### Blueprint applies but service crashes on boot

**Symptom:** `render.yaml` Apply completes; first build succeeds; service crashes immediately with "Cannot read property X of undefined" or similar missing-env error.

**Cause:** Render's Blueprint apply silently failed to save the `sync: false` env values you entered during the prompt.

**Fix:**
1. Service → Environment → click **Edit** on each empty variable
2. Paste the value
3. **Save, rebuild, and deploy**

This is the #1 Render gotcha. **Always verify env immediately after Blueprint apply.**

---

### Cold start adds 30-60 s to first request

**Symptom:** After idle period, the first request to your Render service hangs for ~45 s before responding.

**Cause:** Free tier sleeps after 15 min of inactivity. Cold start = container boot + app boot.

**Fix:** GitHub Actions workflow pinging `/healthz` every 13 min. Template at `templates/workflows/scheduled.yml`.

---

### Render Postgres free tier disappears after 30 days

**Symptom:** Database stops accepting connections about a month after creation, even with active traffic, then returns "Database not found" two weeks later.

**Cause:** Render's free Postgres **expires 30 days after creation**, then enters a **14-day grace period** before permanent deletion (~44 days total). They're explicit about it but easy to miss.

**Fix:** Don't use Render Postgres. Use Supabase (which has no such expiry). Render's strength is web services, not databases.

---

## Vercel

### "Limited to daily cron jobs"

**Symptom:** Deploy rejected with this message in build log:

> Hobby accounts are limited to daily cron jobs.

**Cause:** `vercel.json` has a cron more frequent than daily (`*/N`, `0 * * * *`, etc.).

**Fix:** Move sub-daily crons to GitHub Actions. Keep Vercel cron schedules at `MM HH * * *` (daily). Up to 3 daily crons on Hobby.

---

### Env values empty after JS dispatchEvent

**Symptom:** Tried to script the env form with `input.value = ...; input.dispatchEvent(new Event('input'))`. Save fails or values are blank.

**Cause:** React-controlled value tracker ignores synthetic input events.

**Fix:** Use `ClipboardEvent('paste')` with `clipboardData` set to a KEY=VALUE block. See `references/vercel.md` for the canonical pattern.

---

### Preview URL returns 401, production URL works

**Symptom:** `curl <project>-<sha>.vercel.app/` → 401; `curl <project>.vercel.app/` → 200.

**Cause:** Vercel Authentication is enabled on preview deployments (Settings → Security).

**Fix:** Either disable preview protection (Settings → Security), or always smoke-test against the production alias.

---

### `metadataBase` build warning

**Symptom:** Build log shows `metadataBase property in metadata export is not set, using "http://localhost:3000"`.

**Cause:** Next.js can't determine the absolute URL for OG images at build time.

**Fix:** Cosmetic only — Vercel injects `VERCEL_URL` at request time. Optional cleanup: set `NEXT_PUBLIC_SITE_URL` and reference it in `metadataBase: new URL(...)`.

---

### Project URL has unwanted suffix

**Symptom:** Expected `myapp.vercel.app`, got `myapp-amiz.vercel.app`.

**Cause:** `myapp.vercel.app` is taken globally; Vercel auto-suffixed.

**Fix:**
- Rename project: Settings → General → Project Name.
- Or add custom domain (~$10/yr).
- Or accept the suffix; the production alias still works publicly.

---

## GitHub / OAuth

### Authorize button stays disabled

**Symptom:** OAuth flow with GitHub (during Render or Vercel signup). Click "Authorize", page loads, but the green Authorize button is grayed out for 2-4 seconds.

**Cause:** GitHub's anti-bot animation. JS clicks during this window are silently ignored.

**Fix:** Manual click. JS can't synthesize a trusted user gesture; this requires OS Accessibility, which you don't have from regular page-context JS.

---

### OAuth account picker doesn't select on click

**Symptom:** GitHub's "Which account?" picker shows your username, but clicking it doesn't proceed.

**Cause:** The username text is split across nested DOM nodes, and the click target isn't the obvious element.

**Fix:**

```js
document.querySelector('form[action^="/login/oauth/authorize"]')?.submit();
```

The form submission bypasses the click target ambiguity.

---

### GitHub Actions doesn't re-run on retagged tag

**Symptom:** Pushed a tag, deleted it, repushed; the workflow with `on: push: tags: [...]` doesn't re-trigger.

**Cause:** GitHub considers the tag "already seen" by SHA.

**Fix:** Delete the remote tag first, then re-tag.

```bash
git push origin :refs/tags/v0.1.0
git tag -d v0.1.0
git tag v0.1.0
git push origin v0.1.0
```

---

## General networking

### Clash/Mihomo TUN mode breaks raw TCP

**Symptom:** HTTPS works (curl, browser); Postgres, Redis, SSH, SMTP do not. DNS returns `198.18.x.x` for hosts that should be public.

**Cause:** Clash/Mihomo fakeip allocates `198.18.0.0/15` for non-domestic hosts. TUN passes only HTTPS-recognizable traffic through the proxy; raw TCP gets dropped or NAT'd incorrectly.

**Fix:**
- Use HTTPS-based APIs (Supabase Management API, Upstash REST, etc.).
- For postgres specifically: Supabase Pooler at port 6543 over IPv4 (some networks pass this).
- Or: switch proxy to "rule" mode instead of TUN+fakeip for the affected hosts.
- Or: disable proxy for the duration of the deploy.

---

### Custom domain DNS not propagating

**Symptom:** Added custom domain in Vercel; DNS records configured at registrar; domain still doesn't resolve after 10 minutes.

**Cause:**
- TTL on existing records is high (could be 24 h).
- Conflicting records (old A + new CNAME).
- Registrar caches independently of TTL.

**Fix:**
- Verify with `dig @1.1.1.1 +short <yourdomain>` from an external resolver (use https://dnschecker.org if your local network is suspect).
- Clear conflicting records.
- Lower TTL to 300 s before the next change.
- Wait — sometimes propagation just takes a while.

---

### "Verification Needed" stuck in Vercel after CNAME is correct

**Symptom:** Vercel Domains page shows your custom domain in "Verification Needed" state for > 5 min, even though `dig @1.1.1.1 +short yourdomain CNAME` clearly returns `cname.vercel-dns.com.`.

**Cause:** Usually one of:
- A conflicting A or AAAA record at the same name takes precedence over the CNAME.
- Vercel's resolver is rate-limited / caching old NXDOMAIN.
- The CNAME points to a wrong target (e.g., `cname.vercel-dns.com.com` with typo, or a stale `<sha>.vercel.app`).

**Fix:**
1. `dig @1.1.1.1 +short yourdomain A AAAA CNAME` — if you see A/AAAA + CNAME together, delete the A/AAAA.
2. Click **Refresh** in the Vercel UI, or hit `POST /v9/projects/$PID/domains/$DOMAIN/verify` via the API.
3. If still stuck after 20 min, remove + re-add the domain.

---

### `curl https://yourdomain` fails from laptop, works from phone

**Symptom:** Vercel says the domain is Valid; loading it in a browser on your phone works; `curl` from your laptop hangs or fails with `SSL_ERROR_SYSCALL`.

**Cause:** Your laptop is behind a TUN-mode proxy (Clash/Mihomo with fakeip). Local DNS returns `198.18.x.x` which doesn't route to the real Vercel anycast.

**Fix:** Either disable the proxy for the domain, or curl with an explicit resolve:

```bash
REAL_IP=$(dig @1.1.1.1 +short yourdomain | head -1)
curl --resolve "yourdomain:443:$REAL_IP" https://yourdomain/
```

---

### SSL cert never provisions after Vercel says "Valid Configuration"

**Symptom:** DNS verified, "Valid Configuration" green, but `https://` returns SSL error or "no certificate" for 10+ min.

**Cause:** Your registrar has CAA records that block Let's Encrypt from issuing.

**Fix:** Add a CAA record at the registrar:

```
yourdomain. CAA 0 issue "letsencrypt.org"
```

Wait 5 min for Vercel to retry. Vercel will auto-issue once CAA allows.

---

### macOS osascript permission errors

**Symptom:** `osascript` invocation errors with `execution error: System Events got an error (1002)` or similar.

**Cause:** Your script tried to use System Events for keystroke simulation, which requires Accessibility permission for the Terminal app.

**Fix:**
- Avoid System Events. Use only Chrome's `execute active tab javascript` — that doesn't need Accessibility.
- If you must use System Events: System Settings → Privacy & Security → Accessibility → enable Terminal (or your IDE's embedded terminal).

---

## Vercel

### CI deploys fail "VERCEL_TOKEN ... is not valid" — every day

**Symptom:** the GitHub Actions deploy worked yesterday, today the `vercel pull`
step fails with `The token provided via VERCEL_TOKEN environment variable is not
valid`. You re-set the secret, it works, next day it breaks again.

**Cause:** the secret holds the **Vercel CLI session token** (from
`~/Library/Application Support/com.vercel.cli/auth.json`). That token rotates
~daily, so CI breaks every time it expires.

**Fix:** use a real **no-expiration Personal Access Token** from
vercel.com/account/tokens as `VERCEL_TOKEN`. You can't mint a PAT from the
session token (`vercel tokens create` and `POST /v3/user/tokens` both reject it:
"Only user authentication tokens can be used to create new tokens") — create it
in the dashboard. See `references/vercel.md`.

### Whole domain returns 403, body is a challenge page, `x-vercel-mitigated: challenge`

**Symptom:** every path 403s to `curl`, but the site loads fine in a real
browser.

**Cause:** Vercel Attack Challenge Mode — often auto-triggered by an aggressive
`until curl ...; do sleep; done` deploy-verification loop hammering the domain.
It serves a JS proof-of-work; browsers solve it, `curl` can't.

**Fix:** `POST /v1/security/attack-mode {attackModeEnabled:false}` (see
`references/vercel.md`). And stop tight-looping curl against the live domain —
check `gh run view` for deploy status instead, or space requests 15s+.

---

## Email / SMTP

### Signups 500 / no email arrives / "can only send to your own address"

**Symptom:** auth emails don't arrive; Supabase returns 500 "Error sending
confirmation email"; or your email provider says you can only send to your own
account address.

**Cause:** the provider (Resend/SendGrid/SES/…) requires **domain verification**
before it will send to arbitrary recipients. A "full-access" API key does NOT
bypass this — key permission and domain verification are unrelated.

**Fix:** either verify a sending domain (DKIM/SPF/MX DNS records), or use a real
mailbox's SMTP (Gmail App Password / QQ / Outlook) which sends to anyone with no
DNS. Full playbook in `references/email.md`.

### Supabase custom SMTP PATCH returns 200 but nothing changes

**Symptom:** you PATCH `/config/auth` with smtp fields, get 200, but emails still
use the built-in mailer and the smtp fields read back as null.

**Cause:** `smtp_port` was sent as an integer (`465`). The config validator wants
a **string** (`"465"`).

**Fix:** send `"smtp_port": "465"`. To disable custom SMTP later, set smtp fields
to `null` (not `""` — empty string fails email validation on `smtp_admin_email`).
