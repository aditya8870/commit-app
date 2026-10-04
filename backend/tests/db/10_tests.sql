-- Phase 2 (accountless) database tests. Run by tests/db/run.sh after the migration.
\set ON_ERROR_STOP on
set client_min_messages = warning;
\o /dev/null

create table t_results (n serial, ok boolean, name text, note text);

-- Runs a statement that MUST fail; records whether it did.
create function t_fail(name text, sql text, expect text default null) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    insert into t_results (ok, name, note)
      values (expect is null or sqlerrm ilike '%' || expect || '%', name, sqlerrm);
    return;
  end;
  insert into t_results (ok, name, note) values (false, name, 'statement succeeded but must fail');
end $$;

-- Runs a statement that MUST succeed.
create function t_ok(name text, sql text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    insert into t_results (ok, name, note) values (false, name, sqlerrm);
    return;
  end;
  insert into t_results (ok, name, note) values (true, name, null);
end $$;

-- Records whether a condition holds.
create function t_is(name text, cond boolean) returns void
language sql as $$ insert into t_results (ok, name, note) values (coalesce(cond, false), name, null) $$;

-- ------------------------------------------------------------- fixtures
insert into public.installations (id, credential_hash, recovery_hash, recovery_key_version, app_version) values
  ('00000000-0000-0000-0000-00000000000a', repeat('a', 64), repeat('1', 64), 1, '2.6.0'),
  ('00000000-0000-0000-0000-00000000000b', repeat('b', 64), repeat('2', 64), 1, '2.6.0');

-- Template for a valid challenge insert; %s = extra override pairs.
create function t_challenge_sql(overrides jsonb default '{}') returns text
language sql as $$
  select format(
    'insert into public.challenges (id, installation_id, start_time, end_time,
       duration_minutes, amount_rupees, emergency_limit, emergency_minutes, consent_version,
       consent_accepted_at, idempotency_key)
     values (%L, %L, %L, %L, %s, %s, %s, %s, %L, now(), %L)',
    coalesce(overrides->>'id', gen_random_uuid()::text),
    coalesce(overrides->>'installation', '00000000-0000-0000-0000-00000000000a'),
    coalesce(overrides->>'start_time', '1999-01-01T00:00:00Z'),
    coalesce(overrides->>'end_time', '1999-01-01T00:01:00Z'),
    coalesce(overrides->>'duration', '60'),
    coalesce(overrides->>'amount', '100'),
    coalesce(overrides->>'limit', '2'),
    coalesce(overrides->>'minutes', '5'),
    coalesce(overrides->>'consent', '2026-10-04.1'),
    coalesce(overrides->>'key', 'key-' || gen_random_uuid()::text))
$$;

-- ==================================================== 1. installations
select t_is('installations: the old account tables are gone',
  not exists (select 1 from pg_tables where schemaname = 'public' and tablename in ('users', 'devices')));
select t_is('installations: no column holds a name, email, phone or password',
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name not like 't\_%'
                and column_name ~* '(email|phone|mobile|name$|^name|password|google|profile|address)'
                and column_name not in ('app_name', 'package_name')));
select t_fail('installations: two installs cannot share a credential',
  $$insert into public.installations (credential_hash, app_version) values (repeat('a', 64), '2.6.0')$$, 'installations_credential_key');
select t_fail('installations: one installation per phone (same recovery hash is refused)',
  $$insert into public.installations (credential_hash, recovery_hash, recovery_key_version, app_version) values (repeat('c', 64), repeat('1', 64), 1, '2.6.0')$$, 'installations_recovery_key');
select t_ok('installations: a phone that gives no device identifier is still accepted',
  $$insert into public.installations (id, credential_hash, app_version) values ('00000000-0000-0000-0000-00000000000c', repeat('c', 64), '2.6.0');
    insert into public.installations (credential_hash, app_version) values (repeat('d', 64), '2.6.0')$$);
select t_fail('installations: a raw (unhashed) credential is refused',
  $$insert into public.installations (credential_hash, app_version) values ('my-secret-credential', '2.6.0')$$, 'check');
