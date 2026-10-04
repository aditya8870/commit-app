#!/usr/bin/env bash
# End-to-end test of the Flutter client against the real handler and a local
# database. Touches nothing remote.
# Usage: bash backend/tests/run_client_e2e.sh   (from the project root)
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL="${PSQL:-psql -X -q -v ON_ERROR_STOP=1}"
DB=commit_e2e_test; ROLE=commit_e2e_test; PORT=${PORT:-8787}
PW=$(node -e "console.log(require('crypto').randomBytes(18).toString('hex'))")
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>/dev/null
$PSQL -d $DB -f tests/db/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do $PSQL -d $DB -f "$f"; done
$PSQL -d postgres -c "drop role if exists $ROLE" -c "create role $ROLE login password '$PW' in role service_role" 2>/dev/null
DATABASE_URL="postgres://$ROLE:$PW@127.0.0.1:${PGPORT:-5432}/$DB" PORT=$PORT node tests/serve_local.mjs &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; $PSQL -d postgres -c "drop database if exists $DB" -c "drop role if exists $ROLE" 2>/dev/null' EXIT
sleep 2
cd ..
COMMIT_LOCAL_API="http://127.0.0.1:$PORT" flutter test test/integration
