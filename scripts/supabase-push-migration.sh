#!/usr/bin/env bash
# Push a SQL migration to Supabase via the Management API.
# Works when `supabase db push` fails because direct TCP to :5432 is blocked
# (Clash/Mihomo fakeip, corporate firewall, etc.). HTTPS is almost always allowed.
#
# Usage:
#   SUPABASE_PAT=sbp_… PROJECT_REF=<ref> ./supabase-push-migration.sh path/to/file.sql
#
# Or multi-file:
#   for f in supabase/migrations/*.sql; do
#     SUPABASE_PAT=sbp_… PROJECT_REF=<ref> ./supabase-push-migration.sh "$f"
#   done

set -euo pipefail

: "${SUPABASE_PAT:?SUPABASE_PAT not set — get one at https://supabase.com/dashboard/account/tokens}"
: "${PROJECT_REF:?PROJECT_REF not set — find it in your project URL}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 path/to/migration.sql" >&2
  exit 2
fi

SQL_FILE="$1"
if [[ ! -f "$SQL_FILE" ]]; then
  echo "no such file: $SQL_FILE" >&2
  exit 2
fi

echo ">> Pushing $SQL_FILE to project $PROJECT_REF via Management API..."

# Build JSON safely with jq (handles all the quoting/escaping for arbitrary SQL)
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (brew install jq)" >&2
  exit 1
fi

BODY=$(jq -Rs '{query: .}' < "$SQL_FILE")

HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" \
  -X POST "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$BODY")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
  echo "!! HTTP $HTTP_CODE" >&2
  echo "$HTTP_BODY" | jq . >&2 2>/dev/null || echo "$HTTP_BODY" >&2
  exit 1
fi

echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY"
echo ">> OK"