select t_fail('installations: a raw device identifier is refused',
  $$insert into public.installations (credential_hash, recovery_hash, recovery_key_version, app_version) values (repeat('e', 64), '9774d56d682e549c', 1, '2.6.0')$$, 'check');
select t_fail('installations: status must be active or suspended',
  $$update public.installations set status = 'admin' where id = '00000000-0000-0000-0000-00000000000a'$$, 'check');
select t_fail('installations: the ID cannot be changed',
  $$update public.installations set id = gen_random_uuid() where id = '00000000-0000-0000-0000-00000000000b'$$, 'identity');
select t_ok('recovery: a reinstall replaces the credential of the same installation',
  $$update public.installations set credential_hash = repeat('f', 64) where recovery_hash = repeat('2', 64)$$);
select t_is('recovery: the installation ID is unchanged and the recovery is counted',
  (select id = '00000000-0000-0000-0000-00000000000b' and recovery_count = 1 and last_recovered_at is not null
   from public.installations where credential_hash = repeat('f', 64)));
select t_is('recovery: the old credential no longer matches any installation',
  not exists (select 1 from public.installations where credential_hash = repeat('b', 64)));
select t_fail('recovery: the recovery counter cannot be reset by hand',
  $$update public.installations set recovery_count = 0 where id = '00000000-0000-0000-0000-00000000000b';
    select 1 / (select recovery_count - 1 from public.installations where id = '00000000-0000-0000-0000-00000000000b')$$, 'division by zero');
select t_fail('installations: a suspended installation cannot start a challenge',
  $$update public.installations set status = 'suspended' where id = '00000000-0000-0000-0000-00000000000c';$$ ||
  t_challenge_sql('{"installation":"00000000-0000-0000-0000-00000000000c"}'), 'suspended');

-- ============================================= 3. challenge creation
select t_ok('challenge: a valid challenge is created',
  t_challenge_sql('{"id":"00000000-0000-0000-0000-0000000000c1","duration":"60","amount":"100"}'));
select t_is('challenge: start time is the database clock, not the value sent',
  (select start_time between now() - interval '1 minute' and now() from public.challenges where id = '00000000-0000-0000-0000-0000000000c1'));
select t_is('challenge: end time = start + duration',
  (select end_time = start_time + interval '60 minutes' from public.challenges where id = '00000000-0000-0000-0000-0000000000c1'));
select t_is('challenge: starts active with no actual end',
  (select status = 'active' and actual_end_time is null from public.challenges where id = '00000000-0000-0000-0000-0000000000c1'));

select t_fail('one active challenge: a second one for the same installation is refused',
  t_challenge_sql(), 'challenges_one_active_per_installation');
select t_ok('one active challenge: another installation can still start one',
  t_challenge_sql('{"id":"00000000-0000-0000-0000-0000000000c2","installation":"00000000-0000-0000-0000-00000000000b"}'));
-- Validation (user B has no active challenge inside these failed attempts,
-- because each failing statement rolls back its own cancel).
create function t_b(overrides jsonb) returns text language sql as $$
  select $q$update public.challenges set status = 'cancelled'
            where installation_id = '00000000-0000-0000-0000-00000000000b' and status = 'active';$q$
      || t_challenge_sql(overrides || '{"installation":"00000000-0000-0000-0000-00000000000b"}')
$$;
select t_fail('amount: 99 is refused',    t_b('{"amount":"99"}'),    'amount_rupees');
select t_fail('amount: 10001 is refused', t_b('{"amount":"10001"}'), 'amount_rupees');
-- 0 means "no financial commitment" since the Play-release migration.
select t_fail('amount: 50 is refused',    t_b('{"amount":"50"}'),    'amount_rupees');
select t_fail('amount: negative is refused', t_b('{"amount":"-100"}'), 'amount_rupees');
select t_fail('duration: 0 minutes is refused', t_b('{"duration":"0"}'), 'duration_minutes');
select t_fail('duration: over 30 days is refused', t_b('{"duration":"43201"}'), 'duration_minutes');
select t_fail('emergency limit: 4 is refused', t_b('{"limit":"4"}'), 'emergency_limit');
select t_fail('emergency minutes: 7 is refused', t_b('{"minutes":"7"}'), 'emergency_minutes');
select t_fail('idempotency: same installation and key cannot create twice',
  $$update public.challenges set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000000c2';$$ ||
  t_challenge_sql('{"installation":"00000000-0000-0000-0000-00000000000b","key":"same-key-000000000000"}') || ';' ||
  $$update public.challenges set status = 'cancelled' where installation_id = '00000000-0000-0000-0000-00000000000b' and status = 'active';$$ ||
  t_challenge_sql('{"installation":"00000000-0000-0000-0000-00000000000b","key":"same-key-000000000000"}'),
  'idempotency_key');
