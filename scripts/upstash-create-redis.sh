#!/usr/bin/env bash
# Create a free Upstash Redis database via the Management API.
# Skips the React combobox in the dashboard that fights synthetic events.
#
# Usage:
#   UPSTASH_EMAIL=you@example.com \
#   UPSTASH_API_KEY=<uuid-from-console.upstash.com/account/api> \
#   DB_NAME=myapp-cache \
#   PRIMARY_REGION=us-east-1 \
#     ./upstash-create-redis.sh
#
# Primary regions (pick one close to your Render/Vercel region):
#   us-east-1, us-west-1, us-west-2, eu-west-1, eu-central-1,
#   ap-northeast-1, ap-southeast-1, sa-east-1

set -euo pipefail

: "${UPSTASH_EMAIL:?UPSTASH_EMAIL not set}"
: "${UPSTASH_API_KEY:?UPSTASH_API_KEY not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${PRIMARY_REGION:?PRIMARY_REGION not set}"

echo ">> Creating Upstash Redis '$DB_NAME' in $PRIMARY_REGION..."

RESPONSE=$(curl -sS \
  -u "$UPSTASH_EMAIL:$UPSTASH_API_KEY" \
  -X POST "https://api.upstash.com/v2/redis/database" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --arg name "$DB_NAME" \
    --arg region "$PRIMARY_REGION" \
    '{name: $name, region: "global", primary_region: $region, tls: true}')")

if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  echo "!! Upstash error:" >&2
  echo "$RESPONSE" | jq . >&2
  exit 1
fi

REST_URL=$(echo "$RESPONSE" | jq -r '.rest_url // .endpoint')
REST_TOKEN=$(echo "$RESPONSE" | jq -r '.rest_token')
DB_ID=$(echo "$RESPONSE" | jq -r '.database_id // .id')

cat <<EOF

>> Created.

Database ID: $DB_ID

# Paste into Vercel + Render env:
UPSTASH_REDIS_REST_URL=$REST_URL
UPSTASH_REDIS_REST_TOKEN=$REST_TOKEN

# Verify:
curl -H "Authorization: Bearer \$UPSTASH_REDIS_REST_TOKEN" \
  "\$UPSTASH_REDIS_REST_URL/PING"
# expected: {"result":"PONG"}
EOF
