// Phase 6 tests (first Play release): no financial commitment, and how a
// challenge was completed. Run through the real handler against a
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
  durationMinutes: 60, amountRupees: 0, emergencyLimit: 2, emergencyMinutes: 5,
  consentVersion: "2026-10-06.1", consentAccepted: true, ...over,
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

const get = async (who, id) => (await call("GET", `/v1/challenges/${id}`, { who })).json.challenge;
const complete = (who, id) => call("POST", `/v1/challenges/${id}/complete`, { who, body: {} });
const events = (who, id, types) => call("POST", `/v1/challenges/${id}/events`, { who,
  body: { events: types.map((type) => ({ id: randomUUID(), type, deviceTime: new Date().toISOString() })) } });

// ------------------------------------------------------- no money involved
test("a challenge with no financial commitment (amount 0) is created", async () => {
  const me = await newInstall();
  const res = await create(me);
  assert.equal(res.status, 201);
  assert.equal(res.json.challenge.amountRupees, 0);
  assert.equal(res.json.challenge.completion, null);
  assert.deepEqual(res.json.challenge.payment, { status: "not_started", available: false });
});

test("amounts between 1 and 99 are still refused", async () => {
  const me = await newInstall();
  for (const amountRupees of [1, 50, 99, -1, 10001]) {
    const res = await create(me, { amountRupees });
    assert.equal(res.status, 422, `amount ${amountRupees}`);
  }
  assert.equal((await call("GET", "/v1/challenges/active", { who: me })).json.challenge, null);
});

test("the older app's amounts (100 to 10000) are still accepted", async () => {
  const me = await newInstall();
  assert.equal((await create(me, { amountRupees: 100 })).status, 201);
});

test("ending early is still refused and nothing is charged", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  const res = await call("POST", `/v1/challenges/${c.id}/end-early`, { who: me, body: {},
    headers: { "idempotency-key": key() } });
  assert.equal(res.status, 409);
  assert.equal(res.json.code, "PAYMENTS_UNAVAILABLE");
  assert.equal((await get(me, c.id)).status, "active");
  await db.query("reset role");
  assert.equal((await db.query("select count(*)::int n from public.payments")).rows[0].n, 0);
  await db.query("set role service_role");
});

// ------------------------------------------------- how it was completed
test("the phone never comes back: completed, but NOT a clean completion", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  // Something else asks later (for example the phone after a reinstall).
  const seen = await get(me, c.id);
  assert.equal(seen.status, "completed");
  assert.equal(seen.completion, "unconfirmed");
});

test("the phone confirms at the end with nothing interrupted: clean", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  const res = await complete(me, c.id);
  assert.equal(res.status, 200);
  assert.equal(res.json.challenge.completion, "clean");
  assert.equal((await get(me, c.id)).completion, "clean");
});

test("confirming after the server already completed it still counts, once", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  assert.equal((await get(me, c.id)).completion, "unconfirmed");
  await complete(me, c.id);
  await complete(me, c.id);
  assert.equal((await get(me, c.id)).completion, "clean");
  const n = await db.query(
    "select count(*)::int n from public.challenge_events where challenge_id = $1 and type = 'completed_on_device'", [c.id]);
  assert.equal(n.rows[0].n, 1);
});

test("asking too early confirms nothing", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  assert.equal((await complete(me, c.id)).json.code, "TOO_EARLY");
  await expire(c.id);
  assert.equal((await get(me, c.id)).completion, "unconfirmed");
});

for (const type of ["restored_on_device", "clock_jump", "protection_lost", "force_stopped"]) {
  test(`${type} during the challenge: completed, but interrupted`, async () => {
    const me = await newInstall();
    const c = (await create(me)).json.challenge;
    assert.equal((await events(me, c.id, [type])).status, 200);
    await expire(c.id);
    assert.equal((await complete(me, c.id)).json.challenge.completion, "interrupted");
  });
}

test("data cleared, restored, never confirmed: unconfirmed, never clean", async () => {
  const me = await newInstall();
  const c = (await create(me)).json.challenge;
  await events(me, c.id, ["restored_on_device"]);
  await expire(c.id);
  assert.notEqual((await get(me, c.id)).completion, "clean");
});

test("another installation cannot confirm someone else's challenge", async () => {
  const me = await newInstall(), other = await newInstall();
  const c = (await create(me)).json.challenge;
  await expire(c.id);
  assert.equal((await complete(other, c.id)).status, 404);
  assert.equal((await get(me, c.id)).completion, "unconfirmed");
});

test("history shows how each challenge was completed", async () => {
  const me = await newInstall();
  const a = (await create(me)).json.challenge;
  await expire(a.id, 120);
  await complete(me, a.id);
  const b = (await create(me)).json.challenge;
  await expire(b.id);
  const items = (await call("GET", "/v1/challenges/history", { who: me })).json.items;
  assert.deepEqual(items.map((i) => i.completion).sort(), ["clean", "unconfirmed"]);
});
