# Upstash Redis deep dive

## Why Upstash (vs other free Redis options)

- **Per-command pricing** — sleeps for free, scales for cents. No idle cost.
- **HTTP REST API** — works through every network. No raw TCP needed.
- **Multi-region read replicas on free** — Global tier is included.
- **Generous free tier** — 10K commands/day is enough for prototypes + low-traffic prod.

Alternatives considered:
- **Redis Cloud free** — 30 MB cap, slower, no REST.
- **Cloudflare KV** — eventual consistency, different semantics.
- **Vercel KV (Upstash under the hood)** — same product, more expensive packaging.

## REST API basics

Every command is `<METHOD> <ENDPOINT>/<COMMAND>/<ARGS>` with `Authorization: Bearer <REST_TOKEN>`.

```bash
# SET key value
curl -X POST \
  -H "Authorization: Bearer $UPSTASH_REDIS_REST_TOKEN" \
  "$UPSTASH_REDIS_REST_URL/SET/mykey/myvalue"
# → {"result":"OK"}

# GET key
curl -H "Authorization: Bearer $UPSTASH_REDIS_REST_TOKEN" \
  "$UPSTASH_REDIS_REST_URL/GET/mykey"
# → {"result":"myvalue"}

# Multi-command pipeline (POST a JSON array of arrays)
curl -X POST \
  -H "Authorization: Bearer $UPSTASH_REDIS_REST_TOKEN" \
  -d '[["SET","a","1"],["SET","b","2"],["GET","a"]]' \
  "$UPSTASH_REDIS_REST_URL/pipeline"
```

## Use cases

1. **Rate limiting** — `@upstash/ratelimit` package is officially supported and beautiful.
2. **Concurrency locks** — `SETNX <key> 1 EX <ttl>` for distributed locks (mutex around scarce resources).
3. **Ephemeral state** — short-lived session data, cache (with TTL).
4. **Counters** — `INCR` is atomic and cheap.
5. **Pub/sub** — Realtime via the JS SDK.

## Region selection

Pick the region closest to your Render/Vercel compute. Round-trip latency dominates Redis perf at this scale.

Common pairings:
- Render Oregon → Upstash `us-west-2`
- Render Ohio → Upstash `us-east-1`
- Render Frankfurt → Upstash `eu-central-1`
- Vercel Singapore → Upstash `ap-southeast-1`

Vercel's default is iad1 (`us-east-1`) but Edge Functions run all over the place — Upstash Global (read replicas) helps. The primary stays in `primary_region`.

## Free tier limits

- **10,000 commands / day** — `MULTI`/`EXEC` counts as N commands. Pipelines count as one per command inside.
- **256 MB max storage**.
- **10K monthly active connections** (REST stateless, so this rarely bites).

When you hit 10K/day: REST returns `429`. Retry-after present.

## Management API

Base: `https://api.upstash.com/v2/redis`

Auth: HTTP Basic with `<email>:<api_key>`. Generate API key at https://console.upstash.com/account/api.

### Create database

```
POST /database
Content-Type: application/json

{
  "name": "myapp-cache",
  "region": "global",
  "primary_region": "us-east-1",
  "tls": true
}
```

`region: "global"` enables read replicas. For single-region, set `region` to the region directly.

### List databases

```
GET /databases
```

### Get details

```
GET /database/<id>
```

### Delete

```
DELETE /database/<id>
```

### Other useful endpoints

- `POST /database/<id>/rotate-rest-token`
- `GET /database/<id>/stats` — command counts
- `POST /database/<id>/update-regions` — change replica regions

## Eviction policy

Free tier defaults to `noeviction` (writes fail when full). Change in dashboard if you want LRU cache semantics:
- `allkeys-lru` — most common cache pattern
- `volatile-lru` — only evict keys with TTL set

## Native Redis protocol (if you must)

Endpoint at `<dbid>.upstash.io:6379` with TLS, password = REST token (yes, same value).

```bash
redis-cli --tls -u "rediss://default:$UPSTASH_REDIS_REST_TOKEN@<host>:6379"
```

Avoid in production code unless you have a specific reason — REST works everywhere, native TCP doesn't.

## Rate-limit pattern (Next.js example)

```ts
import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";

const ratelimit = new Ratelimit({
  redis: Redis.fromEnv(),
  limiter: Ratelimit.slidingWindow(10, "1 m"),
  analytics: true,
});

const { success, remaining } = await ratelimit.limit(`api:${userId}`);
if (!success) return new Response("rate limited", { status: 429 });
```

`Redis.fromEnv()` picks up `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN` automatically.