select t_ok('amount: 10000 is accepted (after cancelling the previous one)',
  t_b('{"id":"00000000-0000-0000-0000-0000000000c3","amount":"10000","duration":"43200"}'));

-- ============================================ 4. terms cannot change
select t_fail('terms: amount cannot be updated',
  $$update public.challenges set amount_rupees = 100 where id = '00000000-0000-0000-0000-0000000000c3'$$, 'terms');
select t_fail('terms: end time cannot be moved earlier',
  $$update public.challenges set end_time = now() where id = '00000000-0000-0000-0000-0000000000c1'$$, 'terms');
select t_fail('terms: start time cannot be updated',
  $$update public.challenges set start_time = start_time - interval '1 day' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'terms');
select t_fail('terms: duration cannot be updated',
  $$update public.challenges set duration_minutes = 1 where id = '00000000-0000-0000-0000-0000000000c1'$$, 'terms');
select t_fail('terms: owner cannot be changed',
  $$update public.challenges set installation_id = '00000000-0000-0000-0000-00000000000b' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'terms');
select t_fail('terms: emergency limit cannot be raised',
  $$update public.challenges set emergency_limit = 3 where id = '00000000-0000-0000-0000-0000000000c1'$$, 'terms');
select t_fail('challenge: cannot be deleted',
  $$delete from public.challenges where id = '00000000-0000-0000-0000-0000000000c1'$$, 'cannot be changed or deleted');
select t_ok('challenge: interruption count may be updated',
  $$update public.challenges set interruption_count = 1 where id = '00000000-0000-0000-0000-0000000000c1'$$);

-- =============================================== 5. state machine
select t_fail('state: cannot complete before end time',
  $$update public.challenges set status = 'completed' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'before its end time');
select t_fail('state: cannot end early without a verified payment',
  $$update public.challenges set status = 'ended_early' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'verified payment');
select t_fail('state: a pending payment is not enough to end early',
  $$insert into public.payments (challenge_id, installation_id, amount_rupees, status, attempt)
      values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 100, 'pending', 1);
    update public.challenges set status = 'ended_early' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'verified payment');
select t_fail('state: unknown status is refused',
  $$update public.challenges set status = 'paused' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'check');
select t_fail('state: actual_end_time cannot be set by hand',
  $$update public.challenges set actual_end_time = now() where id = '00000000-0000-0000-0000-0000000000c1'$$, '');

-- A challenge whose end time has already passed (triggers off for the fixture only).
set session_replication_role = replica;
insert into public.challenges (id, installation_id, status, start_time, end_time,
    duration_minutes, amount_rupees, emergency_limit, emergency_minutes, consent_version,
    consent_accepted_at, idempotency_key, created_at, actual_end_time)
  values ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-00000000000a', 'cancelled', now() - interval '2 hours', now() - interval '1 hour',
    60, 500, 1, 5, '2026-10-04.1', now() - interval '2 hours', 'past-key-0000000000000', now() - interval '2 hours', now() - interval '90 minutes');
set session_replication_role = origin;

select t_fail('state: a cancelled challenge cannot become active again',
  $$update public.challenges set status = 'active' where id = '00000000-0000-0000-0000-0000000000c4'$$, 'finished challenge');
select t_fail('state: a cancelled challenge cannot become completed',
  $$update public.challenges set status = 'completed' where id = '00000000-0000-0000-0000-0000000000c4'$$, 'finished challenge');

-- Make C1 look as if its end time has passed, to test completion.
set session_replication_role = replica;
update public.challenges set start_time = now() - interval '61 minutes', end_time = now() - interval '1 minute'
  where id = '00000000-0000-0000-0000-0000000000c1';
