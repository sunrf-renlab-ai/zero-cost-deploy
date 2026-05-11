# Management API cheat sheet

The thesis: **always prefer the API over the UI.** Every form in this stack has an API endpoint behind it. APIs don't break — UIs do.

## Why APIs beat UIs

| Failure mode | UI hit? | API hit? |
|---|---|---|
| React controlled inputs ignore synthetic events | Yes | No |
| Combobox/dropdown needs OS-level keyboard | Yes | No |
| Anti-bot delays disable buttons silently | Yes | No |
| Page layout changes break selectors | Yes | No |
| Form auto-saves wrong field | Yes | No |
| Form is hidden behind a "Show advanced" toggle | Yes | No |

Every Management API call below is auth + HTTPS + JSON. Scriptable, version-controllable, idempotent where it matters.

## Supabase

Base: `https://api.supabase.com/v1`
Auth: `Authorization: Bearer <PAT>` (PAT format: `sbp_*`)

| Operation | Endpoint |
|---|---|
| Run SQL | `POST /projects/<ref>/database/query` body `{query}` |
| List projects | `GET /projects` |
| Get project | `GET /projects/<ref>` |
| Get API keys | `GET /projects/<ref>/api-keys` |
| Update settings | `PATCH /projects/<ref>` |
| List edge functions | `GET /projects/<ref>/functions` |
| Deploy edge function | `POST /projects/<ref>/functions/deploy` |
| Get/set secrets | `GET|POST /projects/<ref>/secrets` |
| Backups (Pro+) | `GET /projects/<ref>/database/backups` |

PAT scope is account-wide. Treat it like a password.

## Upstash

Base: `https://api.upstash.com/v2`
Auth: HTTP Basic with `<email>:<api_key>` (key format: UUID, from console.upstash.com/account/api)

| Operation | Endpoint |
|---|---|
| Create Redis DB | `POST /redis/database` body `{name, region, primary_region, tls}` |
| List DBs | `GET /redis/databases` |
| Get DB details | `GET /redis/database/<id>` |
| Delete DB | `DELETE /redis/database/<id>` |
| Rotate REST token | `POST /redis/database/<id>/rotate-rest-token` |
| Get stats | `GET /redis/database/<id>/stats` |
| Update primary region | `POST /redis/database/<id>/update-regions` |

Kafka, QStash, Vector each have parallel `/v2/<product>` namespaces.

## Render

Base: `https://api.render.com/v1`
Auth: `Authorization: Bearer <API_KEY>` (get one at dashboard.render.com/u/settings#api-keys)

| Operation | Endpoint |
|---|---|
| List services | `GET /services` |
| Get service | `GET /services/<id>` |
| Trigger deploy | `POST /services/<id>/deploys` body `{clearCache}` |
| Update env vars | `PUT /services/<id>/env-vars` body `[{key, value}]` |
| Get logs | `GET /services/<id>/logs?ownerId=<owner>` |
| List databases | `GET /postgres` (paid plans) |
| Manage cron jobs | `GET /cron-jobs` |

**Important:** Render's API can update env vars cleanly even when the UI's silent-save bug bites. After Blueprint, if env is empty, you can `PUT /services/<id>/env-vars` instead of clicking through the UI.

```bash
curl -X PUT \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  "https://api.render.com/v1/services/$SERVICE_ID/env-vars" \
  -d '[
    {"key":"SUPABASE_URL","value":"https://...supabase.co"},
    {"key":"SUPABASE_SERVICE_ROLE_KEY","value":"sb_secret_..."}
  ]'
```

## Vercel

Base: `https://api.vercel.com/v9` (or v10/v11 depending on resource)
Auth: `Authorization: Bearer <TOKEN>` (token at vercel.com/account/tokens)

| Operation | Endpoint |
|---|---|
| List projects | `GET /v9/projects?teamId=<team>` |
| Get project | `GET /v9/projects/<id-or-name>` |
| Create project | `POST /v9/projects` |
| Get env vars | `GET /v9/projects/<id>/env` |
| Add env var | `POST /v10/projects/<id>/env` body `{key, value, target, type}` |
| Trigger deploy | `POST /v13/deployments` |
| List deployments | `GET /v6/deployments` |
| Create alias | `POST /v2/aliases` |

Env API caveat: each variable is a separate POST. Bulk paste through the UI is faster for first-time setup; API is cleaner for CI-driven env management.

```bash
# Add one env var
curl -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v10/projects/$PROJECT_ID/env" \
  -d '{
    "key":"SUPABASE_SERVICE_ROLE_KEY",
    "value":"sb_secret_...",
    "type":"encrypted",
    "target":["production","preview","development"]
  }'
```

## GitHub (for Actions secrets)

Base: `https://api.github.com`
Auth: `Authorization: Bearer <PAT>` with `repo` scope, or fine-grained PAT with Actions: Write.

| Operation | Endpoint |
|---|---|
| Public key (for encryption) | `GET /repos/<owner>/<repo>/actions/secrets/public-key` |
| Set secret | `PUT /repos/<owner>/<repo>/actions/secrets/<NAME>` body `{encrypted_value, key_id}` |
| Set variable | `POST /repos/<owner>/<repo>/actions/variables` body `{name, value}` |
| Trigger workflow | `POST /repos/<owner>/<repo>/actions/workflows/<file>/dispatches` |

Setting secrets requires libsodium to encrypt against the repo's public key. `gh secret set NAME --body VALUE` handles this for you locally.

## API key hygiene

Each of these tokens is account-wide or repo-wide. Treat them like production credentials:
- Don't commit to git (use `.envrc.local` + direnv, or 1Password CLI).
- Don't echo to terminals you share.
- Rotate annually even without incident.
- Use minimum scope where the platform offers granular permissions (GitHub fine-grained PATs especially).
