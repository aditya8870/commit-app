# Commit backend

Server side of Commit. Runs on Supabase. Phase 1: the server-time endpoint. Phase 2: the accountless database schema. Phase 3: installation registration, reinstall recovery and request authentication (see `docs/PHASE3_DESIGN.md`).

## What is here

| File | What it does |
|---|---|
| `supabase/functions/api/index.ts` | The server code: `GET /v1/time`, `POST /v1/installations`, `POST /v1/installations/recover`, `GET /v1/installations/me`, `POST /v1/installations/me/recovery`. |
| `supabase/migrations/20261005090000_installation_api.sql` | Phase 3. Adds `rate_limits`, the `recovery_key_version` column and 6 server-only database functions. |
| `docs/PHASE3_DESIGN.md` | Phase 3 design, API contract and security review. |
| `tests/installations.test.mjs` | 48 Phase 3 API tests against a local database. |
| `tests/run_all.sh` | Runs every backend test locally. |
| `tests/db/verify_phase3.sql` | Read-only check for Supabase after the Phase 3 migration. |
| `package.json` | Test tooling only (database driver for the tests). Nothing in it is deployed. |
| `supabase/config.toml` | Supabase settings: project name `commit-dev`, and the `api` function is public (no sign-in yet). No secrets. |
| `.env.example` | Template for per-environment settings. Phase 1 needs no secrets. |
| `.gitignore` | Keeps real `.env` files out of the source code. |
| `tests/time.test.mjs` | 10 automatic tests of the endpoint. |
| `tests/live_check.mjs` | Checks the deployed endpoint over HTTPS. |
| `supabase/migrations/20261004120000_initial_schema.sql` | First Phase 2 schema (account-based). Applied; superseded by the next file. |
| `supabase/migrations/20261004180000_accountless_schema.sql` | Replaces it with the 7-table accountless schema. |
| `tests/db/run.sh` | Applies all migrations to a fresh local database and runs the database tests. |
| `tests/db/00_supabase_stub.sql` | Test only: recreates the roles and `auth.users` table that every Supabase project already has. |
| `tests/db/10_tests.sql` | 130 database tests (installations, recovery, constraints, state machine, RLS). |
| `tests/db/verify_deployed.sql` | Read-only check to paste into the Supabase SQL Editor after applying the migration. |

## The endpoint

    GET https://<project-ref>.supabase.co/functions/v1/api/v1/time

(`/functions/v1/api` is Supabase's fixed prefix for a function named `api`; `/v1/time` is Commit's own path.)

Answer, status 200:

    { "serverTime": "2026-10-04T09:30:00.000Z", "epochMs": 1791106200000 }

- `serverTime`: ISO-8601, always UTC (ends in `Z`).
- `epochMs`: the same instant as milliseconds since 1970.
- Built only from the server's clock. Nothing sent by the caller is read.
- No sign-in. `Cache-Control: no-store`. Only GET; anything else answers 405.
- Errors look like `{ "code": "...", "message": "...", "retryable": false }`.

## Run the tests

    cd backend
    npm install          # once; test tooling only
    bash tests/run_all.sh

## Environments

- Development: Supabase project **commit-dev**.
- Production: a separate project **commit-prod**, created in a later phase. Nothing here points at it.
- Secrets (added in later phases) are stored with `supabase secrets set` on the server only. Never in this folder, never in the Flutter app.

## Deploy to commit-dev (needs your Supabase account)

With the Supabase command-line tool:

    cd backend
    npx supabase login
    npx supabase link --project-ref <your-project-ref>
    npx supabase functions deploy api
    node tests/live_check.mjs https://<your-project-ref>.supabase.co/functions/v1/api

Or in the browser: Supabase dashboard -> project commit-dev -> Edge Functions -> create a function named `api`, paste the contents of `supabase/functions/api/index.ts`, switch off "Verify JWT", deploy.

## Database (Phase 2, accountless)

Commit has no accounts. The only identity is an anonymous **installation**.

Migrations, applied in order:

1. `20261004120000_initial_schema.sql` — first Phase 2 schema (8 tables, account-based). Already applied to commit-dev. Kept unchanged so the history is reproducible.
2. `20261004180000_accountless_schema.sql` — removes those 8 empty tables and creates the 7 accountless ones. Refuses to run if any old table holds a row, and runs as one transaction.

Tables: `installations`, `challenges`, `challenge_apps`, `challenge_events`, `emergency_uses`, `payments` (empty placeholder), `idempotency_keys`.

- No name, email, phone number, password or sign-in is stored. An installation holds a hash of the phone's secret credential and a keyed hash of Android's per-app device identifier (for reinstall recovery). Raw values are never stored.
- Row Level Security is on for all 7 with no policy, and the app roles hold no privileges. The phone app cannot read or write any table. Only server functions (service role) can.
- The database clock sets challenge start, end and event times. Terms cannot be updated. Status can only move active -> completed / ended_early / cancelled.

Run the database tests (needs a local PostgreSQL):

    cd backend
    tests/db/run.sh

It applies both migrations in order to a fresh database (the same path commit-dev takes), checks the safety guard, then runs the tests in `tests/db/10_tests.sql`.

After applying on Supabase, run `tests/db/verify_deployed.sql` in the SQL Editor; every row must show `ok = true`.

Never edit a migration that has been applied; add a new one.

## Phase 3 deployment order (only after approval)

1. Set two secrets in Supabase (Edge Functions -> Secrets): `COMMIT_RECOVERY_SECRET_V1` = 64 random hex characters, and `COMMIT_RECOVERY_CURRENT_VERSION` = `1`. The key can be rotated later (see `docs/PHASE3_DESIGN.md` section 5a).
2. Run `supabase/migrations/20261005090000_installation_api.sql` once in the SQL Editor.
3. Run `tests/db/verify_phase3.sql`; every row must show `ok = true`.
4. Replace the code of Edge Function `api` with the new `index.ts` (Verify JWT stays off) and deploy.
5. Open `/v1/time` again: it must still answer.

The migration must be applied before the new function is deployed, because the function calls the new database functions.

## Phase 5 deployment order (only after approval)

1. Run `supabase/migrations/20261006090000_challenge_api.sql` once in the SQL Editor (12 functions; no table changes).
2. Run `tests/db/verify_phase5.sql`; every row must show `ok = true`.
3. Replace the code of Edge Function `api` with the new `index.ts` (Verify JWT stays off) and deploy.
4. Open `/v1/time` again: it must still answer.
5. Install app 2.8.0 and follow `docs/PHASE5_DEVICE_TEST.md` in the app project.

No new secrets. Design, API contract, security review and rollback: `docs/PHASE5_DESIGN.md` in the app project.
