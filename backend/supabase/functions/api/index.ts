// Commit backend – Supabase Edge Function "api".
//
// Routes
//   GET  /v1/time                    public   server time
//   POST /v1/installations           public   register this install
//   POST /v1/installations/recover   public   reinstall recovery
//   GET  /v1/installations/me        signed   proves the credential works
//   POST /v1/installations/me/recovery  signed  moves the device hash to the
//                                               current recovery key version
//
// Challenges (all signed; a challenge of another installation is "not found")
//   POST /v1/challenges                         create (Idempotency-Key required)
//   GET  /v1/challenges/active                  the active challenge, or null
//   GET  /v1/challenges/history                 finished challenges, paged
//   GET  /v1/challenges/registrations/{key}     what a create request produced
//   GET  /v1/challenges/{id}                    one challenge
//   POST /v1/challenges/{id}/complete           only once the end time has passed
//   POST /v1/challenges/{id}/emergency          record an emergency use
//   POST /v1/challenges/{id}/events             record what the phone observed
//   POST /v1/challenges/{id}/end-early          needs a payment; none exists yet
//
// The database clock decides start, end and completion. The phone never does.
//
// There are no accounts. An install is identified by a server-issued ID and
// a secret credential that only the phone knows. The server stores hashes
// only. Nothing here handles payments: ending early always answers
// PAYMENTS_UNAVAILABLE.
//
// This file contains no secrets. Secrets are read from the server's
// environment at run time and are never logged or returned.

// Present on Supabase (Deno); absent when the tests run under Node.
declare const Deno: any;

export const API_VERSION = "v1";

/// Calls a database function and returns its rows.
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<any[]>;

export interface Deps {
  /// The server clock. Tests pass their own.
  now?: () => Date;
  /// Database access. On Supabase this uses the server-only service role.
  rpc?: Rpc;
  /// Server-only recovery keys, by version. Tests pass their own.
  recoveryKeys?: RecoveryKeys;
  /// Overrides for the limits below (tests only).
  limits?: Partial<Record<keyof typeof LIMITS, readonly [number, number]>>;
}

/// The recovery keys the server currently accepts. New hashes are made with
/// `current`; every other listed version is still accepted until retired.
export interface RecoveryKeys {
  current: number;
  keys: Record<number, string>;
}

// Limits: [attempts, window in seconds].
//
// The per-address limits are a convenience, not a security boundary: an
// address can be shared or changed. The limits that hold regardless of what
// a caller sends are the *_global caps, recover_device and
// request_installation.
export const LIMITS = {
  register_ip: [10, 3600],
  register_global: [500, 3600],
  recover_ip: [10, 3600],
  recover_global: [500, 3600],
  recover_device: [5, 86400],
  auth_fail_ip: [20, 600],
  request_installation: [120, 60],
} as const;

// Large enough for 50 apps or 100 events, small enough to be cheap to refuse.
const MAX_BODY_BYTES = 32 * 1024;
// 32 random bytes as URL-safe base64 without padding: exactly 43 characters.
const CREDENTIAL = /^[A-Za-z0-9_-]{43}$/;
// SHA-256 of the Android per-app identifier, computed on the phone.
const RECOVERY_MATERIAL = /^[0-9a-f]{64}$/;
const VERSION = /^[0-9A-Za-z.+_ -]{1,50}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const BASE_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

class ApiError extends Error {
  status: number;
  code: string;
  retryable: boolean;
  headers: Record<string, string>;
  /// Extra, non-sensitive fields added to the error body.
  extra: Record<string, unknown>;
  constructor(status: number, code: string, message: string, retryable = false,
    headers: Record<string, string> = {}, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryable = retryable;
    this.headers = headers;
    this.extra = extra;
  }
}

const enc = new TextEncoder();
const hex = (buf: ArrayBuffer) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}

export async function hmacHex(secret: string, text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}

