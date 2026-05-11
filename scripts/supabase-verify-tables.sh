#!/usr/bin/env bash
# Verify tables + RLS policies exist on a Supabase project via Management API.
# Useful after running a migration to confirm what actually landed.
#
# Usage:
#   SUPABASE_PAT=sbp_… PROJECT_REF=<ref> ./supabase-verify-tables.sh

set -euo pipefail

: "${SUPABASE_PAT:?SUPABASE_PAT not set}"
: "${PROJECT_REF:?PROJECT_REF not set}"

QUERY='SELECT tablename FROM pg_tables WHERE schemaname = '\''public'\'' ORDER BY tablename;'
BODY=$(jq -nc --arg q "$QUERY" '{query: $q}')

echo ">> Public tables:"
curl -sS \
  -X POST "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$BODY" | jq -r '.[].tablename' || true

POLICIES='SELECT tablename, policyname, cmd FROM pg_policies WHERE schemaname = '\''public'\'' ORDER BY tablename, policyname;'
BODY=$(jq -nc --arg q "$POLICIES" '{query: $q}')

echo ""
echo ">> RLS policies:"
curl -sS \
  -X POST "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$BODY" | jq -r '.[] | "  \(.tablename).\(.policyname)  (\(.cmd))"' || true
