# Vercel deep dive

## Hobby plan — what it actually gives you

| Resource | Cap |
|---|---|
| Fast Data Transfer | 100 GB / month (the real metering also caps 1M edge requests, 4 CPU-hrs active CPU, and 1M function invocations / month) |
| Function execution | 300 s max (5 min) on Fluid Compute — both default and max (Edge: 25 s) |
| Function invocations | 1,000,000 / month (Edge: 1M / day) |
| Concurrent builds | 1 |
| Cron jobs | Daily-only frequency, up to 100 per project |
| Custom domains | Unlimited (DNS only — no email forwarding) |
| Team size | 1 (you) |
| **Commercial use** | **Prohibited** |

The commercial-use ban is the biggest gotcha — if you start charging users, Vercel can terminate. Either upgrade to Pro ($20/seat/mo) or move the frontend to Cloudflare Pages (allows commercial on free, similar feature set).

## The env paste trick (canonical)

Vercel's env variable form uses React-controlled inputs that ignore programmatic `input`/`change` events. But the form DOES listen for clipboard `paste` events and auto-parses `KEY=VALUE\nKEY=VALUE` into separate rows.

**Manual flow**:
1. Project Settings → Environment Variables.
2. Click the **Key** input (placeholder: `EXAMPLE_NAME`).
3. Cmd+V (Ctrl+V on Linux) with your env block in the clipboard.
4. Vercel splits the lines into rows.
5. Save.

**Programmatic flow** (paste this in DevTools Console on the env page):

```js
const block = `
NEXT_PUBLIC_SUPABASE_URL=https://...supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=sb_publishable_...
SUPABASE_SERVICE_ROLE_KEY=sb_secret_...
UPSTASH_REDIS_REST_URL=https://....upstash.io
UPSTASH_REDIS_REST_TOKEN=...
INTERNAL_RPC_TOKEN=...
CRON_SECRET=...
`.trim();

const keyInput = document.querySelector('input[placeholder="EXAMPLE_NAME"]');
const dt = new DataTransfer();
dt.setData('text/plain', block);
keyInput.focus();
keyInput.dispatchEvent(new ClipboardEvent('paste', {
  clipboardData: dt,
  bubbles: true,
  cancelable: true,
}));
```

After paste, check:
- Each row has both Key and Value populated.
- Blank trailing rows are removed (the **Add Another** + **Save** flow fights you if a row has empty Key).
- Right scope checkboxes (Production / Preview / Development) are set as you want.

## Why this works (and what doesn't)

Vercel's env form composes with `react-hook-form` or similar. Its value cells are `<textarea>` elements that respond to:
- ✅ Native `paste` event (treated as a real user paste)
- ✅ Native `keydown`/`input` from a real keyboard
- ❌ JS-dispatched `Event('input')` (synthetic events are filtered by React's value tracker)
- ❌ Setting `.value` directly (React detects desync and overwrites)

The paste handler is special because Vercel built it explicitly for `.env` import UX. Most React forms don't have this, so the trick is Vercel-specific.

## Hobby cron limit (the actual error)

If `vercel.json` has anything more frequent than daily:

```json
{
  "crons": [{ "path": "/api/cron/warm", "schedule": "*/14 * * * *" }]
}
```

Deploy fails with:

> Hobby accounts are limited to daily cron jobs. Reduce to one execution per day or upgrade to Pro.

Hobby allows up to **100 cron jobs per project**, so count is not the bottleneck — the constraint is purely **frequency**: each cron can fire at most once per day, and any sub-daily expression fails the deploy.

**Valid Hobby schedules**: `MM HH * * *` only. Examples:
- `0 7 * * *` — daily at 07:00 UTC
- `30 14 * * *` — daily at 14:30 UTC
- `0 0 * * *` — daily midnight UTC

**Workaround for sub-daily**: GitHub Actions schedule (free, unlimited on public repos):

```yaml
# .github/workflows/scheduled.yml
on:
  schedule:
    - cron: "*/14 * * * *"
jobs:
  hit-cron-endpoint:
    runs-on: ubuntu-latest
    steps:
      - run: |
          curl -sfL "https://${{ vars.WEB_HOST }}/api/cron/warm" \
            -H "Authorization: Bearer ${{ secrets.CRON_SECRET }}"
```

Your cron endpoint authenticates via `CRON_SECRET`. Vercel cron and GitHub Actions cron use the same authorization header pattern.

## Project name + auto-suffix

When you import a repo named `foo`, Vercel tries to create a project at `foo.vercel.app`. If that's taken globally (very common), it appends a random suffix: `foo-amiz.vercel.app`.

Options:
- **Accept the suffix** — totally fine for prototypes, the production alias works.
- **Rename** post-import: Project Settings → General → Project Name. Updates URLs.
- **Custom domain**: see next section.

## Custom domain — DNS + verification + SSL

Three moving pieces: registrar, DNS, Vercel project. Order matters: DNS first, then Vercel.

### 1. DNS record at your host

For a **subdomain** (`pair.example.com`):

| Type | Name | Value | TTL |
|---|---|---|---|
| CNAME | `pair` | `cname.vercel-dns.com` | 300 |

For an **apex / naked domain** (`example.com`), most DNS hosts don't allow CNAME at the root. Three options:
- **ALIAS / ANAME** record (Cloudflare, Route 53, DNSimple support this — points to `cname.vercel-dns.com`).
- **Flattened CNAME** (Cloudflare proxies the lookup so apex effectively becomes CNAME-able).
- **Plain A record** to Vercel's anycast IP (`76.76.21.21` at time of writing — Vercel's docs have the current set).