set session_replication_role = origin;

select t_fail('state: past its end time a challenge cannot end early',
  $$insert into public.payments (challenge_id, installation_id, amount_rupees, status, attempt)
      values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 100, 'successful', 1);
    update public.challenges set status = 'ended_early' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'completes');
select t_ok('state: completes once end time has passed',
  $$update public.challenges set status = 'completed' where id = '00000000-0000-0000-0000-0000000000c1'$$);
select t_is('state: actual end of a completed challenge is its end time',
  (select actual_end_time = end_time from public.challenges where id = '00000000-0000-0000-0000-0000000000c1'));
select t_fail('state: a completed challenge cannot be cancelled',
  $$update public.challenges set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'finished challenge');
select t_fail('state: a completed challenge cannot become ended_early',
  $$update public.challenges set status = 'ended_early' where id = '00000000-0000-0000-0000-0000000000c1'$$, 'finished challenge');
select t_ok('one active challenge: a new one is allowed after the old one finished',
  t_challenge_sql('{"id":"00000000-0000-0000-0000-0000000000c5","limit":"1","minutes":"5","amount":"250"}'));

-- ============================================== 6. challenge apps
select t_ok('apps: a valid app is stored',
  $$insert into public.challenge_apps values ('00000000-0000-0000-0000-0000000000c5', 'com.instagram.android', 'Instagram')$$);
select t_fail('apps: same app twice is refused',
  $$insert into public.challenge_apps values ('00000000-0000-0000-0000-0000000000c5', 'com.instagram.android', 'Instagram')$$, 'duplicate');
select t_fail('apps: a malformed package name is refused',
  $$insert into public.challenge_apps values ('00000000-0000-0000-0000-0000000000c5', 'not a package; drop table', 'X')$$, 'check');
select t_fail('apps: at most 50 per challenge',
  $$insert into public.challenge_apps select '00000000-0000-0000-0000-0000000000c5', 'com.example.app' || g, 'App' from generate_series(1, 50) g$$, 'at most 50');
select t_fail('apps: cannot be removed from a challenge',
  $$delete from public.challenge_apps where challenge_id = '00000000-0000-0000-0000-0000000000c5'$$, 'cannot be changed or deleted');

-- ====================================================== 7. events
select t_ok('events: a device event is stored',
  $$insert into public.challenge_events (id, challenge_id, source, type, device_time, server_time)
    values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c5',
            'device', 'force_stopped', '1999-01-01', '1999-01-01')$$);
select t_is('events: server_time is the database clock, not the value sent',
  (select server_time between now() - interval '1 minute' and now() from public.challenge_events where id = '00000000-0000-0000-0000-0000000000e1'));
select t_fail('events: the same event ID twice is refused (repeat is ignored by the API)',
  $$insert into public.challenge_events (id, challenge_id, source, type)
    values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c5',
            'device', 'force_stopped')$$, 'duplicate');
select t_fail('events: a phone cannot record a status change',
  $$insert into public.challenge_events (challenge_id, source, type)
    values ('00000000-0000-0000-0000-0000000000c5', 'device', 'completed')$$, 'status_from_server');
select t_fail('events: unknown type is refused',
  $$insert into public.challenge_events (challenge_id, source, type)
    values ('00000000-0000-0000-0000-0000000000c5', 'server', 'hacked')$$, 'check');
select t_fail('events: cannot be updated',
  $$update public.challenge_events set type = 'created', source = 'server' where id = '00000000-0000-0000-0000-0000000000e1'$$, 'cannot be changed or deleted');
select t_fail('events: cannot be deleted',
  $$delete from public.challenge_events where id = '00000000-0000-0000-0000-0000000000e1'$$, 'cannot be changed or deleted');

-- ============================================== 8. emergency uses
select t_ok('emergency: first use is recorded',
  $$insert into public.emergency_uses (id, challenge_id, started_at_device, minutes, over_limit)
    values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c5',
            now(), 5, true)$$);
select t_is('emergency: within the limit is not flagged, whatever was sent',
  (select not over_limit from public.emergency_uses where id = '00000000-0000-0000-0000-0000000000f1'));
