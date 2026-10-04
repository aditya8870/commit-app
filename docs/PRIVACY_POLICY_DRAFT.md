# Commit – Privacy Policy (DRAFT, not published)

Status: draft for app version 2.9.0. **Do not publish until the items in square brackets are filled in and section 8 is decided.** Have a lawyer review it (India DPDP Act) before publication.

Where it must go before Play submission:

| Place | What |
|---|---|
| Public web page | One HTTPS address that opens without login, is not a PDF, and is not geo-blocked. Proposed form: `https://[your-domain]/commit/privacy` (a free option is GitHub Pages: `https://[github-username].github.io/commit-privacy/`) |
| Play Console | App content → Privacy policy → that exact address |
| The app | Build with `--dart-define=commitPrivacyUrl=<that address>`; Settings then shows "Privacy policy" |

---

## Privacy Policy for Commit

Effective date: [date]

Commit is an Android app that blocks apps you choose, for a time you choose. This policy explains what information Commit handles.

**Who we are.** Commit is provided by [developer or company legal name], [postal address, country]. Contact for privacy questions: [privacy email address].

### 1. No account

You do not create an account. Commit does not ask for your name, email address or phone number.

### 2. Information Commit collects

Commit works with a server. The following is sent to the server and stored there:

| Information | Why |
|---|---|
| An installation ID: a random identifier the server creates for this copy of the app | To know which challenges belong to this installation |
| A device identifier in scrambled (hashed) form. Android's per-app device ID is hashed on your phone before sending and hashed again on the server with a secret key. The original ID is never sent or stored | Only to recognise the same phone if you reinstall Commit, so a running challenge can be restored |
| App version and Android version | To keep the app working across versions |
| The apps you choose to block in a challenge: app name and package name. Only the apps you select, not the list of apps on your phone | To run and restore your challenge |
| Challenge details: length, start and end time, emergency-access settings, status, and the version of the terms you accepted | To run the challenge and keep its time honest |
| Use of emergency access: when and for how long | To keep the limit you set |
| Protection events during a challenge: for example that blocking was switched off or restored, that the app was stopped, that the phone's clock was changed, or that a challenge was restored after a reinstall | To record whether a challenge was fully kept |
| Times of first use, last contact and recovery | To operate and protect the service |
| Your IP address | Seen by the server when your phone connects, as with any internet service. Commit keeps only a scrambled form for up to one day to limit abuse. Our hosting provider's own logs may hold IP addresses for a limited time |

A copy of your challenges is also stored on your phone.

### 3. Information Commit does not collect

- Your name, email address, phone number or any account details.
- Anything shown on your screen, your messages, passwords, or what you type.
- Which app is open at any moment. This is used on your phone to block the apps you chose and is not saved or sent.
- The full list of apps installed on your phone.
- Location, contacts, photos, files, microphone or camera.
- Advertising identifiers. Commit has no ads and no analytics or tracking tools.
- Payment information. This version of Commit is free and never charges you.

### 4. Special access on your phone

| Access | What Commit does with it |
|---|---|
| Accessibility service | Only notices when an app you chose to block is opened, so Commit can cover it. It cannot read screen content. Commit is not an accessibility tool for people with disabilities. Commit asks for your agreement before sending you to this setting |
| Usage access | A backup way to notice that a blocked app was opened if Accessibility is off |
| Display over other apps | Shows the blocked screen over a blocked app |
| Notifications | Shows that a challenge is active or that protection was interrupted |

You can switch each of these off at any time in Android Settings, and you can uninstall Commit or clear its data at any time. If you do so during a challenge, that is recorded and the challenge is not counted as fully kept.

### 5. How the information is used

To provide the app: start, run, restore and finish your challenges; keep challenge times accurate; and prevent abuse of the service. It is not used for advertising and no profile is built about you.

### 6. Sharing

We do not sell your information and do not share it for advertising or analytics. It is processed on our behalf by our hosting provider, Supabase ([legal entity], servers in [region]). We may disclose information if the law requires it.

### 7. Security

All communication between the app and the server is encrypted (HTTPS). The secret that identifies your installation is stored encrypted on your phone and only as a hash on the server. Device identifiers are stored only in hashed form. No method is perfectly secure.

### 8. How long information is kept, and deletion  ⚠ DECISION NEEDED BEFORE PUBLISHING

Proposed text (valid only once the retention process in `PHASE6_REMEDIATION.md` section 8 exists):

> Information is kept while this installation is in use. If an installation has not contacted the server for [12] months and has no running challenge, its information is deleted. You can ask for your information to be deleted sooner by writing to [privacy email address] and including the installation ID shown in Commit → Settings → Privacy. We act on requests within [30] days. Clearing Commit's data or uninstalling it removes the copy on your phone.

Until that process exists the honest text is: "Information is currently kept without a fixed time limit. To ask for deletion, write to [privacy email address]." – and deletions would be done by hand.

### 9. Children

Commit is not directed at children under [13/18 – decide with the Play target-audience setting].

### 10. Your rights

Depending on where you live you may have the right to access, correct or delete your information, or to complain to a data-protection authority. Contact [privacy email address]. [Grievance officer name and contact, if required under Indian law.]

### 11. Changes

If this policy changes, the new version will be published at this address with a new effective date. Significant changes will also be shown in the app.
