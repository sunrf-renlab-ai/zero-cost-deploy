---
name: zero-cost-deploy
description: Use when deploying a web app to production for $0/month on a free-tier stack — Next.js on Vercel + Render (long-running) + Supabase (Postgres/Auth/Storage/Realtime/pgvector) + Upstash + Cloudflare DNS, plus Stripe (payments), Resend (email), Clerk (auth), PostHog (analytics), Sentry (errors), and Pinecone (vectors). Covers the strict order of services, the patterns that work across all of them (Management API > UI automation, ClipboardEvent paste trick, OAuth+GitHub-App separation, network-aware fallbacks for Clash/Mihomo fakeip), and the gotchas that have actually broken real first-time deploys (Vercel Hobby daily-only cron limit, Supabase 5432 blocked by proxies, Render Blueprint silently dropping env vars, GitHub OAuth anti-bot delay, Stripe webhook raw-body signature, Resend domain DNS, Clerk NEXT_PUBLIC_ env + middleware filename, PostHog region/ad-block, Cloudflare grey-cloud in front of Vercel, Pinecone index dimension). Trigger phrases: "deploy this", "ship to prod", "put online", "免费上线", "zero-cost host", "how do I deploy".
---

# Zero-Cost Production Deploy

The path from a working web codebase to a live free-tier stack. Every form, every secret, every weird network quirk, every gotcha that broke a real deploy — documented so the next person doesn't re-discover them.

## The stack

Free-tier caps verified 2026-06. **Core platform** (the spine — every deploy uses these):

| Service | Role | Free-tier caps |
|---|---|---|
| **Vercel Hobby** | Next.js frontend + full-stack, short API routes, daily cron | 100 GB bandwidth · 60 s function timeout · daily-only crons · no commercial use |
| **Render Free** | Long-running services (WebSocket hubs, workers, anything > 60 s), Docker, sub-daily cron | 512 MB RAM · sleeps after 15 min idle · 750 hr/month |
| **Supabase Free** | **Default backend**: Postgres + Auth + RLS + Storage + Realtime + pgvector | 500 MB DB · 50 K MAU · 1 GB Storage · project pauses after 7 days inactivity |
| **Upstash Redis Free** | Rate limiting, concurrency locks, light queues, ephemeral state | 10 K commands/day · 256 MB |
| **Cloudflare Free** | DNS (authoritative, ~unlimited records) + edge/CDN + Universal SSL; optional Pages hosting | Unmetered DNS/CDN/SSL · Pages: 500 builds/mo, unlimited bandwidth |
| **GitHub** | Version control + Actions CI + scheduled jobs the free tier won't allow | Actions: 2 K min/mo private, unlimited public |

**Application services** (add the ones your app needs):

| Service | Role | Free-tier caps |
|---|---|---|
| **Stripe** | Payments — cards, checkout, subscriptions, Connect payouts | **$0 fixed** (no monthly/setup fee) · 2.9% + $0.30 per successful card charge · test mode free + unlimited |
| **Resend Free** | Transactional + broadcast email (React Email templating) | 3 K emails/mo · 100/day · 1 verified domain · 5 req/s |
| **Clerk Free (Hobby)** | Drop-in auth — sessions, social login, orgs, prebuilt UI _(alt to Supabase Auth)_ | 50 K monthly-active (retained) users · 100 orgs · MFA + de-branding are Pro ($25/mo) |
| **PostHog Free** | Product analytics + session replay + feature flags | 1 M events/mo · 5 K replays/mo · set per-product $0 cap to never get billed |
| **Sentry Free** | Error monitoring + sourcemaps | 5 K errors/mo |
| **Pinecone Starter** | Managed vector DB _(alt to Supabase pgvector)_ | 2 GB storage · 5 serverless indexes · 2 M write / 1 M read units/mo · AWS us-east-1 only |
| **Namecheap / any registrar** | Domain registration | ~$12/year for a `.com` (≈ $1/mo) |

**Monthly cost: $0** for the platform tier. Variable: domain ~$12/yr (≈$1/mo) · Stripe 2.9% + $0.30 per transaction (no fixed fee) · every other service is free until you outgrow a cap above.

Skip individual layers you don't need. The patterns below apply whether you use one service or all of them.

## Tech-stack mapping (default picks)

| Layer | Default | Notes |
|---|---|---|
| Frontend / full-stack | **Next.js** (on Vercel) | — |
| Backend | **Supabase** | DB + Auth + Storage + Realtime + pgvector, one project |
| Long-running / workers | **Render** | anything that can't fit Vercel's 60 s budget |
| Payments | **Stripe** | — |
| Email | **Resend** | — |
| Analytics | **PostHog** | — |
| Error monitoring | **Sentry** | — |
| Cache / light queue | **Upstash** | Redis over REST |
| Domain / DNS / edge | **Cloudflare** + any solid registrar (Namecheap) | DNS-only (grey cloud) in front of Vercel |

