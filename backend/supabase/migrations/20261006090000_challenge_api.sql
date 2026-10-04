-- Commit backend – Phase 5: challenge API.
--
-- Adds database FUNCTIONS only. No table, column, constraint or trigger is
-- changed; the payments table is not touched. Every function is callable
-- only by the server-only service role and always works on ONE installation,
-- the one the server authenticated: a challenge that belongs to another
-- installation is treated exactly like one that does not exist.
--
-- All lifecycle decisions use the database clock (now()).
-- This file contains no secrets.

begin;

-- Timestamps leave the database as UTC ISO-8601 with milliseconds.
create function public.api_iso(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;

-- One challenge as the API returns it.
create function public.api_challenge_json(c public.challenges) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'status', c.status,
    'startTime', public.api_iso(c.start_time),
    'endTime', public.api_iso(c.end_time),
    'actualEndTime', public.api_iso(c.actual_end_time),
    'durationMinutes', c.duration_minutes,
    'amountRupees', c.amount_rupees,
    'emergencyLimit', c.emergency_limit,
    'emergencyMinutes', c.emergency_minutes,
    'emergencyUsed', (select count(*) from public.emergency_uses e
                      where e.challenge_id = c.id and not e.over_limit),
    'interruptionCount', c.interruption_count,
    'consentVersion', c.consent_version,
    'consentAcceptedAt', public.api_iso(c.consent_accepted_at),
    'createdAt', public.api_iso(c.created_at),
    'apps', coalesce((select jsonb_agg(jsonb_build_object(
                        'packageName', a.package_name, 'appName', a.app_name)
                        order by a.app_name, a.package_name)
                      from public.challenge_apps a where a.challenge_id = c.id), '[]'::jsonb),
    -- Placeholder until a payment phase exists. Never reports success here.
    'payment', jsonb_build_object('status', 'not_started', 'available', false)
  )
$$;

-- Completes every challenge of this installation whose end time has passed.
-- The database clock decides; nothing a phone says is involved.
create function public.api_complete_due(p_installation_id uuid) returns integer
language plpgsql set search_path = '' as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    update public.challenges c set status = 'completed'
     where c.installation_id = p_installation_id
       and c.status = 'active' and c.end_time <= now()
    returning c.id
  loop
    insert into public.challenge_events (challenge_id, source, type)
      values (r.id, 'server', 'completed');
    n := n + 1;
  end loop;
  return n;
end $$;

-- POST /v1/challenges
--   created               a new challenge was made
--   existing              this idempotency key already made a challenge (a repeat)
--   idempotency_mismatch  same key, different request
--   active_exists         the installation already has an active challenge
--   invalid               a value was refused by the database rules
create function public.api_create_challenge(
  p_installation_id uuid, p_idempotency_key text, p_request_hash text,
  p_duration_minutes integer, p_amount_rupees integer,
  p_emergency_limit integer, p_emergency_minutes integer,
  p_consent_version text, p_apps jsonb
) returns table (outcome text, challenge jsonb)
language plpgsql set search_path = '' as $$
declare
  k public.idempotency_keys%rowtype;
  c public.challenges%rowtype;
  v_endpoint constant text := 'POST /v1/challenges';
