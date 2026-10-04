# Commit 2.7.0 – physical device test (installation identity)

You need: the phone, Wi-Fi or mobile data, and the Supabase dashboard open on project `commit-dev`.

The app shows nothing new on screen. You check the result in Supabase with this read-only query (SQL Editor, new query). It changes nothing:

    select id, recovery_count, app_version, android_version,
           created_at, last_seen_at, last_recovered_at
    from public.installations order by created_at;

Before you start, run it once and note how many rows exist (expected: 0).

Install as usual: pause Play Protect scanning, tap the APK, choose **Update**, re-enable scanning.

| # | Step | Expected |
|---|---|---|
| A1 | With internet on, open Commit | App opens normally, nothing new on screen |
| A2 | Run the query | Exactly 1 new row. `recovery_count` 0, `app_version` 2.7.0. **Write down the `id`** |
| B1 | Close Commit from recents, open it again | Opens normally |
| B2 | Run the query | Still 1 row, same `id` |
| C1 | Turn on airplane mode. Open Commit, start a 2-minute challenge on any app, open that app | The app is blocked exactly as before; countdown works; challenge completes |
| C2 | Turn airplane mode off | Nothing visible changes |
| D1 | Settings → Apps → Commit → Force stop (turn tamper protection off first if needed, with no challenge running). Open Commit | Opens normally |
| D2 | Wait 2 minutes, open Commit again, run the query | Still 1 row, same `id`. `last_seen_at` is recent (this proves the signed `/me` call works) |
| E1 | With no challenge running: Commit → Settings → Tamper protection → turn off. Uninstall Commit | Uninstalled |
| E2 | Install the same 2.7.0 APK again, open it, complete the welcome/setup screens | Opens as a fresh app |
| F/G | Run the query | **Still 1 row, same `id` as A2.** `recovery_count` is now 1 and `last_recovered_at` is filled |
| H | Wait 2 minutes, open Commit again, run the query | `last_seen_at` is newer than `last_recovered_at` (the new credential is accepted) |
| I | Turn the blocking setup back on, start a 5-minute challenge, test blocking, emergency access and completion | All work as in 2.6.0 |

If a step differs:

- **A2 shows no new row:** check the phone has internet, wait a minute, bring Commit to the front again, re-run the query.
- **F/G shows 2 rows:** recovery did not match the phone. Send me both rows (no secrets are in them).
- **Anything about blocking differs from 2.6.0:** send the step number and a screenshot.

Do not send me anything from Supabase's Secrets page.
