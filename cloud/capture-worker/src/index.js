// Cloud version of scripts/capture_proxy.py: records what Auday sends to its BYOK AI
// endpoint, forwards it to the real provider, and keeps working while the Mac is off.
//
//   Auday base URL:  https://<worker>.workers.dev/<PROXY_TOKEN>/v1beta/openai   (OpenAI shape)
//                    https://<worker>.workers.dev/<PROXY_TOKEN>                  (Gemini shape)
//   Read logs:       GET /admin/list?cursor=...      Authorization: Bearer <ADMIN_TOKEN>
//                    GET /admin/get?id=<entry id>    Authorization: Bearer <ADMIN_TOKEN>
//
// API keys (headers or ?key=) are forwarded, never stored. Captured prompts are private.

const SECRET_HEADERS = new Set(["authorization", "x-api-key", "x-goog-api-key", "api-key", "cookie"]);
const PRIVATE_HEADERS = new Set(["x-real-ip", "x-forwarded-for", "true-client-ip"]); // not logged
const SECRET_PARAMS = new Set(["key", "api_key"]);
const MAX_LOG = 20_000_000; // KV values are capped at 25 MB
const KEEP_SECONDS = 60 * 24 * 3600; // entries expire after 60 days
// Bodies are stored as raw text, not parsed: the free plan allows ~10 ms CPU per request.

// Constant-time comparison, so the admin token cannot be guessed from response timing.
function same(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

async function admin(request, env, url) {
  const auth = request.headers.get("Authorization") || "";
  if (!same(auth.replace(/^Bearer /, ""), env.ADMIN_TOKEN)) return json({ error: "forbidden" }, 403);
  if (url.pathname === "/admin/list") {
    const page = await env.LOGS.list({ cursor: url.searchParams.get("cursor") || undefined, limit: 1000 });
    return json({ keys: page.keys.map((k) => ({ id: k.name, ...k.metadata })),
                  cursor: page.list_complete ? null : page.cursor });
  }
  if (url.pathname === "/admin/get") {
    const value = await env.LOGS.get(url.searchParams.get("id") || "");
    return value ? new Response(value, { headers: { "Content-Type": "application/json" } }) : json({ error: "not found" }, 404);
  }
  return json({ error: "not found" }, 404);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/admin/")) return admin(request, env, url);

    const prefix = `/${env.PROXY_TOKEN}`;
    if (!env.PROXY_TOKEN || !(url.pathname === prefix || url.pathname.startsWith(prefix + "/"))) {
      return json({ error: "not found" }, 404);
    }
    const path = url.pathname.slice(prefix.length) || "/";
    const body = ["GET", "HEAD"].includes(request.method) ? "" : await request.text();

    const query = new URLSearchParams(url.search);
    for (const name of SECRET_PARAMS) query.delete(name);
    const started = new Date().toISOString();
    const id = `${started}_${crypto.randomUUID().slice(0, 8)}`;
    const entry = {
      id, ts: started, method: request.method, path, query: query.toString(),
      headers: Object.fromEntries([...request.headers].filter(([k]) => !SECRET_HEADERS.has(k) && !PRIVATE_HEADERS.has(k) && !k.startsWith("cf-"))),
      secret_headers_present: [...request.headers.keys()].filter((k) => SECRET_HEADERS.has(k)),
      body: body.slice(0, MAX_LOG),
    };

    const headers = new Headers();
    for (const [key, value] of request.headers) {
      if (!["host", "content-length", "accept-encoding", "connection"].includes(key) && !key.startsWith("cf-")) {
        headers.set(key, value);
      }
    }
    let upstream;
    try {
      upstream = await fetch(env.UPSTREAM.replace(/\/$/, "") + path + url.search,
                             { method: request.method, headers, body: body || undefined });
    } catch (error) {
      entry.response = { status: 502, error: String(error) };
      ctx.waitUntil(env.LOGS.put(id, JSON.stringify(entry), { expirationTtl: KEEP_SECONDS, metadata: { path, status: 502 } }));
      return json({ error: "upstream unreachable" }, 502);
    }

    // Stream the answer to Auday while a copy is recorded in the background.
    const [toClient, toLog] = upstream.body ? upstream.body.tee() : [null, null];
    ctx.waitUntil((async () => {
      const text = toLog ? await new Response(toLog).text() : "";
      entry.response = { status: upstream.status, content_type: upstream.headers.get("Content-Type"),
                         body: text.slice(0, MAX_LOG), truncated: text.length > MAX_LOG };
      await env.LOGS.put(id, JSON.stringify(entry), { expirationTtl: KEEP_SECONDS, metadata: { path, status: upstream.status } });
    })());
    return new Response(toClient, { status: upstream.status, headers: upstream.headers });
  },
};