select t_fail('emergency: same use ID twice counts once',
  $$insert into public.emergency_uses (id, challenge_id, started_at_device, minutes)
    values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c5',
            now(), 5)$$, 'duplicate');
select t_ok('emergency: a use beyond the limit is still stored',
  $$insert into public.emergency_uses (id, challenge_id, started_at_device, minutes, over_limit)
    values ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c5',
            now(), 5, false)$$);
select t_is('emergency: the use beyond the limit is flagged over_limit',
  (select over_limit from public.emergency_uses where id = '00000000-0000-0000-0000-0000000000f2'));
select t_fail('emergency: length must match the challenge',
  $$insert into public.emergency_uses (id, challenge_id, started_at_device, minutes)
    values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000c5', now(), 30)$$, 'emergency length');
select t_fail('emergency: a recorded use cannot be deleted',
  $$delete from public.emergency_uses where id = '00000000-0000-0000-0000-0000000000f2'$$, 'cannot be changed or deleted');

-- ============================ 8b. one installation cannot reach another
-- The API finds the installation from the credential and then filters every
-- query by that installation. These checks prove the data supports it.
select t_is('isolation: a credential resolves to exactly one installation',
  (select count(*) = 1 from public.installations where credential_hash = repeat('a', 64)));
select t_is('isolation: an unknown credential resolves to nothing',
  (select count(*) = 0 from public.installations where credential_hash = repeat('9', 64)));
select t_is('isolation: installation B sees none of installation A''s challenges',
  (select count(*) = 0 from public.challenges
   where id = '00000000-0000-0000-0000-0000000000c5' and installation_id = '00000000-0000-0000-0000-00000000000b'));
select t_fail('isolation: a challenge cannot be moved to another installation',
  $$update public.challenges set installation_id = '00000000-0000-0000-0000-00000000000b' where id = '00000000-0000-0000-0000-0000000000c5'$$, 'terms');
select t_fail('isolation: an installation that owns challenges cannot be deleted',
  $$delete from public.installations where id = '00000000-0000-0000-0000-00000000000a'$$, 'foreign key');

-- ================================= 9. payments placeholder integrity
select t_ok('payments: a placeholder row can be stored',
  $$insert into public.payments (id, challenge_id, installation_id, amount_rupees, status, attempt)
    values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c5',
            '00000000-0000-0000-0000-00000000000b', 9999, 'initiated', 1)$$);
select t_is('payments: amount is copied from the challenge, not taken from the request',
  (select amount_rupees = 250 from public.payments where id = '00000000-0000-0000-0000-0000000000b1'));
select t_is('payments: owner is the challenge''s installation, not the one sent',
  (select installation_id = '00000000-0000-0000-0000-00000000000a' from public.payments where id = '00000000-0000-0000-0000-0000000000b1'));
select t_fail('payments: amount cannot be changed',
  $$update public.payments set amount_rupees = 100 where id = '00000000-0000-0000-0000-0000000000b1'$$, 'cannot be changed');
select t_fail('payments: unknown status is refused',
  $$update public.payments set status = 'paid_i_promise' where id = '00000000-0000-0000-0000-0000000000b1'$$, 'check');
select t_fail('payments: only one successful payment per challenge',
  $$update public.payments set status = 'successful' where id = '00000000-0000-0000-0000-0000000000b1';
    insert into public.payments (challenge_id, installation_id, amount_rupees, status, attempt)
    values ('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-00000000000a', 250, 'successful', 2)$$, 'payments_one_success_per_challenge');
select t_fail('payments: cannot be deleted',
  $$delete from public.payments where id = '00000000-0000-0000-0000-0000000000b1'$$, 'cannot be changed or deleted');
select t_is('payments: table has no card, UPI or bank columns',
  not exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and column_name ~* '(card|cvv|upi|vpa|iban|ifsc|account_number|bank|pin$|contact|secret|password|token)'));

-- ============================================ 10. idempotency keys
select t_ok('idempotency: a key is stored',
  $$insert into public.idempotency_keys (installation_id, key, endpoint, request_hash, response)
    values ('00000000-0000-0000-0000-00000000000a', 'idem-key-0000000000000', 'POST /v1/challenges', 'hash', '{}')$$);
