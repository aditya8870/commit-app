-- Read-only check to paste into the Supabase SQL Editor AFTER the Phase 5
-- migration (20261006090000). It changes nothing. Every row must show ok = true.
select 'tables present (expect 8)' as check, count(*) as found, count(*) = 8 as ok
  from pg_tables where schemaname = 'public'
   and tablename in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys','rate_limits')
union all
select 'row level security on (expect 8)', count(*), count(*) = 8
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
    and c.relname in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys','rate_limits')
union all
select 'policies (expect 0)', count(*), count(*) = 0 from pg_policies where schemaname = 'public'
union all
select 'table privileges held by the app roles (expect 0)', count(*), count(*) = 0
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon', 'authenticated')
union all
select 'server functions present (expect 18)', count(*), count(*) = 18
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'api\_%'
union all
select 'new challenge functions present (expect 12)', count(*), count(*) = 12
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in (
    'api_iso','api_challenge_json','api_complete_due','api_create_challenge',
    'api_registration_result','api_get_active','api_get_challenge','api_list_history',
    'api_complete_challenge','api_record_emergency','api_record_events','api_end_early')
union all
select 'server functions callable by the app roles (expect 0)', count(*), count(*) = 0
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'api\_%'
    and (has_function_privilege('anon', p.oid, 'execute')
      or has_function_privilege('authenticated', p.oid, 'execute'))
union all
select 'server functions callable by the server role (expect 18)', count(*), count(*) = 18
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'api\_%'
    and has_function_privilege('service_role', p.oid, 'execute')
union all
select 'integrity triggers unchanged (expect 14)', count(*), count(*) = 14
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal
union all
select 'rows in payments (expect 0)', count(*), count(*) = 0 from public.payments
union all
select 'challenges ended early (expect 0)', count(*), count(*) = 0
  from public.challenges where status = 'ended_early';
