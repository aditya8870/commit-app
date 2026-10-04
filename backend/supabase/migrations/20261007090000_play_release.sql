-- Commit backend – Phase 6 remediation (first Play release).
--
-- 1. A challenge may have NO financial commitment: amount_rupees = 0.
--    The current app only creates such challenges. Nothing is charged for any
--    challenge; the payments table is not touched.
-- 2. A completed challenge now says how it was completed ("completion"):
--      clean        the phone was present at the end and nothing was interrupted
--      interrupted  protection was interrupted, the phone's clock was wrong, or
--                   the phone lost the challenge and restored it
--      unconfirmed  the end time passed but the phone never came back to
--                   confirm it (for example the app was removed)
--    So losing the phone's copy never counts as a clean completion.
--
-- No row is changed or deleted. No table is added. This file contains no secrets.

begin;

alter table public.challenges drop constraint challenges_amount_rupees_check;
alter table public.challenges add constraint challenges_amount_rupees_check
  check (amount_rupees = 0 or amount_rupees between 100 and 10000);

-- How a finished challenge was completed. Null while it is not completed.
create function public.api_completion(c public.challenges) returns text
language sql stable set search_path = '' as $$
  select case
    when c.status <> 'completed' then null
    when not exists (select 1 from public.challenge_events e
                      where e.challenge_id = c.id and e.source = 'device'
                        and e.type = 'completed_on_device') then 'unconfirmed'
    when c.interruption_count > 0
      or exists (select 1 from public.challenge_events e
                  where e.challenge_id = c.id and e.source = 'device'
                    and e.type in ('restored_on_device', 'clock_jump')) then 'interrupted'
    else 'clean'
  end
$$;

create or replace function public.api_challenge_json(c public.challenges) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'status', c.status,
    'completion', public.api_completion(c),
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

-- POST /v1/challenges/{id}/complete. Same outcomes as before. New: when the
-- phone asks at or after the end time, that it was present is recorded once.
create or replace function public.api_complete_challenge(p_installation_id uuid, p_challenge_id uuid)
returns table (outcome text, challenge jsonb, seconds_remaining integer)
language plpgsql set search_path = '' as $$
declare
  c public.challenges%rowtype;
  v_outcome text;
begin
  select * into c from public.challenges x
    where x.id = p_challenge_id and x.installation_id = p_installation_id for update;
  if not found then
    return query select 'not_found'::text, null::jsonb, null::integer;
    return;
  end if;
  if c.status = 'completed' then
    v_outcome := 'already';
  elsif c.status <> 'active' then
    return query select 'not_active'::text, public.api_challenge_json(c), null::integer;
    return;
  elsif now() < c.end_time then
    return query select 'too_early'::text, public.api_challenge_json(c),
      ceil(extract(epoch from (c.end_time - now())))::integer;
    return;
  else
    update public.challenges x set status = 'completed' where x.id = c.id returning * into c;
    insert into public.challenge_events (challenge_id, source, type)
      values (c.id, 'server', 'completed');
    v_outcome := 'completed';
  end if;
  if not exists (select 1 from public.challenge_events e
                  where e.challenge_id = c.id and e.source = 'device'
                    and e.type = 'completed_on_device') then
    insert into public.challenge_events (challenge_id, source, type)
      values (c.id, 'device', 'completed_on_device');
  end if;
  return query select v_outcome, public.api_challenge_json(c), 0;
end $$;

revoke all on function public.api_completion(public.challenges) from anon, authenticated, public;
grant execute on function public.api_completion(public.challenges) to service_role;

commit;
