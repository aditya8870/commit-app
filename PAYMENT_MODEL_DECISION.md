# Commit — payment model, policy and architecture decision

Date: 4 Oct 2026. Applies to Commit 2.2.0. No code was changed for this document.

**How to read this.** Policy statements are labelled FACT (quoted from an
official page I read today), LIKELY (my reading of it) or UNCERTAIN (needs
Google's answer or professional advice). I am not a lawyer, chartered
accountant or payments compliance adviser. Sources are listed at the end.

---

## Summary

1. **Every money model has a policy problem on Google Play, and they are
   different problems.**
   - "Pay to end the challenge" fits Google Play Billing, but reads
     uncomfortably close to Google's own definition of ransomware.
   - "Deposit, refunded on completion" avoids that, but does not fit Google
     Play Billing and may not be allowed through an outside provider inside a
     Play app.
2. **Under your own rule (never charge for force stop, crash, lost permission
   or offline), a deposit loses most of its advantage.** Its extra deterrent
   only exists if silence forfeits the deposit, which is exactly what you
   ruled out. What remains is its cost: holding other people's money, refunds,
   disputes and regulatory exposure.
3. **Recommendation:** treat the money as a payment for voluntarily ending a
   challenge (Model A), charge it through Google Play Billing in a Play Store
   build, and do not build anything provider-specific until a free build has
   passed Google's review of the blocking permissions.
4. **The largest risk is not payments.** It is whether Google approves an app
   that combines Accessibility, device admin and a payment to stop blocking.

---

## Part 1 — Business model

Model A: pay only if you quit. Model B: deposit at start, refunded on
completion. Model C (a variant of B worth knowing about): funds are *blocked in
the user's own account* at the start and released on completion, without
moving to you unless the user quits.

| Factor | A: pay on quit | B: deposit and refund | C: blocked funds (hold) |
|--------|----------------|------------------------|--------------------------|
| User psychology | Weak pull: the cost is hypothetical until you quit | Strong pull: the money is already gone unless you finish | Strong: money visibly blocked, but still "yours" |
| Trust needed | Low: nothing leaves the account unless the user acts | High: an unknown app takes money first | Medium |
| Conversion | Best: starting is free | Worst: pay before any value | Middle |
| Abuse by users | Bypass costs nothing | Chargeback after forfeiting; false "it crashed" claims | Same as A for bypass |
| Bypass incentive | High: switch tamper protection off, force stop, use the app for free | Low **only if** silence forfeits the deposit | Same as A under your rules |
| Refund work | Rare (late or duplicate payments) | Constant: every completed challenge is a refund | None: holds expire or are released |
| Failed payments | A failed payment leaves the user blocked and annoyed | Fail before the challenge starts: harmless | Fail before the challenge starts: harmless |
| Late payments | Possible (paid after the challenge ended) | Not applicable | Not applicable |
| Chargebacks / disputes | Few; each payment was explicitly confirmed | Many more: "I completed it", "the app crashed" | Few |
| Accounting | Simple: each payment is income | Every deposit is a liability until resolved; refund fees | Simple: only captures are income |
| Customer support | Low | High | Low to medium |
| Provider fit | Any gateway; Google Play Billing | Gateways yes; Google Play Billing poorly | PayU documents a UPI block of up to 90 days; cards about 7 days; **not possible in Google Play Billing** |
| Revenue | Small, and earned only when users quit | Forfeited deposits, if you keep them | Same as A |
| Technical complexity | Lowest | Highest | Medium |
| Scalability | Good | Refund volume and float management grow with users | Good |

Two points that the table hides:

**Revenue alignment.** In A and B your income rises when users fail. That is a
trust problem you will be asked about. If the stake is the product's core, a
separate source of income (a paid tier, for example) avoids profiting from
failure.

**Your rule changes the comparison.** B's whole advantage is that a bypass
does not get the money back. But "the app went silent" is also what a crash, a
dead battery or an aggressive battery saver looks like. If silence never
forfeits (your rule 8), a user can bypass, wait, and collect the refund, and B
deters no better than A while costing far more to run.

**Recommendation for this app: Model A.** A solo developer, no backend yet,
one test phone, and a firm rule against charging for technical failures all
point the same way. Model C is the better long-term design mechanically, but
it needs an outside provider, which runs into Part 2.

---

## Part 2 — Google Play and Android policy

### What the official pages say (FACT)

- F1. "Play-distributed apps requiring or accepting payment for access to
  in-app features or services … must use Google Play's billing system."
  Examples listed include "app functionality or content".
- F2. Not required for: physical goods and services, bill remittances,
  "peer-to-peer payments, online auctions, tax-exempt donations", and online
  gambling content.
- F3. "Apps may not lead users to a payment method other than Google Play's
  billing system", including through webviews, buttons and links, except under
  specific regional programmes.
- F4. India: developers may offer an alternative billing system "alongside
  Google Play's". It cannot replace it. Conditions include PCI DSS
  certification and reporting each transaction within 24 hours. The service
  fee is reduced by 4 points (for example 11% instead of 15%).
- F5. "Google Play allows any app to be consumption-only": no purchase inside
  the app at all, with content paid for elsewhere. Outside the app you may
  tell users about other purchase options.
- F6. Deposits, penalties, stakes and commitment fees are not mentioned in the
  payments policy or its FAQ.
- F7. Play Protect defines ransomware as "code that takes partial or extensive
  control of a device or data on a device and demands that the user make a
  payment or perform an action to release control."
- F8. Gambling policy covers apps that let users "wager, stake, or participate
  using real money … to obtain a prize of real world monetary value."
- F9. Apps using the Accessibility API that are not accessibility tools need
  in-app prominent disclosure, affirmative consent, and a declaration approved
  by Google. App blocking is not listed as an accepted use.
- F10. Commitment apps with money stakes and app blocking exist on Google Play
  today (for example Forfeit, whose listing shows in-app purchases). I could
  not confirm how they collect the stake.

### Your eight questions

| # | Question | Answer |
|---|----------|--------|
| 1 | Can the Commitment Amount go through Google Play Billing? | **LIKELY yes for Model A.** "Pay ₹100 to end this challenge" is a one-time in-app purchase of app functionality, which is what Play Billing is for (F1). It needs fixed price points, so the custom amount would go. **LIKELY no for B and C:** Play Billing has no deposit, hold or conditional-refund product. |
| 2 | Can an outside provider be used inside a Play app? | **LIKELY not on its own**, if the payment is for an in-app feature (F1, F3). |
| 3 | Does India change that? | **Partly (FACT F4).** You may add an outside provider, but only next to Play Billing, with PCI DSS certification and reporting. For a solo developer that is more work than Play Billing alone, not less. |
| 4 | Is it payment for app functionality? | **LIKELY yes for A.** For a refundable deposit, **UNCERTAIN**: it is not a purchase in the usual sense, and the policy is silent (F6). |
| 5 | Does pay-to-quit create a special problem? | **Yes, UNCERTAIN how serious.** An app that holds device admin, blocks apps and asks for money to stop matches the wording of F7 closely. Mitigating facts: the user sets it up, it ends by itself, emergency access is free, and the user can always switch tamper protection off in Settings and uninstall without paying. Existing apps (F10) suggest Google tolerates the category. A reviewer or an automated scan may still object. |
| 6 | Does deposit/refund create a different problem? | **Yes, UNCERTAIN.** It avoids "pay to release", but (a) it is outside Play Billing, (b) F8's "stake" wording could be raised, although there is no prize, only the user's own money back, and (c) holding deposits raises Indian regulatory questions that need advice. |
| 7 | Does a web payment flow change anything? | **LIKELY yes (F5).** If the stake is funded entirely on your website and the app contains no purchase screen, the app is "consumption-only". Linking to that site from inside the app is restricted (F3), so users would have to go there themselves. Worse experience, cleaner policy position. |
| 8 | Play Store versus sideloaded? | **FACT:** Play's payment rules bind only Play-distributed apps. A sideloaded build can use any provider. But on your own phone Play Protect blocked the sideloaded install because of Accessibility, so sideloading is not a route to ordinary users. |

### Other policy items that affect distribution

- **Accessibility declaration (F9)** is required for a Play release and is the
  first gate. The app's disclosure screen exists; consent wording will need
  checking against the policy.
- **Android 17 Advanced Protection** (reported March 2026) blocks
  non-accessibility-tool apps from the Accessibility API for users who turn
  that mode on. LIKELY impact: those users fall back to the backup detector.
- **Indian law: UNCERTAIN and outside what I can assess.** A payment gateway
  needs a registered business and KYC. Forfeited amounts are income and may
  attract GST. Whether a deposit model touches rules on holding customer
  funds, or the 2025 online gaming law's definitions, needs a professional's
  answer.

---

## Part 3 — Payment architecture

```
Flutter app ──▶ Backend API ──▶ Payment provider (Play Billing or gateway)
     ▲              │  ▲                    │
     │              ▼  └──── webhook / server notification
     └──── challenge and payment status (read-only for the app)
```

### What the client is never trusted for

Amount · payment success · payment status · who owns a transaction · the time a
challenge ends. The app sends requests and displays what the server returns.

### Tables

| Table | Key columns |
|-------|-------------|
| `users` | id, created_at, auth_provider_id, status |
| `devices` | id, user_id, install_id, app_version, integrity_verdict, last_seen_at |
| `challenges` | id, user_id, device_id, apps (json), start_at, end_at (server time), amount_paise, product_id, emergency_limit, emergency_minutes, emergency_used, status, actual_end_at, interruption_count, created_at |
| `payments` | id, challenge_id (unique), provider, provider_order_id (unique), provider_payment_id / purchase_token (unique), amount_paise, status, expires_at, captured_at, refund_id, refund_reason |
| `payment_events` | id, payment_id, source (client / webhook / poll / admin), provider_event_id (unique), type, payload, received_at |
| `challenge_events` | id, challenge_id, type (emergency_used, protection_lost, force_stopped, restored, completed_reported), at_client, at_server |

Money is integer paise. No card number, CVV, UPI PIN, bank login or provider
secret is stored anywhere in these tables or on the phone.

### Endpoints

| Endpoint | Request carries | Server does |
|----------|-----------------|-------------|
| `POST /v1/auth/device` | sign-in token, attestation | Creates user and device, returns session token |
| `POST /v1/challenges` | apps, duration, emergency settings, **amount tier** | Validates, stamps start and end with server time, stores, returns challenge |
| `GET /v1/challenges/{id}` | — | Returns authoritative status and payment status |
| `POST /v1/challenges/{id}/events` | emergency use, interruption events | Stores with server time; never charges |
| `POST /v1/challenges/{id}/end-intent` | idempotency key | Checks ACTIVE and time left; returns the one open payment for this challenge, creating it if none |
| `POST /v1/payments/{id}/client-result` | whatever the checkout returned (purchase token or provider IDs) | Verifies with the provider; never trusts the result as given |
| `GET /v1/payments/{id}` | — | Status for polling |
| `POST /v1/webhooks/{provider}` | provider payload + signature | Verifies signature, de-duplicates, applies once |
| `POST /internal/reconcile` (scheduled) | — | Compares open payments with the provider; fixes drift; triggers refunds |

### Challenge state machine (server)

```
ACTIVE ──end_at reached──────────────▶ COMPLETED
ACTIVE ──payment CAPTURED before end─▶ ENDED_EARLY
ACTIVE ──admin / fraud──────────────▶ CANCELLED
```

Emergency access and protection interruptions are events on an ACTIVE
challenge, not states. COMPLETED is decided by server time alone.

### Payment state machine (server)

```
CREATED ─▶ PENDING ─▶ CAPTURED ─▶ (challenge ENDED_EARLY)
              │           └─ captured after end_at ─▶ REFUND_PENDING ─▶ REFUNDED
              ├─▶ FAILED / CANCELLED ─▶ PENDING   (new attempt, same payment row)
              └─▶ EXPIRED
```

CAPTURED is final for charging. One payment row per challenge, enforced by a
unique constraint.

### Rules

- **Idempotency.** Every write carries a client-generated key stored with the
  result; repeating the call returns the stored result. `end-intent` is keyed
  on the challenge, so ten taps produce one payment.
- **Webhooks.** Verify the signature, look up `provider_event_id`, ignore it
  if already seen, apply the transition in one database transaction.
- **Retries.** The app may only start a new attempt after the server confirms
  the previous one is FAILED, CANCELLED or EXPIRED.
- **Refunds.** Automatic when a capture arrives after `end_at` or a second
  capture ever appears; manual through an admin action otherwise.
- **Reconciliation.** A scheduled job re-queries every non-final payment and
  compares daily totals with the provider's report.
- **Server time.** `start_at` and `end_at` are set by the server. The phone's
  clock is used only to draw the countdown.
- **Authentication.** A real sign-in (Google or phone number) so a challenge
  survives reinstall; short-lived session tokens; device attestation attached
  to money-related calls.
- **Transaction references.** Issued by the server (and the provider); the
  phone never invents one.

---

## Part 4 — Security review

| # | Attack | Server-side defence |
|---|--------|---------------------|
| 1 | Changes the amount locally | Amount is fixed in `challenges` at creation; the payment is created from that row |
| 2 | Changes the challenge end time | `end_at` lives on the server; completion is judged by server time |
| 3 | Changes local payment status | The server's status is the only one used; the app's copy is display only. The apps can still be unlocked locally: see the note below |
| 4 | Replays an old success response | A purchase token or provider payment ID can be attached to one payment row only (unique), and is verified with the provider each time |
| 5 | Creates many payment attempts | One payment row per challenge; `end-intent` is idempotent; rate limits |
| 6 | Closes the app during payment | Outcome arrives by webhook; app reads status when reopened |
| 7 | Loses internet during payment | Same as 6; payment stays PENDING until the provider answers or it expires |
| 8 | Payment succeeds, webhook arrives late | Client-result verification and webhook both lead to CAPTURED; whichever is first wins, the other is a no-op |
| 9 | Payment succeeds, app crashes | Same as 6 |
| 10 | Reinstalls the app | Challenge belongs to the signed-in user; the server returns it on next sign-in and the app resumes blocking |
| 11 | Clears app data | Same as 10 (and already refused on the phone during a challenge) |
| 12 | Restores an Android backup | Backup switched off for the state file; server copy wins on any difference |
| 13 | Changes device time | Irrelevant to money decisions; server time only |
| 14 | Uses another device | The server shows the same challenge on any device the user signs in on; it cannot block a phone without the app |
| 15 | Tampers with the APK | Device attestation on money-related calls; the server never accepts amount, time or paid status from the app anyway |
| 16 | Force-stops the blocker | Recorded as an event when the app next reports; never charged; challenge is not counted as fully kept |
| 17 | Disables permissions | Same as 16 |
| 18 | Pays after the challenge expired | Server refuses to create a payment near the end; a capture after `end_at` is refunded automatically |

**Limit that no backend removes.** Attacks 3, 15, 16 and 17 can unlock the
apps on that phone without paying. The server makes the money correct and the
record honest; it cannot enforce the block.

---

## Part 5 — Payment for ending, or a stake that is held?

**Treat it as a payment for voluntarily ending the challenge (A).**

- *Commercially safer:* you never hold a user's money, so there is nothing to
  refund in the normal case, far fewer disputes, simpler accounts, and no
  question about holding deposits.
- *Technically:* a held stake is cleaner on the money path (no payment at the
  moment of quitting, no pending state, no late payment). That is a real
  advantage of Model C, and worth revisiting later. But it needs an outside
  provider.
- *Deterrence:* a held stake only deters bypassing if silence forfeits it,
  which you have ruled out. So it would not fix the bypass problem either.

The honest position for the product: the amount is a commitment device for
people who want to keep their word, not an enforcement mechanism. The record
of interruptions, and not counting an interrupted challenge as kept, is the
consequence for bypassing.

---

## Part 6 — Payment provider

### Requirements first

1. Allowed by the distribution channel's rules for this exact transaction.
2. Their own terms accept this business type (a charge for ending a
   self-imposed block). **Must be asked in writing before integrating.**
3. One-time payments from ₹10 with UPI support.
4. Server-side order creation and server-side verification.
5. Signed webhooks or server notifications.
6. Refund API.
7. A test mode that needs no live money.
8. Onboarding you can actually pass (business type, KYC).
9. Fees that make sense at ₹10–₹100.

### Comparison

| | Google Play Billing | Razorpay | Cashfree | PayU |
|---|---|---|---|---|
| Fits Model A | Yes: one-time product per price tier | Yes | Yes | Yes |
| Fits B / C | No deposit or hold product | Authorise-then-capture exists, with a short window (days) | Not checked | Documents a UPI block of up to 90 days ("UPI Reserve Pay") |
| Allowed in a Play Store build | Yes, it is the required method | Only alongside Play Billing under the India programme, or outside the app | Same | Same |
| Server verification | Purchase token checked with Google's API; server notifications | Signature check, status API, webhooks | Not checked | Not checked |
| Onboarding | Play developer account and payments profile | Registered business + KYC | Registered business + KYC | Registered business + KYC |
| Fee (FACT for Play; others not checked) | 15% tier mentioned by Google | — | — | — |
| Custom amounts | No: fixed price points | Yes | Yes | Yes |
| Accepts this business type | UNCERTAIN (Part 2, question 5) | UNCERTAIN: ask | UNCERTAIN: ask | UNCERTAIN: ask |

"Not checked" means I did not read that provider's documentation today and am
not going to guess.

**Answer to your key question.** For a Play Store app and Model A, Google Play
Billing is the only option that is clearly permitted to take the payment. None
of the three gateways can be confirmed as legally usable inside a Play build
without the India alternative-billing programme. For a held stake, only a
gateway can do it technically, and its permissibility is uncertain.

---

## Part 7 — Implementation order

| Step | What | Safe before the policy / provider decision? |
|------|------|---------------------------------------------|
| 1 | Finalise the model (this document) | — |
| 2 | **Policy path:** Play developer account; submit a free build (no money features switched on) to closed testing with the Accessibility declaration | Yes, and it should come first: it tests the biggest risk at no cost |
| 3 | App hardening: B1 (verify before every retry), B4 (backup off), B5 (keep paid records), B8 (payment apps versus the blocker), B10 (release signing key) | Yes |
| 4 | Backend skeleton and hosting | Yes |
| 5 | Sign-in and device identity | Yes |
| 6 | Server-side challenge creation, server time, event log | Yes |
| 7 | Payment tables, state machines, idempotency layer with a stand-in provider | Yes |
| 8 | Order creation / purchase flow | No: provider-specific |
| 9 | Verification and webhook / server notifications | No |
| 10 | Refunds and reconciliation | No |
| 11 | Test environment (provider test mode, licence testers) | No |
| 12 | Real-device payment tests | No |
| 13 | Small live pilot with a low cap | No |

---

## Final recommendations

**1. Business model.** Pay only if you choose to end early (Model A),
presented as accountability. Plan for income that does not depend on users
quitting.

**2. Payment model.** Google Play Billing one-time products at the fixed tiers
(₹10, 20, 50, 100, 200, 500, 1,000); drop the custom amount; server-verified
purchase; automatic refund for a payment that lands after the challenge ended.
Keep a held-stake design (Model C) as a later option that needs legal advice.

**3. Distribution model.** Google Play, starting with closed testing.
Sideloading is not viable for ordinary users because Play Protect blocks the
install.

**4. Backend architecture.** A small managed backend: sign-in, an API layer,
one database with the six tables above, a scheduled reconciliation job, and
the provider's server notifications. Server owns amount, time, ownership and
payment status.

**5. Biggest risks.**
1. Google rejecting or later removing the app over Accessibility, device
   admin, or the pay-to-end pattern (F7).
2. The stake not deterring anyone, because bypassing is free.
3. Earning only when users fail.
4. Indian tax and regulatory questions I cannot settle.
5. Running payments, refunds and support alone.

**6. What to do next.**
1. Tell me whether you accept Model A through Google Play Billing, or want a
   different path.
2. Find out (or tell me) whether you have, or will set up, a registered
   business; it affects every option except Play Billing.
3. Approve steps 2–7 above, or a subset. None of them touches a payment
   provider.
4. Before any live payment: get the Indian tax and regulatory questions
   answered by a professional.

---

## Sources

- Google Play Payments policy: https://support.google.com/googleplay/android-developer/answer/9858738
- Understanding Google Play's Payments policy (FAQ): https://support.google.com/googleplay/android-developer/answer/10281818
- Changes to Google Play's billing requirements for developers serving users in India: https://support.google.com/googleplay/android-developer/answer/13306652
- Real-Money Gambling, Games, and Contests: https://support.google.com/googleplay/android-developer/answer/9877032
- Use of the AccessibilityService API: https://support.google.com/googleplay/android-developer/answer/10964491
- Google Play Protect malware categories: https://developers.google.com/android/play-protect/phacategories
- Forfeit on Google Play: https://play.google.com/store/apps/details?id=app.forfeit.forfeit
- Razorpay best practices: https://razorpay.com/docs/payments/payment-gateway/web-integration/standard/best-practices/
- Razorpay payment capture settings: https://razorpay.com/docs/payments/payments/capture-settings/
- PayU UPI Reserve Pay: https://docs.payu.in/docs/upi-reserve-pay
- Android 17 Advanced Protection and Accessibility (news report): https://securityaffairs.com/189497/security/advanced-protection-mode-in-android-17-prevents-apps-from-misusing-accessibility-services.html
