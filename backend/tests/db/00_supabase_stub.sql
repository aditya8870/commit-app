-- TEST ONLY. Recreates, on a plain local PostgreSQL, the few things every
-- Supabase project already has: the three API roles and the auth.users table.
-- Never run this on Supabase.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema auth;
create table auth.users (id uuid primary key, email text);
grant usage on schema public to anon, authenticated, service_role;
-- Supabase grants everything on new public tables to these roles by default.
-- The migration must take it away again from anon and authenticated.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
