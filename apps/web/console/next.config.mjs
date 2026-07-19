// The console is a thin Next front over hop-accountd: every /api/* call is proxied to the account
// service, so the browser sees ONE origin (dashboard.hopme.sh) and the __Host- session cookie the
// account service sets is first-party. HOP_ACCOUNTD_URL points at the account service (a Cloud Run
// URL in prod, http://localhost:9446 in dev); it never reaches the browser.
const accountd = process.env.HOP_ACCOUNTD_URL || "http://localhost:9446";

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Standalone output = a self-contained server bundle for a slim Cloud Run image.
  output: "standalone",
  reactStrictMode: true,
  async rewrites() {
    return [
      { source: "/api/:path*", destination: `${accountd}/:path*` },
    ];
  },
};

export default nextConfig;
