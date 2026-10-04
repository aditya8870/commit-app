// Phase 1 tests for GET /v1/time.
// Run from the backend folder:  node --test tests/time.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../supabase/functions/api/index.ts";

const get = (path, init = {}) =>
  handle(new Request(`https://example.test${path}`, init));
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

test("GET /v1/time responds successfully with JSON", async () => {
  const res = await get("/v1/time");
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  assert.equal(res.headers.get("cache-control"), "no-store");
});

test("works behind the Supabase function prefix", async () => {
  assert.equal((await get("/api/v1/time")).status, 200);
  assert.equal((await get("/functions/v1/api/v1/time/")).status, 200);
});

test("serverTime is a valid ISO-8601 timestamp in UTC", async () => {
  const body = await (await get("/v1/time")).json();
  assert.match(body.serverTime, ISO_UTC);
  assert.equal(new Date(body.serverTime).toISOString(), body.serverTime);
  assert.equal(new Date(body.serverTime).getTime(), body.epochMs);
});

test("serverTime is the server's current time", async () => {
  const before = Date.now();
  const body = await (await get("/v1/time")).json();
  const after = Date.now();
  assert.ok(body.epochMs >= before && body.epochMs <= after);
});

test("the answer comes only from the server clock", async () => {
  const fixed = new Date("2026-10-04T09:30:00.000Z");
  const body = await (await handle(new Request("https://example.test/v1/time"), { now: () => fixed })).json();
  assert.equal(body.serverTime, "2026-10-04T09:30:00.000Z");
});

test("nothing the phone sends can change the time", async () => {
  const fixed = new Date("2026-10-04T09:30:00.000Z");
  const req = new Request(
    "https://example.test/v1/time?time=1999-01-01T00:00:00Z&now=0&epochMs=1",
    {
      headers: {
        date: "Fri, 01 Jan 1999 00:00:00 GMT",
        "x-client-time": "1999-01-01T00:00:00Z",
        "x-device-time": "915148800000",
      },
    },
  );
  const body = await (await handle(req, { now: () => fixed })).json();
  assert.equal(body.serverTime, "2026-10-04T09:30:00.000Z");
  assert.equal(body.epochMs, fixed.getTime());
});

test("the response is the same regardless of the server's time zone setting", async () => {
  const saved = process.env.TZ;
  process.env.TZ = "Asia/Kolkata";
  const body = await (await get("/v1/time")).json();
  process.env.TZ = saved;
  assert.match(body.serverTime, ISO_UTC);
});

test("only GET is allowed", async () => {
  for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
    const res = await get("/v1/time", { method });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "GET");
    assert.equal((await res.json()).code, "METHOD_NOT_ALLOWED");
  }
});

test("unknown paths answer 404 in the standard error shape", async () => {
  for (const path of ["/", "/v1", "/v1/nothing", "/v1/challenges/x/y/z", "/v2/time", "/v1/timex", "/x/v1/time", "/api/api/v1/time"]) {
    const res = await get(path);
    assert.equal(res.status, 404, path);
    assert.deepEqual(Object.keys(await res.json()).sort(),
      ["code", "epochMs", "message", "retryable", "serverTime"]);
  }
});

test("the function file contains no secrets or keys", async () => {
  const { readFile } = await import("node:fs/promises");
  const src = await readFile(new URL("../supabase/functions/api/index.ts", import.meta.url), "utf8");
  // Environment variable NAMES may appear; values must not.
  assert.doesNotMatch(src, /eyJ[A-Za-z0-9_-]{10,}|sb_secret_|sb_publishable_|postgres(ql)?:\/\//);
  assert.doesNotMatch(src, /(SECRET|KEY)\s*=\s*["'][^"']+["']/);
});