begin
  perform public.api_complete_due(p_installation_id);

  select * into k from public.idempotency_keys i
    where i.installation_id = p_installation_id and i.key = p_idempotency_key
      and i.endpoint = v_endpoint;
  if found then
    if k.request_hash <> p_request_hash then
      return query select 'idempotency_mismatch'::text, null::jsonb;
      return;
    end if;
    select * into c from public.challenges x
      where x.id = (k.response ->> 'challengeId')::uuid and x.installation_id = p_installation_id;
    return query select 'existing'::text, public.api_challenge_json(c);
    return;
  end if;

  select * into c from public.challenges x
    where x.installation_id = p_installation_id and x.status = 'active';
  if found then
    return query select 'active_exists'::text, public.api_challenge_json(c);
    return;
  end if;

  if jsonb_typeof(p_apps) is distinct from 'array'
     or jsonb_array_length(p_apps) not between 1 and 50
     or (select count(distinct e ->> 'packageName') from jsonb_array_elements(p_apps) e)
          <> jsonb_array_length(p_apps) then
    return query select 'invalid'::text, null::jsonb;
    return;
  end if;

  begin
    -- The insert trigger sets status, start, end and consent time itself.
    insert into public.challenges
        (installation_id, start_time, end_time, duration_minutes, amount_rupees,
         emergency_limit, emergency_minutes, consent_version, consent_accepted_at,
         idempotency_key)
      values (p_installation_id, now(), now(), p_duration_minutes, p_amount_rupees,
              p_emergency_limit, p_emergency_minutes, p_consent_version, now(),
              p_idempotency_key)
      returning * into c;
    insert into public.challenge_apps (challenge_id, package_name, app_name)
      select c.id, e ->> 'packageName', e ->> 'appName' from jsonb_array_elements(p_apps) e;
    insert into public.challenge_events (challenge_id, source, type)
      values (c.id, 'server', 'created');
    insert into public.idempotency_keys (installation_id, key, endpoint, request_hash, response)
      values (p_installation_id, p_idempotency_key, v_endpoint, p_request_hash,
              jsonb_build_object('challengeId', c.id));
  exception
    when unique_violation then
      -- A second request won the race.
      select * into c from public.challenges x
        where x.installation_id = p_installation_id and x.idempotency_key = p_idempotency_key;
      if found then
        return query select 'existing'::text, public.api_challenge_json(c);
        return;
      end if;
      select * into c from public.challenges x
        where x.installation_id = p_installation_id and x.status = 'active';
      return query select 'active_exists'::text,
        case when found then public.api_challenge_json(c) else null end;
      return;
    when check_violation or not_null_violation or string_data_right_truncation
      or invalid_text_representation then
      return query select 'invalid'::text, null::jsonb;
      return;
  end;

  return query select 'created'::text, public.api_challenge_json(c);
end $$;

-- GET /v1/challenges/registrations/{key}: what became of a create request
-- whose answer was lost. Never creates anything. No row = nothing was made.
create function public.api_registration_result(
  p_installation_id uuid, p_idempotency_key text
) returns table (challenge jsonb)
language plpgsql set search_path = '' as $$
begin
  perform public.api_complete_due(p_installation_id);
  return query
    select public.api_challenge_json(c) from public.challenges c
     where c.installation_id = p_installation_id and c.idempotency_key = p_idempotency_key;
end $$;

-- GET /v1/challenges/active. No row = no active challenge.
create function public.api_get_active(p_installation_id uuid)
returns table (challenge jsonb)
language plpgsql set search_path = '' as $$
begin
  perform public.api_complete_due(p_installation_id);
  return query
    select public.api_challenge_json(c) from public.challenges c
     where c.installation_id = p_installation_id and c.status = 'active';
end $$;

-- GET /v1/challenges/{id}. No row = not found OR not yours.
create function public.api_get_challenge(p_installation_id uuid, p_challenge_id uuid)
returns table (challenge jsonb)
language plpgsql set search_path = '' as $$
begin
  perform public.api_complete_due(p_installation_id);
  return query
    select public.api_challenge_json(c) from public.challenges c
     where c.id = p_challenge_id and c.installation_id = p_installation_id;
end $$;

-- GET /v1/challenges/history: finished challenges, newest first.
create function public.api_list_history(
  p_installation_id uuid, p_before timestamptz, p_limit integer
) returns table (challenge jsonb, created_at timestamptz)
language plpgsql set search_path = '' as $$
begin
  perform public.api_complete_due(p_installation_id);
  return query
    select public.api_challenge_json(c), c.created_at from public.challenges c
     where c.installation_id = p_installation_id and c.status <> 'active'
       and (p_before is null or c.created_at < p_before)
     order by c.created_at desc
     limit least(greatest(p_limit, 1), 50);
