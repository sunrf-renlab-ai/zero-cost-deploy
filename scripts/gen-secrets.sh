#!/usr/bin/env bash
# Generate all the random secrets you'll need for a fresh zero-cost deploy.
# Run once at the start; paste the output into Vercel + Render env panels.
#
# Safe to re-run — but each run gives NEW values. If you re-roll, you must
# update every service that's already deployed.

set -euo pipefail

# Cross-platform 32-byte base64 (macOS + Linux)
rand_b64() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n='
  else
    head -c 32 /dev/urandom | base64 | tr -d '\n='
  fi
}

# Hex variant — friendlier for things rejecting `+/=`
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | xxd -p -c 64
  fi
}

cat <<EOF
# === Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) ===
# Copy this WHOLE block. Paste into Vercel env paste box.
# Then paste the same KEY=VALUE pairs into Render service env.
# Same secret value MUST be used in both services where they communicate.

# --- Inter-service auth (Vercel ↔ Render) ---
INTERNAL_RPC_TOKEN=$(rand_hex)

# --- Cron route authorization (Vercel daily crons + GH Actions schedules) ---
CRON_SECRET=$(rand_hex)

# --- AES-GCM key for at-rest encryption of user secrets ---
# 32 random bytes, base64. Used by app-side encrypt/decrypt of tokens, PII, etc.
APP_ENCRYPTION_KEY=$(rand_b64)

# --- HMAC secret for signing webhooks / share links ---
WEBHOOK_HMAC_SECRET=$(rand_hex)

# --- Session signing (if not delegating to Supabase Auth) ---
SESSION_SECRET=$(rand_hex)

# === Reminder: rotate any of these that leak to stdout, chat, or commits. ===
EOF
