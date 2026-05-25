# zero-cost-deploy

> Ship a web app to production for **$0/month** on **Vercel + Render + Supabase + Upstash** free tiers. A Claude Code / Agent Skill (also a human-readable playbook) with every gotcha documented — Hobby cron limits, Blueprint env-loss, `supabase db push` 5432 timeout, ClipboardEvent paste trick, Vercel CLI `Must not contain "***"` in CI, and 20+ more.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) [![Agent Skills spec](https://img.shields.io/badge/spec-agentskills.io-0a7-blue)](https://agentskills.io/specification) [![MCP-first](https://img.shields.io/badge/MCP-first-purple)](https://modelcontextprotocol.io/)

```bash
git clone https://github.com/sunrf-renlab-ai/zero-cost-deploy ~/.claude/skills/zero-cost-deploy
```

Claude Code auto-discovers it. Next time you say **"deploy this"** / **"ship to prod"** / **"免费上线"**, the skill activates. Works in Cursor, Cline, Continue, OpenClaw, and any agent that follows the [Agent Skills spec](https://agentskills.io/specification).

---

## Use this when

You're hitting any of these — or about to wire a fresh free-tier prod stack first time:

- 🟥 **`Hobby accounts are limited to daily cron jobs`** — Vercel rejects your deploy
- 🟥 **`tls error (EOF)`** on `supabase db push` (Clash/Mihomo fakeip blocks port 5432)
- 🟥 **`Error: must not contain "***"`** — Vercel CLI in GitHub Actions
- 🟥 **`Authorization header is badly formatted`** — GitHub MCP refusing to connect
- 🟥 **Render Blueprint apply** completes, then service crashes on missing env
- 🟥 **GitHub OAuth Authorize button** stays disabled 2-4 s after page load; JS clicks ignored
- 🟥 **`sb_publishable_*` rejected** by older `@supabase/supabase-js`
- 🟥 **Vercel env paste form** swallows your values when scripted

…or the broader "I want to deploy free but every tutorial handwaves the broken parts."

## What it actually does

- ✅ **$0/month** — Vercel Hobby + Render Free + Supabase Free + Upstash Free + GitHub Actions
- ✅ **MCP-first** — uses Supabase / Vercel / GitHub MCP tools by default; HTTPS Management API fallback for Render + Upstash (no MCP yet)
- ✅ **Pre-flight self-install** — detects missing CLIs/MCP plugins and installs them (`claude plugin install …`, `brew install …`, `gh auth login`)
- ✅ **Real gotchas, real fixes** — every entry in `references/gotchas.md` is a documented "lost an hour to this" moment with the actual error string + workaround
- ✅ **Reproducible** — secrets generation script, smoke test script, secret rotation playbook, render.yaml + Dockerfile + workflows templates

End-to-end first deploy: ~10 minutes once you have the API keys.

## Stack & free-tier caps

| Service | Role | Cap | MCP |
|---|---|---|---|
| **Supabase Free** | Postgres + Auth + RLS + Storage | 500 MB DB · 50K MAU · pauses 7d idle | ✅ official |
| **Vercel Hobby** | Frontend + short API + daily cron | 100 GB BW · 60 s timeout · daily-only cron · no commercial | ✅ (env vars not exposed) |
| **Render Free** | Long-running, WebSocket, > 60 s, Docker | 512 MB RAM · sleeps 15 min · 750 hr/mo | ❌ — HTTPS API |
| **Upstash Free** | Redis (rate-limit, locks, ephemeral state) | 10K cmd/day · 256 MB | ❌ — HTTPS REST |
| **GitHub Actions** | CI + sub-daily crons | Unlimited on public repos | ✅ |
| **Sentry Free** (opt) | Errors + sourcemaps | 5K errors/month | — |

Monthly bill: **$0**. Optional custom domain: ~$10/year.

## Why this exists

Every "deploy your app for free" guide handwaves the broken parts. They tell you to *click the deploy button* — they don't tell you:

- **Vercel Hobby blocks sub-daily crons** after you've designed your whole app around them
- **Render Blueprint silently saves empty env vars** — service crashloops on boot
- **Clash/Mihomo TUN fakeip** (`198.18.0.0/15`) breaks raw TCP to Supabase Postgres on port 5432
- **GitHub's OAuth Authorize button** has a 2-4 s anti-bot disable window; JS clicks during it are silently ignored
- **Vercel CLI in Actions** dies with `Must not contain "***"` when a trailing `\n` in the secret triggers GitHub's redaction regex to eat `--` in the command line
- The 2026 **`sb_publishable_*` / `sb_secret_*`** key format breaks `@supabase/supabase-js` < 2.x
- **Render Postgres free tier deletes itself after 90 days** (use Supabase instead)
- **Custom domain stuck at "Verification Needed"** when there's a conflicting A/AAAA record at the same name
- **SSL cert never provisions** because of CAA records blocking Let's Encrypt

Each gotcha in `references/gotchas.md` is a real "I lost an hour to this" moment with the exact symptom + working fix.

## Universal patterns

1. **MCP > Management API > UI automation.** Use MCP tools where they exist; fall back to bare HTTPS API; touch UIs only when unavoidable.
2. **ClipboardEvent for paste-aware React forms.** The one synthetic event React's value tracker accepts (Vercel env vars).
3. **OAuth identity vs GitHub App permissions are different things.** Render and Vercel both have this split; conflating them is the #1 "no repos found" cause.
4. **Network-aware fallbacks for TUN proxies.** Clash / Mihomo / corporate firewalls break raw TCP. Use HTTPS Management APIs.
5. **Anti-bot delays are real.** GitHub OAuth Authorize, hCaptcha, Stripe — don't fight them, fall back to manual click.

## What's in here

```
zero-cost-deploy/
├── SKILL.md                            # entry point — 334-line dense playbook
├── references/
│   ├── mcp-tools.md                    # MCP tool catalog per service + curl fallbacks
│   ├── supabase.md                     # Management API, RLS, project pausing, key formats
│   ├── upstash.md                      # Region selection, REST API, rate-limit pattern
│   ├── render.md                       # Blueprint quirks, Dockerfile patterns, cold starts
│   ├── vercel.md                       # Hobby limits, env paste trick, Edge vs Node, custom domain, GH Actions CI deploy
│   ├── management-apis.md              # REST surface for every service
│   ├── browser-fallbacks.md            # Last-resort UI scripting (rare, mostly "don't")
│   └── gotchas.md                      # Real-world breakage catalog with literal error strings
├── scripts/
│   ├── gen-secrets.sh                  # generate randoms (RPC token, CRON_SECRET, AES key, …)
│   ├── supabase-push-migration.sh      # push SQL via HTTPS Management API
│   ├── supabase-verify-tables.sh       # confirm tables + RLS landed
│   ├── upstash-create-redis.sh         # create Redis DB without fighting the UI
│   ├── verify-deploy.sh                # smoke-test a fresh deploy
│   ├── vercel-add-domain.sh            # add custom domain + poll verification
│   └── rotate-secrets.md               # rotation checklist
└── templates/
    ├── render.yaml  Dockerfile  vercel.json  .env.example
    └── workflows/{ci,scheduled}.yml    # GH Actions: CI + sub-daily crons
```

## When NOT to use this stack

- Sub-second cold start required (Render Free sleeps; 30–60 s wake)
- Commercial monetization on Vercel Hobby (banned by ToS — use Cloudflare Pages)
- Postgres > 500 MB or > 50K MAU (Supabase Pro $25/mo)
- Heavy compute > 512 MB RAM (Render Starter $7/mo or Cloudflare Workers for stateless)
- Multi-region writes (everything here is single-region on free)
- HIPAA / SOC2 — free tiers don't sign BAAs

## Install — other agents

Same `git clone`. Then:

| Client | How |
|---|---|
| **Claude Code** | clone into `~/.claude/skills/` — auto-discovered |
| **Cursor** | symlink the dir into Cursor's rules path, or `@-mention` SKILL.md |
| **Cline / Continue** | point the client's instruction file at `SKILL.md` |
| **OpenClaw / Codex CLI** | follows Agent Skills spec — drop into their skills dir |

The skill body references MCP tools (`mcp__plugin_supabase_supabase__*`, `mcp__plugin_vercel_vercel__*`, etc.) — install the equivalent MCP servers in your client. Fallback paths use plain `curl` and standard CLIs, so it degrades gracefully without MCP.

## Contributing

Hit a gotcha that isn't documented? Open a PR adding it to `references/gotchas.md`.

The bar: every entry must be a real issue you (or someone you trust) actually hit. No theoretical "what if X happens" — only "X happened on date Y, here's the exact symptom and the fix."

## Related

- [agentskills.io](https://agentskills.io/specification) — Agent Skills spec
- [anthropics/skills](https://github.com/anthropics/skills) — official Anthropic skills
- [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) — curated cross-agent skill list
- [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) — Claude Code resources

## Keywords

For discoverability: claude code skill · claude code plugin · agent skill · MCP server · zero cost deploy · free tier deploy · vercel hobby · vercel render supabase · supabase upstash redis · 免费上线 · 零成本部署 · vercel 免费 · supabase 免费 · render 免费 · how to deploy free 2026 · indie hacker stack · side project deploy · serverless deploy free · self host alternative · clash mihomo fakeip 5432 · vercel cron limit workaround · render blueprint env empty fix · supabase 5432 timeout fix · vercel CLI must not contain · github mcp authorization header badly formatted

## License

MIT. See `LICENSE`.
