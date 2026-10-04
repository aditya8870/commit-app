// TEST ONLY. Serves the real Edge Function handler over plain HTTP on this
// machine, backed by a local PostgreSQL, so the Flutter client can be tested
// end to end without touching Supabase.
//   DATABASE_URL=... PORT=8787 node tests/serve_local.mjs
import http from "node:http";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { handle } from "../supabase/functions/api/index.ts";

const db = new pg.Client({ connectionString: process.env.DATABASE_URL });
await db.connect();
await db.query("set role service_role");
const rpc = async (fn, args) => {
  const keys = Object.keys(args);
  return (await db.query(
    `select * from public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(", ")})`,
    // JSON arguments go as JSON text, as the real API gateway sends them.
    keys.map((k) => (args[k] && typeof args[k] === "object" && !k.endsWith("_hashes"))
      ? JSON.stringify(args[k]) : args[k]))).rows;
};
// A throwaway key, made fresh on every start.
const deps = { rpc, recoveryKeys: { current: 1, keys: { 1: randomBytes(32).toString("hex") } } };

http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const headers = { ...req.headers, "x-forwarded-for": req.socket.remoteAddress ?? "" };
  const answer = await handle(new Request(`https://local.test${req.url}`, {
    method: req.method,
    headers,
    body: ["GET", "HEAD"].includes(req.method) ? undefined : Buffer.concat(chunks),
  }), deps);
  res.writeHead(answer.status, Object.fromEntries(answer.headers));
  res.end(await answer.text());
}).listen(Number(process.env.PORT ?? 8787), "127.0.0.1", () => console.log("ready"));
