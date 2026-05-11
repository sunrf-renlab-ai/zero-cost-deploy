# Vercel deep dive

## Hobby plan — what it actually gives you

| Resource | Cap |
|---|---|
| Bandwidth | 100 GB / month |
| Function execution | 60 s max (Edge: 25 s) |
| Function invocations | 100K / day (Edge: 1M / day) |
| Concurrent builds | 1 |
| Cron jobs | Daily only, up to 3 |
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

## Function timeout — the 60 s line

Any API route that might take longer than 60 s needs to either:
1. Move to Render (long-running service).
2. Move to a queue + worker pattern (Inngest, Vercel Queues with Pro, custom Upstash queue).
3. Stream the response (Edge runtime + ReadableStream) so the wall clock doesn't apply.

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
| Max duration | 60 s | 25 s |
| Free invocations | 100K/day | 1M/day |
| Available APIs | Full Node | Web standards + limited Node compat |
| Native modules | Yes | No (Wasm only) |
| Postgres direct | Yes | Use HTTP-based clients only |

Use Edge for: stream-heavy endpoints, geo-distributed reads, simple JSON APIs.
Use Node for: anything that uses a Node-native lib, file system, heavy CPU.