**Alternatives in the kit** — swap in when you don't want Supabase's built-ins: **Clerk** for auth instead of Supabase Auth; **Pinecone** for vectors instead of Supabase pgvector. Both are in the stack table with their free tiers; the deploy steps below default to Supabase.

## When NOT to use this stack

- **Sub-second cold start matters** — Render Free sleeps after 15 min. First request after idle waits 30–60 s. A scheduled warmup helps but doesn't eliminate.
- **Commercial monetization on Vercel** — Hobby plan explicitly bans this. Either upgrade to Pro ($20/seat/mo) or move frontend to Cloudflare Pages (allows commercial use, also free).
- **Postgres > 500 MB or > 50 K MAU** — Supabase Free caps. Either pay or shard out.
- **Heavy compute > 512 MB RAM** — Render Free cap. Cloudflare Workers is a different free-tier option for stateless work.
- **Multi-region writes** — Everything in this stack is single-region on free tier. Pay for replicas.
- **You need always-on with HIPAA/SOC2** — Free tiers don't sign BAAs or compliance agreements.

## Pre-flight (5 min)

```bash
brew install bun supabase/tap/supabase gh jq curl
```

Generate random secrets up front. **Save the output to a temp file** — you'll paste these values into Vercel + Render in later steps.

```bash
~/.claude/skills/zero-cost-deploy/scripts/gen-secrets.sh
```

That prints lines like:

```
APP_ENCRYPTION_KEY=UAsi…sbM=          # 32 random bytes, base64 — for AES-GCM at rest
INTERNAL_RPC_TOKEN=CnE5…m5k           # for Vercel↔Render auth
CRON_SECRET=qDyY…+PlD                 # for cron route authorization
```

**Important:** any secret used by BOTH Vercel and Render must be the **same value** in both. The script generates each secret once. Don't re-roll them per service.

## Order of operations — strict

```
1. Supabase    → emits project_ref + URL + service_role key
2. Upstash     → independent; can parallel with Render
3. Render      → uses Supabase URL + service_role key + shared RPC token
4. Add-ons     → Stripe / Resend / Clerk / PostHog / Pinecone — independent; grab each key now (§③.5)
5. Cloudflare  → add domain as a zone, point DNS at Vercel (grey cloud)
6. Vercel      → uses everything above (paste all env at once)
7. Smoke test  → scripts/verify-deploy.sh
8. Rotate      → any secret that touched terminal output or chat
```

GitHub Actions for CI runs implicitly on push; for scheduled jobs (warming Render, releases), add the workflow at any point.

---

## ① Supabase

Sign up + new project at https://supabase.com/dashboard. Region close to your users (`us-east-2`, `ap-northeast-1`, etc.). Free plan.

After project creates, **Project Settings → API → Data API** has the values you need:

| Field | Use as |
|---|---|
| Project URL | `NEXT_PUBLIC_SUPABASE_URL` (or whatever your framework names it) |
| Publishable key (`sb_publishable_…`) | Browser-side anon key |
| Secret key (`sb_secret_…`) | `SUPABASE_SERVICE_ROLE_KEY` — server-only, never exposed |
| Project ID / Ref (substring of URL) | `<project-ref>` for CLI / Management API |

> Note: Supabase migrated to `sb_publishable_…` / `sb_secret_…` keys in 2026. Older `@supabase/supabase-js` versions only know the JWT-format keys; bump to ≥ 2.x.

### Pushing migrations — two paths

**Path A (default): CLI**

```bash
supabase login        # opens browser; requires CLI ≥ 1.219
supabase link --project-ref <project-ref>
supabase db push --linked
```

**Path B: Management API (when behind Clash/Mihomo/corporate firewall)**

If you see `tls error (EOF)` or `dial timeout` on `db.<ref>.supabase.co:5432`, your network's blocking direct postgres. (Clash fakeip mode uses `198.18.0.0/15`; corporate firewalls often block raw TCP to non-standard ports.) HTTPS works.

1. Generate a Personal Access Token: https://supabase.com/dashboard/account/tokens → Generate → copy `sbp_…`.
2. Run:

```bash
SUPABASE_PAT="sbp_…" PROJECT_REF="<ref>" \
  ~/.claude/skills/zero-cost-deploy/scripts/supabase-push-migration.sh path/to/migration.sql
```

The script POSTs your full SQL to `POST /v1/projects/<ref>/database/query`. Multi-statement migrations work. Errors come back as JSON; the script exits non-zero on any error.

3. Verify:

```bash
SUPABASE_PAT="…" PROJECT_REF="…" \
  ~/.claude/skills/zero-cost-deploy/scripts/supabase-verify-tables.sh
```

