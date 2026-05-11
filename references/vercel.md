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
- **Custom domain**: Settings → Domains → add your own. Vercel issues a cert in ~1 min.

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
