# Supabase deep dive

## Key formats — what's what

As of 2026 Supabase uses prefixed keys:

| Key | Format | Where to use |
|---|---|---|
| Project URL | `https://<ref>.supabase.co` | Public, browser + server |
| Publishable key | `sb_publishable_<...>` | Browser-side anon — replaces old "anon JWT" |
| Secret key | `sb_secret_<...>` | Server-only service-role — replaces old "service_role JWT" |
| Personal Access Token (PAT) | `sbp_<hex>` | Your laptop only — for Management API + CLI |
| DB password | shown once at project creation | Postgres pooler, CLI `supabase link` |

**Important**: older `@supabase/supabase-js` SDKs (< 2.x of the 2026 line) reject the `sb_*` keys. They expect JWT format. Bump SDK version before using new keys in production.

## Management API (use when DB direct-connect is blocked)

Base: `https://api.supabase.com/v1/projects/<project-ref>`

Auth header on every request:

```
Authorization: Bearer <SUPABASE_PAT>
```

### Run arbitrary SQL

```
POST /database/query
Content-Type: application/json

{ "query": "SELECT 1;" }
```

Multi-statement migrations work. Each statement runs in order. Errors return `4xx` with `{ message, code }` JSON.

### List tables

```sql
SELECT tablename FROM pg_tables WHERE schemaname = 'public';
```

### List RLS policies

```sql
SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'public';
```

### Other useful endpoints

- `GET /` — project metadata
- `GET /secrets` — list edge function secrets
- `POST /secrets` — set edge function secrets
- `GET /functions` — list edge functions
- `GET /database/backups` — backup list (Pro only)

Full surface: https://api.supabase.com/api/v1

## Why Path B (Management API) exists

Direct postgres on `:5432` requires:
- IPv6 connectivity for the un-pooled `db.<ref>.supabase.co` hostname (Supabase deprecated IPv4 direct in 2024).
- Either the DB password, OR being logged in via `supabase login`.
- A network that doesn't NAT-block non-HTTPS ports.

**Networks that block 5432** (in practice):
- Clash / Mihomo in TUN mode with fakeip (`198.18.0.0/15`) — the resolved IP isn't routable.
- Most corporate firewalls.
- Some hotel / coffee shop WiFi.
- ISP-level transparent proxies in certain regions.

The Management API is HTTPS-only, so it works through any proxy that passes HTTPS.

## Pooler fallback (if you must use TCP)

`db.<ref>.supabase.co:5432` is IPv6-direct. The Pooler at `aws-0-<region>.pooler.supabase.com:6543` is IPv4 + transaction-mode + uses the DB password. Use:

```
postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres?pgbouncer=true
```

This bypasses the IPv6 issue. Not all corporate firewalls will allow port 6543 either; try API first.

## RLS — the patterns that matter

Enable on every table that holds user data:

```sql
ALTER TABLE my_table ENABLE ROW LEVEL SECURITY;
```

Then declare per-action policies. Common shape:

```sql
-- Users can SELECT their own rows
CREATE POLICY "users see own rows"
  ON my_table FOR SELECT
  USING (auth.uid() = user_id);

-- Users can INSERT only with their own user_id
CREATE POLICY "users insert own rows"
  ON my_table FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Users can UPDATE their own rows
CREATE POLICY "users update own rows"
  ON my_table FOR UPDATE
  USING (auth.uid() = user_id);
```

**Service-role bypass:** when using the `sb_secret_*` key on the server, RLS is bypassed by default. That's why server-side mutations work without policies. Never expose `sb_secret_*` to the browser.

**Common RLS mistake**: forgetting `WITH CHECK` on `INSERT`. `USING` is checked on read-back; `WITH CHECK` is checked on write. Always declare both for `INSERT`/`UPDATE`.

## Auth callback URLs

After project creation:
1. **Authentication → URL Configuration**.
2. Site URL: your production origin (no trailing slash). Example: `https://myapp.vercel.app`.
3. Redirect URLs: `https://myapp.vercel.app/**` and any preview deployments you want to allow (`https://myapp-*-myorg.vercel.app/**`).

Forgetting this is the #1 cause of "Site URL mismatch" on OAuth callbacks.

## Free tier specifics

- 500 MB database (includes indexes; vacuum aggressively if you're near the cap).
- 50,000 MAU (monthly active users).
- 1 GB storage.
- **7-day inactivity = project paused.** Any HTTP request to the project (or a logged-in dashboard view) resets the timer. A GitHub Actions ping every few days is enough.
- 5 GB egress / month.

## When to pay

- > 500 MB. Pro is $25/mo and includes 8 GB.
- Need PITR backups.
- Need SLA / commercial support.

## Project pausing — the silent killer

A paused free project: no requests work, no dashboard access without resume. The dashboard shows a banner to resume.

Avoid by:
1. Production traffic naturally keeps it warm.
2. If pre-launch, set up a GitHub Actions workflow that pings any endpoint daily.

```yaml
# .github/workflows/keep-supabase-warm.yml
on:
  schedule:
    - cron: "0 6 * * *"   # daily
jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - run: curl -sf "${{ secrets.NEXT_PUBLIC_SUPABASE_URL }}/auth/v1/health"
```
