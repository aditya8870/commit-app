#!/usr/bin/env bash
# Runs every backend test against a local PostgreSQL. Touches nothing remote.
#   1. Phase 1: server time
#   2. Phase 2: database schema (both migrations, safety guard, constraints, RLS)
#   3. Phase 3: installation API against a fresh database
#   4. Phase 5: challenge API against the same database
# Usage: bash tests/run_all.sh     (PSQL may be overridden, see tests/db/run.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL="${PSQL:-psql -X -q -v ON_ERROR_STOP=1}"

echo "== Phase 1: server time"
node --test tests/time.test.mjs | grep -E "^# (tests|pass|fail)"

echo "== Phase 2: database"
PSQL="$PSQL" bash tests/db/run.sh 2>&1 | grep -E "^(NOT OK|GUARD|# (tests|pass|fail)|RESULT)"

echo "== Phase 3: installation API"
DB=commit_api_test
ROLE=commit_api_test
# A throwaway local password, generated now and never written to a file.
PW=$(node -e "console.log(require('crypto').randomBytes(18).toString('hex'))")
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d $DB -f tests/db/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do $PSQL -d $DB -f "$f"; done
$PSQL -d postgres -c "drop role if exists $ROLE" -c "create role $ROLE login superuser password '$PW' in role service_role, anon, authenticated"
DATABASE_URL="postgres://$ROLE:$PW@127.0.0.1:${PGPORT:-5432}/$DB" \
  node --test tests/installations.test.mjs | grep -E "^(not ok|# (tests|pass|fail))"

echo "== Phase 5: challenge API"
DATABASE_URL="postgres://$ROLE:$PW@127.0.0.1:${PGPORT:-5432}/$DB" \
  node --test tests/challenges.test.mjs | grep -E "^(not ok|# (tests|pass|fail))"

echo "== Phase 6: Play release (no money, completion quality)"
DATABASE_URL="postgres://$ROLE:$PW@127.0.0.1:${PGPORT:-5432}/$DB" \
  node --test tests/play_release.test.mjs | grep -E "^(not ok|# (tests|pass|fail))"
$PSQL -d postgres -c "drop database $DB" -c "drop role $ROLE"
echo "== done"
