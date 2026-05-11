# Secret rotation checklist

Run this after a deploy if any of the following happened:
- Secrets appeared in terminal output, chat transcripts, screenshots, or commits.
- A team member left.
- You're suspicious of a leak.
- It's been > 90 days.

## Pre-rotation prep

1. **Inventory.** List every secret you generated. The `gen-secrets.sh` output is one set; you also have provider secrets (Supabase service_role, PAT; Upstash management key; service REST token).
2. **Coordinate.** Rotation involves brief downtime. Decide between:
   - **Hot rotation**: update Vercel + Render env nearly simultaneously. ~30 s of mismatch where one service has old key, other has new. Acceptable for low-traffic.
   - **Versioned rotation**: app reads `KEY_V1` AND `KEY_V2`, you add V2, deploy, remove V1, deploy again. Zero downtime but requires code support.
3. **Schedule**. Off-peak hours.

## Per-secret rotation

### Supabase `sb_secret_*` (service_role)

1. Dashboard → **Project Settings → API → Secret keys**.
2. Click **Revoke** on the current key. **Note**: this immediately invalidates it. Schedule the next step in the same minute.
3. Click **Generate new secret key**. Copy.
4. Update Vercel env: Settings → Environment Variables → edit `SUPABASE_SERVICE_ROLE_KEY` → Save → **Redeploy** the production deployment.
5. Update Render env: Service → Environment → edit `SUPABASE_SERVICE_ROLE_KEY` → Save+rebuild+deploy.

### Supabase Personal Access Token (`sbp_*`)

Used only for migrations from your laptop. Has no production runtime impact.

1. https://supabase.com/dashboard/account/tokens → find the token → **Delete**.
2. Generate a fresh one only when you next need to run a migration.

### Upstash Redis REST token

1. https://console.upstash.com/redis → click your DB → **REST API** tab.
2. Click **Rotate REST Token**. (Some plans require deleting + recreating the DB. If so, follow the database-recreation flow below.)
3. Update Vercel + Render `UPSTASH_REDIS_REST_TOKEN`. Redeploy.

#### If your plan requires DB recreation:
1. Create new DB via `scripts/upstash-create-redis.sh`.
2. Update env to new URL + token.
3. Deploy.
4. Delete old DB.

### Upstash management API key (UUID, scoped to console)

1. https://console.upstash.com/account/api → find key → **Delete**.
2. Don't generate a new one until you need to script DB creation again.

### Inter-service RPC token (`INTERNAL_RPC_TOKEN`)

The token Vercel and Render use to authenticate to each other.

**Hot rotation** (brief inflight-request rejection):
1. `rand_hex` to generate new value.
2. Update Vercel env → Save (do not redeploy yet).
3. Update Render env → Save+rebuild+deploy. Wait for service to be healthy.
4. Redeploy Vercel production. Both services now use new token.

**Versioned rotation** (zero downtime, requires app code):
1. Add `INTERNAL_RPC_TOKEN_V2` to both services. Server code accepts `V1 OR V2`.
2. Deploy. Service now accepts both.
3. Swap the env vars so clients use V2.
4. Deploy.
5. Remove V1 from server + envs. Deploy.

### App encryption key (`APP_ENCRYPTION_KEY`)

**Cannot rotate naively** if any user data is encrypted with it. Rotation invalidates all existing ciphertexts.

Three options:
- **No encrypted data yet**: regenerate, update both services, deploy. Done.
- **Has data, OK with re-prompting users**: regenerate, then either delete + re-prompt for encrypted blobs (re-encryption on next use), or accept the data loss.
- **Has data, must preserve**: implement key versioning.
  1. Store key version alongside ciphertext: `{v: 1, ct: "..."}`.
  2. Add `APP_ENCRYPTION_KEY_V2`. App can decrypt with V1, encrypt fresh with V2.
  3. Deploy.
  4. Run a background re-encryption job to migrate V1 → V2.
  5. Remove `APP_ENCRYPTION_KEY` (V1) when no V1 ciphertexts remain.

### Webhook HMAC + session secrets

Same logic as RPC token: hot rotation or versioned. Versioned is safer when sessions are live — old sessions stay valid until the V1 key is removed.

### `CRON_SECRET`

Hot rotation is fine; only used by your own scheduled jobs.

1. Generate new value.
2. Update Vercel env. Redeploy.
3. Update GitHub Actions secret if applicable: repo → Settings → Secrets → Actions → edit `CRON_SECRET`. Workflows pick up the new value on next run.

## Post-rotation verification

```bash
WEB_URL=https://your-app.vercel.app \
ORCH_URL=https://your-svc.onrender.com \
  ~/.claude/skills/zero-cost-deploy/scripts/verify-deploy.sh
```

If any check fails, the new env didn't propagate. Force-redeploy both services.

## Audit log

Track every rotation. Example template (paste into a private doc):

```
2026-XX-XX  Rotated: SUPABASE_SERVICE_ROLE_KEY, INTERNAL_RPC_TOKEN
Reason:     Initial deploy leaked secrets in terminal output
By:         <name>
Verified:   verify-deploy.sh green at 14:32 UTC
```