end $$;

-- POST /v1/challenges/{id}/complete
--   completed  the end time has passed; the challenge is now completed
--   already    it was completed before (a repeat)
--   too_early  the end time has not been reached; nothing changed
--   not_active it ended early or was cancelled
--   not_found  no such challenge for this installation
create function public.api_complete_challenge(p_installation_id uuid, p_challenge_id uuid)
returns table (outcome text, challenge jsonb, seconds_remaining integer)
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
begin
  select * into c from public.challenges x
    where x.id = p_challenge_id and x.installation_id = p_installation_id for update;
  if not found then
    return query select 'not_found'::text, null::jsonb, null::integer;
    return;
  end if;
  if c.status = 'completed' then
    return query select 'already'::text, public.api_challenge_json(c), 0;
    return;
  end if;
  if c.status <> 'active' then
    return query select 'not_active'::text, public.api_challenge_json(c), null::integer;
    return;
  end if;
  if now() < c.end_time then
    return query select 'too_early'::text, public.api_challenge_json(c),
      ceil(extract(epoch from (c.end_time - now())))::integer;
    return;
  end if;
  update public.challenges x set status = 'completed' where x.id = c.id returning * into c;
  insert into public.challenge_events (challenge_id, source, type)
    values (c.id, 'server', 'completed');
  return query select 'completed'::text, public.api_challenge_json(c), 0;
end $$;

-- POST /v1/challenges/{id}/emergency
--   recorded          stored and within the limit
--   duplicate         this use ID was stored before (a repeat); nothing changed
--   limit_exceeded    stored but flagged: no uses were left
--   not_active        the challenge is not active; kept in the event history only
--   invalid_minutes   the length does not match the challenge
--   invalid_time      the reported time is impossible for this challenge
--   not_found         no such challenge for this installation
create function public.api_record_emergency(
  p_installation_id uuid, p_challenge_id uuid, p_use_id uuid,
  p_started_at timestamptz, p_minutes integer
) returns table (outcome text, remaining integer, challenge jsonb)
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
  u public.emergency_uses%rowtype;
  v_remaining integer;
begin
  perform public.api_complete_due(p_installation_id);
  select * into c from public.challenges x
    where x.id = p_challenge_id and x.installation_id = p_installation_id for update;
  if not found then
    return query select 'not_found'::text, null::integer, null::jsonb;
    return;
  end if;

  select * into u from public.emergency_uses e where e.id = p_use_id;
  if found then
    if u.challenge_id <> c.id then
      return query select 'not_found'::text, null::integer, null::jsonb;
      return;
    end if;
  elsif p_minutes <> c.emergency_minutes then
    return query select 'invalid_minutes'::text, null::integer, null::jsonb;
    return;
  elsif p_started_at < c.start_time - interval '5 minutes'
        or p_started_at > now() + interval '5 minutes' then
    return query select 'invalid_time'::text, null::integer, null::jsonb;
    return;
  elsif c.status <> 'active' then
    -- Reported after the challenge finished (for example after being offline).
    -- It is kept as history but is not an emergency use of an active challenge.
    insert into public.challenge_events (id, challenge_id, source, type, device_time)
      values (p_use_id, c.id, 'device', 'emergency_used', p_started_at)
      on conflict (id) do nothing;
  else
    insert into public.emergency_uses (id, challenge_id, started_at_device, minutes)
      values (p_use_id, c.id, p_started_at, p_minutes)
      returning * into u;
  end if;

  select greatest(c.emergency_limit - count(*), 0)::integer into v_remaining
    from public.emergency_uses e where e.challenge_id = c.id and not e.over_limit;

  return query select
    (case when u.id is null then 'not_active'
          when u.received_at < now() then 'duplicate'
          when u.over_limit then 'limit_exceeded'
          else 'recorded' end)::text,
    v_remaining, public.api_challenge_json(c);
