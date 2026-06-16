#!/usr/bin/env bash
# Smoke test a fresh deploy. Returns 0 if everything's green, non-zero on any failure.
#
# Usage:
#   WEB_URL=https://your-app.vercel.app \
#   ORCH_URL=https://your-svc.onrender.com \
#     ./verify-deploy.sh
#
# Optional:
#   LOCALES="en zh"   # locale prefixes to test against WEB_URL (skip if no i18n)
#   PROTECTED_PATH=/api/internal/ping  # must return 401/403 without auth
#   STRIPE_WEBHOOK_PATH=/api/stripe/webhook  # bad-signature POST must return 400

set -euo pipefail

: "${WEB_URL:?WEB_URL not set}"
WEB_URL="${WEB_URL%/}"

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAILED=1; }

FAILED=0
echo ">> Smoke test"

# 1. Landing page
CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$WEB_URL/")
if [[ "$CODE" =~ ^(200|307|308)$ ]]; then
  pass "GET $WEB_URL → $CODE"
else
  fail "GET $WEB_URL → $CODE (expected 200/307/308)"
fi

# 2. Locale routing (optional)
if [[ -n "${LOCALES:-}" ]]; then
  for loc in $LOCALES; do
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$WEB_URL/$loc")
    if [[ "$CODE" == "200" ]]; then
      pass "GET $WEB_URL/$loc → 200"
    else
      fail "GET $WEB_URL/$loc → $CODE"
    fi
  done
fi

# 3. Protected endpoint (optional)
if [[ -n "${PROTECTED_PATH:-}" ]]; then
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$WEB_URL$PROTECTED_PATH")
  if [[ "$CODE" =~ ^(401|403)$ ]]; then
    pass "GET $WEB_URL$PROTECTED_PATH (no auth) → $CODE"
  else
    fail "GET $WEB_URL$PROTECTED_PATH (no auth) → $CODE (expected 401/403)"
  fi
fi

# 4. Orchestrator health (optional)
if [[ -n "${ORCH_URL:-}" ]]; then
  ORCH_URL="${ORCH_URL%/}"
  # Render free cold start can take 30-60 s — be patient on first hit
  BODY=$(curl -sS --max-time 90 "$ORCH_URL/healthz" || true)
  if [[ "$BODY" == "ok" || "$BODY" == *'"status":"ok"'* ]]; then
    pass "GET $ORCH_URL/healthz → ok"
  else
    fail "GET $ORCH_URL/healthz → '$BODY' (expected 'ok' or {status:ok})"
  fi
fi

# 5. Stripe webhook signature enforcement (optional)
# POST a payload with a bogus Stripe-Signature; a correctly wired handler must
# reject it at signature verification with 400 (not 200, 401, or 500).
if [[ -n "${STRIPE_WEBHOOK_PATH:-}" ]]; then
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$WEB_URL$STRIPE_WEBHOOK_PATH" \
    -H "Content-Type: application/json" \
    -H "Stripe-Signature: t=0,v1=deadbeef" \
    --data '{"id":"evt_bad","object":"event"}')
  if [[ "$CODE" == "400" ]]; then
    pass "POST $WEB_URL$STRIPE_WEBHOOK_PATH (bad signature) → 400"
  else
    fail "POST $WEB_URL$STRIPE_WEBHOOK_PATH (bad signature) → $CODE (expected 400)"
  fi
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo ">> All checks passed."
  exit 0
else
  echo ">> One or more checks failed."
  exit 1
fi
