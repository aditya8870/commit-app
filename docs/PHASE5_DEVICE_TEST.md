# Commit 2.8.0 – physical device test (challenge sync)

Do this only after the Phase 5 migration and function are deployed.
Check results with these read-only queries (SQL Editor). They change nothing.

    -- Q1 challenges
    select id, status, start_time, end_time, actual_end_time, duration_minutes,
           amount_rupees, emergency_limit, interruption_count
    from public.challenges order by created_at desc limit 5;

    -- Q2 emergency uses
    select challenge_id, minutes, started_at_device, received_at, over_limit
    from public.emergency_uses order by received_at desc limit 5;

    -- Q3 history of the newest challenge
    select type, source, device_time, server_time from public.challenge_events
    where challenge_id = (select id from public.challenges order by created_at desc limit 1)
    order by server_time;

    -- Q4 must always be 0
    select count(*) from public.payments;

| # | Step | Expected |
|---|---|---|
| A | Internet on. Start a 10-minute challenge, ₹100, 1 emergency access. Run Q1 | 1 new row, `status` active, `end_time` = `start_time` + 10 min, amount 100 |
| B | Close Commit from recents, open again | Same challenge, same remaining time. Q1 unchanged |
| C | Restart the phone, open a blocked app | Blocked. Q1 unchanged |
| D | Airplane mode on. Open a blocked app; wait 1 minute | Still blocked; countdown continues |
| E | Still offline: use emergency access | Works for the set minutes, then locks again. Q2 shows nothing yet |
| F | Airplane mode off, open Commit, wait 30 s. Run Q2 and Q3 | Q2: exactly 1 row. Q3 contains `emergency_used` |
| G | Force stop Commit (Settings → Apps), open it again, wait 30 s. Run Q3 | Challenge still active and blocking. Q3 may show `force_stopped` / `protection_lost` |
| H | In Commit choose to end the challenge early | Not ended. Message that payment is not available. Q1 still active. Q4 = 0 |
| I | Start a 30-minute challenge (after the first one finishes). Change the phone's date to tomorrow. Open Commit with internet on | Challenge is active again within seconds; blocked app is blocked. Q1 active. Q3 shows `clock_jump`. Set the date back to automatic |
| J | Let a challenge reach its end with internet on. Run Q1 | `status` completed, `actual_end_time` = `end_time`. Q4 = 0 |
| K | Start a 30-minute challenge. Turn tamper protection off is NOT possible during a challenge, so: Settings → Apps → Commit → Storage → Clear data. Open Commit with internet on, finish setup | The same challenge is back with the original end time. Q1 still 1 active row (no second row). Q3 shows `restored_on_device` |
| L | Airplane mode on, try to start a new challenge (when none is running) | Not started. Message "The server could not be reached. Nothing was started." Q1 has no new row |

If a step differs, send me the step letter, a screenshot, and the query result. Never send anything from the Secrets page.