In Studio: Table Editor should list all your tables; each table's Policies tab should show your RLS policies.

See `references/supabase.md` for the full Management API surface.

---

## ② Upstash Redis

Console: https://console.upstash.com/. GitHub OAuth signup works.

**Recommended: create the DB via Management API.** Upstash's UI uses a React combobox for region selection that ignores synthetic JS events — you'll fight it if you try to script. The API is bulletproof.

1. Generate a developer API key: https://console.upstash.com/account/api → **Create API Key** → name it, Read/Write, set expiry → copy the UUID key. Note your account email — Upstash uses HTTP Basic Auth with `email:apikey`.
2. Create the database:

```bash
UPSTASH_EMAIL="you@example.com" \
UPSTASH_API_KEY="<uuid>" \
DB_NAME="myapp-rate-limit" \
PRIMARY_REGION="us-east-1" \
  ~/.claude/skills/zero-cost-deploy/scripts/upstash-create-redis.sh
```

The script prints `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`.

3. Verify:

```bash
curl -H "Authorization: Bearer $UPSTASH_REDIS_REST_TOKEN" "$UPSTASH_REDIS_REST_URL/PING"
# → {"result":"PONG"}
```

See `references/upstash.md` for region options, global vs regional, eviction config.

---

## ③ Render

Use if your app has anything that can't fit in Vercel's 60 s function budget: WebSocket servers, long-running orchestration, background workers, scheduled jobs more frequent than daily.

### Repo prep

You need three files in your repo root (templates included):

- `render.yaml` — Blueprint defining the service(s)
- `Dockerfile` — multi-stage, fits 512 MB
- `.env.example` — all env vars (Render reads which ones to prompt from `render.yaml`)

### Sign up + connect repo

1. https://dashboard.render.com → **Get Started → GitHub** OAuth using your repo's org.
2. Render sends an email verification — **you have to click that link**; OAuth alone doesn't unlock the dashboard.
3. Dashboard → **New → Blueprint** → connect your repo.
4. If the org isn't visible: click **Configure account** under GitHub → install Render's GitHub App for the right org → return to Render and refresh.

### Apply the Blueprint

Render parses `render.yaml`, shows env vars marked `sync: false` for you to fill. Provide values from the secrets you generated + Supabase keys.

Click **Apply**. Build runs (3–5 min on first deploy of free tier).

### **GOTCHA**: Verify env vars actually saved

When applying the Blueprint, the env values may **silently fail to save** if your React state is in a weird place (or if you scripted the form). The Service builds with EMPTY env vars and crashes at boot.

**Always check after first deploy:** Service → Environment → click **Edit** → confirm actual values. If empty, paste them in and click **Save, rebuild, and deploy**.

### Verify

```bash
curl https://<your-service>.onrender.com/healthz
# → ok
```

---

## ③.5 Add-on services — grab keys before Vercel

Each is independent: sign up, grab the credential, note the env var. Wire them into the **Vercel env paste** (step ④) so they ship in one shot. Caps verified 2026-06. Default backend is still Supabase — **Clerk** and **Pinecone** are here only if you're swapping out Supabase Auth / pgvector.

> **Wire the payment-funnel observability trio early: PostHog + Sentry + Stripe webhook replay.** Once real charges flow, "why did this checkout fail / did the webhook actually fire / where did the user drop off?" is only answerable if PostHog (funnel + drop-off), Sentry (server errors), and replayable Stripe events were already capturing. Stripe lets you **resend** any past event (Dashboard → event → Resend, or `stripe events resend <evt_id>`) — invaluable for re-driving a failed webhook against a fixed handler. Retrofitting these after a paid-path bug means the events that would've explained it are already gone. Cheap up front, expensive in hindsight.

### Stripe (payments)

Dashboard → Developers → API keys: `pk_…` (browser → `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY`) + `sk_…` (server → `STRIPE_SECRET_KEY`). Add a webhook endpoint → copy its `whsec_…` into `STRIPE_WEBHOOK_SECRET`. **$0 fixed cost; 2.9% + $0.30 per live charge.** `sk_test_` mode is free + unlimited for dev.

- **GOTCHA**: the webhook HMAC is computed over the **raw** body. In App Router read `await req.text()` (never `req.json()`) before `stripe.webhooks.constructEvent(...)`, or every event 400s with `SignatureVerificationError`. Test and live are **separate endpoints with separate `whsec_`** — the local `stripe listen` secret won't verify prod events.
- https://stripe.com/pricing

### Resend (email)

resend.com/api-keys → Create (value shown **once**) → `RESEND_API_KEY`. `npm i resend`, send server-side only. **Free: 3 K emails/mo · 100/day · 1 verified domain · 5 req/s.** Pro $20/mo = 50 K/mo.