end $$;

-- POST /v1/challenges/{id}/events: what the phone observed (interruptions,
-- clock jumps). Testimony only: it never changes the status of a challenge.
create function public.api_record_events(
  p_installation_id uuid, p_challenge_id uuid, p_events jsonb
) returns table (outcome text, accepted integer, duplicates integer)
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
  e jsonb;
  v_new integer := 0;
  v_dup integer := 0;
  v_gaps integer := 0;
  v_rows integer;
begin
  select * into c from public.challenges x
    where x.id = p_challenge_id and x.installation_id = p_installation_id for update;
  if not found then
    return query select 'not_found'::text, 0, 0;
    return;
  end if;
  for e in select * from jsonb_array_elements(p_events) loop
    insert into public.challenge_events (id, challenge_id, source, type, device_time)
      values ((e ->> 'id')::uuid, c.id, 'device', e ->> 'type',
              (e ->> 'deviceTime')::timestamptz)
      on conflict (id) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 1 then
      v_new := v_new + 1;
      if e ->> 'type' in ('protection_lost', 'force_stopped') then v_gaps := v_gaps + 1; end if;
    else
      v_dup := v_dup + 1;
    end if;
  end loop;
  if v_gaps > 0 then
    update public.challenges x set interruption_count = x.interruption_count + v_gaps
      where x.id = c.id;
  end if;
  return query select 'recorded'::text, v_new, v_dup;
end $$;

-- POST /v1/challenges/{id}/end-early
-- Ending early needs a verified payment, and no payment system exists yet.
-- This only reports why the request cannot proceed. It never changes anything.
--   payments_unavailable  the challenge could be ended early once payments exist
--   too_close_to_end      less than 60 seconds remain
--   not_active            the challenge is not active
--   not_found             no such challenge for this installation
create function public.api_end_early(p_installation_id uuid, p_challenge_id uuid)
returns table (outcome text, challenge jsonb)
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
begin
  perform public.api_complete_due(p_installation_id);
  select * into c from public.challenges x
    where x.id = p_challenge_id and x.installation_id = p_installation_id;
  if not found then
    return query select 'not_found'::text, null::jsonb;
  elsif c.status <> 'active' then
    return query select 'not_active'::text, public.api_challenge_json(c);
  elsif c.end_time - now() < interval '60 seconds' then
    return query select 'too_close_to_end'::text, public.api_challenge_json(c);
  else
    return query select 'payments_unavailable'::text, public.api_challenge_json(c);
  end if;
end $$;

-- Only the server role may call these.
revoke all on function
  public.api_iso(timestamptz),
  public.api_challenge_json(public.challenges),
  public.api_complete_due(uuid),
  public.api_create_challenge(uuid, text, text, integer, integer, integer, integer, text, jsonb),
  public.api_registration_result(uuid, text),
  public.api_get_active(uuid),
  public.api_get_challenge(uuid, uuid),
  public.api_list_history(uuid, timestamptz, integer),
  public.api_complete_challenge(uuid, uuid),
  public.api_record_emergency(uuid, uuid, uuid, timestamptz, integer),
  public.api_record_events(uuid, uuid, jsonb),
  public.api_end_early(uuid, uuid)
from anon, authenticated, public;

grant execute on function
  public.api_iso(timestamptz),
  public.api_challenge_json(public.challenges),
  public.api_complete_due(uuid),
  public.api_create_challenge(uuid, text, text, integer, integer, integer, integer, text, jsonb),
  public.api_registration_result(uuid, text),
  public.api_get_active(uuid),
  public.api_get_challenge(uuid, uuid),
  public.api_list_history(uuid, timestamptz, integer),
  public.api_complete_challenge(uuid, uuid),
  public.api_record_emergency(uuid, uuid, uuid, timestamptz, integer),
  public.api_record_events(uuid, uuid, jsonb),
  public.api_end_early(uuid, uuid)
to service_role;

commit;