Verify the record propagated **from an external resolver** before continuing:

```bash
dig @1.1.1.1 +short pair.example.com CNAME
# → cname.vercel-dns.com.
```

(If your laptop is behind Clash/Mihomo with fakeip, local `dig` will lie. Use https://dnschecker.org/#CNAME/pair.example.com to confirm.)

### 2. Add domain in Vercel

Project → Settings → Domains → search box → type FQDN → **Add Existing** → confirm in dialog → **Save**.

Vercel does two things in sequence:
1. **Verify CNAME** by querying its own resolvers (not yours). Usually < 30 s.
2. **Provision Let's Encrypt SSL cert**. Usually 30–90 s after verification.

While waiting you'll see "Verification Needed" → "Pending" → "Valid Configuration". The Refresh button forces a re-check.

### 3. Wire it up

Once Valid:
- **Set as Primary** (click the domain → menu → Set as Primary) so all other aliases 308-redirect to it.
- Update `NEXT_PUBLIC_SITE_URL` (and any equivalents — `metadataBase`, OAuth redirect URLs in Supabase, etc.) to the new domain. Redeploy so absolute URLs are correct.
- Update Supabase Auth → URL Configuration → Site URL + Redirect URLs.

### Apex + www together

Common pattern: serve at `example.com`, redirect `www.example.com → example.com` (or vice versa).

In Vercel: add both domains. For the redirect one, click → **Redirect to** → enter the primary, choose 308 Permanent.

### Automating via Vercel API

```bash
# Add domain
curl -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v10/projects/$PROJECT_ID/domains" \
  -d '{"name":"pair.example.com"}'

# Poll verification status
curl -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$PROJECT_ID/domains/pair.example.com" \
  | jq '{verified, verification, gitBranch}'

# Force re-verification
curl -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$PROJECT_ID/domains/pair.example.com/verify"
```

`scripts/vercel-add-domain.sh` wraps these calls.

### Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| "Verification Needed" stuck > 10 min | CNAME hasn't propagated, or there's a conflicting A/AAAA at the same name | Confirm via `dig @1.1.1.1`; remove conflicting records |
| SSL cert pending forever after verification | Domain has CAA records that block Let's Encrypt | Add a CAA `0 issue "letsencrypt.org"` record at registrar |
| `curl https://your-domain` fails from your laptop, works on phone | Your laptop is behind a TUN-mode proxy returning fakeip (Clash/Mihomo) | Bypass proxy for the domain, or use `curl --resolve` with the real IP from `dig @1.1.1.1` |
| OAuth callback "Site URL mismatch" after switching to custom domain | Forgot to update Supabase Auth → URL Configuration | Add new domain to Site URL + Redirect URLs |
| Old `*.vercel.app` URL still indexed by Google | Aliases keep working but redirect 308 to primary; you can also robots-block them | Set primary domain; Vercel auto-redirects |

## Preview URL 401 vs production URL 200

Vercel deploys two URLs per deployment:
- `<project>-<sha>-<team>.vercel.app` — preview URL, tied to commit
- `<project>.vercel.app` — production alias (the public URL)

Preview URLs may return 401 on private deployments (Settings → Security → Vercel Authentication). Production aliases are always public unless you've enabled team-wide auth.

**When debugging "my smoke test gets 401"**: hit the production alias, not the preview URL.

## `metadataBase` warning

```
metadataBase property in metadata export is not set
```

Cosmetic. Means OG image absolute URLs default to `localhost:3000` during build. Runtime `VERCEL_URL` env is auto-injected, so at request time the URLs resolve fine.

Fix (optional): set `NEXT_PUBLIC_SITE_URL` and reference it in `app/layout.tsx`:

```ts
export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? 'https://example.com'),
  // ...
};
```

## Function timeout — the 300 s line

With Fluid Compute (default-on for new projects since 2025-04), Hobby functions run up to **300 s (5 minutes)** — both the default and the max. Most "long" work now fits inside that envelope, so Render is no longer needed just to dodge a 60 s wall.

Any API route that might still exceed 300 s needs to either:
1. Move to Render (long-running service).
2. Move to a queue + worker pattern (Inngest, Vercel Queues with Pro, custom Upstash queue).
3. Stream the response (Edge runtime + ReadableStream) so the wall clock doesn't apply.
4. Use **Vercel Workflows** — durable, pausable/resumable steps with **no overall duration limit** — for genuinely unbounded execution.

For LLM streaming specifically, Edge runtime + `StreamingTextResponse` from `ai` package handles this elegantly.

## Cron auth pattern

Vercel sends `Authorization: Bearer <CRON_SECRET>` to cron paths. Your handler:

```ts
export async function GET(req: Request) {
  const auth = req.headers.get('authorization');
  if (auth !== `Bearer ${process.env.CRON_SECRET}`) {
    return new Response('unauthorized', { status: 401 });
  }
  // ... do work
  return Response.json({ ok: true });
}
```

The same handler works for GitHub Actions schedule (above) since it sends the same header.

## Edge vs Node runtime

Default: Node. Set per-route:

```ts
export const runtime = 'edge'; // or 'nodejs' (default)
```

| | Node | Edge |
|---|---|---|
| Cold start | Slower (~300 ms) | Fast (~50 ms) |
| Max duration | 300 s | 25 s |
| Free invocations | 1M/month | 1M/day |
| Available APIs | Full Node | Web standards + limited Node compat |
| Native modules | Yes | No (Wasm only) |
| Postgres direct | Yes | Use HTTP-based clients only |

Use Edge for: stream-heavy endpoints, geo-distributed reads, simple JSON APIs.
Use Node for: anything that uses a Node-native lib, file system, heavy CPU.

## Auto-deploy via GitHub Actions (when Vercel's GitHub App isn't an option)

Vercel's native GitHub integration installs a GitHub App on the repo owner. Smoothest path — but **the App can't be auto-installed**. The owner has to click through `https://github.com/apps/vercel/installations/new`, so you can't fully script first-time deploys.

You also can't use it when:
- The deploying account (e.g. `gh` logged in as `someone-else`) lacks repo Settings → Secrets write permission on the target repo
- You want **path-filtered** triggers (monorepo: only `web/**` deploys; CLI changes don't burn CI minutes)
- You want CI-controllable build/test gating before the deploy promotes

Workaround: **deploy via Vercel CLI from GitHub Actions** using a stored token. Setup is one workflow file + three repo secrets.

### Setup

```bash
# 1. Get a Vercel token.
#    *** USE A REAL PAT, NOT THE CLI SESSION TOKEN. ***  vercel.com/account/tokens
#    → Create → name "ci-<project>", scope = the team, Expiration = No Expiration
#    (or 1y). Store it: `security add-generic-password -U -a "$USER" -s <name> -w 'vcp_...'`
#
#    The CLI session token (~/Library/Application Support/com.vercel.cli/auth.json)
#    is tempting but it ROTATES ~daily — every CI deploy after it expires fails with
#    "The token provided via VERCEL_TOKEN environment variable is not valid", and you
#    end up re-setting the secret before every push. A no-expiration PAT ends that loop.
#    (You can't mint a PAT from the session token via API — `vercel tokens create` and
#    POST /v3/user/tokens both reject it with "Only user authentication tokens can be
#    used to create new tokens." So the PAT must be created in the dashboard.)
VT=$(security find-generic-password -s pp-vercel-pat -w)   # the PAT you stored above

# 2. Find the project + org IDs.
PROJECT_ID=$(cat web/.vercel/project.json | jq -r .projectId)
ORG_ID=$(cat web/.vercel/project.json | jq -r .orgId)

# 3. Push as repo secrets. CRITICAL: use --body, NOT `echo | --body -`.
#    Echo's trailing newline ends up in the secret value and Vercel CLI then
#    rejects the env var with `Must not contain "***"` (see GOTCHA below).
gh secret set VERCEL_TOKEN      --repo OWNER/REPO --body "$VT"
gh secret set VERCEL_ORG_ID     --repo OWNER/REPO --body "$ORG_ID"
gh secret set VERCEL_PROJECT_ID --repo OWNER/REPO --body "$PROJECT_ID"
```

### Workflow file

Drop at `.github/workflows/deploy-web.yml`. Replace `web` with your sub-directory (or remove `working-directory:` for repos with the Next.js app at the root).

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

### Project setting — clear `rootDirectory`

If your workflow uses `working-directory: web`, set the Vercel project's `rootDirectory` to `null`. Otherwise both layers prepend `web/` and the CLI looks at `web/web/package.json` → `ENOENT`.

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "content-type: application/json" \
  "https://api.vercel.com/v9/projects/$PROJECT_ID?teamId=$ORG_ID" \
  -d '{"rootDirectory":null}'
```

(Inverse — keep `rootDirectory=web` on the project, drop `working-directory` from the workflow — also works. Pick one.)

### GOTCHA: do NOT use `--token` flag (and: no trailing newline in the secret)

Two distinct traps. Both produce the same error:

> `Error: You defined "***token", but its contents are invalid. Must not contain: "***"`

The `***` is GitHub Actions redacting characters that *happen to be in your secret value*. Trailing `\n` in the secret causes substring matching across runner output to flag every `-` and `--` as redacted. The error message and the entire command line become unparseable garbage.

**Fix 1 (always do this):** pass `VERCEL_TOKEN` via `env:`, not via `--token "${{ secrets.X }}"`. The CLI reads `VERCEL_TOKEN` natively; the flag is unnecessary. Eliminates the flag-redaction angle.

**Fix 2 (always do this):** when storing the secret, use `gh secret set --body "$VAR"`, not `echo "$VAR" | gh secret set --body -`. Echo appends `\n`; the newline corrupts the value and triggers the redaction storm above.

### Verify

```bash
gh run list --repo OWNER/REPO --workflow "deploy-web.yml" --limit 1
# in_progress → completed,success expected in ~60-90s
gh workflow run "Deploy web → Vercel" --repo OWNER/REPO --ref main
```

After the first green run, add a `deployed_via: "github-actions"` marker to your `/api/health` route — confirms the new pipeline (not a prior manual `vercel --prod`) put the build in production.

---

## Setting env vars via the REST API (no UI, no CLI link)

The paste trick is for humans at the dashboard. To script env vars from CI or a
setup tool, hit the API directly — works without `vercel link`:

```bash
VT=$(security find-generic-password -s pp-vercel-pat -w)
TEAM="team_xxx"   # your team id
PRJ=$(curl -s -H "Authorization: Bearer $VT" \
  "https://api.vercel.com/v9/projects?teamId=$TEAM&search=my-project" | jq -r '.projects[0].id')

curl -s -X POST "https://api.vercel.com/v10/projects/$PRJ/env?teamId=$TEAM&upsert=true" \
  -H "Authorization: Bearer $VT" -H "Content-Type: application/json" \
  -d '{"key":"NEXT_PUBLIC_SUPABASE_URL","value":"https://x.supabase.co",
       "type":"plain","target":["production","preview","development"]}'
```

- `upsert=true` makes it idempotent (set-or-update).
- `type`: `plain` for non-secrets (incl. `NEXT_PUBLIC_*`, which are exposed to the
  browser anyway), `encrypted` for secrets.
- `target` must be an array. `NEXT_PUBLIC_*` vars need `production` AND `preview`
  AND `development` or the build won't see them.
- Env-var changes do NOT redeploy. Trigger a fresh deploy after.

## Attack Challenge Mode — when curl gets 403 but browsers work

**Symptom:** every path on your domain returns `403`, the body is an Astro-ish
challenge page, and the response headers include:

```
x-vercel-mitigated: challenge
x-vercel-challenge-token: ...
```

**Cause:** Vercel's Attack Challenge Mode is on (auto-triggered by a traffic spike
— e.g. an aggressive `until curl ...; do` polling loop hammering the domain during
deploy verification). It serves a JS proof-of-work that real browsers solve
silently, so the site is fine for users — but `curl` (no JS) can't pass, so every
scripted check returns 403 and looks like a total outage.

**Fix:** disable it via the API (needs a valid token):

```bash
VT=$(security find-generic-password -s pp-vercel-pat -w)
TEAM="team_xxx"; PRJ="prj_xxx"
curl -s -X POST "https://api.vercel.com/v1/security/attack-mode?teamId=$TEAM" \
  -H "Authorization: Bearer $VT" -H "Content-Type: application/json" \
  -d "{\"projectId\":\"$PRJ\",\"attackModeEnabled\":false}"
# → {"attackModeEnabled":false,...}  (edge propagation takes a minute)
```

**Avoid re-triggering it:** don't poll the live domain in tight loops. Verify via
the GitHub Actions run status (`gh run view`) or space curls out (15s+). A
headless browser (Playwright) also passes the challenge if you must check rendered
output.