- **GOTCHA**: sending from your own domain needs DNS verification — publish DKIM + SPF (TXT) + a bounce **MX** on a sending **subdomain** (`send.example.com`, not the root). On Cloudflare set those records **DNS-only (grey cloud)**; proxying breaks verification. Until verified you can only send from `onboarding@resend.dev` to your own account email. Resend marks the domain "failed" if records aren't seen within 72 h.
- https://resend.com/pricing · deeper notes in `references/email.md`

### Clerk (auth — alternative to Supabase Auth)

Dashboard → API keys → `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_…` + `CLERK_SECRET_KEY=sk_…`. `npm i @clerk/nextjs`, export `clerkMiddleware()` from the root middleware file. **Free Hobby: 50 K monthly-active (retained) users + 100 orgs** (MFA + de-branding are Pro $25/mo).

- **GOTCHA**: the publishable key MUST keep the `NEXT_PUBLIC_` prefix or the client SDK never initializes. The middleware file is `middleware.ts` on Next ≤ 15 but **`proxy.ts` on Next 16+** — wrong filename = auth context missing everywhere.
- https://clerk.com/pricing

### PostHog (analytics)

Project Settings → public `phc_…` key → `NEXT_PUBLIC_POSTHOG_KEY` + `NEXT_PUBLIC_POSTHOG_HOST` (`https://us.i.posthog.com` **or** `https://eu.i.posthog.com`). **Free: 1 M events/mo · 5 K session replays/mo.** Set each product's billing limit to **$0** → overage is dropped, never charged.

- **GOTCHA**: US and EU clouds are **separate hosts that don't sync** — wrong host silently drops every event. 30 %+ of users ad-block `*.posthog.com`; reverse-proxy through your own domain on an **obscure path** (managed proxy or a Cloudflare Worker — Vercel rewrites burn Edge quota; replays are 1–5 MB each).
- https://posthog.com/pricing

### Cloudflare (DNS + edge)

Add the domain as a zone → switch the registrar's nameservers to Cloudflare's two NS → add Vercel's records (apex `A 76.76.21.21` or CNAME; apex CNAME is auto-flattened). **Free: unmetered DNS/CDN/Universal-SSL, ~unlimited records.**

- **GOTCHA**: in front of Vercel keep the records **DNS-only (grey cloud)**. Orange-cloud stacks two CDNs + two SSL terminations and — unless SSL/TLS mode is **Full** or **Full (strict)** — loops infinitely (525/526). Vercel itself recommends DNS-only.
- https://www.cloudflare.com/plans/free/

### Pinecone (vectors — alternative to Supabase pgvector)

app.pinecone.io (auto-enrolls free Starter) → console → API key → `PINECONE_API_KEY` (server only). `npm i @pinecone-database/pinecone`. **Free Starter: 2 GB storage · 5 serverless indexes · 2 M write / 1 M read units/mo.**

- **GOTCHA**: Starter indexes are locked to **AWS us-east-1** (latency if your app runs elsewhere). The index **dimension must exactly match your embedding model** (1536 for OpenAI `text-embedding-3-small`, 1024 for `llama-text-embed-v2`, …) or every upsert/query throws. Over 2 GB / WU / RU caps = hard **403/429**, not overage billing.
- https://www.pinecone.io/pricing/

---

## ④ Vercel

1. https://vercel.com/new → **Continue with GitHub**.
2. If "Install the GitHub application for the accounts you wish to Import from": click **Install** → grant Vercel access to your repo's org.
3. Back on vercel.com/new, find your repo → **Import**.
4. On the project config page:
   - Framework: auto-detected (Next.js, etc.)
   - Project Name: edit if you don't want Vercel's auto-suffix. Vercel appends a random suffix (e.g. `-amiz`) when your preferred name is taken globally.
   - **Don't click Deploy yet.** Expand **Environment Variables** first.

### Paste all env vars at once — the ClipboardEvent trick

**This is the magic.** Vercel's env var form has React-controlled value inputs that ignore synthetic `input` events. But it **does** listen for the clipboard `paste` event and auto-parses `KEY=VALUE` pairs into separate rows.

Format your env block:

```
NEXT_PUBLIC_SUPABASE_URL=https://<ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=sb_publishable_…
SUPABASE_SERVICE_ROLE_KEY=sb_secret_…
UPSTASH_REDIS_REST_URL=https://….upstash.io
UPSTASH_REDIS_REST_TOKEN=…
NEXT_PUBLIC_ORCHESTRATOR_URL=https://<your-render>.onrender.com
INTERNAL_RPC_TOKEN=…
CRON_SECRET=…
# … plus whatever else your app needs
```

Click the empty **Key** input (placeholder `EXAMPLE_NAME`), then paste (Cmd+V). All rows expand.

If automating via JS in DevTools:

```js
const block = `KEY1=value1\nKEY2=value2\n…`;
const keyInput = document.querySelector('input[placeholder="EXAMPLE_NAME"]');
const dt = new DataTransfer();
dt.setData('text/plain', block);
keyInput.focus();
keyInput.dispatchEvent(new ClipboardEvent('paste', {
  clipboardData: dt, bubbles: true, cancelable: true,
}));
```

Remove any blank rows that remain (the **Deploy** button stays disabled if any row has empty Key or Value).

### **GOTCHA**: Vercel Hobby blocks sub-daily crons

If `vercel.json` has any cron more frequent than once a day (`*/N`, `0 * * * *`, etc.), Deploy is rejected with:

> "Hobby accounts are limited to daily cron jobs."

**Fix**: move sub-daily crons to GitHub Actions. Template at `templates/workflows/scheduled.yml`. GitHub Actions on a public repo is free and has no schedule cap.

Keep Vercel cron schedules at `MM HH * * *` (daily). Up to 3 daily crons on Hobby.

### Deploy

Click **Deploy**. ~2 min for a typical Next.js 16 build.

If the build log shows:
- `metadataBase property not set` — cosmetic warning. Runtime `VERCEL_URL` is auto-injected, so OG image URLs resolve at request time. Ignore.
- Build fails on a specific commit — check the env vars are present; missing required env is the most common cause.

After deploy:
- `<project>-<random>.vercel.app` — unique deployment URL (preview, may 401 on private deployments)
- `<project>.vercel.app` — production alias (the public URL)

### Custom domain (optional, ~5 min)

The auto-generated `<project>-<suffix>.vercel.app` URL is fine for a prototype but ugly for real users. Bring your own domain:

1. **At your DNS host** (Cloudflare / Route 53 / Namecheap / etc.) — add a CNAME:

   | Type | Name | Value | TTL |
   |---|---|---|---|
   | CNAME | `pair` (subdomain) or `@` (apex) | `cname.vercel-dns.com` | 300 |

   Apex / naked domains: many DNS hosts don't allow CNAME at the root. Use an `ALIAS` / `ANAME` record instead, or use a flattened-CNAME provider like Cloudflare. Vercel also provides `A` records (`76.76.21.21`) if you must use plain A — check Vercel's docs for the current IP set.

2. **In Vercel** — Project → Settings → Domains → **Add** → enter the FQDN (e.g., `pair.renlab.ai`) → Save.

   Vercel auto-verifies the CNAME from its own resolvers (not yours), then provisions an SSL cert. Verification + cert: usually 60–120 s. If your local DNS goes through a TUN proxy (Clash/Mihomo), you won't be able to `curl` the domain from your laptop until you bypass the proxy — but Vercel's check still passes.

3. **Watch for "Verification Needed"** — clears automatically once Vercel sees the CNAME. If it sits longer than ~10 min:
   - Confirm CNAME with an external resolver: https://dnschecker.org/#CNAME/pair.example.com
   - Check for conflicting records (existing A or AAAA at the same name takes precedence over CNAME).
   - Click **Refresh** in the Vercel UI to force a re-check.

4. **Update `NEXT_PUBLIC_SITE_URL`** (and equivalent env vars) in Vercel to the new domain, then redeploy so absolute links + OG metadata point at the canonical host.

5. **Set the primary domain** — Settings → Domains → click the domain → **Set as Primary**. Vercel now 308-redirects all other aliases to it.

Cost: ~$10/year for a `.com` / `.ai` / etc. — paid to your registrar, not Vercel.

#### Automating via Vercel API (optional)

```bash
curl -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v10/projects/$PROJECT_ID/domains" \
  -d '{"name":"pair.renlab.ai"}'
```

Adds the domain + kicks off verification. Polling endpoint: `GET /v9/projects/$PROJECT_ID/domains/pair.renlab.ai` returns `{verified: true|false, ...}`.

---

## ④.5 Auto-deploy via GitHub Actions (when Vercel's GitHub App isn't an option)

Vercel's native GitHub integration installs a GitHub App on the repo owner.
It's the smoothest path — but **the App can't be auto-installed**. The owner
has to click through `https://github.com/apps/vercel/installations/new`,
which means you can't fully script first-time deploys.

You also can't use it when:
- The deploying account (e.g. `gh` logged in as `someone-else`) lacks repo
  Settings → Secrets write permission on the target repo
