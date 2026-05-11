# Render deep dive

## When you need Render

Vercel can't handle:
- **WebSockets** (functions are HTTP, 60 s max)
- **Long-running orchestration** (60 s limit applies to every Edge/Serverless route)
- **Sub-daily crons on Hobby** (`*/N`, `0 * * * *`, etc.)
- **Stateful background workers** (queues, schedulers, daemons)
- **Anything Docker-native** (Vercel runs Node/Python in their own runtime)

Render covers all of these on the Free tier. Cloudflare Workers + Durable Objects is the alternative; Render is friendlier for traditional Docker apps.

## Free tier — what you get

- **Web Service**: 512 MB RAM, 0.1 CPU
- **Sleeps after 15 min idle** — first request waits 30–60 s for cold start
- **750 hr / month** active time. Single 24/7 service is fine.
- **No private network on free**. Cross-service calls go through public HTTPS.
- **PostgreSQL** is offered but is 90-day shutdown trap (database gets deleted). Use Supabase instead.

## Blueprint = `render.yaml`

A reproducible deploy spec checked into your repo. Render parses on each commit and reconciles.

Minimum viable Blueprint:

```yaml
services:
  - type: web
    name: my-orchestrator
    runtime: docker
    region: oregon
    plan: free
    dockerfilePath: ./Dockerfile
    healthCheckPath: /healthz
    envVars:
      - key: NODE_ENV
        value: production
      - key: SUPABASE_URL
        sync: false
      - key: SUPABASE_SERVICE_ROLE_KEY
        sync: false
      - key: INTERNAL_RPC_TOKEN
        sync: false
```

- `sync: false` makes Render prompt for the value during Blueprint apply.
- `value: ...` bakes the value into the file. Use only for non-secrets (NODE_ENV, log levels).
- `region: oregon|ohio|frankfurt|singapore` — pick the one closest to Upstash + your users.

## The Blueprint env-loss gotcha (read carefully)

When you click **Apply** on a Blueprint, Render parses `render.yaml`, prompts for `sync: false` values, then provisions the service.

**Failure mode:** even after typing values in the prompt, some Blueprint applies have created the service with EMPTY environment variables. The build succeeds; the service crashes at boot trying to read undefined env. Logs show "missing SUPABASE_URL" or similar.

This bit has cost real hours. **Always verify post-apply:**

1. Dashboard → your service → **Environment** tab.
2. Each variable should show a non-empty `Value` field.
3. If empty: click **Edit**, paste the value, **Save, rebuild, and deploy**.

This is more reliable than retrying the Blueprint flow. Once env is set manually, future `render.yaml` updates respect the existing values (Render only re-prompts for new variables).

## Dockerfile patterns for 512 MB

Multi-stage builds keep the runtime image small. For Bun:

```dockerfile
FROM oven/bun:1 AS builder
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY . .
RUN bun build src/server.ts --target=bun --outfile=server.js

FROM oven/bun:1-slim
WORKDIR /app
COPY --from=builder /app/server.js ./
COPY --from=builder /app/node_modules ./node_modules
ENV NODE_ENV=production
EXPOSE 8080
CMD ["bun", "run", "server.js"]
```

For Node:

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "dist/server.js"]
```

## Health check `/healthz`

Render polls this every minute. Return 200 with a tiny body:

```ts
app.get('/healthz', () => new Response('ok'));
```

Don't query the database here — Render's polling will hammer your Postgres connection pool unnecessarily. Health = "process is up", not "downstream is up".

## Cold-start mitigation

Render sleeps the free service after 15 min of no requests. First request after sleep:
- ~30 s container boot
- ~5–15 s app boot

Mitigation: ping the service every 13 min. GitHub Actions is the cleanest free way:

```yaml
# .github/workflows/warm.yml
on:
  schedule:
    - cron: "*/13 * * * *"
  workflow_dispatch:

jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - run: curl -sf https://my-orchestrator.onrender.com/healthz
```

Caveat: this consumes ~110 Actions runs/day. Free public repos have unlimited; private repos have 2000 min/month — a 5 s ping × 110 = ~9 min/day, well under cap.

## Logging

Render's log dashboard truncates at ~100 lines. For real logging, ship to a third party:

- **Logflare** (free 5 GB) — drop-in for Cloudflare-style log routing
- **Better Stack** (formerly Logtail, free 1 GB / 3 day retention)
- **Sentry** for errors specifically

Add a logging library client to your app and configure the relevant DSN.

## Region pinning

Once a service is in a region, you can't move it without recreating. Pick once:

| Region | Closest Supabase region | Closest Upstash |
|---|---|---|
| `oregon` (us-west-2) | us-west-2 | us-west-1 / us-west-2 |
| `ohio` (us-east-2) | us-east-2 / us-east-1 | us-east-1 |
| `virginia` (us-east-1) | us-east-1 | us-east-1 |
| `frankfurt` | eu-central-1 | eu-central-1 |
| `singapore` | ap-southeast-1 | ap-southeast-1 |

Cross-region adds 100–200 ms to every DB roundtrip. Worth pinning correctly.

## When to upgrade off free

- Cold starts are a real UX problem (consumer app, not background worker)
- > 512 MB RAM (Starter = $7/mo, 512 MB → 2 GB)
- Need a private network between services
- Need SSH access to the running container

Starter is the obvious next step. Production tier is $25/mo with autoscaling.
