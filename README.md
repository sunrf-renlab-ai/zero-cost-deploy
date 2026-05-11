# zero-cost-deploy

A Claude Code skill (and a human-readable playbook) for shipping a web app to production for **$0/month**. Encodes every form, every secret-handling pattern, every weird-network workaround, and every gotcha that has actually broken a real first-time deploy.

> The stack: **Vercel + Render + Supabase + Upstash + GitHub Actions** (+ optional Sentry).
> Everything sits on free tiers. No credit card required to launch.

## Who this is for

- Indie hackers shipping a side project on a Friday night.
- Open-source maintainers who want a public demo without a hosting bill.
- Teams prototyping before committing to paid infra.
- AI agents (this is a Claude Code skill) that need a reliable deploy playbook.

## What's in here

```
zero-cost-deploy/
├── SKILL.md                      # Skill entry point — Claude loads this first
├── README.md                     # You are here
├── LICENSE
├── references/
│   ├── supabase.md               # Management API, RLS, project pausing, key formats
│   ├── upstash.md                # Region selection, REST API, rate-limit pattern
│   ├── render.md                 # Blueprint quirks, Dockerfile patterns, cold starts
│   ├── vercel.md                 # Hobby limits, paste trick, Edge vs Node
│   ├── management-apis.md        # Cheat sheet for every service's REST surface
│   ├── browser-automation.md     # When (rarely) to script UIs, and how
│   └── gotchas.md                # Catalog of real-world breakage + fixes
├── scripts/
│   ├── gen-secrets.sh            # Pre-flight: generate random secrets
│   ├── supabase-push-migration.sh# Push SQL via Management API (HTTPS-only)
│   ├── supabase-verify-tables.sh # Verify tables + RLS landed
│   ├── upstash-create-redis.sh   # Create Redis DB without fighting the UI
│   ├── verify-deploy.sh          # Smoke test a fresh deploy
│   └── rotate-secrets.md         # Step-by-step rotation playbook
└── templates/
    ├── render.yaml               # Blueprint with safe defaults
    ├── Dockerfile                # Multi-stage Bun image, fits in 512 MB
    ├── vercel.json               # Hobby-safe (daily-only) cron + security headers
    ├── .env.example
    └── workflows/
        ├── ci.yml                # Typecheck + lint + test on push/PR
        └── scheduled.yml         # Sub-daily crons via GitHub Actions
```

## Install as a Claude Code skill

```bash
git clone https://github.com/sunrf-renlab-ai/serverless ~/.claude/skills/zero-cost-deploy
```

That's it. Claude Code auto-discovers skills under `~/.claude/skills/`. Next time you say "deploy this" or "免费上线", the skill kicks in.

## Use without Claude (humans only)

Read `SKILL.md` top to bottom — it's the playbook. Then:

1. `scripts/gen-secrets.sh` to generate randoms.
2. Walk through ① Supabase → ② Upstash → ③ Render → ④ Vercel → ⑤ smoke test.
3. `scripts/rotate-secrets.md` if anything leaked.

Each `references/<service>.md` is a deeper dive for when the SKILL.md summary isn't enough.

## The stack — at a glance

| Service | What it does | Free-tier cap |
|---|---|---|
| **Vercel Hobby** | Frontend, short API routes, daily cron | 100 GB BW · 60 s timeout · daily cron · no commercial use |
| **Render Free** | Long-running services, WebSocket, > 60 s work | 512 MB RAM · sleeps after 15 min · 750 hr/month |
| **Supabase Free** | Postgres + Auth + RLS + Storage | 500 MB DB · 50K MAU · pauses after 7 days idle |
| **Upstash Free** | Redis for rate-limit, locks, ephemeral state | 10K commands/day · 256 MB |
| **GitHub Actions** | CI + sub-daily schedules | Unlimited on public repos |
| **Sentry Free** (opt) | Errors + sourcemaps | 5K errors/month |

Monthly bill: **$0**. Optional custom domain: ~$10/year.

## Why this exists

Every "deploy your app for free" guide on the internet handwaves the broken parts. They tell you to "click the deploy button" — they don't tell you about:

- Vercel's Hobby plan rejecting sub-daily crons after you've configured your whole app around them.
- Render's Blueprint silently saving empty environment variables, leaving your service crashlooping.
- Clash/Mihomo fakeip blocking Supabase's `db.<ref>.supabase.co:5432` so `supabase db push` mysteriously times out.
- GitHub's OAuth Authorize button looking enabled but ignoring clicks for 2-4 seconds after page load.
- The new `sb_publishable_*` / `sb_secret_*` key format breaking SDKs older than 2 months.

Each entry in `references/gotchas.md` is a real "I lost an hour to this" moment. The patterns in SKILL.md are the workarounds that work.

## Universal patterns it teaches you

1. **Management API > UI automation.** Always. Every service has one; use it.
2. **ClipboardEvent for paste-aware React forms.** The only synthetic event React's value tracker accepts.
3. **OAuth identity vs GitHub App permissions are separate.** Render/Vercel both do this; getting them confused is the most common "no repos found" cause.
4. **Network-aware fallbacks.** TUN-mode proxies break raw TCP. Use HTTPS APIs.
5. **Anti-bot delays exist on real buttons.** GitHub OAuth, hCaptcha, Stripe — don't fight them, fall back to manual click.

## When NOT to use this stack

- Sub-second cold start matters (Render free sleeps; 30–60 s wake).
- Commercial monetization on Vercel Hobby (banned by ToS — use Cloudflare Pages instead).
- Postgres > 500 MB or > 50K MAU (upgrade Supabase or shard).
- Heavy compute > 512 MB RAM (upgrade Render or use Cloudflare Workers for stateless).
- Multi-region writes (everything here is single-region on free).

See SKILL.md "When NOT to use this stack" for the full list.

## Contributing

Hit a gotcha that isn't documented? Open a PR adding it to `references/gotchas.md`. Pattern that should be in the universal patterns section? Same.

The bar: every entry must be a real issue you (or someone you trust) actually hit. No theoretical "what if X happens" — only "X happened, here's the symptom and the fix."

## License

MIT. See `LICENSE`.
