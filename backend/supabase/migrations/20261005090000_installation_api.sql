-- Commit backend – Phase 3: installation registration, reinstall recovery,
-- request authentication and rate limiting.
--
-- Adds ONE table (rate_limits), ONE column (installations.recovery_key_version)
-- and SIX functions. Everything here is usable only by the server-only service role;
-- the app roles (anon, authenticated) get nothing.
--
-- The functions receive HASHES only. A raw credential, a raw Android
-- identifier or a raw network address never reaches the database.
-- This file contains no secrets.

begin;

-- ------------------------------------------- recovery key version (rotation)
-- Which version of the server-only recovery key produced recovery_hash.
-- Lets the key be rotated: old and new versions are both accepted during a
-- rotation window, and each installation is moved to the new one.
alter table public.installations
  add column recovery_key_version integer
    check (recovery_key_version is null or recovery_key_version between 1 and 1000),
  add constraint installations_recovery_version_matches
    check ((recovery_hash is null) = (recovery_key_version is null));
create index installations_recovery_version on public.installations (recovery_key_version);

-- ------------------------------------------------------------ rate_limits
-- Fixed-window counters. "subject" is always a hash (of a network address,
-- a device or an installation ID), never a raw value.
create table public.rate_limits (
  bucket       text not null check (bucket in (
                 'register_ip', 'register_global', 'recover_ip', 'recover_global',
                 'recover_device', 'auth_fail_ip', 'request_installation')),
  subject      text not null check (subject ~ '^[0-9a-f]{64}$'),
  window_start timestamptz not null,
  count        integer not null check (count >= 1),
  primary key (bucket, subject, window_start)
);
create index rate_limits_age on public.rate_limits (window_start);

alter table public.rate_limits enable row level security;
revoke all on table public.rate_limits from anon, authenticated, public;
grant select, insert, update, delete on table public.rate_limits to service_role;

-- Counts one attempt and says whether it is within the limit.
create function public.api_rate_limit(
  p_bucket text, p_subject text, p_limit integer, p_window_seconds integer
) returns table (allowed boolean, remaining integer, resets_at timestamptz)
language plpgsql set search_path = '' as $$
declare
  v_start timestamptz;
  v_count integer;
begin
  if p_limit < 1 or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'invalid rate limit settings' using errcode = 'check_violation';
  end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  -- Old windows of this subject are no longer needed.
  delete from public.rate_limits r
    where r.bucket = p_bucket and r.subject = p_subject and r.window_start < v_start;
  insert into public.rate_limits as r (bucket, subject, window_start, count)
    values (p_bucket, p_subject, v_start, 1)
    on conflict (bucket, subject, window_start) do update set count = r.count + 1
    returning r.count into v_count;
  return query select v_count <= p_limit,
                      greatest(p_limit - v_count, 0),
                      v_start + make_interval(secs => p_window_seconds);
end $$;

-- Removes counters older than one day. Called by the server now and then.
create function public.api_rate_limit_cleanup() returns integer
language plpgsql set search_path = '' as $$
declare
  n integer;
begin
  delete from public.rate_limits where window_start < now() - interval '1 day';
  get diagnostics n = row_count;
  return n;
end $$;

-- First registration of an install.
-- p_known_hashes holds the device hash under EVERY active key version, so a
-- phone is recognised whichever version its installation was made with.
--   created            a new installation was made (with the current version)
--   existing           this exact credential is already registered (a repeat)
--   recovery_required  this phone already has an installation; nothing made
create function public.api_register_installation(
  p_credential_hash text, p_recovery_hash text, p_recovery_key_version integer,
  p_known_hashes text[], p_app_version text, p_android_version text
) returns table (installation_id uuid, outcome text)
language plpgsql set search_path = '' as $$
declare
  v_id uuid;
begin
  select i.id into v_id from public.installations i
    where i.credential_hash = p_credential_hash;
  if found then
    return query select v_id, 'existing'::text;
    return;
  end if;

  if p_recovery_hash is not null and exists (
       select 1 from public.installations i
       where i.recovery_hash = any (p_known_hashes || p_recovery_hash)) then
    return query select null::uuid, 'recovery_required'::text;
    return;
  end if;

  begin
    insert into public.installations
        (credential_hash, recovery_hash, recovery_key_version, app_version, android_version)
      values (p_credential_hash, p_recovery_hash, p_recovery_key_version,
              p_app_version, p_android_version)
      returning id into v_id;
  exception when unique_violation then
    -- Two identical requests arrived at the same moment.
    select i.id into v_id from public.installations i
      where i.credential_hash = p_credential_hash;
    if found then
      return query select v_id, 'existing'::text;
    else
      return query select null::uuid, 'recovery_required'::text;
    end if;
    return;
  end;
  return query select v_id, 'created'::text;
end $$;

-- Reinstall recovery: the same phone, a new credential.
-- The phone is found under any active key version and is moved to the
-- current version in the same step.
--   recovered  the credential was replaced; the old one no longer works
--   unchanged  this credential is already the current one (a repeat)
--   not_found  no installation for this phone
--   suspended  the installation is suspended
--   conflict   the new credential already belongs to another installation
create function public.api_recover_installation(
  p_new_credential_hash text, p_recovery_hash text, p_recovery_key_version integer,
  p_known_hashes text[], p_app_version text, p_android_version text
) returns table (installation_id uuid, outcome text, recovery_count integer,
                 has_active_challenge boolean)
