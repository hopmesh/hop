// The same-origin proxy to hop-accountd.
//
// This is a runtime route handler, NOT a next.config rewrite, and that distinction is the whole
// point. Next evaluates `rewrites()` during `next build` and bakes the resolved destination into
// routes-manifest.json, so a rewrite reading process.env.HOP_ACCOUNTD_URL captures whatever the
// value was AT BUILD TIME. In the Cloud Run image that variable is unset, so the rewrite baked in
// the dev fallback and every /api/* call in production failed with
// `connect ECONNREFUSED 127.0.0.1:9446`. A route handler reads the env var per request, so one
// environment-agnostic image works in dev and in prod, and the digest-pinned deploy model holds.
//
// Everything under /api/* is forwarded verbatim with the /api prefix stripped: /api/auth/request
// becomes <accountd>/auth/request. Cookies must survive in BOTH directions, because the session is
// a __Host- cookie that hop-accountd sets and the browser only ever sees on this origin.

import { NextRequest } from "next/server";

// Always run per request. The upstream depends on env + cookies, so a cached or statically
// optimized response here would be wrong.
export const dynamic = "force-dynamic";

const ACCOUNTD = process.env.HOP_ACCOUNTD_URL || "http://localhost:9446";

// Hop-by-hop and length headers must not be forwarded: undici sets its own framing, and passing a
// stale content-length or a connection header through makes the upstream request malformed.
const STRIP_REQUEST_HEADERS = new Set([
  "connection",
  "content-length",
  "host",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

// Same idea on the way back, plus content-encoding: fetch has already decoded the body, so echoing
// the original encoding would tell the browser to decode it a second time.
const STRIP_RESPONSE_HEADERS = new Set([
  "connection",
  "content-encoding",
  "content-length",
  "keep-alive",
  "transfer-encoding",
]);

async function proxy(request: NextRequest): Promise<Response> {
  const incoming = new URL(request.url);
  // pathname is /api/<rest>; forward <rest> and keep the query string intact.
  const rest = incoming.pathname.replace(/^\/api\//, "");
  const target = `${ACCOUNTD.replace(/\/$/, "")}/${rest}${incoming.search}`;

  const headers = new Headers();
  request.headers.forEach((value, key) => {
    if (!STRIP_REQUEST_HEADERS.has(key.toLowerCase())) headers.set(key, value);
  });

  // GET and HEAD must not carry a body; anything else streams through untouched so JSON posts and
  // the Stripe webhook's raw bytes arrive byte-identical (signature verification depends on that).
  const method = request.method.toUpperCase();
  const hasBody = method !== "GET" && method !== "HEAD";

  let upstream: Response;
  try {
    upstream = await fetch(target, {
      method,
      headers,
      body: hasBody ? await request.arrayBuffer() : undefined,
      redirect: "manual",
      cache: "no-store",
    });
  } catch (cause) {
    // Surface the upstream being unreachable as a 502 rather than a generic Next 500, so the next
    // failure of this kind is legible from the status code alone.
    console.error(`hop-console: proxy to ${target} failed`, cause);
    return new Response(JSON.stringify({ error: "upstream_unreachable" }), {
      status: 502,
      headers: { "content-type": "application/json" },
    });
  }

  const responseHeaders = new Headers();
  upstream.headers.forEach((value, key) => {
    if (!STRIP_RESPONSE_HEADERS.has(key.toLowerCase())) responseHeaders.append(key, value);
  });

  // getSetCookie() preserves MULTIPLE Set-Cookie headers as distinct values. Headers.get() would
  // fold them into one comma-joined string, which browsers reject, and the session cookie would be
  // silently dropped on any response that sets more than one.
  const setCookies = upstream.headers.getSetCookie?.() ?? [];
  if (setCookies.length > 0) {
    responseHeaders.delete("set-cookie");
    for (const cookie of setCookies) responseHeaders.append("set-cookie", cookie);
  }

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}

export const GET = proxy;
export const HEAD = proxy;
export const POST = proxy;
export const PUT = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
export const OPTIONS = proxy;
