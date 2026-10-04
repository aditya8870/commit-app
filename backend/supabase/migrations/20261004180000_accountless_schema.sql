-- Commit backend – Phase 2 (revised): ACCOUNTLESS schema.
--
-- Replaces the first Phase 2 schema (8 tables built around user accounts)
-- with 7 tables built around an anonymous INSTALLATION. No name, email,
-- phone number, password or sign-in is stored anywhere.
--
-- SAFETY: this file refuses to run if any of the old tables contains a row,
-- and it runs as one transaction: either everything changes or nothing does.
-- It contains no secrets.

begin;

-- ------------------------------------------------ 0. refuse if data exists
do $$
declare
  t text;
  n bigint;
begin
  foreach t in array array['users', 'devices', 'challenges', 'challenge_apps',
                           'challenge_events', 'emergency_uses', 'payments',
                           'idempotency_keys'] loop
    execute format('select count(*) from public.%I', t) into n;
    if n > 0 then
      raise exception 'STOPPED: table % contains % row(s). Nothing was changed.', t, n;
    end if;
  end loop;
end $$;

-- ------------------------------------- 1. remove the empty account schema
drop table public.idempotency_keys;
drop table public.payments;
drop table public.emergency_uses;
drop table public.challenge_events;
drop table public.challenge_apps;
drop table public.challenges;
drop table public.devices;
drop table public.users;

drop function public.challenges_before_insert();
drop function public.challenges_before_update();
drop function public.challenge_apps_before_insert();
drop function public.challenge_events_before_insert();
drop function public.emergency_uses_before_insert();
drop function public.payments_before_insert();
drop function public.payments_before_update();
drop function public.reject_change();

-- ============================================================ new schema

