-- Read-only check to paste into the Supabase SQL Editor AFTER the accountless
-- migration (20261004180000). It changes nothing. Every row must show ok = true.
select 'new tables present (expect 7)' as check, count(*) as found, count(*) = 7 as ok
  from pg_tables where schemaname = 'public'
   and tablename in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')
union all
select 'old account tables removed (expect 0)', count(*), count(*) = 0
  from pg_tables where schemaname = 'public' and tablename in ('users','devices')
union all
select 'account columns anywhere (expect 0)', count(*), count(*) = 0
  from information_schema.columns
  where table_schema = 'public' and column_name in ('user_id','device_id','email','display_name','created_on_device_id')
union all
select 'row level security on (expect 7)', count(*), count(*) = 7
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
    and c.relname in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')
union all
select 'policies on these tables (expect 0)', count(*), count(*) = 0
  from pg_policies where schemaname = 'public'
   and tablename in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')
union all
select 'privileges held by the app roles (expect 0)', count(*), count(*) = 0
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon', 'authenticated')
    and table_name in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments','idempotency_keys')
union all
select 'integrity triggers (expect 14)', count(*), count(*) = 14
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal
    and c.relname in ('installations','challenges','challenge_apps','challenge_events','emergency_uses','payments')
union all
select 'rows in installations (expect 0)', count(*), count(*) = 0 from public.installations
union all
select 'rows in challenges (expect 0)', count(*), count(*) = 0 from public.challenges;
