// Phase 3 tests: installation registration, reinstall recovery, request
// authentication and rate limiting.
//
// These run the real handler against a real local PostgreSQL that has every
// migration applied. Started by tests/run_all.sh, which sets DATABASE_URL.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomBytes, createHash, createHmac } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import pg from "pg";
import { handle, LIMITS } from "../supabase/functions/api/index.ts";

// Test-only server keys, generated fresh on every run.
const K1 = randomBytes(32).toString("hex"), K2 = randomBytes(32).toString("hex");
const SECRET = K1;
const V1 = { current: 1, keys: { 1: K1 } };          // before a rotation
const ROTATING = { current: 2, keys: { 1: K1, 2: K2 } }; // during the window
const V2 = { current: 2, keys: { 2: K2 } };          // after version 1 is retired
let db;

before(async () => {
  db = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await db.connect();
  await db.query("set role service_role"); // the role the real server uses
});
after(async () => { await db.end(); });

// Same contract as the Supabase adapter: named arguments in, rows out.
const rpc = async (fn, args) => {
  assert.match(fn, /^api_[a-z_]+$/);
  const keys = Object.keys(args);
  const sql = `select * from public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(", ")})`;
  return (await db.query(sql, keys.map((k) => args[k]))).rows;
};
const deps = { rpc, recoveryKeys: V1 };
const during = { rpc, recoveryKeys: ROTATING };
const afterRetire = { rpc, recoveryKeys: V2 };

let ipCounter = 0;
const freshIp = () => `10.${(ipCounter >> 8) & 255}.${ipCounter++ & 255}.7`;
const newCredential = () => randomBytes(32).toString("base64url");
const newAndroidId = () => randomBytes(8).toString("hex");
// What the phone sends: a hash of its Android ID, never the ID itself.
const materialFor = (androidId) =>
  createHash("sha256").update(`commit-recovery-v1:${androidId}`).digest("hex");