/// Database access on Supabase, through the server-only service role.
function supabaseRpc(): Rpc {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new ApiError(500, "SERVER_MISCONFIGURED", "Server is not configured.");
  return async (fn, args) => {
    const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: key,
        authorization: `Bearer ${key}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(args),
    });
    if (!res.ok) throw new Error(`database call failed (${res.status})`);
    const rows = await res.json();
    return Array.isArray(rows) ? rows : [rows];
  };
}

interface Ctx {
  req: Request;
  now: () => Date;
  rpc: Rpc;
  keys: RecoveryKeys;
  limits: Deps["limits"];
}

const MAX_KEY_VERSION = 50;

/// Reads the recovery keys from the server's secret store:
///   COMMIT_RECOVERY_SECRET_V1, COMMIT_RECOVERY_SECRET_V2, ...
///   COMMIT_RECOVERY_CURRENT_VERSION   which one new hashes use
function envRecoveryKeys(): RecoveryKeys | undefined {
  if (typeof Deno === "undefined") return undefined;
  const keys: Record<number, string> = {};
  for (let v = 1; v <= MAX_KEY_VERSION; v++) {
    const value = Deno.env.get(`COMMIT_RECOVERY_SECRET_V${v}`);
    if (value) keys[v] = value;
  }
  return { current: Number(Deno.env.get("COMMIT_RECOVERY_CURRENT_VERSION")), keys };
}

function context(req: Request, deps: Deps): Ctx {
  const keys = deps.recoveryKeys ?? envRecoveryKeys();
  const misconfigured = new ApiError(500, "SERVER_MISCONFIGURED", "Server is not configured.");
  // No fallback: without valid keys nothing is registered or recovered.
  if (!keys || !Number.isInteger(keys.current)) throw misconfigured;
  const versions = Object.keys(keys.keys).map(Number);
  const values = versions.map((v) => keys.keys[v]);
  if (!keys.keys[keys.current] ||
      versions.some((v) => !Number.isInteger(v) || v < 1 || v > MAX_KEY_VERSION) ||
      values.some((k) => typeof k !== "string" || k.length < 32) ||
      new Set(values).size !== values.length) {
    throw misconfigured;
  }
  return {
    req,
    now: deps.now ?? (() => new Date()),
    rpc: deps.rpc ?? supabaseRpc(),
    keys,
    limits: deps.limits,
  };
}

/// The caller's network address, for the per-address limits only.
///
/// Source: the LAST entry of X-Forwarded-For. Each proxy appends the address
/// it received the request from, so the last entry is written by the proxy
/// nearest the server, not by the caller. The FIRST entry is whatever the
/// caller typed and is never used. No other header (X-Real-IP,
/// CF-Connecting-IP, Forwarded) is read, because a caller could send those.
///
/// If the header is missing, or the last entry is not an address, every such
/// caller shares one bucket ("unknown"): the limit gets stricter, never looser.
export function clientAddress(req: Request): string {
  const last = (req.headers.get("x-forwarded-for") ?? "").split(",").pop()!.trim();
  return /^[0-9a-fA-F:.]{3,45}$/.test(last) ? last.toLowerCase() : "unknown";
}

/// Hashed so the raw address is never stored.
async function ipSubject(c: Ctx): Promise<string> {
  return hmacHex(c.keys.keys[c.keys.current], `ip:${clientAddress(c.req)}`);
}

const GLOBAL_SUBJECT = "0".repeat(64);

/// The device hash under every active key version, current first.
async function deviceHashes(c: Ctx, material: string):
  Promise<{ current: string; all: string[] }> {
  const current = await hmacHex(c.keys.keys[c.keys.current], `device:${material}`);
  const all = [current];
  for (const v of Object.keys(c.keys.keys).map(Number)) {
    if (v !== c.keys.current) all.push(await hmacHex(c.keys.keys[v], `device:${material}`));
  }
  return { current, all };
}

async function limit(c: Ctx, bucket: keyof typeof LIMITS, subject: string): Promise<void> {
  const [max, windowSeconds] = c.limits?.[bucket] ?? LIMITS[bucket];
  const [row] = await c.rpc("api_rate_limit", {
    p_bucket: bucket,
    p_subject: subject,
    p_limit: max,
    p_window_seconds: windowSeconds,
  });
  if (!row?.allowed) {
    const wait = Math.max(1, Math.ceil(
      (new Date(row?.resets_at ?? c.now()).getTime() - c.now().getTime()) / 1000));
    throw new ApiError(429, "RATE_LIMITED", "Too many requests. Try again later.", true,
      { "retry-after": String(wait) });
  }
}

async function readJson(req: Request): Promise<Record<string, unknown>> {
  const type = req.headers.get("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) {
    throw new ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Send JSON.");
  }
  const text = await req.text();
  if (enc.encode(text).length > MAX_BODY_BYTES) {
    throw new ApiError(413, "PAYLOAD_TOO_LARGE", "Request is too large.");
  }
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new ApiError(422, "VALIDATION_FAILED", "Request is not valid JSON.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ApiError(422, "VALIDATION_FAILED", "Request must be a JSON object.");
  }
  return body as Record<string, unknown>;
}

const invalid = (what: string) => new ApiError(422, "VALIDATION_FAILED", `Invalid ${what}.`);

interface InstallationInput {
  credentialHash: string;
  recoveryHash: string | null;
  knownHashes: string[];
  appVersion: string;
  androidVersion: string | null;
}

async function installationInput(
  c: Ctx, body: Record<string, unknown>, recoveryRequired: boolean,
): Promise<InstallationInput> {
  // The server issues the ID. A request that tries to choose one is refused.
  if ("installationId" in body || "id" in body) throw invalid("field: installationId");

  const credential = body.credential;
  if (typeof credential !== "string" || !CREDENTIAL.test(credential) ||
      new Set(credential).size < 10) {
    throw invalid("credential");
  }
  const material = body.recoveryMaterial ?? null;
  if (material === null) {
    if (recoveryRequired) throw invalid("recoveryMaterial");
  } else if (typeof material !== "string" || !RECOVERY_MATERIAL.test(material)) {
    throw invalid("recoveryMaterial");
  }
  const appVersion = body.appVersion;
  if (typeof appVersion !== "string" || !VERSION.test(appVersion)) throw invalid("appVersion");
  const androidVersion = body.androidVersion ?? null;
  if (androidVersion !== null &&
      (typeof androidVersion !== "string" || !VERSION.test(androidVersion))) {
    throw invalid("androidVersion");
  }
  const hashes = material === null ? null : await deviceHashes(c, material as string);
  return {
    credentialHash: await sha256Hex(credential),
    recoveryHash: hashes?.current ?? null,
    knownHashes: hashes?.all ?? [],
    appVersion,
    androidVersion: androidVersion as string | null,
  };
}

async function register(c: Ctx): Promise<[number, Record<string, unknown>]> {
  await limit(c, "register_ip", await ipSubject(c));
  await limit(c, "register_global", GLOBAL_SUBJECT);
  const input = await installationInput(c, await readJson(c.req), false);
  const [row] = await c.rpc("api_register_installation", {
    p_credential_hash: input.credentialHash,
    p_recovery_hash: input.recoveryHash,
    p_recovery_key_version: input.recoveryHash === null ? null : c.keys.current,
    p_known_hashes: input.knownHashes,
    p_app_version: input.appVersion,
    p_android_version: input.androidVersion,
  });
  switch (row?.outcome) {
    case "created":
      return [201, { installationId: row.installation_id }];
    case "existing":
      return [200, { installationId: row.installation_id }];
    case "recovery_required":
      throw new ApiError(409, "RECOVERY_REQUIRED",
        "This phone already has an installation. Use recovery.");
    default:
      throw new Error("unexpected registration outcome");
  }
}

async function recover(c: Ctx): Promise<[number, Record<string, unknown>]> {
  await limit(c, "recover_ip", await ipSubject(c));
  await limit(c, "recover_global", GLOBAL_SUBJECT);
  const input = await installationInput(c, await readJson(c.req), true);
  // Keyed by the device itself, so it holds whatever address the caller uses.
  await limit(c, "recover_device", input.recoveryHash!);
  const [row] = await c.rpc("api_recover_installation", {
    p_new_credential_hash: input.credentialHash,
    p_recovery_hash: input.recoveryHash,
    p_recovery_key_version: c.keys.current,
    p_known_hashes: input.knownHashes,
    p_app_version: input.appVersion,
    p_android_version: input.androidVersion,
  });
  switch (row?.outcome) {
    case "recovered":
    case "unchanged":
      return [200, {
        installationId: row.installation_id,
        recoveryCount: row.recovery_count,
        hasActiveChallenge: row.has_active_challenge,
      }];
    case "not_found":
      throw new ApiError(404, "RECOVERY_NOT_FOUND", "No installation to recover.");
    case "suspended":
      throw new ApiError(403, "INSTALLATION_SUSPENDED", "This installation is suspended.");
    case "conflict":
      throw new ApiError(409, "CREDENTIAL_IN_USE", "Generate a new credential and try again.");
    default:
      throw new Error("unexpected recovery outcome");
  }
}

export interface Installation {
  id: string;
  status: string;
  recoveryCount: number;
  recoveryKeyVersion: number | null;
  createdAt: string;
}

/// Identifies the caller of a signed request, or throws 401.
///
///   Authorization: Bearer <credential>
///   X-Installation-Id: <installation ID>
///
/// Both must match the same installation. Every failure gives the same
/// answer, so nothing reveals whether an ID exists.
export async function authenticate(c: Ctx): Promise<Installation> {
  const denied = new ApiError(401, "UNAUTHENTICATED", "Not authorised.");
  const header = c.req.headers.get("authorization") ?? "";
  const credential = header.startsWith("Bearer ") ? header.slice(7) : "";
  const id = (c.req.headers.get("x-installation-id") ?? "").toLowerCase();

  let row: any;
  if (CREDENTIAL.test(credential) && UUID.test(id)) {
    [row] = await c.rpc("api_authenticate", {
      p_installation_id: id,
      p_credential_hash: await sha256Hex(credential),
    });
  }
  if (!row) {
    await limit(c, "auth_fail_ip", await ipSubject(c));
    throw denied;
  }
  if (row.status !== "active") {
    throw new ApiError(403, "INSTALLATION_SUSPENDED", "This installation is suspended.");
  }
  await limit(c, "request_installation", await sha256Hex(`installation:${row.installation_id}`));
  return {
    id: row.installation_id,
    status: row.status,
    recoveryCount: row.recovery_count,
    recoveryKeyVersion: row.recovery_key_version ?? null,
    createdAt: new Date(row.created_at).toISOString(),
  };
}

async function me(c: Ctx): Promise<[number, Record<string, unknown>]> {
  const i = await authenticate(c);
  return [200, {
    installationId: i.id,
    status: i.status,
    recoveryCount: i.recoveryCount,
    // False means the app should call POST /v1/installations/me/recovery.
    recoveryUpToDate: i.recoveryKeyVersion === c.keys.current,
    createdAt: i.createdAt,
  }];
}

/// Signed. The phone presents its device hash again so the server can move
/// it to the current recovery key version (or store one if it had none).
async function refreshRecovery(c: Ctx): Promise<[number, Record<string, unknown>]> {
  const i = await authenticate(c);
  const body = await readJson(c.req);
  const material = body.recoveryMaterial;
  if (typeof material !== "string" || !RECOVERY_MATERIAL.test(material)) {
    throw invalid("recoveryMaterial");
  }
  const hashes = await deviceHashes(c, material);
  const [row] = await c.rpc("api_refresh_recovery", {
    p_installation_id: i.id,
    p_recovery_hash: hashes.current,
    p_recovery_key_version: c.keys.current,
    p_known_hashes: hashes.all,
  });
  switch (row?.outcome) {
    case "current":
    case "upgraded":
    case "set":
      return [200, { recoveryUpToDate: true, changed: row.outcome !== "current" }];
    case "mismatch":
    case "in_use":
      // One answer for both, so it cannot be used to test other phones' IDs.
      throw new ApiError(409, "RECOVERY_NOT_UPDATED", "Recovery could not be updated.");
    default:
      throw new Error("unexpected refresh outcome");
  }
}

// ---------------------------------------------------------------- challenges

const PACKAGE_NAME = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
const IDEMPOTENCY_KEY = /^[A-Za-z0-9_-]{16,128}$/;
const CONSENT_VERSION = /^[0-9A-Za-z._-]{1,50}$/;
const EMERGENCY_MINUTES = [2, 5, 10, 15, 30];
const MAX_APPS = 50;
const MAX_EVENTS = 100;
// What a phone may report. Status changes are never among them.
const DEVICE_EVENT_TYPES = [
  "protection_lost", "protection_restored", "force_stopped", "accessibility_off",
  "tamper_protection_off", "restored_on_device", "clock_jump",
];
// Things only the server decides. A request that tries to set one is refused.
const SERVER_ONLY_FIELDS = [
  "id", "installationId", "status", "startTime", "endTime", "actualEndTime",
  "createdAt", "consentAcceptedAt", "payment",
];

const notFound = () => new ApiError(404, "NOT_FOUND", "Not found.");

function wholeNumber(v: unknown, min: number, max: number, name: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) throw invalid(name);
  return v;
}

function timestamp(v: unknown, name: string): string {
  if (typeof v !== "string" || v.length > 40 ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.test(v) ||
      Number.isNaN(Date.parse(v))) {
    throw invalid(name);
  }
  return new Date(v).toISOString();
}

function idempotencyKey(c: Ctx): string {
  const key = c.req.headers.get("idempotency-key") ?? "";
  if (!IDEMPOTENCY_KEY.test(key)) {
    throw new ApiError(400, "IDEMPOTENCY_KEY_REQUIRED", "Send an Idempotency-Key header.");
  }
  return key;
}

/// A challenge ID from the address. Anything that is not a UUID cannot exist.
function challengeId(raw: string): string {
  const id = raw.toLowerCase();
  if (!UUID.test(id)) throw notFound();
  return id;
}

async function createChallenge(c: Ctx): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const key = idempotencyKey(c);
  const body = await readJson(c.req);
  for (const f of SERVER_ONLY_FIELDS) {
    if (f in body) throw invalid(`field: ${f}`);
  }
  const duration = wholeNumber(body.durationMinutes, 1, 43200, "durationMinutes");
  // 0 = a challenge with no financial commitment (the only kind the current
  // app creates). Nothing is ever charged by this server either way.
  const amount = wholeNumber(body.amountRupees, 0, 10000, "amountRupees");
  if (amount !== 0 && amount < 100) throw invalid("amountRupees");
  const emergencyLimit = wholeNumber(body.emergencyLimit, 0, 3, "emergencyLimit");
  const emergencyMinutes = wholeNumber(body.emergencyMinutes, 1, 60, "emergencyMinutes");
  if (!EMERGENCY_MINUTES.includes(emergencyMinutes)) throw invalid("emergencyMinutes");
  if (typeof body.consentVersion !== "string" || !CONSENT_VERSION.test(body.consentVersion)) {
    throw invalid("consentVersion");
  }
  if (body.consentAccepted !== true) {
    throw new ApiError(422, "CONSENT_REQUIRED", "The terms must be accepted.");
  }
  if (!Array.isArray(body.apps) || body.apps.length < 1 || body.apps.length > MAX_APPS) {
    throw invalid("apps");
  }
  const seen = new Set<string>();
  const apps = body.apps.map((a: unknown) => {
    const app = a as Record<string, unknown>;
    if (typeof a !== "object" || a === null ||
        typeof app.packageName !== "string" || app.packageName.length > 255 ||
        !PACKAGE_NAME.test(app.packageName) || seen.has(app.packageName) ||
        typeof app.appName !== "string" || app.appName.length < 1 || app.appName.length > 100 ||
        // deno-lint-ignore no-control-regex
        /[\u0000-\u001f\u007f]/.test(app.appName)) {
      throw invalid("apps");
    }
    seen.add(app.packageName);
    return { packageName: app.packageName, appName: app.appName };
  }).sort((x, y) => x.packageName < y.packageName ? -1 : 1);

  const request = {
    duration, amount, emergencyLimit, emergencyMinutes,
    consentVersion: body.consentVersion, apps,
  };
  const [row] = await c.rpc("api_create_challenge", {
    p_installation_id: me.id,
    p_idempotency_key: key,
    p_request_hash: await sha256Hex(JSON.stringify(request)),
    p_duration_minutes: duration,
    p_amount_rupees: amount,
    p_emergency_limit: emergencyLimit,
    p_emergency_minutes: emergencyMinutes,
    p_consent_version: body.consentVersion,
    p_apps: apps,
  });
  switch (row?.outcome) {
    case "created":
      return [201, { challenge: row.challenge }];
    case "existing":
      return [200, { challenge: row.challenge }];
    case "idempotency_mismatch":
      throw new ApiError(409, "IDEMPOTENCY_MISMATCH",
        "This Idempotency-Key was used for a different request.");
    case "active_exists":
      throw new ApiError(409, "ACTIVE_CHALLENGE_EXISTS",
        "You already have a challenge in progress.", false, {}, { challenge: row.challenge });
    case "invalid":
      throw invalid("challenge");
    default:
      throw new Error("unexpected create outcome");
  }
}

async function activeChallenge(c: Ctx): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const [row] = await c.rpc("api_get_active", { p_installation_id: me.id });
  return [200, { challenge: row?.challenge ?? null }];
}

async function oneChallenge(c: Ctx, [id]: string[]): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const [row] = await c.rpc("api_get_challenge", {
    p_installation_id: me.id,
    p_challenge_id: challengeId(id),
  });
  if (!row) throw notFound();
  return [200, { challenge: row.challenge }];
}

async function registrationResult(c: Ctx, [key]: string[]):
  Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  if (!IDEMPOTENCY_KEY.test(key)) throw notFound();
  const [row] = await c.rpc("api_registration_result", {
    p_installation_id: me.id,
    p_idempotency_key: key,
  });
  if (!row) throw notFound();
  return [200, { challenge: row.challenge }];
}

async function history(c: Ctx): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const q = new URL(c.req.url).searchParams;
  for (const name of q.keys()) {
    if (name !== "limit" && name !== "before") throw invalid(`query: ${name}`);
  }
  const limitText = q.get("limit") ?? "20";
  if (!/^\d{1,3}$/.test(limitText)) throw invalid("limit");
  const limit = wholeNumber(Number(limitText), 1, 50, "limit");
  const before = q.has("before") ? timestamp(q.get("before"), "before") : null;
  const rows = await c.rpc("api_list_history", {
    p_installation_id: me.id,
    p_before: before,
    p_limit: limit,
  });
  return [200, {
    items: rows.map((r) => r.challenge),
    // Pass this back as "before" to get the next page; null means no more.
    nextBefore: rows.length === limit
      ? new Date(rows[rows.length - 1].created_at).toISOString()
      : null,
  }];
}

async function completeChallenge(c: Ctx, [id]: string[]):
  Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const [row] = await c.rpc("api_complete_challenge", {
    p_installation_id: me.id,
    p_challenge_id: challengeId(id),
  });
  switch (row?.outcome) {
    case "completed":
    case "already":
      return [200, { challenge: row.challenge }];
    case "too_early":
      throw new ApiError(409, "TOO_EARLY", "This challenge has not reached its end time.", false,
        {}, { secondsRemaining: row.seconds_remaining, challenge: row.challenge });
    case "not_active":
      throw new ApiError(409, "CHALLENGE_NOT_ACTIVE", "This challenge is not active.", false,
        {}, { challenge: row.challenge });
    case "not_found":
      throw notFound();
    default:
      throw new Error("unexpected complete outcome");
  }
}

async function emergency(c: Ctx, [id]: string[]): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const body = await readJson(c.req);
  if (typeof body.useId !== "string" || !UUID.test(body.useId.toLowerCase())) {
    throw invalid("useId");
  }
  const minutes = wholeNumber(body.minutes, 1, 60, "minutes");
  if (!EMERGENCY_MINUTES.includes(minutes)) throw invalid("minutes");
  const [row] = await c.rpc("api_record_emergency", {
    p_installation_id: me.id,
    p_challenge_id: challengeId(id),
    p_use_id: body.useId.toLowerCase(),
    p_started_at: timestamp(body.startedAt, "startedAt"),
    p_minutes: minutes,
  });
  switch (row?.outcome) {
    case "recorded":
      return [201, { remaining: row.remaining, challenge: row.challenge }];
    case "duplicate":
      return [200, { remaining: row.remaining, challenge: row.challenge }];
    case "limit_exceeded":
      throw new ApiError(409, "EMERGENCY_LIMIT_EXCEEDED", "No emergency access is left.", false,
        {}, { remaining: 0 });
    case "not_active":
      throw new ApiError(409, "CHALLENGE_NOT_ACTIVE", "This challenge is not active.", false,
        {}, { challenge: row.challenge });
    case "invalid_minutes":
      throw invalid("minutes");
    case "invalid_time":
      throw invalid("startedAt");
    case "not_found":
      throw notFound();
    default:
      throw new Error("unexpected emergency outcome");
  }
}

async function recordEvents(c: Ctx, [id]: string[]): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  const body = await readJson(c.req);
  if (!Array.isArray(body.events) || body.events.length < 1 || body.events.length > MAX_EVENTS) {
    throw invalid("events");
  }
  const latest = c.now().getTime() + 5 * 60 * 1000;
  const events = body.events.map((raw: unknown) => {
    const e = raw as Record<string, unknown>;
    if (typeof raw !== "object" || raw === null ||
        typeof e.id !== "string" || !UUID.test(e.id.toLowerCase()) ||
        typeof e.type !== "string" || !DEVICE_EVENT_TYPES.includes(e.type)) {
      throw invalid("events");
    }
    const deviceTime = timestamp(e.deviceTime, "events");
    if (Date.parse(deviceTime) > latest) throw invalid("events");
    return { id: e.id.toLowerCase(), type: e.type, deviceTime };
  });
  const [row] = await c.rpc("api_record_events", {
    p_installation_id: me.id,
    p_challenge_id: challengeId(id),
    p_events: events,
  });
  if (row?.outcome === "not_found") throw notFound();
  if (row?.outcome !== "recorded") throw new Error("unexpected events outcome");
  return [200, { accepted: row.accepted, duplicates: row.duplicates }];
}

/// Ending early requires a verified payment. No payment system is connected,
/// so this always refuses, in a controlled way, and changes nothing.
async function endEarly(c: Ctx, [id]: string[]): Promise<[number, Record<string, unknown>]> {
  const me = await authenticate(c);
  idempotencyKey(c);
  const [row] = await c.rpc("api_end_early", {
    p_installation_id: me.id,
    p_challenge_id: challengeId(id),
  });
  switch (row?.outcome) {
    case "payments_unavailable":
      throw new ApiError(409, "PAYMENTS_UNAVAILABLE",
        "Ending a challenge early requires a payment, and payments are not available yet. " +
        "The challenge is still active.", false, {},
        { paymentRequired: true, amountRupees: row.challenge?.amountRupees ?? null });
    case "too_close_to_end":
      throw new ApiError(409, "TOO_CLOSE_TO_END", "This challenge ends in under a minute.");
    case "not_active":
      throw new ApiError(409, "CHALLENGE_NOT_ACTIVE", "This challenge is not active.", false,
        {}, { challenge: row.challenge });
    case "not_found":
      throw notFound();
    default:
      throw new Error("unexpected end-early outcome");
  }
}

type Handler = (c: Ctx, params: string[]) => Promise<[number, Record<string, unknown>]>;
const V = `/${API_VERSION}`;
const ID = "([^/]{1,64})";
// Order matters: fixed paths come before the ones with an ID in them.
const ROUTES: { method: string; pattern: RegExp; run: Handler }[] = [
  { method: "POST", pattern: new RegExp(`^${V}/installations$`), run: register },
  { method: "POST", pattern: new RegExp(`^${V}/installations/recover$`), run: recover },
  { method: "GET", pattern: new RegExp(`^${V}/installations/me$`), run: me },
  { method: "POST", pattern: new RegExp(`^${V}/installations/me/recovery$`), run: refreshRecovery },
  { method: "POST", pattern: new RegExp(`^${V}/challenges$`), run: createChallenge },
  { method: "GET", pattern: new RegExp(`^${V}/challenges/active$`), run: activeChallenge },
  { method: "GET", pattern: new RegExp(`^${V}/challenges/history$`), run: history },
  { method: "GET", pattern: new RegExp(`^${V}/challenges/registrations/${ID}$`), run: registrationResult },
  { method: "GET", pattern: new RegExp(`^${V}/challenges/${ID}$`), run: oneChallenge },
  { method: "POST", pattern: new RegExp(`^${V}/challenges/${ID}/complete$`), run: completeChallenge },
  { method: "POST", pattern: new RegExp(`^${V}/challenges/${ID}/emergency$`), run: emergency },
  { method: "POST", pattern: new RegExp(`^${V}/challenges/${ID}/events$`), run: recordEvents },
  { method: "POST", pattern: new RegExp(`^${V}/challenges/${ID}/end-early$`), run: endEarly },
];

/// Handles one request.
export async function handle(req: Request, deps: Deps = {}): Promise<Response> {
  const now = deps.now ?? (() => new Date());
  const respond = (status: number, body: Record<string, unknown>,
    extra: Record<string, string> = {}) => {
    const t = now();
    return new Response(
      JSON.stringify({ ...body, serverTime: t.toISOString(), epochMs: t.getTime() }),
      { status, headers: { ...BASE_HEADERS, ...extra } });
  };

  // On Supabase the path arrives as /api/v1/...; locally it may be /v1/...
  const path = new URL(req.url).pathname
    .replace(/\/+$/, "")
    .replace(/^\/functions\/v1(?=\/)/, "")
    .replace(/^\/api(?=\/)/, "");

  try {
    if (path === `/${API_VERSION}/time`) {
      if (req.method !== "GET") {
        throw new ApiError(405, "METHOD_NOT_ALLOWED", "Use GET.", false, { allow: "GET" });
      }
      return respond(200, {});
    }
    const matching = ROUTES.filter((r) => r.pattern.test(path));
    if (matching.length === 0) throw new ApiError(404, "NOT_FOUND", "No such endpoint.");
    const route = matching.find((r) => r.method === req.method);
    if (!route) {
      const allow = [...new Set(matching.map((r) => r.method))].join(", ");
      throw new ApiError(405, "METHOD_NOT_ALLOWED", `Use ${allow}.`, false, { allow });
    }
    const params = (path.match(route.pattern) ?? []).slice(1);
    const [status, body] = await route.run(context(req, deps), params);
    return respond(status, body);
  } catch (e) {
    if (e instanceof ApiError) {
      return respond(e.status,
        { ...e.extra, code: e.code, message: e.message, retryable: e.retryable }, e.headers);
    }
    // Never log request contents: they may hold a credential.
    console.error(`api error on ${req.method} ${path}`);
    return respond(500, { code: "SERVER_ERROR", message: "Something went wrong.", retryable: true });
  }
}

if (typeof Deno !== "undefined") {
  Deno.serve((req: Request) => handle(req));
}
