// The console is a thin Next front over hop-accountd: every /api/* call is proxied to the account
// service, so the browser sees ONE origin (dashboard.hopme.sh) and the __Host- session cookie the
// account service sets is first-party.
//
// The proxy is app/api/[...path]/route.ts, NOT a rewrite here. Next resolves `rewrites()` during
// `next build` and bakes the destination into routes-manifest.json, so a rewrite built from
// process.env.HOP_ACCOUNTD_URL freezes whatever that variable was at BUILD time. The Cloud Run
// image is built without it, so the rewrite baked the dev fallback and every /api/* call in
// production failed with `connect ECONNREFUSED 127.0.0.1:9446`. The route handler reads the
// variable per request instead, which keeps one environment-agnostic image valid everywhere.
// Do not reintroduce an /api rewrite here.

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Standalone output = a self-contained server bundle for a slim Cloud Run image.
  output: "standalone",
  reactStrictMode: true,
};

export default nextConfig;