const call = async (method, path, { body, headers = {}, ip = freshIp(), d = deps } = {}) => {
  const res = await handle(new Request(`https://example.test/functions/v1/api${path}`, {
    method,
    headers: {
      "x-forwarded-for": ip,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    body: body === undefined ? undefined : (typeof body === "string" ? body : JSON.stringify(body)),
  }), d);
  return { status: res.status, headers: res.headers, json: await res.json() };
};
const signed = (id, credential) => ({ authorization: `Bearer ${credential}`, "x-installation-id": id });

const register = async (over = {}, d = deps) => {
  const credential = newCredential(), androidId = newAndroidId();
  const body = { credential, recoveryMaterial: materialFor(androidId), appVersion: "2.6.0", androidVersion: "14", ...over };
  const res = await call("POST", "/v1/installations", { body, d });
  return { res, credential: body.credential, androidId, material: body.recoveryMaterial };
};

// -------------------------------------------------------------- registration
test("valid registration creates an installation with a server-issued ID", async () => {
  const { res } = await register();
  assert.equal(res.status, 201);
  assert.match(res.json.installationId, /^[0-9a-f-]{36}$/);
  assert.match(res.json.serverTime, /Z$/);
  assert.deepEqual(Object.keys(res.json).sort(), ["epochMs", "installationId", "serverTime"]);
});

test("the answer never contains the credential or recovery data", async () => {
  const { res, credential, material } = await register();
  const text = JSON.stringify(res.json);
  assert.ok(!text.includes(credential) && !text.includes(material));
});

test("repeating the same registration returns the same installation, not a new one", async () => {
  const first = await register();
  const again = await call("POST", "/v1/installations", {
    body: { credential: first.credential, recoveryMaterial: first.material, appVersion: "2.6.0" },
  });
  assert.equal(again.status, 200);
  assert.equal(again.json.installationId, first.res.json.installationId);
  const n = await db.query("select count(*)::int n from public.installations where id = $1", [first.res.json.installationId]);
  assert.equal(n.rows[0].n, 1);
});

test("a phone that already has an installation is told to recover; no duplicate is made", async () => {
  const first = await register();
  const before = (await db.query("select count(*)::int n from public.installations")).rows[0].n;
  const second = await call("POST", "/v1/installations", {
    body: { credential: newCredential(), recoveryMaterial: first.material, appVersion: "2.6.0" },
  });
  assert.equal(second.status, 409);
  assert.equal(second.json.code, "RECOVERY_REQUIRED");
  assert.equal(second.json.installationId, undefined);
  const after = (await db.query("select count(*)::int n from public.installations")).rows[0].n;
  assert.equal(after, before);
});

test("registration works without recovery data (phone gave no identifier)", async () => {
  const { res } = await register({ recoveryMaterial: null });
  assert.equal(res.status, 201);
});

test("a client-supplied installation ID is refused", async () => {
  for (const key of ["installationId", "id"]) {
    const { res } = await register({ [key]: "00000000-0000-0000-0000-000000000001" });
    assert.equal(res.status, 422, key);
  }
});

test("invalid credentials are refused", async () => {
  const bad = [undefined, null, 12345, "", "short", "A".repeat(43), newCredential() + "x",
    newCredential().slice(0, 42) + "=", randomBytes(32).toString("hex"), "x".repeat(5000)];
  for (const credential of bad) {
    const { res } = await register({ credential });
    assert.ok([413, 422].includes(res.status), `${String(credential).slice(0, 12)} -> ${res.status}`);
  }
});

test("invalid recovery data is refused, including a raw Android ID", async () => {
  for (const recoveryMaterial of [newAndroidId(), "9774d56d682e549c", "Z".repeat(64), "A".repeat(64), 42, {}]) {
    const { res } = await register({ recoveryMaterial });
    assert.equal(res.status, 422);
    assert.equal(res.json.code, "VALIDATION_FAILED");
  }
});

test("invalid versions, non-JSON and wrong content type are refused", async () => {
  assert.equal((await register({ appVersion: "" })).res.status, 422);
  assert.equal((await register({ appVersion: undefined })).res.status, 422);
  assert.equal((await register({ appVersion: "<script>" })).res.status, 422);
  assert.equal((await register({ androidVersion: "x".repeat(51) })).res.status, 422);
  assert.equal((await call("POST", "/v1/installations", { body: "{not json" })).status, 422);
  assert.equal((await call("POST", "/v1/installations", { body: "[]" })).status, 422);
  const noType = await handle(new Request("https://example.test/v1/installations", {
    method: "POST", headers: { "x-forwarded-for": freshIp() }, body: "{}" }), deps);
  assert.equal(noType.status, 415);
});

test("wrong methods answer 405", async () => {
  assert.equal((await call("GET", "/v1/installations")).status, 405);
  assert.equal((await call("GET", "/v1/installations/recover")).status, 405);
  assert.equal((await call("POST", "/v1/installations/me", { body: {} })).status, 405);
});

// ------------------------------------------------------------- what is stored
test("only hashes are stored: no raw credential, Android ID, recovery data or address", async () => {
  const ip = "203.0.113.77";
  const credential = newCredential(), androidId = newAndroidId(), material = materialFor(androidId);
  const res = await call("POST", "/v1/installations", {
    ip, body: { credential, recoveryMaterial: material, appVersion: "2.6.0", androidVersion: "14" } });
  assert.equal(res.status, 201);

  const row = (await db.query("select * from public.installations where id = $1", [res.json.installationId])).rows[0];
  assert.equal(row.credential_hash, createHash("sha256").update(credential).digest("hex"));
  assert.equal(row.recovery_hash, createHmac("sha256", SECRET).update(`device:${material}`).digest("hex"));
  assert.notEqual(row.recovery_hash, material, "stored value is keyed, not the phone's hash");

  const dump = (await db.query(
    `select coalesce(string_agg(t::text, ' '), '') d from (
       select row_to_json(i) t from public.installations i
       union all select row_to_json(r) from public.rate_limits r) x`)).rows[0].d;
  for (const raw of [credential, androidId, material, ip]) {
    assert.ok(!dump.includes(raw), `database contains a raw value: ${raw.slice(0, 8)}…`);
  }
});

test("without valid server keys nothing is registered", async () => {
  const badKeys = [
    { current: 1, keys: {} },
    { current: 1, keys: { 1: "" } },
    { current: 1, keys: { 1: "too-short" } },
    { current: 2, keys: { 1: K1 } },                // current version has no key
    { current: NaN, keys: { 1: K1 } },
    { current: 2, keys: { 1: K1, 2: K1 } },         // the same key twice
    { current: 1, keys: { 1: K1, 99: K2 } },        // version out of range
  ];
  for (const recoveryKeys of badKeys) {
    const res = await call("POST", "/v1/installations", {
      d: { rpc, recoveryKeys },
      body: { credential: newCredential(), recoveryMaterial: materialFor(newAndroidId()), appVersion: "2.6.0" } });
    assert.equal(res.status, 500);
    assert.equal(res.json.code, "SERVER_MISCONFIGURED");
  }
});

// ------------------------------------------------------------ authentication
test("the credential and ID together authenticate a request", async () => {
  const { res, credential } = await register();
  const me = await call("GET", "/v1/installations/me", { headers: signed(res.json.installationId, credential) });
  assert.equal(me.status, 200);
  assert.equal(me.json.installationId, res.json.installationId);
  assert.equal(me.json.status, "active");
  assert.equal(me.json.recoveryCount, 0);
});

test("missing, malformed or wrong credentials all get the same 401", async () => {
  const a = await register();
  const id = a.res.json.installationId;
  const attempts = [
    {},
    { authorization: `Bearer ${a.credential}` },
    { "x-installation-id": id },
    signed(id, newCredential()),
    signed(id, "nonsense"),
    signed("not-a-uuid", a.credential),
    signed("00000000-0000-4000-8000-000000000000", a.credential),
    { authorization: `Basic ${a.credential}`, "x-installation-id": id },
  ];
  const answers = new Set();
  for (const headers of attempts) {
    const res = await call("GET", "/v1/installations/me", { headers });
    assert.equal(res.status, 401);
    answers.add(`${res.json.code}|${res.json.message}`);
  }
  assert.equal(answers.size, 1, "every failure looks identical");
});

test("the credential is not accepted in the URL", async () => {
  const a = await register();
  const res = await call("GET", `/v1/installations/me?credential=${a.credential}&installationId=${a.res.json.installationId}`);
  assert.equal(res.status, 401);
});

test("cross-installation access is rejected", async () => {
  const a = await register(), b = await register();
  const res = await call("GET", "/v1/installations/me", { headers: signed(b.res.json.installationId, a.credential) });
  assert.equal(res.status, 401);
  const other = await call("GET", "/v1/installations/me", { headers: signed(a.res.json.installationId, b.credential) });
  assert.equal(other.status, 401);
});

test("a suspended installation is refused", async () => {
  const a = await register();
  await db.query("update public.installations set status = 'suspended' where id = $1", [a.res.json.installationId]);
  const res = await call("GET", "/v1/installations/me", { headers: signed(a.res.json.installationId, a.credential) });
  assert.equal(res.status, 403);
  assert.equal(res.json.code, "INSTALLATION_SUSPENDED");
});

// ------------------------------------------------------------------ recovery
const recoverAs = (material, credential, ip, d = deps) => call("POST", "/v1/installations/recover", {
  ip, d, body: { credential, recoveryMaterial: material, appVersion: "2.6.1", androidVersion: "15" } });

test("recovery keeps the installation ID, rotates the credential and counts the recovery", async () => {
  const a = await register();
  const id = a.res.json.installationId;
  const fresh = newCredential();
  const rec = await recoverAs(a.material, fresh);
  assert.equal(rec.status, 200);
  assert.equal(rec.json.installationId, id, "same installation, not a duplicate");
  assert.equal(rec.json.recoveryCount, 1);
  assert.equal(rec.json.hasActiveChallenge, false);

  const row = (await db.query("select * from public.installations where id = $1", [id])).rows[0];
  assert.equal(row.recovery_count, 1);
  assert.ok(row.last_recovered_at instanceof Date);
  assert.equal(row.app_version, "2.6.1");

  const old = await call("GET", "/v1/installations/me", { headers: signed(id, a.credential) });
  assert.equal(old.status, 401, "old credential no longer works");
  const now = await call("GET", "/v1/installations/me", { headers: signed(id, fresh) });
  assert.equal(now.status, 200, "new credential works");
  assert.equal(now.json.recoveryCount, 1);
});

test("recovery preserves the active challenge", async () => {
  const a = await register();
  const id = a.res.json.installationId;
  const ch = (await db.query(
    `insert into public.challenges (installation_id, start_time, end_time, duration_minutes, amount_rupees,
       emergency_limit, emergency_minutes, consent_version, consent_accepted_at, idempotency_key)
     values ($1, now(), now(), 1440, 100, 1, 5, '2026-10-04.1', now(), $2) returning id, end_time`,
    [id, `key-${randomBytes(12).toString("hex")}`])).rows[0];

  const rec = await recoverAs(a.material, newCredential());
  assert.equal(rec.status, 200);
  assert.equal(rec.json.installationId, id);
  assert.equal(rec.json.hasActiveChallenge, true);

  const after = (await db.query("select installation_id, status, end_time from public.challenges where id = $1", [ch.id])).rows[0];
  assert.equal(after.installation_id, id);
  assert.equal(after.status, "active");
  assert.equal(after.end_time.getTime(), ch.end_time.getTime(), "end time unchanged");
});

test("repeating a recovery with the same new credential does not count twice", async () => {
  const a = await register();
  const fresh = newCredential();
  assert.equal((await recoverAs(a.material, fresh)).json.recoveryCount, 1);
  const again = await recoverAs(a.material, fresh);
  assert.equal(again.status, 200);
  assert.equal(again.json.recoveryCount, 1);
});

test("recovery for an unknown phone creates nothing", async () => {
  const before = (await db.query("select count(*)::int n from public.installations")).rows[0].n;
  const res = await recoverAs(materialFor(newAndroidId()), newCredential());
  assert.equal(res.status, 404);
  assert.equal(res.json.code, "RECOVERY_NOT_FOUND");
  assert.equal((await db.query("select count(*)::int n from public.installations")).rows[0].n, before);
});

test("recovery needs valid recovery data", async () => {
  for (const material of [null, undefined, "", newAndroidId(), "g".repeat(64)]) {
    const res = await recoverAs(material, newCredential());
    assert.equal(res.status, 422);
  }
});

test("recovery cannot hand one installation another installation's credential", async () => {
  const a = await register(), b = await register();
  const res = await recoverAs(a.material, b.credential);
  assert.equal(res.status, 409);
  assert.equal(res.json.code, "CREDENTIAL_IN_USE");
  const stillB = await call("GET", "/v1/installations/me", { headers: signed(b.res.json.installationId, b.credential) });
  assert.equal(stillB.status, 200);
});

test("a suspended installation cannot be recovered", async () => {
  const a = await register();
  await db.query("update public.installations set status = 'suspended' where id = $1", [a.res.json.installationId]);
  assert.equal((await recoverAs(a.material, newCredential())).status, 403);
});

test("the recovery answer never exposes the recovery identifier", async () => {
  const a = await register();
  const rec = await recoverAs(a.material, newCredential());
  const text = JSON.stringify(rec.json);
  assert.ok(!text.includes(a.material) && !text.includes(a.androidId));
  assert.deepEqual(Object.keys(rec.json).sort(),
    ["epochMs", "hasActiveChallenge", "installationId", "recoveryCount", "serverTime"]);
});

// ------------------------------------------------------- recovery key rotation
const versionOf = async (id) =>
  (await db.query("select recovery_key_version v, recovery_hash h from public.installations where id = $1", [id])).rows[0];
const keyed = (key, material) => createHmac("sha256", key).update(`device:${material}`).digest("hex");
const refresh = (id, credential, material, d) => call("POST", "/v1/installations/me/recovery", {
  d, headers: signed(id, credential), body: { recoveryMaterial: material } });

test("new installations record the current key version", async () => {
  const a = await register();
  assert.equal((await versionOf(a.res.json.installationId)).v, 1);
  const b = await register({}, during);
  const row = await versionOf(b.res.json.installationId);
  assert.equal(row.v, 2, "during a rotation, new installs use the new key");
  assert.equal(row.h, keyed(K2, b.material));
});

test("rotation: an existing installation still recovers, and is moved to the new key", async () => {
  const a = await register();                      // made under version 1
  const id = a.res.json.installationId;
  const fresh = newCredential();
  const rec = await recoverAs(a.material, fresh, undefined, during);
  assert.equal(rec.status, 200);
  assert.equal(rec.json.installationId, id, "same installation");
  const row = await versionOf(id);
  assert.equal(row.v, 2);
  assert.equal(row.h, keyed(K2, a.material));
  // Version 1 can now be retired without breaking this installation.
  const later = await recoverAs(a.material, newCredential(), undefined, afterRetire);
  assert.equal(later.status, 200);
  assert.equal(later.json.installationId, id);
});

test("rotation: a known phone is still recognised at registration (no duplicate)", async () => {
  const a = await register();                      // version 1
  const again = await call("POST", "/v1/installations", { d: during,
    body: { credential: newCredential(), recoveryMaterial: a.material, appVersion: "2.6.0" } });
  assert.equal(again.status, 409);
  assert.equal(again.json.code, "RECOVERY_REQUIRED");
});

test("rotation: credentials keep working; rotation never signs anyone out", async () => {
  const a = await register();
  for (const d of [deps, during, afterRetire]) {
    const me = await call("GET", "/v1/installations/me", { d, headers: signed(a.res.json.installationId, a.credential) });
    assert.equal(me.status, 200);
  }
});

test("rotation: the app is told when its device hash needs moving, and can move it", async () => {
  const a = await register();
  const id = a.res.json.installationId;
  const before = await call("GET", "/v1/installations/me", { d: during, headers: signed(id, a.credential) });
  assert.equal(before.json.recoveryUpToDate, false);

  const moved = await refresh(id, a.credential, a.material, during);
  assert.equal(moved.status, 200);
  assert.deepEqual([moved.json.recoveryUpToDate, moved.json.changed], [true, true]);
  assert.equal((await versionOf(id)).v, 2);

  const again = await refresh(id, a.credential, a.material, during);
  assert.deepEqual([again.status, again.json.changed], [200, false]);
  const after = await call("GET", "/v1/installations/me", { d: during, headers: signed(id, a.credential) });
  assert.equal(after.json.recoveryUpToDate, true);

  // After version 1 is retired, recovery still works for this installation.
  const rec = await recoverAs(a.material, newCredential(), undefined, afterRetire);
  assert.equal(rec.status, 200);
  assert.equal(rec.json.installationId, id);
});

test("rotation: moving the device hash needs the same device", async () => {
  const a = await register();
  const id = a.res.json.installationId;
  const wrong = await refresh(id, a.credential, materialFor(newAndroidId()), during);
  assert.equal(wrong.status, 409);
  assert.equal(wrong.json.code, "RECOVERY_NOT_UPDATED");
  const row = await versionOf(id);
  assert.equal(row.v, 1);
  assert.equal(row.h, keyed(K1, a.material), "nothing changed");
});

test("rotation: one installation cannot claim another phone's device hash", async () => {
  const victim = await register();                         // version 1, not yet moved
  const attacker = await register({ recoveryMaterial: null });
  const res = await refresh(attacker.res.json.installationId, attacker.credential, victim.material, during);
  assert.equal(res.status, 409);
  assert.equal((await versionOf(attacker.res.json.installationId)).h, null);
  // The victim can still recover and is still the owner of that device.
  const rec = await recoverAs(victim.material, newCredential(), undefined, during);
  assert.equal(rec.json.installationId, victim.res.json.installationId);
});

test("rotation: moving the device hash needs a valid credential", async () => {
  const a = await register();
  const res = await refresh(a.res.json.installationId, newCredential(), a.material, during);
  assert.equal(res.status, 401);
  assert.equal((await versionOf(a.res.json.installationId)).v, 1);
});

test("rotation: an installation that had no device hash can store one", async () => {
  const a = await register({ recoveryMaterial: null });
  const material = materialFor(newAndroidId());
  const res = await refresh(a.res.json.installationId, a.credential, material, deps);
  assert.deepEqual([res.status, res.json.changed], [200, true]);
  assert.equal((await versionOf(a.res.json.installationId)).h, keyed(K1, material));
});

test("rotation: only an installation that was never moved loses recovery when the old key is retired", async () => {
  const stale = await register();                  // version 1, never opened during the window
  const rec = await recoverAs(stale.material, newCredential(), undefined, afterRetire);
  assert.equal(rec.status, 404, "documented limit of retiring a key");
  // Its credential still works; only reinstall recovery is lost.
  const me = await call("GET", "/v1/installations/me", { d: afterRetire, headers: signed(stale.res.json.installationId, stale.credential) });
  assert.equal(me.status, 200);
  assert.equal(me.json.recoveryUpToDate, false);
  // And a retired key cannot be used to move it afterwards.
  const res = await refresh(stale.res.json.installationId, stale.credential, stale.material, afterRetire);
  assert.equal(res.status, 409);
});

test("rotation: the database refuses a hash without a version, or a version without a hash", async () => {
  await assert.rejects(db.query(
    "insert into public.installations (credential_hash, recovery_hash, app_version) values (repeat('7',64), repeat('8',64), '1')"),
    /installations_recovery_version_matches/);
  await assert.rejects(db.query(
    "insert into public.installations (credential_hash, recovery_key_version, app_version) values (repeat('7',64), 1, '1')"),
    /installations_recovery_version_matches/);
});

// ------------------------------------------------------- network address source
test("the address comes from the LAST X-Forwarded-For entry, never the first", async () => {
  const { clientAddress } = await import("../supabase/functions/api/index.ts");
  const at = (h) => clientAddress(new Request("https://example.test/", { headers: h }));
  assert.equal(at({ "x-forwarded-for": "203.0.113.5" }), "203.0.113.5");
  assert.equal(at({ "x-forwarded-for": "1.2.3.4, 9.9.9.9, 203.0.113.5" }), "203.0.113.5");
  assert.equal(at({ "x-forwarded-for": "2001:DB8::1" }), "2001:db8::1");
  assert.equal(at({}), "unknown");
  assert.equal(at({ "x-forwarded-for": "" }), "unknown");
  assert.equal(at({ "x-forwarded-for": "1.2.3.4, <script>" }), "unknown");
  // Headers a caller could send are ignored.
  assert.equal(at({ "x-real-ip": "1.2.3.4", "cf-connecting-ip": "1.2.3.4", forwarded: "for=1.2.3.4" }), "unknown");
});

test("a forged first X-Forwarded-For entry does not escape the per-address limit", async () => {
  const real = "198.51.100.40";
  const [max] = LIMITS.register_ip;
  let last;
  for (let i = 0; i <= max; i++) {
    last = await call("POST", "/v1/installations", { ip: `10.99.${i}.1, ${real}`,
      body: { credential: newCredential(), recoveryMaterial: materialFor(newAndroidId()), appVersion: "2.6.0" } });
    if (i < max) assert.equal(last.status, 201);
  }
  assert.equal(last.status, 429, "rotating the forged entry did not help");
});

test("callers without a usable address share one strict bucket", async () => {
  const d = { ...deps, limits: { register_ip: [2, 3600] } };
  const post = (headers) => handle(new Request("https://example.test/v1/installations", {
    method: "POST", headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ credential: newCredential(), recoveryMaterial: materialFor(newAndroidId()), appVersion: "2.6.0" }) }), d);
  // The shared bucket may already hold counts from other tests; drain it.
  let status;
  for (let i = 0; i < 4; i++) status = (await post({ "x-real-ip": `10.1.1.${i}` })).status;
  assert.equal(status, 429);
  assert.equal((await post({ "x-forwarded-for": "garbage" })).status, 429, "same bucket");
});