-- ---------------------------------------------------------- installations
-- One row per install of the app. This is the only identity Commit has.
-- It holds no name, email, phone number or account of any kind.
create table public.installations (
  id               uuid primary key default gen_random_uuid(),
  -- SHA-256 (hex) of the secret credential the phone generated. The secret
  -- itself is never stored on the server.
  credential_hash  text not null check (credential_hash ~ '^[0-9a-f]{64}$'),
  -- Keyed hash (HMAC-SHA-256, hex) of Android's per-app device identifier.
  -- Used only to recognise the same phone after a reinstall. The raw
  -- identifier is never stored. Empty if the phone did not provide one.
  recovery_hash    text check (recovery_hash is null or recovery_hash ~ '^[0-9a-f]{64}$'),
  status           text not null default 'active' check (status in ('active', 'suspended')),
  app_version      text not null check (length(app_version) between 1 and 50),
  android_version  text check (android_version is null or length(android_version) <= 50),
  recovery_count   integer not null default 0 check (recovery_count >= 0),
  last_recovered_at timestamptz,
  last_seen_at     timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create unique index installations_credential_key on public.installations (credential_hash);
-- One installation per phone: a reinstall is matched to its existing row.
create unique index installations_recovery_key
  on public.installations (recovery_hash) where recovery_hash is not null;

-- ------------------------------------------------------------- challenges
create table public.challenges (
  id                   uuid primary key default gen_random_uuid(),
  installation_id      uuid not null references public.installations (id) on delete restrict,
  status               text not null default 'active'
                         check (status in ('active', 'completed', 'ended_early', 'cancelled')),
  start_time           timestamptz not null,
  end_time             timestamptz not null,
  duration_minutes     integer not null check (duration_minutes between 1 and 43200),
  amount_rupees        integer not null check (amount_rupees between 100 and 10000),
  emergency_limit      integer not null check (emergency_limit between 0 and 3),
  emergency_minutes    integer not null check (emergency_minutes in (2, 5, 10, 15, 30)),
  consent_version      text not null check (length(consent_version) between 1 and 50),
  consent_accepted_at  timestamptz not null,
  actual_end_time      timestamptz,
  interruption_count   integer not null default 0 check (interruption_count >= 0),
  idempotency_key      text not null check (length(idempotency_key) between 16 and 128),
  created_at           timestamptz not null default now(),
  constraint challenges_end_matches_duration
    check (end_time = start_time + make_interval(mins => duration_minutes)),
  constraint challenges_actual_end_only_when_finished
    check ((status = 'active') = (actual_end_time is null)),
  unique (installation_id, idempotency_key)
);
-- The one-active-challenge rule, enforced by the database.
create unique index challenges_one_active_per_installation
  on public.challenges (installation_id) where status = 'active';
create index challenges_history on public.challenges (installation_id, created_at desc);
create index challenges_due on public.challenges (status, end_time);

-- --------------------------------------------------------- challenge_apps
create table public.challenge_apps (
  challenge_id uuid not null references public.challenges (id) on delete restrict,
  package_name text not null
                 check (length(package_name) <= 255
                        and package_name ~ '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$'),
  app_name     text not null check (length(app_name) between 1 and 100),
  primary key (challenge_id, package_name)
);

-- ------------------------------------------------------- challenge_events
-- Append-only history. Rows are never updated or deleted.
create table public.challenge_events (
  id           uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.challenges (id) on delete restrict,
  source       text not null check (source in ('server', 'device')),
  type         text not null check (type in (
                 'created', 'completed', 'ended_early', 'cancelled',
                 'emergency_used', 'protection_lost', 'protection_restored',
                 'force_stopped', 'accessibility_off', 'tamper_protection_off',
                 'restored_on_device', 'completed_on_device', 'clock_jump')),
  device_time  timestamptz,
  server_time  timestamptz not null default now(),
  details      jsonb check (details is null or pg_column_size(details) <= 4096),
  -- Only the server can record a change of status.
  constraint challenge_events_status_from_server
    check (type not in ('created', 'completed', 'ended_early', 'cancelled')
           or source = 'server')
);
create index challenge_events_by_challenge
  on public.challenge_events (challenge_id, server_time);

-- --------------------------------------------------------- emergency_uses
create table public.emergency_uses (
  id                uuid primary key,  -- generated on the phone; a repeat is ignored
  challenge_id      uuid not null references public.challenges (id) on delete restrict,
  started_at_device timestamptz not null,
  minutes           integer not null,
  received_at       timestamptz not null default now(),
  over_limit        boolean not null default false
);
create index emergency_uses_by_challenge on public.emergency_uses (challenge_id);

-- --------------------------------------------------------------- payments
-- EMPTY PLACEHOLDER. Unused until a payment phase is separately approved.
-- Holds references only: no card numbers, UPI IDs, bank accounts, contact
-- details or provider secrets.
create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  challenge_id        uuid not null references public.challenges (id) on delete restrict,
  installation_id     uuid not null references public.installations (id) on delete restrict,
  amount_rupees       integer not null check (amount_rupees between 100 and 10000),
  status              text not null default 'not_started' check (status in (
                        'not_started', 'initiated', 'pending', 'successful',
                        'failed', 'cancelled', 'verification_failed')),
  attempt             integer not null check (attempt >= 1),
  provider            text check (provider is null or length(provider) <= 50),
  provider_order_id   text check (provider_order_id is null or length(provider_order_id) <= 200),
  provider_payment_id text check (provider_payment_id is null or length(provider_payment_id) <= 200),
  refund_status       text not null default 'none'
                        check (refund_status in ('none', 'pending', 'refunded', 'failed')),
  expires_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (challenge_id, attempt)
);
create unique index payments_provider_order_key
  on public.payments (provider_order_id) where provider_order_id is not null;
create unique index payments_one_success_per_challenge
  on public.payments (challenge_id) where status = 'successful';

-- ------------------------------------------------------- idempotency_keys
create table public.idempotency_keys (
  installation_id uuid not null references public.installations (id) on delete restrict,
  key             text not null check (length(key) between 16 and 128),
  endpoint        text not null check (length(endpoint) between 1 and 100),
  request_hash    text not null check (length(request_hash) between 1 and 128),
  response        jsonb not null,
  created_at      timestamptz not null default now(),
  primary key (installation_id, key, endpoint)
);
create index idempotency_keys_age on public.idempotency_keys (created_at);

