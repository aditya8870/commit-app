-- Commit backend – Phase 2: database foundation.
--
-- Eight tables. Row Level Security is ON for every table with NO policy, and
-- the app's database roles (anon, authenticated) have no privileges at all,
-- so the phone app can neither read nor write any of this directly. Only
-- server functions, using the server-only service role, touch these tables.
--
-- All times are timestamptz (UTC) and are set by the database clock.
-- Money is whole rupees. No card, UPI or bank details are stored anywhere.
-- This file contains no secrets.

-- ------------------------------------------------------------------ users
-- One row per person. Sign-in itself lives in Supabase Auth (auth.users).
create table public.users (
  id           uuid primary key references auth.users (id) on delete restrict,
  email        text not null check (length(email) between 3 and 320),
  display_name text check (display_name is null or length(display_name) <= 200),
  status       text not null default 'active' check (status in ('active', 'suspended')),
  created_at   timestamptz not null default now()
);
create unique index users_email_key on public.users (lower(email));

-- ---------------------------------------------------------------- devices
-- One row per install of the app.
create table public.devices (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users (id) on delete restrict,
  install_id      text not null check (length(install_id) between 8 and 128),
  model           text check (model is null or length(model) <= 100),
  android_version text check (android_version is null or length(android_version) <= 50),
  app_version     text not null check (length(app_version) between 1 and 50),
  last_seen_at    timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  unique (user_id, install_id)
);

-- ------------------------------------------------------------- challenges
-- The authoritative record of each challenge.
create table public.challenges (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.users (id) on delete restrict,
  created_on_device_id uuid not null references public.devices (id) on delete restrict,
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
  -- The end is always exactly start + duration.
  constraint challenges_end_matches_duration
    check (end_time = start_time + make_interval(mins => duration_minutes)),
  -- A running challenge has no actual end; a finished one always has.
  constraint challenges_actual_end_only_when_finished
    check ((status = 'active') = (actual_end_time is null)),
  unique (user_id, idempotency_key)
);
-- The one-active-challenge rule, enforced by the database.
create unique index challenges_one_active_per_user
  on public.challenges (user_id) where status = 'active';
create index challenges_history on public.challenges (user_id, created_at desc);
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
  device_id    uuid references public.devices (id) on delete restrict,
  source       text not null check (source in ('server', 'device')),
  type         text not null check (type in (
                 'created', 'completed', 'ended_early', 'cancelled',
                 'emergency_used', 'protection_lost', 'protection_restored',
                 'force_stopped', 'accessibility_off', 'tamper_protection_off',
                 'restored_on_device', 'completed_on_device', 'clock_jump')),
  device_time  timestamptz,
  server_time  timestamptz not null default now(),
  details      jsonb check (details is null or pg_column_size(details) <= 4096),
  -- What a phone says always names the phone.
  constraint challenge_events_device_named
    check (source = 'server' or device_id is not null),
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
  device_id         uuid not null references public.devices (id) on delete restrict,
  started_at_device timestamptz not null,
  minutes           integer not null,
  received_at       timestamptz not null default now(),
  over_limit        boolean not null default false
);
create index emergency_uses_by_challenge on public.emergency_uses (challenge_id);

-- --------------------------------------------------------------- payments
-- PLACEHOLDER. Unused until the payment phase. Holds references only:
-- no card numbers, UPI IDs, bank accounts or provider secrets.
create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  challenge_id        uuid not null references public.challenges (id) on delete restrict,
  user_id             uuid not null references public.users (id) on delete restrict,
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
-- A challenge can be paid for at most once.
create unique index payments_one_success_per_challenge
  on public.payments (challenge_id) where status = 'successful';

-- ------------------------------------------------------- idempotency_keys
create table public.idempotency_keys (
  user_id      uuid not null references public.users (id) on delete restrict,
  key          text not null check (length(key) between 16 and 128),
  endpoint     text not null check (length(endpoint) between 1 and 100),
  request_hash text not null check (length(request_hash) between 1 and 128),
  response     jsonb not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, key, endpoint)
);
create index idempotency_keys_age on public.idempotency_keys (created_at);

-- =============================================================== triggers
-- Each function runs with an empty search_path and names everything in full.

-- Challenges: the database clock sets the times; a challenge always starts active.
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
  if not exists (select 1 from public.devices d
                 where d.id = new.created_on_device_id and d.user_id = new.user_id) then
    raise exception 'device does not belong to this user' using errcode = 'check_violation';
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
     or new.user_id is distinct from old.user_id
     or new.created_on_device_id is distinct from old.created_on_device_id
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
    -- The database clock records when it ended.
    new.actual_end_time := case when new.status = 'completed' then old.end_time else now() end;
  elsif new.actual_end_time is distinct from old.actual_end_time then
    raise exception 'actual_end_time is set by the database' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger challenges_before_update before update on public.challenges
  for each row execute function public.challenges_before_update();

-- Challenge apps: at most 50, and only while the challenge is being created.
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

-- Shared: a table whose rows are never updated or deleted.
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
  if not exists (select 1 from public.devices d
                 where d.id = new.device_id and d.user_id = c.user_id) then
    raise exception 'device does not belong to the owner of this challenge'
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
  new.user_id := c.user_id;
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
     or new.user_id is distinct from old.user_id
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
alter table public.users            enable row level security;
alter table public.devices          enable row level security;
alter table public.challenges       enable row level security;
alter table public.challenge_apps   enable row level security;
alter table public.challenge_events enable row level security;
alter table public.emergency_uses   enable row level security;
alter table public.payments         enable row level security;
alter table public.idempotency_keys enable row level security;

-- Second layer: the app roles hold no privileges on these tables or functions.
revoke all on table
  public.users, public.devices, public.challenges, public.challenge_apps,
  public.challenge_events, public.emergency_uses, public.payments,
  public.idempotency_keys
from anon, authenticated, public;

revoke all on function
  public.challenges_before_insert(), public.challenges_before_update(),
  public.challenge_apps_before_insert(), public.reject_change(),
  public.challenge_events_before_insert(), public.emergency_uses_before_insert(),
  public.payments_before_insert(), public.payments_before_update()
from anon, authenticated, public;

-- The server-only role used by Edge Functions. Its key is a secret that lives
-- only in Supabase's secret store, never in this repository or in the app.
grant select, insert, update, delete on table
  public.users, public.devices, public.challenges, public.challenge_apps,
  public.challenge_events, public.emergency_uses, public.payments,
  public.idempotency_keys
to service_role;