test("a global cap holds even if every request claims a different address", async () => {
  await db.query("delete from public.rate_limits where bucket in ('register_global', 'recover_global')");
  const d = { ...deps, limits: { register_global: [3, 3600], recover_global: [2, 3600] } };
  const statuses = [];
  for (let i = 0; i < 5; i++) {
    statuses.push((await register({}, d)).res.status);   // each call uses a new address
  }
  assert.deepEqual(statuses, [201, 201, 201, 429, 429]);
  const rec = [];
  for (let i = 0; i < 4; i++) rec.push((await recoverAs(materialFor(newAndroidId()), newCredential(), undefined, d)).status);
  assert.deepEqual(rec, [404, 404, 429, 429]);
  await db.query("delete from public.rate_limits where bucket in ('register_global', 'recover_global')");
});

// -------------------------------------------------------------- rate limiting
test("registration is limited per network address", async () => {
  const ip = "198.51.100.10";
  const [max] = LIMITS.register_ip;
  for (let i = 0; i < max; i++) {
    const res = await call("POST", "/v1/installations", { ip,
      body: { credential: newCredential(), recoveryMaterial: materialFor(newAndroidId()), appVersion: "2.6.0" } });
    assert.equal(res.status, 201, `attempt ${i + 1}`);
  }
  const blocked = await call("POST", "/v1/installations", { ip,
    body: { credential: newCredential(), recoveryMaterial: materialFor(newAndroidId()), appVersion: "2.6.0" } });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.json.code, "RATE_LIMITED");
  assert.equal(blocked.json.retryable, true);
  assert.ok(Number(blocked.headers.get("retry-after")) >= 1);
  const elsewhere = await register();
  assert.equal(elsewhere.res.status, 201, "another address is unaffected");
});

