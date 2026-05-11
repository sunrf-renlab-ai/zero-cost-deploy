#!/usr/bin/env bash
# Add a custom domain to a Vercel project via the Management API.
# Use when you don't want to click through Settings → Domains, or when
# scripting deploys across many projects.
#
# Usage:
#   VERCEL_TOKEN=... PROJECT_ID=prj_... ./vercel-add-domain.sh pair.example.com
#
# Pre-flight: CNAME (or ALIAS / A) must already be in place at your DNS host.
# Confirm with `dig @1.1.1.1 +short pair.example.com CNAME` before running.

set -euo pipefail

: "${VERCEL_TOKEN:?VERCEL_TOKEN not set — generate at https://vercel.com/account/tokens}"
: "${PROJECT_ID:?PROJECT_ID not set — find in Project Settings → General → Project ID (prj_*)}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <domain> [redirect-target]" >&2
  echo "  $0 pair.example.com" >&2
  echo "  $0 www.example.com example.com  # adds www as 308 redirect to apex" >&2
  exit 2
fi

DOMAIN="$1"
REDIRECT_TARGET="${2:-}"

BODY=$(jq -nc --arg name "$DOMAIN" '{name: $name}')
if [[ -n "$REDIRECT_TARGET" ]]; then
  BODY=$(jq -nc \
    --arg name "$DOMAIN" \
    --arg target "$REDIRECT_TARGET" \
    '{name: $name, redirect: $target, redirectStatusCode: 308}')
fi

echo ">> Adding $DOMAIN to project $PROJECT_ID..."

ADD_RESPONSE=$(curl -sS \
  -X POST "https://api.vercel.com/v10/projects/$PROJECT_ID/domains" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY")

if echo "$ADD_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  ERR=$(echo "$ADD_RESPONSE" | jq -r '.error.code // .error.message')
  if [[ "$ERR" == "domain_already_exists" || "$ERR" == "domain_already_in_use" ]]; then
    echo ">> Already attached to this project — continuing to verify."
  else
    echo "!! Vercel error:" >&2
    echo "$ADD_RESPONSE" | jq . >&2
    exit 1
  fi
else
  echo ">> Added."
fi

# Poll verification status — Vercel verifies CNAME from its own resolvers,
# then provisions SSL. Both usually complete in < 90 seconds.
echo ">> Verifying (up to 3 minutes)..."
for i in $(seq 1 36); do
  STATUS=$(curl -sS \
    -H "Authorization: Bearer $VERCEL_TOKEN" \
    "https://api.vercel.com/v9/projects/$PROJECT_ID/domains/$DOMAIN")
  VERIFIED=$(echo "$STATUS" | jq -r '.verified // false')
  if [[ "$VERIFIED" == "true" ]]; then
    echo ">> $DOMAIN: verified."
    echo "$STATUS" | jq '{name, verified, redirect, createdAt}'
    exit 0
  fi
  printf "."
  sleep 5
done

echo ""
echo "!! Not verified within timeout. Current status:"
curl -sS \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$PROJECT_ID/domains/$DOMAIN" | jq .
echo ""
echo ">> Common causes:"
echo "   - CNAME hasn't propagated. Check: dig @1.1.1.1 +short $DOMAIN CNAME"
echo "   - Conflicting A/AAAA record at the same name."
echo "   - DNS host caching despite low TTL. Wait, then re-run."
exit 1
