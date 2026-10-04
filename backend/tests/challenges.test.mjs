// Phase 5 tests: the challenge API, run through the real handler against a
// real local PostgreSQL with every migration applied (tests/run_all.sh).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID, createHash } from "node:crypto";
import pg from "pg";
import { handle } from "../supabase/functions/api/index.ts";

let db;
before(async () => {
  db = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await db.connect();
  await db.query("set role service_role");
});
after(async () => { await db.end(); });

const rpc = async (fn, args) => {
  const keys = Object.keys(args);
  const sql = `select * from public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(", ")})`;
  const values = keys.map((k) => (Array.isArray(args[k]) || (args[k] && typeof args[k] === "object"))
    && !k.endsWith("_hashes") ? JSON.stringify(args[k]) : args[k]);
  return (await db.query(sql, values)).rows;
};
const deps = {
  rpc,
  recoveryKeys: { current: 1, keys: { 1: randomBytes(32).toString("hex") } },
  // Generous limits: these tests are about challenges, not rate limiting.
  limits: { register_ip: [100000, 3600], register_global: [100000, 3600], request_installation: [100000, 60] },
};

const call = async (method, path, { body, who, headers = {} } = {}) => {
  const res = await handle(new Request(`https://example.test/functions/v1/api${path}`, {
    method,
    headers: {
      "x-forwarded-for": "10.0.0.1",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(who ? { authorization: `Bearer ${who.credential}`, "x-installation-id": who.id } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), deps);
  return { status: res.status, json: await res.json() };
};

const newInstall = async () => {
  const credential = randomBytes(32).toString("base64url");
  const recoveryMaterial = createHash("sha256").update(randomBytes(8)).digest("hex");
  const res = await call("POST", "/v1/installations", { body: { credential, recoveryMaterial, appVersion: "2.8.0" } });
  assert.equal(res.status, 201);
  return { id: res.json.installationId, credential, recoveryMaterial };
};

const key = () => randomBytes(16).toString("hex");
const valid = (over = {}) => ({
  apps: [{ packageName: "com.instagram.android", appName: "Instagram" },
         { packageName: "com.google.android.youtube", appName: "YouTube" }],
  durationMinutes: 60, amountRupees: 100, emergencyLimit: 2, emergencyMinutes: 5,
  consentVersion: "2026-10-04.1", consentAccepted: true, ...over,
});
const create = (who, over = {}, k = key()) =>
  call("POST", "/v1/challenges", { who, body: valid(over), headers: { "idempotency-key": k } });

/// Test fixture only: moves a challenge into the past, bypassing the rules
/// that normally make its times unchangeable.
const expire = async (id, secondsAgo = 5) => {
  await db.query("reset role");
  await db.query("set session_replication_role = replica");
  await db.query(
    `update public.challenges set
       start_time = now() - make_interval(mins => duration_minutes) - make_interval(secs => $2),
       end_time = now() - make_interval(secs => $2) where id = $1`, [id, secondsAgo]);
  await db.query("set session_replication_role = origin");
  await db.query("set role service_role");
};
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

// ------------------------------------------------------------------ creation
test("create: the server decides ID, start, end and status", async () => {
  const me = await newInstall();
  const before = Date.now();
  const res = await create(me, { durationMinutes: 90, amountRupees: 250 });
  assert.equal(res.status, 201);
  const c = res.json.challenge;
  assert.match(c.id, /^[0-9a-f-]{36}$/);
  assert.equal(c.status, "active");
  assert.match(c.startTime, ISO);
  assert.match(c.endTime, ISO);
  assert.ok(Math.abs(Date.parse(c.startTime) - before) < 5000, "start is the server's now");
  assert.equal(Date.parse(c.endTime) - Date.parse(c.startTime), 90 * 60 * 1000);
  assert.equal(c.amountRupees, 250);
  assert.equal(c.emergencyUsed, 0);
  assert.deepEqual(c.apps.map((a) => a.packageName).sort(),
    ["com.google.android.youtube", "com.instagram.android"]);
  assert.deepEqual(c.payment, { status: "not_started", available: false });
});

test("create: the client cannot choose start, end, status or ID", async () => {
  const me = await newInstall();
  for (const field of ["startTime", "endTime", "status", "id", "installationId", "actualEndTime", "payment"]) {
    const res = await create(me, { [field]: "2020-01-01T00:00:00Z" });
    assert.equal(res.status, 422, field);
  }
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null);
});

test("create: validation failures", async () => {
  const me = await newInstall();
  const app = (packageName, appName = "X") => ({ packageName, appName });
  const bad = {
    "duration 0": { durationMinutes: 0 },
    "duration over 30 days": { durationMinutes: 43201 },
    "duration not whole": { durationMinutes: 1.5 },
    "duration as text": { durationMinutes: "60" },
    "amount 99": { amountRupees: 99 },
    "amount 10001": { amountRupees: 10001 },
    "amount negative": { amountRupees: -100 },
    "amount missing": { amountRupees: undefined },
    "emergency limit 4": { emergencyLimit: 4 },
    "emergency limit -1": { emergencyLimit: -1 },
    "emergency minutes 7": { emergencyMinutes: 7 },
    "no apps": { apps: [] },
    "apps not a list": { apps: "com.instagram.android" },
    "51 apps": { apps: Array.from({ length: 51 }, (_, i) => app(`com.example.app${i}`)) },
    "bad package": { apps: [app("not a package; drop table")] },
    "duplicate app": { apps: [app("com.a.b"), app("com.a.b")] },
    "empty app name": { apps: [app("com.a.b", "")] },
    "app name too long": { apps: [app("com.a.b", "x".repeat(101))] },
    "app name with control character": { apps: [app("com.a.b", "A\u0000B")] },
    "app not an object": { apps: ["com.a.b"] },
    "no consent version": { consentVersion: undefined },
    "bad consent version": { consentVersion: "<script>" },
    "consent not accepted": { consentAccepted: false },
  };
  for (const [name, over] of Object.entries(bad)) {
    const res = await create(me, over);
    assert.equal(res.status, 422, `${name} -> ${res.status} ${res.json.code}`);
  }
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null,
    "nothing was created by any refused request");
});

test("create: boundaries are accepted (₹100, ₹10,000, 1 minute, 30 days, 50 apps)", async () => {
  for (const over of [
    { amountRupees: 100, durationMinutes: 1 },
    { amountRupees: 10000, durationMinutes: 43200, emergencyLimit: 0 },
    { apps: Array.from({ length: 50 }, (_, i) => ({ packageName: `com.example.app${i}`, appName: `App ${i}` })) },
  ]) {
    const res = await create(await newInstall(), over);
    assert.equal(res.status, 201, JSON.stringify(over).slice(0, 60));
  }
});

test("create: an idempotency key is required", async () => {
  const me = await newInstall();
  for (const headers of [{}, { "idempotency-key": "short" }, { "idempotency-key": "has spaces in the key" }]) {
    const res = await call("POST", "/v1/challenges", { who: me, body: valid(), headers });
    assert.equal(res.status, 400);
    assert.equal(res.json.code, "IDEMPOTENCY_KEY_REQUIRED");
  }
});

test("create: only one active challenge per installation", async () => {
  const me = await newInstall();
  const first = await create(me);
  const second = await create(me);
  assert.equal(second.status, 409);
  assert.equal(second.json.code, "ACTIVE_CHALLENGE_EXISTS");
  assert.equal(second.json.challenge.id, first.json.challenge.id);
  const n = await db.query("select count(*)::int n from public.challenges where installation_id = $1", [me.id]);
  assert.equal(n.rows[0].n, 1);
});

test("create: two simultaneous requests still produce exactly one challenge", async () => {
  // Two separate database connections, so the requests truly overlap.
  const other = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await other.connect();
  await other.query("set role service_role");
  const rpc2 = async (fn, args) => {
    const keys = Object.keys(args);
    return (await other.query(
      `select * from public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(", ")})`,
      keys.map((k) => (args[k] && typeof args[k] === "object" && !k.endsWith("_hashes")) ? JSON.stringify(args[k]) : args[k]))).rows;
  };
  const me = await newInstall();
  const req = (r) => handle(new Request("https://example.test/v1/challenges", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${me.credential}`,
      "x-installation-id": me.id, "idempotency-key": key(), "x-forwarded-for": "10.0.0.1" },
    body: JSON.stringify(valid()),
  }), { ...deps, rpc: r });
  const [a, b] = await Promise.all([req(rpc), req(rpc2)]);
  await other.end();
  assert.deepEqual([a.status, b.status].sort(), [201, 409]);
  const n = await db.query("select count(*)::int n from public.challenges where installation_id = $1 and status = 'active'", [me.id]);
  assert.equal(n.rows[0].n, 1);
});

test("create: repeating a request with the same key returns the same challenge", async () => {
  const me = await newInstall();
  const k = key();
  const first = await create(me, {}, k);
  const again = await create(me, {}, k);
  assert.equal(first.status, 201);
  assert.equal(again.status, 200);
  assert.deepEqual(again.json.challenge, first.json.challenge);
  const n = await db.query("select count(*)::int n from public.challenges where installation_id = $1", [me.id]);
  assert.equal(n.rows[0].n, 1);
});

test("create: the same key with a different request is refused", async () => {
  const me = await newInstall();
  const k = key();
  await create(me, { amountRupees: 100 }, k);
  const changed = await create(me, { amountRupees: 5000 }, k);
  assert.equal(changed.status, 409);
  assert.equal(changed.json.code, "IDEMPOTENCY_MISMATCH");
  const row = await db.query("select amount_rupees from public.challenges where installation_id = $1", [me.id]);
  assert.equal(row.rows[0].amount_rupees, 100);
});

test("registrations: tells what a create request produced, and never creates", async () => {
  const me = await newInstall();
  const k = key();
  const none = await call("GET", `/v1/challenges/registrations/${k}`, { who: me });
  assert.equal(none.status, 404);
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null);
  const made = await create(me, {}, k);
  const found = await call("GET", `/v1/challenges/registrations/${k}`, { who: me });
  assert.equal(found.status, 200);
  assert.equal(found.json.challenge.id, made.json.challenge.id);
  const stranger = await newInstall();
  assert.equal((await call("GET", `/v1/challenges/registrations/${k}`, { who: stranger })).status, 404);
});

// ------------------------------------------------------- retrieval, isolation
test("active: returns the active challenge, or null", async () => {
  const me = await newInstall();
  assert.deepEqual((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null);
  const made = await create(me);
  const res = await call("GET", "/v1/challenges/active", { who: me });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.challenge, made.json.challenge);
});

test("every challenge route needs a valid installation credential", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const routes = [
    ["POST", "/v1/challenges", valid()], ["GET", "/v1/challenges/active"], ["GET", "/v1/challenges/history"],
    ["GET", `/v1/challenges/${c.id}`], ["POST", `/v1/challenges/${c.id}/complete`, {}],
    ["POST", `/v1/challenges/${c.id}/emergency`, { useId: randomUUID(), startedAt: new Date().toISOString(), minutes: 5 }],
    ["POST", `/v1/challenges/${c.id}/events`, { events: [] }], ["POST", `/v1/challenges/${c.id}/end-early`, {}],
    ["GET", `/v1/challenges/registrations/${key()}`],
  ];
  for (const [method, path, body] of routes) {
    const none = await call(method, path, { body, headers: { "idempotency-key": key() } });
    assert.equal(none.status, 401, `${method} ${path} without credentials`);
    const wrong = await call(method, path, { body, who: { id: me.id, credential: randomBytes(32).toString("base64url") }, headers: { "idempotency-key": key() } });
    assert.equal(wrong.status, 401, `${method} ${path} with a wrong credential`);
  }
});

test("ownership: another installation gets 'not found' for everything", async () => {
  const owner = await newInstall(), stranger = await newInstall();
  const c = (await create(owner)).json.challenge;
  const use = { useId: randomUUID(), startedAt: new Date().toISOString(), minutes: 5 };
  const attempts = [
    ["GET", `/v1/challenges/${c.id}`],
    ["POST", `/v1/challenges/${c.id}/complete`, {}],
    ["POST", `/v1/challenges/${c.id}/emergency`, use],
    ["POST", `/v1/challenges/${c.id}/events`, { events: [{ id: randomUUID(), type: "force_stopped", deviceTime: new Date().toISOString() }] }],
    ["POST", `/v1/challenges/${c.id}/end-early`, {}],
  ];
  for (const [method, path, body] of attempts) {
    const res = await call(method, path, { who: stranger, body, headers: { "idempotency-key": key() } });
    assert.equal(res.status, 404, `${method} ${path}`);
    assert.equal(res.json.code, "NOT_FOUND");
    assert.equal(res.json.challenge, undefined, "nothing about the challenge leaks");
  }
  const missing = await call("GET", `/v1/challenges/${randomUUID()}`, { who: stranger });
  assert.deepEqual([missing.status, missing.json.code, missing.json.message],
    [404, "NOT_FOUND", (await call("GET", `/v1/challenges/${c.id}`, { who: stranger })).json.message],
    "someone else's challenge looks exactly like one that does not exist");
  assert.equal((await call("GET", "/v1/challenges/active", { who: stranger })).json.challenge, null);
  assert.deepEqual((await call("GET", "/v1/challenges/history", { who: stranger })).json.items, []);
  const row = await db.query("select status, interruption_count from public.challenges where id = $1", [c.id]);
  assert.deepEqual(row.rows[0], { status: "active", interruption_count: 0 });
  assert.equal((await db.query("select count(*)::int n from public.emergency_uses where challenge_id = $1", [c.id])).rows[0].n, 0);
});

test("ownership: a supplied installation ID never overrides the authenticated one", async () => {
  const owner = await newInstall(), stranger = await newInstall();
  await create(owner);
  // The stranger signs with their own credential but names the owner's ID.
  const res = await call("GET", "/v1/challenges/active", { who: { id: owner.id, credential: stranger.credential } });
  assert.equal(res.status, 401);
  // And cannot create a challenge "for" the owner through the body.
  const made = await create(stranger, { installationId: owner.id });
  assert.equal(made.status, 422);
});

test("a malformed challenge ID is simply not found", async () => {
  const me = await newInstall();
  for (const id of ["1", "abc", "../../x", "00000000-0000-0000-0000-00000000000g", "%27%20or%201%3D1"]) {
    assert.equal((await call("GET", `/v1/challenges/${id}`, { who: me })).status, 404, id);
  }
});

// ---------------------------------------------------------------- completion
test("complete: refused before the end time; nothing changes", async () => {
  const me = await newInstall();
  const c = (await create(me, { durationMinutes: 60 })).json.challenge;
  const res = await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: {} });
  assert.equal(res.status, 409);
  assert.equal(res.json.code, "TOO_EARLY");
  assert.ok(res.json.secondsRemaining > 3500 && res.json.secondsRemaining <= 3600);
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge.status, "active");
});

test("complete: nothing the client sends can force it early", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const res = await call("POST", `/v1/challenges/${c.id}/complete`, { who: me,
    body: { now: "2099-01-01T00:00:00Z", endTime: "2000-01-01T00:00:00Z", status: "completed", force: true },
    headers: { date: "Fri, 01 Jan 2099 00:00:00 GMT", "x-client-time": "2099-01-01T00:00:00Z" } });
  assert.equal(res.status, 409);
  assert.equal(res.json.code, "TOO_EARLY");
});

test("complete: succeeds once the database clock has reached the end time", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  const res = await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: {} });
  assert.equal(res.status, 200);
  assert.equal(res.json.challenge.status, "completed");
  assert.equal(res.json.challenge.actualEndTime, res.json.challenge.endTime);
  // Repeating it (a late or duplicate request) is harmless.
  const again = await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: {} });
  assert.equal(again.status, 200);
  assert.deepEqual(again.json.challenge, res.json.challenge);
  const events = await db.query("select count(*)::int n from public.challenge_events where challenge_id = $1 and type = 'completed'", [c.id]);
  assert.equal(events.rows[0].n, 1, "recorded once");
});

test("complete: happens on the server even if the phone never asks", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null);
  assert.equal((await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge.status, "completed");
  // And a new challenge can start: an old one can never block the installation.
  assert.equal((await create(me)).status, 201);
});

// ------------------------------------------------------- terminal immutability
test("terminal states cannot be changed through any route", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  const done = (await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: {} })).json.challenge;

  const early = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me, body: {}, headers: { "idempotency-key": key() } });
  assert.deepEqual([early.status, early.json.code], [409, "CHALLENGE_NOT_ACTIVE"]);
  const use = await call("POST", `/v1/challenges/${c.id}/emergency`, { who: me,
    body: { useId: randomUUID(), startedAt: new Date(Date.parse(done.endTime) - 600000).toISOString(), minutes: 5 } });
  assert.deepEqual([use.status, use.json.code], [409, "CHALLENGE_NOT_ACTIVE"]);
  const after = (await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge;
  assert.deepEqual({ ...after, interruptionCount: 0 }, { ...done, interruptionCount: 0 });
  assert.equal(after.emergencyUsed, 0, "a late report is history, not an emergency use");

  for (const status of ["active", "cancelled", "ended_early"]) {
    await assert.rejects(db.query("update public.challenges set status = $2 where id = $1", [c.id, status]),
      /finished challenge cannot change state/);
  }
});

// ------------------------------------------------------------------ end early
test("end early: always refused with PAYMENTS_UNAVAILABLE; the challenge stays active", async () => {
  const me = await newInstall();
  const c = (await create(me, { amountRupees: 500 })).json.challenge;
  const res = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me, body: {}, headers: { "idempotency-key": key() } });
  assert.equal(res.status, 409);
  assert.equal(res.json.code, "PAYMENTS_UNAVAILABLE");
  assert.equal(res.json.retryable, false);
  assert.equal(res.json.paymentRequired, true);
  assert.equal(res.json.amountRupees, 500);
  const after = (await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge;
  assert.equal(after.status, "active");
  assert.equal(after.payment.status, "not_started");
  assert.equal((await db.query("select count(*)::int n from public.payments")).rows[0].n, 0, "no payment row is ever made");
});

test("end early: needs an idempotency key, and is refused in the final minute", async () => {
  const me = await newInstall();
  const c = (await create(me, { durationMinutes: 1 })).json.challenge;
  const noKey = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me, body: {} });
  assert.equal(noKey.json.code, "IDEMPOTENCY_KEY_REQUIRED");
  const res = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me, body: {}, headers: { "idempotency-key": key() } });
  assert.deepEqual([res.status, res.json.code], [409, "TOO_CLOSE_TO_END"]);
});

test("end early: even a forged 'paid' claim from the client changes nothing", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const res = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me,
    body: { paid: true, paymentStatus: "successful", transactionId: "txn_fake" }, headers: { "idempotency-key": key() } });
  assert.equal(res.json.code, "PAYMENTS_UNAVAILABLE");
  assert.equal((await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge.status, "active");
});

// ------------------------------------------------------------------ emergency
const use = (who, id, over = {}) => call("POST", `/v1/challenges/${id}/emergency`, { who,
  body: { useId: randomUUID(), startedAt: new Date().toISOString(), minutes: 5, ...over } });

test("emergency: recorded with a server timestamp; remaining count goes down", async () => {
  const me = await newInstall();
  const c = (await create(me, { emergencyLimit: 2 })).json.challenge;
  const first = await use(me, c.id, { startedAt: "2026-10-05T00:00:00Z" === c.startTime ? c.startTime : new Date().toISOString() });
  assert.equal(first.status, 201);
  assert.equal(first.json.remaining, 1);
  assert.equal(first.json.challenge.emergencyUsed, 1);
  const row = (await db.query("select received_at, over_limit from public.emergency_uses where challenge_id = $1", [c.id])).rows[0];
  assert.ok(Math.abs(row.received_at.getTime() - Date.now()) < 5000, "receipt time is the server's");
  assert.equal(row.over_limit, false);
});

test("emergency: uses beyond the limit are refused, but kept and flagged", async () => {
  const me = await newInstall();
  const c = (await create(me, { emergencyLimit: 1 })).json.challenge;
  assert.equal((await use(me, c.id)).status, 201);
  const extra = await use(me, c.id);
  assert.deepEqual([extra.status, extra.json.code, extra.json.remaining], [409, "EMERGENCY_LIMIT_EXCEEDED", 0]);
  const rows = (await db.query("select over_limit from public.emergency_uses where challenge_id = $1 order by received_at", [c.id])).rows;
  assert.deepEqual(rows.map((r) => r.over_limit), [false, true]);
  assert.equal((await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge.emergencyUsed, 1);
});

test("emergency: a challenge with no emergency access accepts none", async () => {
  const me = await newInstall();
  const c = (await create(me, { emergencyLimit: 0 })).json.challenge;
  assert.equal((await use(me, c.id)).json.code, "EMERGENCY_LIMIT_EXCEEDED");
});

test("emergency: the same use submitted twice counts once", async () => {
  const me = await newInstall();
  const c = (await create(me, { emergencyLimit: 2 })).json.challenge;
  const body = { useId: randomUUID(), startedAt: new Date().toISOString(), minutes: 5 };
  const first = await call("POST", `/v1/challenges/${c.id}/emergency`, { who: me, body });
  const again = await call("POST", `/v1/challenges/${c.id}/emergency`, { who: me, body });
  assert.deepEqual([first.status, again.status], [201, 200]);
  assert.equal(again.json.remaining, 1);
  assert.equal((await db.query("select count(*)::int n from public.emergency_uses where challenge_id = $1", [c.id])).rows[0].n, 1);
});

test("emergency: validation of length, time and ID", async () => {
  const me = await newInstall();
  const c = (await create(me, { emergencyMinutes: 5 })).json.challenge;
  const cases = {
    "wrong length": { minutes: 30 },
    "length not allowed at all": { minutes: 7 },
    "length as text": { minutes: "5" },
    "far in the future": { startedAt: new Date(Date.now() + 3600e3).toISOString() },
    "before the challenge started": { startedAt: new Date(Date.now() - 3600e3).toISOString() },
    "not a time": { startedAt: "yesterday" },
    "bad use ID": { useId: "not-a-uuid" },
  };
  for (const [name, over] of Object.entries(cases)) {
    assert.equal((await use(me, c.id, over)).status, 422, name);
  }
  assert.equal((await db.query("select count(*)::int n from public.emergency_uses where challenge_id = $1", [c.id])).rows[0].n, 0);
});

test("emergency: one installation cannot spend another challenge's use ID", async () => {
  const a = await newInstall(), b = await newInstall();
  const ca = (await create(a)).json.challenge, cb = (await create(b)).json.challenge;
  const body = { useId: randomUUID(), startedAt: new Date().toISOString(), minutes: 5 };
  assert.equal((await call("POST", `/v1/challenges/${ca.id}/emergency`, { who: a, body })).status, 201);
  const reuse = await call("POST", `/v1/challenges/${cb.id}/emergency`, { who: b, body });
  assert.equal(reuse.status, 404);
  assert.equal((await call("GET", `/v1/challenges/${cb.id}`, { who: b })).json.challenge.emergencyUsed, 0);
});

// --------------------------------------------------------------------- events
const event = (type, over = {}) => ({ id: randomUUID(), type, deviceTime: new Date().toISOString(), ...over });

test("events: stored once, counted as interruptions, and never change status", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const events = [event("protection_lost"), event("protection_restored"), event("force_stopped"), event("clock_jump")];
  const first = await call("POST", `/v1/challenges/${c.id}/events`, { who: me, body: { events } });
  assert.deepEqual([first.status, first.json.accepted, first.json.duplicates], [200, 4, 0]);
  const again = await call("POST", `/v1/challenges/${c.id}/events`, { who: me, body: { events: [...events, event("accessibility_off")] } });
  assert.deepEqual([again.json.accepted, again.json.duplicates], [1, 4]);
  const after = (await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge;
  assert.equal(after.interruptionCount, 2);
  assert.equal(after.status, "active");
});

test("events: a phone cannot report a status change or an unknown type", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  for (const type of ["completed", "ended_early", "cancelled", "created", "emergency_used", "hacked"]) {
    const res = await call("POST", `/v1/challenges/${c.id}/events`, { who: me, body: { events: [event(type)] } });
    assert.equal(res.status, 422, type);
  }
  for (const body of [{}, { events: [] }, { events: "x" }, { events: [event("force_stopped", { deviceTime: "2099-01-01T00:00:00Z" })] },
    { events: Array.from({ length: 101 }, () => event("force_stopped")) }]) {
    assert.equal((await call("POST", `/v1/challenges/${c.id}/events`, { who: me, body })).status, 422);
  }
  assert.equal((await call("GET", `/v1/challenges/${c.id}`, { who: me })).json.challenge.status, "active");
});

// -------------------------------------------------------------------- history
test("history: finished challenges only, newest first, paged", async () => {
  const me = await newInstall();
  const ids = [];
  for (let i = 0; i < 5; i++) {
    const c = (await create(me)).json.challenge;
    await expire(c.id);
    await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: {} });
    ids.unshift(c.id);
    await db.query("select pg_sleep(0.01)");
  }
  const running = (await create(me)).json.challenge;

  const page1 = await call("GET", "/v1/challenges/history?limit=2", { who: me });
  assert.equal(page1.status, 200);
  assert.deepEqual(page1.json.items.map((c) => c.id), ids.slice(0, 2));
  assert.ok(page1.json.items.every((c) => c.status === "completed"));
  assert.match(page1.json.nextBefore, /Z$/);

  const page2 = await call("GET", `/v1/challenges/history?limit=2&before=${encodeURIComponent(page1.json.nextBefore)}`, { who: me });
  assert.deepEqual(page2.json.items.map((c) => c.id), ids.slice(2, 4));
  const page3 = await call("GET", `/v1/challenges/history?limit=2&before=${encodeURIComponent(page2.json.nextBefore)}`, { who: me });
  assert.deepEqual(page3.json.items.map((c) => c.id), ids.slice(4));
  assert.equal(page3.json.nextBefore, null);

  const all = await call("GET", "/v1/challenges/history", { who: me });
  assert.equal(all.json.items.length, 5);
  assert.ok(!all.json.items.some((c) => c.id === running.id), "the active challenge is not history");
});

test("history: bad paging values are refused", async () => {
  const me = await newInstall();
  for (const q of ["limit=0", "limit=51", "limit=abc", "limit=-1", "before=yesterday", "offset=5", "limit=1;drop"]) {
    assert.equal((await call("GET", `/v1/challenges/history?${q}`, { who: me })).status, 422, q);
  }
});

// ------------------------------------------------------- reinstall and clocks
test("reinstall: after recovery the new credential sees the same active challenge", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const fresh = randomBytes(32).toString("base64url");
  const rec = await call("POST", "/v1/installations/recover", { body: { credential: fresh, recoveryMaterial: me.recoveryMaterial, appVersion: "2.8.0" } });
  assert.deepEqual([rec.status, rec.json.installationId, rec.json.hasActiveChallenge], [200, me.id, true]);
  const restored = await call("GET", "/v1/challenges/active", { who: { id: me.id, credential: fresh } });
  assert.deepEqual(restored.json.challenge, c, "same challenge, same end time");
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).status, 401, "the old credential is dead");
});

test("clock: the phone's time never moves a challenge's start, end or completion", async () => {
  const me = await newInstall();
  const made = await call("POST", "/v1/challenges", { who: me, body: valid(),
    headers: { "idempotency-key": key(), date: "Mon, 01 Jan 2035 00:00:00 GMT", "x-client-time": "2035-01-01T00:00:00Z" } });
  const c = made.json.challenge;
  assert.ok(Math.abs(Date.parse(c.startTime) - Date.now()) < 5000);
  // An emergency use claiming a time years ahead is refused.
  assert.equal((await use(me, c.id, { startedAt: "2035-01-01T00:00:00Z" })).status, 422);
  // And "completed on device" claims do not complete it.
  const res = await call("POST", `/v1/challenges/${c.id}/complete`, { who: me, body: { completedAt: "2035-01-01T00:00:00Z" } });
  assert.equal(res.json.code, "TOO_EARLY");
});

test("every answer carries the server time, including errors", async () => {
  const me = await newInstall();
  const ok = await call("GET", "/v1/challenges/active", { who: me });
  const err = await call("GET", `/v1/challenges/${randomUUID()}`, { who: me });
  for (const r of [ok, err]) {
    assert.match(r.json.serverTime, ISO);
    assert.ok(Math.abs(r.json.epochMs - Date.now()) < 5000);
  }
});

test("wrong methods answer 405, unknown challenge paths 404", async () => {
  const me = await newInstall();
  const id = randomUUID();
  assert.equal((await call("DELETE", `/v1/challenges/${id}`, { who: me })).status, 405);
  assert.equal((await call("PUT", "/v1/challenges", { who: me, body: {} })).status, 405);
  assert.equal((await call("GET", `/v1/challenges/${id}/complete`, { who: me })).status, 405);
  assert.equal((await call("POST", `/v1/challenges/${id}/cancel`, { who: me, body: {} })).status, 404);
});

test("the app roles cannot call any challenge function directly", async () => {
  const fns = (await db.query(`select p.oid::regprocedure::text sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'public' and p.proname like 'api\\_%'`)).rows;
  assert.ok(fns.length >= 18);
  for (const role of ["anon", "authenticated"]) {
    const r = await db.query(`select count(*)::int n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname like 'api\\_%' and has_function_privilege($1, p.oid, 'execute')`, [role]);
    assert.equal(r.rows[0].n, 0, role);
  }
});