test("recovery is limited per network address", async () => {
  const ip = "198.51.100.20";
  const [max] = LIMITS.recover_ip;
  for (let i = 0; i < max; i++) {
    assert.equal((await recoverAs(materialFor(newAndroidId()), newCredential(), ip)).status, 404);
  }
  assert.equal((await recoverAs(materialFor(newAndroidId()), newCredential(), ip)).status, 429);
});

test("recovery is limited per phone, even from many addresses", async () => {
  const a = await register();
  const [max] = LIMITS.recover_device;
  for (let i = 0; i < max; i++) {
    assert.equal((await recoverAs(a.material, newCredential())).status, 200, `recovery ${i + 1}`);
  }
  const blocked = await recoverAs(a.material, newCredential());
  assert.equal(blocked.status, 429);
  const row = (await db.query("select recovery_count from public.installations where id = $1", [a.res.json.installationId])).rows[0];
  assert.equal(row.recovery_count, max, "the blocked attempt changed nothing");
});

test("failed sign-ins are limited per network address", async () => {
  const ip = "198.51.100.30";
  const a = await register();
  const [max] = LIMITS.auth_fail_ip;
  for (let i = 0; i < max; i++) {
    const res = await call("GET", "/v1/installations/me", { ip, headers: signed(a.res.json.installationId, newCredential()) });
    assert.equal(res.status, 401);
  }
  const blocked = await call("GET", "/v1/installations/me", { ip, headers: signed(a.res.json.installationId, newCredential()) });
  assert.equal(blocked.status, 429);
});