-- =============================================================== triggers
-- Each function runs with an empty search_path and names everything in full.

-- Installations: identity and creation time never change; the database
-- clock records a recovery (a change of credential).
create function public.installations_before_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
    raise exception 'the identity of an installation cannot be changed'
      using errcode = 'check_violation';
  end if;
  if new.credential_hash is distinct from old.credential_hash then
    new.recovery_count := old.recovery_count + 1;
    new.last_recovered_at := now();
  else
    new.recovery_count := old.recovery_count;
    new.last_recovered_at := old.last_recovered_at;
  end if;
  return new;
end $$;
create trigger installations_before_update before update on public.installations
  for each row execute function public.installations_before_update();

create function public.installations_before_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.created_at := now();
  new.last_seen_at := now();
  new.recovery_count := 0;
  new.last_recovered_at := null;
  return new;
end $$;
create trigger installations_before_insert before insert on public.installations
  for each row execute function public.installations_before_insert();

-- Challenges: the database clock sets the times; a challenge always starts
-- active; a suspended installation cannot start one.
create function public.challenges_before_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.status := 'active';
  new.start_time := now();
  new.end_time := new.start_time + make_interval(mins => new.duration_minutes);
  new.consent_accepted_at := now();
  new.actual_end_time := null;
  new.interruption_count := 0;
  new.created_at := now();
  if exists (select 1 from public.installations i
             where i.id = new.installation_id and i.status <> 'active') then
    raise exception 'this installation is suspended' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger challenges_before_insert before insert on public.challenges
  for each row execute function public.challenges_before_insert();

-- Challenges: terms never change, and status follows the state machine.
create function public.challenges_before_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id
     or new.installation_id is distinct from old.installation_id
     or new.start_time is distinct from old.start_time
     or new.end_time is distinct from old.end_time
     or new.duration_minutes is distinct from old.duration_minutes
     or new.amount_rupees is distinct from old.amount_rupees
     or new.emergency_limit is distinct from old.emergency_limit
     or new.emergency_minutes is distinct from old.emergency_minutes
     or new.consent_version is distinct from old.consent_version
     or new.consent_accepted_at is distinct from old.consent_accepted_at
     or new.idempotency_key is distinct from old.idempotency_key
     or new.created_at is distinct from old.created_at then
    raise exception 'the terms of a challenge cannot be changed'
      using errcode = 'check_violation';
  end if;

  if new.status is distinct from old.status then
    if old.status <> 'active' then
      raise exception 'a finished challenge cannot change state (% -> %)', old.status, new.status
        using errcode = 'check_violation';
    end if;
    if new.status = 'completed' and now() < old.end_time then
      raise exception 'a challenge cannot be completed before its end time'
        using errcode = 'check_violation';
    end if;
    if new.status = 'ended_early' then
      if now() >= old.end_time then
        raise exception 'a challenge past its end time completes; it cannot end early'
          using errcode = 'check_violation';
      end if;
      if not exists (select 1 from public.payments p
                     where p.challenge_id = old.id and p.status = 'successful') then
        raise exception 'a challenge cannot end early without a verified payment'
          using errcode = 'check_violation';
      end if;
    end if;
    new.actual_end_time := case when new.status = 'completed' then old.end_time else now() end;
  elsif new.actual_end_time is distinct from old.actual_end_time then
    raise exception 'actual_end_time is set by the database' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger challenges_before_update before update on public.challenges
  for each row execute function public.challenges_before_update();

-- Challenge apps: at most 50 per challenge.
create function public.challenge_apps_before_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (select count(*) from public.challenge_apps a where a.challenge_id = new.challenge_id) >= 50 then
    raise exception 'a challenge can protect at most 50 apps' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger challenge_apps_before_insert before insert on public.challenge_apps
  for each row execute function public.challenge_apps_before_insert();

-- Shared: rows that are never updated or deleted.
create function public.reject_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% rows cannot be changed or deleted', tg_table_name
    using errcode = 'check_violation';