select t_fail('idempotency: same installation, key and endpoint twice is refused',
  $$insert into public.idempotency_keys (installation_id, key, endpoint, request_hash, response)
    values ('00000000-0000-0000-0000-00000000000a', 'idem-key-0000000000000', 'POST /v1/challenges', 'hash2', '{}')$$, 'duplicate');

-- ==================================== 11. Row Level Security and grants
select t_is('rls: enabled on all 7 tables',
  (select count(*) = 7 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
     and c.relname in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')));
select t_is('rls: enabled on rate_limits too',
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'rate_limits'));
select t_is('rls: no policies exist (deny everything)',
  (select count(*) = 0 from pg_policies where schemaname = 'public'));
select t_is('grants: anon and authenticated hold no privilege on any table',
  not exists (select 1 from information_schema.role_table_grants
              where table_schema = 'public' and grantee in ('anon', 'authenticated', 'PUBLIC')
                and table_name not like 't\_%'));

create function t_as(role text, name text, sql text, expect text) returns void
language plpgsql as $$
begin
  begin
    execute format('set local role %I', role);
    execute sql;
  exception when others then
    reset role;
    insert into t_results (ok, name, note) values (sqlerrm ilike '%' || expect || '%', name, sqlerrm);
    return;
  end;
  reset role;
  insert into t_results (ok, name, note) values (false, name, 'statement succeeded but must fail');
end $$;

do $$
declare t text; r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array array['installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys'] loop
      perform t_as(r, format('%s cannot read %s', r, t), format('select * from public.%I', t), 'permission denied');
      perform t_as(r, format('%s cannot delete from %s', r, t), format('delete from public.%I', t), 'permission denied');
    end loop;
    perform t_as(r, r || ' cannot create a challenge',
      t_challenge_sql('{"installation":"00000000-0000-0000-0000-00000000000b"}'), 'permission denied');
    perform t_as(r, r || ' cannot change a challenge status',
      $q$update public.challenges set status = 'completed'$q$, 'permission denied');
    perform t_as(r, r || ' cannot replace an installation credential',
      $q$update public.installations set credential_hash = repeat('0', 64)$q$, 'permission denied');
    perform t_as(r, r || ' cannot change a payment status',
      $q$update public.payments set status = 'successful'$q$, 'permission denied');
    perform t_as(r, r || ' cannot change an amount',
      $q$update public.challenges set amount_rupees = 100$q$, 'permission denied');
  end loop;
end $$;

-- Even if a privilege were granted by mistake, RLS alone still denies.
grant select, insert, update, delete on public.challenges, public.payments to authenticated;
create function t_count_as(role text, sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute format('set local role %I', role);
  execute sql into n;
  reset role;
  return n;
end $$;
select t_is('rls alone: with a mistaken grant, authenticated still sees 0 challenges',
  t_count_as('authenticated', 'select count(*) from public.challenges') = 0);
select t_is('rls alone: with a mistaken grant, an update changes 0 rows',
  t_count_as('authenticated', $$with u as (update public.challenges set interruption_count = 9 returning 1) select count(*) from u$$) = 0);
select t_as('authenticated', 'rls alone: with a mistaken grant, an insert is still refused',
  t_challenge_sql('{"installation":"00000000-0000-0000-0000-00000000000b"}'), '');
revoke all on public.challenges, public.payments from authenticated;

select t_is('service role: can read challenges (used only by server functions)',
  t_count_as('service_role', 'select count(*) from public.challenges') >= 4);

-- ============================================================== report
\o
\pset tuples_only on
\pset format unaligned
select (case when ok then 'ok ' else 'NOT OK ' end) || n || ' - ' || name
       || (case when ok then '' else '   [' || coalesce(note, '') || ']' end)
from t_results order by n;
select '# tests ' || count(*) || E'\n# pass ' || count(*) filter (where ok)
       || E'\n# fail ' || count(*) filter (where not ok) from t_results;
select case when exists (select 1 from t_results where not ok) then 'RESULT: FAIL' else 'RESULT: PASS' end;