test("signed requests are limited per installation", async () => {
  const a = await register();
  const [max] = LIMITS.request_installation;
  // Stay inside one 60-second window.
  const msLeft = 60000 - (Date.now() % 60000);
  if (msLeft < 20000) await new Promise((r) => setTimeout(r, msLeft + 500));
  let last;
  for (let i = 0; i <= max; i++) {
    last = await call("GET", "/v1/installations/me", { headers: signed(a.res.json.installationId, a.credential) });
    if (i < max) assert.equal(last.status, 200, `request ${i + 1}`);
  }
  assert.equal(last.status, 429);
  const b = await register();
  const other = await call("GET", "/v1/installations/me", { headers: signed(b.res.json.installationId, b.credential) });
  assert.equal(other.status, 200, "another installation is unaffected");
});

test("old rate-limit counters can be cleaned up", async () => {
  await db.query(`insert into public.rate_limits values ('register_ip', repeat('0', 64), now() - interval '2 days', 3)`);
  const [row] = (await db.query("select public.api_rate_limit_cleanup() n")).rows;
  assert.ok(row.n >= 1);
});

// ------------------------------------------------------- database permissions
test("the app roles cannot call the server functions or touch rate limits", async () => {
  for (const role of ["anon", "authenticated"]) {
    await db.query("reset role");
    await db.query(`set role ${role}`);
    for (const sql of [
      "select * from public.api_register_installation(repeat('a',64), null, null, '{}', '1', null)",
      "select * from public.api_recover_installation(repeat('a',64), repeat('b',64), 1, '{}', '1', null)",
      "select * from public.api_refresh_recovery(gen_random_uuid(), repeat('b',64), 1, '{}')",
      "select * from public.api_authenticate(gen_random_uuid(), repeat('a',64))",
      "select * from public.api_rate_limit('register_ip', repeat('a',64), 1, 60)",
      "select public.api_rate_limit_cleanup()",
      "select * from public.rate_limits",
      "select * from public.installations",
    ]) {
      await assert.rejects(db.query(sql), /permission denied/, `${role}: ${sql.slice(0, 50)}`);
    }
  }
  await db.query("reset role");
  await db.query("set role service_role");
});

// --------------------------------------------------------------------- source
test("no secrets are committed to the source", async () => {
  const root = new URL("../", import.meta.url);
  const files = [];
  const walk = async (dir) => {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      if (["node_modules", ".temp"].includes(e.name)) continue;
      const u = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
      if (e.isDirectory()) await walk(u); else files.push(u);
    }
  };
  await walk(root);
  assert.ok(files.length >= 8);
  for (const f of files) {
    const text = await readFile(f, "utf8");
    const name = f.pathname.split("/backend/")[1];
    assert.doesNotMatch(text, /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, `${name}: looks like a key`);
    assert.doesNotMatch(text, /sb_secret_[A-Za-z0-9]|sb_publishable_[A-Za-z0-9]/, `${name}: Supabase key`);
    assert.doesNotMatch(text, /postgres(ql)?:\/\/[^\s:]+:[^\s@$]+@/, `${name}: database password`);
    assert.doesNotMatch(text, /^\s*COMMIT_RECOVERY_SECRET(_V\d+)?\s*=\s*[^\s<#]/m, `${name}: recovery secret value`);
    assert.doesNotMatch(text, /^\s*SUPABASE_SERVICE_ROLE_KEY\s*=\s*[^\s<#]/m, `${name}: service key value`);
  }
});