end $$;
create trigger challenge_apps_fixed before update or delete on public.challenge_apps
  for each row execute function public.reject_change();
create trigger challenge_events_append_only before update or delete on public.challenge_events
  for each row execute function public.reject_change();
create trigger emergency_uses_append_only before update or delete on public.emergency_uses
  for each row execute function public.reject_change();
create trigger challenges_no_delete before delete on public.challenges
  for each row execute function public.reject_change();
create trigger payments_no_delete before delete on public.payments
  for each row execute function public.reject_change();

-- Events: the database clock stamps the receipt time.
create function public.challenge_events_before_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.server_time := now();
  return new;
end $$;
create trigger challenge_events_before_insert before insert on public.challenge_events
  for each row execute function public.challenge_events_before_insert();

-- Emergency uses: length must match the challenge; uses beyond the limit are
-- kept and flagged, never silently dropped.
create function public.emergency_uses_before_insert() returns trigger
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
  used integer;
begin
  select * into c from public.challenges where id = new.challenge_id for update;
  if not found then
    raise exception 'unknown challenge' using errcode = 'foreign_key_violation';
  end if;
  if new.minutes <> c.emergency_minutes then
    raise exception 'emergency length must be % minutes', c.emergency_minutes
      using errcode = 'check_violation';
  end if;
  select count(*) into used from public.emergency_uses e
    where e.challenge_id = new.challenge_id and not e.over_limit;
  new.over_limit := used >= c.emergency_limit;
  new.received_at := now();
  return new;
end $$;
create trigger emergency_uses_before_insert before insert on public.emergency_uses
  for each row execute function public.emergency_uses_before_insert();

-- Payments (placeholder): owner and amount always come from the challenge.
create function public.payments_before_insert() returns trigger
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
begin
  select * into c from public.challenges where id = new.challenge_id;
  if not found then
    raise exception 'unknown challenge' using errcode = 'foreign_key_violation';
  end if;
  new.installation_id := c.installation_id;
  new.amount_rupees := c.amount_rupees;
  new.created_at := now();
  new.updated_at := now();
  return new;
end $$;
create trigger payments_before_insert before insert on public.payments
  for each row execute function public.payments_before_insert();

create function public.payments_before_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id
     or new.challenge_id is distinct from old.challenge_id
     or new.installation_id is distinct from old.installation_id
     or new.amount_rupees is distinct from old.amount_rupees
     or new.attempt is distinct from old.attempt
     or new.created_at is distinct from old.created_at then
    raise exception 'the owner, challenge and amount of a payment cannot be changed'
      using errcode = 'check_violation';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger payments_before_update before update on public.payments
  for each row execute function public.payments_before_update();

-- ============================================================== security
-- Row Level Security on, with NO policies: deny everything to the app roles.
alter table public.installations    enable row level security;
alter table public.challenges       enable row level security;
alter table public.challenge_apps   enable row level security;
alter table public.challenge_events enable row level security;
alter table public.emergency_uses   enable row level security;
alter table public.payments         enable row level security;
alter table public.idempotency_keys enable row level security;

revoke all on table
  public.installations, public.challenges, public.challenge_apps,
  public.challenge_events, public.emergency_uses, public.payments,
  public.idempotency_keys
from anon, authenticated, public;

revoke all on function
  public.installations_before_insert(), public.installations_before_update(),
  public.challenges_before_insert(), public.challenges_before_update(),
  public.challenge_apps_before_insert(), public.reject_change(),
  public.challenge_events_before_insert(), public.emergency_uses_before_insert(),
  public.payments_before_insert(), public.payments_before_update()
from anon, authenticated, public;

-- The server-only role used by Edge Functions. Its key is a secret that lives
-- only in Supabase's secret store, never in this repository or in the app.
grant select, insert, update, delete on table
  public.installations, public.challenges, public.challenge_apps,
  public.challenge_events, public.emergency_uses, public.payments,
  public.idempotency_keys
to service_role;

commit;
