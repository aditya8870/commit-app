// Checks the DEPLOYED endpoint over HTTPS.
// Usage:  node tests/live_check.mjs https://<project-ref>.supabase.co/functions/v1/api
const base = (process.argv[2] ?? process.env.COMMIT_API_BASE ?? "").replace(/\/+$/, "");
if (!base.startsWith("https://")) {
  console.error("Give the HTTPS base address of the API.");
  process.exit(2);
}
const res = await fetch(`${base}/v1/time`);
const body = await res.json();
const ok =
  res.status === 200 &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(body.serverTime ?? "") &&
  Math.abs(body.epochMs - Date.now()) < 5 * 60 * 1000;
console.log(res.status, body);
console.log(ok ? "PASS: /v1/time is live" : "FAIL");
process.exit(ok ? 0 : 1);
