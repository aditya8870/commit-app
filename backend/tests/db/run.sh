#!/usr/bin/env bash
# Applies every migration to a brand-new local database and runs the tests.
# Usage: tests/db/run.sh        (needs a local PostgreSQL; uses database "commit_test")
set -euo pipefail
cd "$(dirname "$0")/../.."
PSQL="${PSQL:-psql -X -q -v ON_ERROR_STOP=1}"
DB=commit_test
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d $DB -f tests/db/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do
  echo "# applying $f"
  $PSQL -d $DB -f "$f"
done

# Safety check: the accountless migration must refuse to run when an old
# table holds data, and must leave everything as it was.
G=commit_guard
$PSQL -d postgres -c "drop database if exists $G" -c "create database $G"
$PSQL -d $G -f tests/db/00_supabase_stub.sql
$PSQL -d $G -f supabase/migrations/20261004120000_initial_schema.sql
$PSQL -d $G -c "insert into auth.users values ('00000000-0000-0000-0000-00000000000a', 'x'); insert into public.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'x@example.test')"
if $PSQL -d $G -f supabase/migrations/20261004180000_accountless_schema.sql >/dev/null 2>&1; then
  echo "GUARD: FAIL (migration ran although a table held data)"; exit 1
fi
LEFT=$($PSQL -At -d $G -c "select count(*) from pg_tables where schemaname='public' and tablename in ('users','devices','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')")
ROWS=$($PSQL -At -d $G -c "select count(*) from public.users")
NEW=$($PSQL -At -d $G -c "select count(*) from pg_tables where schemaname='public' and tablename='installations'")
if [ "$LEFT" = "8" ] && [ "$ROWS" = "1" ] && [ "$NEW" = "0" ]; then
  echo "GUARD: PASS (refused to run with data present; old schema and its row untouched)"
else
  echo "GUARD: FAIL (left=$LEFT rows=$ROWS new=$NEW)"; exit 1
fi
$PSQL -d postgres -c "drop database $G"

$PSQL -d $DB -f tests/db/10_tests.sql | tee /dev/stderr | grep -q "RESULT: PASS"