- You want **path-filtered** triggers (monorepo: only `web/**` deploys; CLI
  changes don't burn CI minutes)
- You want CI-controllable build/test gating before the deploy promotes

Workaround: **deploy via Vercel CLI from GitHub Actions** using a stored
token. Setup is one workflow file + three repo secrets.

### Setup

```bash
# 1. Get a Vercel token. Best practice: vercel.com/account/tokens → New →
#    name "ci-<project>", set scope, ~1 year expiry. MVP shortcut: use the
#    CLI's own session token (~/Library/Application Support/com.vercel.cli
#    /auth.json on macOS). Either way rotate before sharing the repo.
VT=$(cat ~/Library/Application\ Support/com.vercel.cli/auth.json \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"], end="")')

# 2. Find the project + org IDs.
PROJECT_ID=$(cat web/.vercel/project.json | jq -r .projectId)
ORG_ID=$(cat web/.vercel/project.json | jq -r .orgId)

# 3. Push them as repo secrets. CRITICAL: use --body, NOT `echo | --body -`.
#    Echo's trailing newline ends up in the secret value and Vercel CLI then
#    rejects the env var with the cryptic "must not contain ***" (see GOTCHA
#    below for what's happening). Direct --body avoids it entirely.
gh secret set VERCEL_TOKEN      --repo OWNER/REPO --body "$VT"
gh secret set VERCEL_ORG_ID     --repo OWNER/REPO --body "$ORG_ID"
gh secret set VERCEL_PROJECT_ID --repo OWNER/REPO --body "$PROJECT_ID"
```

### Workflow file

Drop this at `.github/workflows/deploy-web.yml`. Replace `web` with your
sub-directory (or remove `working-directory:` for repos with the Next.js
app at the root).

```yaml
name: Deploy web → Vercel

on:
  push:
    branches: [main]
    paths: ["web/**", ".github/workflows/deploy-web.yml"]
  pull_request:
    branches: [main]
    paths: ["web/**"]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: web } }
    env:
      # Pass via env, NOT `--token` flag. See GOTCHA below.
      VERCEL_TOKEN:     ${{ secrets.VERCEL_TOKEN }}
      VERCEL_ORG_ID:    ${{ secrets.VERCEL_ORG_ID }}
      VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm install -g vercel@latest
      - name: Pull env
        run: |
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            vercel pull --yes --environment=preview
          else
            vercel pull --yes --environment=production
          fi
      - name: Build
        run: |
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            vercel build
          else
            vercel build --prod
          fi
      - name: Deploy
        run: |
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            vercel deploy --prebuilt
          else
            vercel deploy --prebuilt --prod
          fi
```

### Project setting — **clear `rootDirectory`**

If your workflow uses `working-directory: web`, set the Vercel project's
`rootDirectory` to `null`. Otherwise both layers prepend `web/` and the CLI
ends up looking at `web/web/package.json` — `ENOENT`.

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "content-type: application/json" \
  "https://api.vercel.com/v9/projects/$PROJECT_ID?teamId=$ORG_ID" \
  -d '{"rootDirectory":null}'
```

(The inverse — keep `rootDirectory=web` on the project, drop
`working-directory` from the workflow — also works. Pick one.)

### GOTCHA: do NOT use `--token` flag (and: no trailing newline in the secret)

Two distinct traps. Both produce the same error:

> `Error: You defined "***token", but its contents are invalid. Must not contain: "***"`

The `***` is GitHub Actions redacting characters that *happen to be in your
secret value*. Trailing `\n` in the secret causes substring matching across
runner output to flag every `-` and `--` as redacted. The error message and
the entire command line become unparseable garbage.

**Fix 1 (always do this):** pass `VERCEL_TOKEN` via `env:`, not via
`--token "${{ secrets.X }}"`. The CLI reads `VERCEL_TOKEN` natively; the
flag is unnecessary. This eliminates the flag-redaction angle entirely.

**Fix 2 (always do this):** when storing the secret, use `gh secret set
--body "$VAR"`, not `echo "$VAR" | gh secret set --body -`. Echo appends
`\n`; the newline corrupts the value and triggers the redaction storm above.

### Verify

```bash
gh run list --repo OWNER/REPO --workflow "deploy-web.yml" --limit 1
# in_progress → completed,success expected in ~60-90s
gh workflow run "Deploy web → Vercel" --repo OWNER/REPO --ref main
```

After the first green run, add a `deployed_via: "github-actions"` marker to
your `/api/health` route and push it — confirms the new pipeline (not a
prior manual `vercel --prod`) put the build in production.

---

## ⑤ Smoke test

```bash
WEB_URL=https://<your-app>.vercel.app \
ORCH_URL=https://<your-orch>.onrender.com \
  ~/.claude/skills/zero-cost-deploy/scripts/verify-deploy.sh
```

The script asserts:
- Landing page returns 200
- Locale routing (if i18n) works at `/en`, `/zh`, etc.
- Internal-token-protected endpoints reject unauthenticated requests with 403
- Orchestrator `/healthz` returns `ok`

All green = ship-ready.

---

## ⑥ Rotate exposed secrets

Anything that appeared in your terminal output, chat transcripts, screenshots, or commits is **leaked**. Rotate before sharing the URL with real users.

| Type | Where to rotate |
|---|---|
| Supabase `sb_secret_…` (service_role) | Dashboard → Settings → API → revoke → create new → update Vercel + Render env |
| Supabase PAT (`sbp_…`) used for migrations | https://supabase.com/dashboard/account/tokens → delete |
| Upstash management API key (UUID) | https://console.upstash.com/account/api → delete |
| Generated AES-GCM / HMAC keys for at-rest encryption | If users haven't created encrypted data yet: regenerate and update Vercel + Render. **If users have stored encrypted data**: rotating invalidates it — implement a key-versioning rewrap before rotation. |
| Inter-service RPC token (Vercel↔Render) | Regenerate, update BOTH services (must match) |
| `CRON_SECRET` | Regenerate, update Vercel |

`scripts/rotate-secrets.md` has a step-by-step checklist.

---

## Universal patterns

### Management API > UI automation

Every service in this stack has a REST API. **Always prefer the API**:

- The UI breaks: React state ignores synthetic events (Upstash region picker, Vercel env value textareas), `react-hook-form` doesn't update from `dispatchEvent`, macOS osascript lacks Accessibility permission for keyboard simulation.
- The API doesn't break: HTTPS + JSON, works the same in every network condition, scriptable, version-controllable.

The one-time UI interaction is generating an API key. After that, everything else is `curl`.

### ClipboardEvent for paste-aware React forms

When a service has a `.env` import or KEY=VALUE paste UX, this works where simple input events don't:

```js
const dt = new DataTransfer();
dt.setData('text/plain', envBlock);
input.dispatchEvent(new ClipboardEvent('paste', {
  clipboardData: dt, bubbles: true, cancelable: true,
}));
```

React's `onPaste` handler runs against the synthetic ClipboardEvent and updates internal state. **Works on Vercel env vars and several other places** (file upload zones with paste fallback, etc.).

Doesn't work for:
- Simple text inputs without a paste handler (only respond to keyboard)
- Combobox / dropdown selections (need actual keyboard events, which require OS-level Accessibility permission)

### OAuth identity vs GitHub App permissions

Render and Vercel both use:
1. **GitHub OAuth** for sign-in (identity, one-time per user)
2. **A separate GitHub App** for repo permissions (one-time per org)

If you see "No repositories found" after sign-in: the GitHub App isn't installed for the right org. Click **Configure account** → install the App on the org → return.

### Network-aware fallbacks

If you're behind Clash, Mihomo, a corporate firewall, or any TUN-mode proxy:
- DNS may return `198.18.0.0/15` fakeip addresses for non-domestic hosts
- Direct TCP to non-HTTPS ports (5432, 6379) fails
- Use Management APIs (HTTPS-only) for everything that has them
- Use REST API (`/PING`, `/GET`, `/SET`) instead of native Redis protocol

The scripts in this skill use API paths by default for this reason.

### Anti-bot delays

GitHub's OAuth Authorize button stays `disabled` for 2-4 s on the page-load animation. JavaScript clicks DURING that window are silently ignored (the click event isn't trusted).

If automating: detect the disabled state, sleep until enabled, **then ask the user to click manually** — GitHub's check often requires a trusted user gesture (real mouse movement) that JS can't synthesize without OS-level accessibility.

The same applies to:
- hCaptcha challenges
- Stripe's anti-fraud checks
- Some Vercel "deploy" confirmations on first project import

---

## Catalog of gotchas

See `references/gotchas.md` for the full list. Highlights:

| Gotcha | Symptom | Fix |
|---|---|---|
| Clash/Mihomo fakeip | `supabase db push` timeout on 5432 | `scripts/supabase-push-migration.sh` (Management API over HTTPS) |
| Render Blueprint env loss | Service deploys but crashes on missing env | Edit env vars manually after Blueprint creation, click Save+rebuild |
| Vercel Hobby cron limit | Deploy rejected with "limited to daily" | Move sub-daily crons to GitHub Actions |
| Vercel env paste fail | Value cells empty after `dispatchEvent('input')` | Use `ClipboardEvent('paste')` instead |
| Vercel CLI in CI: "must not contain ***" | GitHub redacts `--` in args when secret value has trailing `\n` | (a) pass `VERCEL_TOKEN` via env not `--token`; (b) `gh secret set --body "$X"`, never `echo "$X" \| gh secret set --body -` |
| Vercel CI: `ENOENT: …/web/web/package.json` | Both Vercel project's `rootDirectory=web` AND workflow `working-directory: web` apply, doubling the path | Clear one of them: `PATCH /v9/projects/$ID {"rootDirectory":null}` |
| GitHub OAuth anti-bot | Authorize button stuck disabled | Manual click — JS can't synthesize trusted gesture |
| Render Free cold start | First request after idle waits 30–60 s | Schedule a ping every 13 min via GitHub Actions |
| OAuth account picker | Username text split across DOM nodes, JS click misses | Find `<form action="…/oauth/authorize_app">` and call `.submit()` |
| Supabase 5432 IPv6-only | `Network is unreachable` from some hosts | Management API; Supabase pooler is IPv4 but needs DB password |
| GitHub Actions on retagged tag | Workflow doesn't re-run | `git push origin :refs/tags/X` first, then re-tag |
| Vercel auto-suffix | Project URL has `-xxxxx` random suffix | Either accept it or rename project in Settings → General |
| `metadataBase` warning | Build warns about localhost OG | Set `NEXT_PUBLIC_SITE_URL` in Vercel, or trust runtime `VERCEL_URL` |
| Supabase service_role key rotated | App breaks after old key revoked | Update both Vercel AND Render in same minute; restart Render service |
| Upstash command exhaustion | 429 from REST endpoint | Free tier is 10 K commands/day; cache aggressively or upgrade |
| Vercel CI token "not valid" daily | Secret holds the CLI session token, which rotates ~daily | Use a no-expiration PAT from vercel.com/account/tokens, not `auth.json` |
| Whole domain 403, `x-vercel-mitigated: challenge` | Attack Challenge Mode (often tripped by tight curl-polling loops) | `POST /v1/security/attack-mode {attackModeEnabled:false}`; stop polling the live domain |
| Auth email won't reach users / "can only send to your own address" | Provider needs domain verification before sending to strangers (full-access key doesn't bypass) | Verify a domain, OR use a real mailbox's SMTP (Gmail App Password) — no DNS. See `references/email.md` |
| Supabase SMTP PATCH 200 but no effect | `smtp_port` sent as int | Send `"smtp_port": "465"` (string) |
| Stripe webhook 400s every event | `constructEvent` throws `SignatureVerificationError` | Read raw body via `await req.text()` (not `req.json()`); each endpoint has its own `whsec_`, test ≠ live |
| Resend domain "failed" / can only send to self | DKIM/SPF/MX not detected within 72 h | Publish records on a sending **subdomain**; Cloudflare **grey-cloud** (DNS-only) |
| Clerk auth context missing everywhere | wrong middleware filename or non-public key | `middleware.ts` (Next ≤15) / `proxy.ts` (Next 16+); publishable key needs `NEXT_PUBLIC_` prefix |
| PostHog events silently dropped | wrong region host, or ad-blocker on `*.posthog.com` | Match US/EU host to the project; reverse-proxy on an obscure path |
| Cloudflare 525/526 loop in front of Vercel | orange-cloud proxy + Flexible SSL | Grey-cloud (DNS-only), or set SSL mode **Full (strict)** |
| Pinecone upsert/query throws | index dimension ≠ embedding model output | Create the index with the model's exact dim (1536/1024/…); Starter is us-east-1 only |

---

## Skill structure

```
zero-cost-deploy/
├── SKILL.md                                # this file — the entry point
├── README.md                               # README for humans browsing the repo
├── references/
│   ├── supabase.md                         # Management API endpoints, RLS patterns
│   ├── upstash.md                          # Region options, REST surface
│   ├── render.md                           # Blueprint quirks, env var workarounds
│   ├── vercel.md                           # Hobby limits, paste trick, PAT vs session token, env-via-API, attack mode
│   ├── email.md                            # Transactional email / magic links — SMTP, Resend domain verification, Gmail App Password
│   ├── management-apis.md                  # Per-service REST endpoints catalog
│   ├── browser-automation.md               # When to use osascript, when not to
│   └── gotchas.md                          # Every weird issue + fix
├── scripts/
│   ├── gen-secrets.sh                      # Pre-flight: generate all randoms
│   ├── supabase-push-migration.sh          # POST SQL via Management API
│   ├── supabase-verify-tables.sh           # Check tables + RLS via API
│   ├── upstash-create-redis.sh             # Create DB via Management API
│   ├── verify-deploy.sh                    # Post-deploy smoke check
│   ├── vercel-add-domain.sh                # Add custom domain + poll verification
│   └── rotate-secrets.md                   # Step-by-step rotation
└── templates/
    ├── render.yaml                         # Generic Bun/Node Blueprint
    ├── Dockerfile                          # Multi-stage, fits 512 MB
    ├── vercel.json                         # Hobby-safe (daily-only) crons
    ├── .env.example
    └── workflows/
        ├── ci.yml                          # Typecheck + test on push/PR
        └── scheduled.yml                   # Every-N-minute cron via GH Actions
```

---

## Source

This skill encodes patterns from a real $0/month production deployment that worked first-try after hitting every gotcha above.

PRs to https://github.com/sunrf-renlab-ai/serverless welcome.