language plpgsql set search_path = '' as $$
declare
  i public.installations%rowtype;
  v_active boolean;
begin
  select * into i from public.installations x
    where x.recovery_hash = any (p_known_hashes || p_recovery_hash)
    order by x.created_at limit 1 for update;
  if not found then
    return query select null::uuid, 'not_found'::text, null::integer, null::boolean;
    return;
  end if;
  if i.status <> 'active' then
    return query select null::uuid, 'suspended'::text, null::integer, null::boolean;
    return;
  end if;

  v_active := exists (select 1 from public.challenges c
                      where c.installation_id = i.id and c.status = 'active');

  if i.credential_hash = p_new_credential_hash then
    update public.installations x
       set recovery_hash = p_recovery_hash, recovery_key_version = p_recovery_key_version
     where x.id = i.id and x.recovery_hash is distinct from p_recovery_hash;
    return query select i.id, 'unchanged'::text, i.recovery_count, v_active;
    return;
  end if;
  if exists (select 1 from public.installations x
             where x.credential_hash = p_new_credential_hash) then
    return query select null::uuid, 'conflict'::text, null::integer, null::boolean;
    return;
  end if;

  -- The installations trigger counts the recovery and stamps the time.
  update public.installations x
     set credential_hash = p_new_credential_hash,
         recovery_hash = p_recovery_hash,
         recovery_key_version = p_recovery_key_version,
         app_version = p_app_version,
         android_version = p_android_version,
         last_seen_at = now()
   where x.id = i.id
   returning x.recovery_count into i.recovery_count;

  return query select i.id, 'recovered'::text, i.recovery_count, v_active;
end $$;

-- Moves a signed-in installation's device hash to the current key version.
-- The phone must present the SAME device again: the stored hash has to match
-- one of the active versions. It can never take over another phone's hash.
--   current   already on the current version; nothing to do
--   upgraded  moved from an older active version to the current one
--   set       had no device hash yet; one was stored
--   mismatch  the device does not match what is stored (or its version is retired)
--   in_use    that device belongs to another installation
create function public.api_refresh_recovery(
  p_installation_id uuid, p_recovery_hash text, p_recovery_key_version integer,
  p_known_hashes text[]
) returns table (outcome text, recovery_key_version integer)
language plpgsql set search_path = '' as $$
declare
  i public.installations%rowtype;
begin
  select * into i from public.installations x where x.id = p_installation_id for update;
  if not found then
    return query select 'mismatch'::text, null::integer;
    return;
  end if;
  if i.recovery_hash = p_recovery_hash then
    return query select 'current'::text, i.recovery_key_version;
    return;
  end if;
  if exists (select 1 from public.installations x
             where x.id <> i.id
               and x.recovery_hash = any (p_known_hashes || p_recovery_hash)) then
    return query select 'in_use'::text, i.recovery_key_version;
    return;
  end if;
  if i.recovery_hash is not null and not (i.recovery_hash = any (p_known_hashes)) then
    return query select 'mismatch'::text, i.recovery_key_version;
    return;
  end if;
  update public.installations x
     set recovery_hash = p_recovery_hash, recovery_key_version = p_recovery_key_version
   where x.id = i.id;
  return query select (case when i.recovery_hash is null then 'set' else 'upgraded' end)::text,
                      p_recovery_key_version;
end $$;

-- Who is making this request? Both the ID and the credential must match.
-- Returns no row when they do not.
create function public.api_authenticate(
  p_installation_id uuid, p_credential_hash text
) returns table (installation_id uuid, status text, recovery_count integer,
                 recovery_key_version integer, created_at timestamptz)
language plpgsql set search_path = '' as $$
declare
  i public.installations%rowtype;
begin
  select * into i from public.installations x
    where x.id = p_installation_id and x.credential_hash = p_credential_hash;
  if not found then
    return;
  end if;
  if i.last_seen_at < now() - interval '1 minute' then
    update public.installations x set last_seen_at = now() where x.id = i.id;
  end if;
  return query select i.id, i.status, i.recovery_count, i.recovery_key_version, i.created_at;
end $$;

-- Only the server role may call these.
revoke all on function
  public.api_rate_limit(text, text, integer, integer),
  public.api_rate_limit_cleanup(),
  public.api_register_installation(text, text, integer, text[], text, text),
  public.api_recover_installation(text, text, integer, text[], text, text),
  public.api_refresh_recovery(uuid, text, integer, text[]),
  public.api_authenticate(uuid, text)
from anon, authenticated, public;

grant execute on function
  public.api_rate_limit(text, text, integer, integer),
  public.api_rate_limit_cleanup(),
  public.api_register_installation(text, text, integer, text[], text, text),
  public.api_recover_installation(text, text, integer, text[], text, text),
  public.api_refresh_recovery(uuid, text, integer, text[]),
  public.api_authenticate(uuid, text)
to service_role;

commit;
