# apps/web/console — the Hop console (dashboard.hopme.sh)

The customer-facing console: passwordless signup + sign-in and (phase 6b) the team dashboard. A thin
**Next.js** (App Router) front over **hop-accountd**; the account service owns auth, billing, keys, and
the tenant registry, and the console renders them.

## How it talks to the backend

Every `/api/*` request is proxied to hop-accountd by `next.config.mjs` rewrites (`HOP_ACCOUNTD_URL`),
so the browser sees ONE origin and the `__Host-hop_session` cookie the account service sets stays
first-party. Never call hop-accountd cross-origin from the browser (it would break the `__Host-` cookie
and SameSite). `lib/api.ts` wraps the auth surface.

## Auth flow (passwordless, locked)

- `/` — one email field or "Continue with GitHub". No password, no org, no "email taken", no "already
  have an account". Sign-up and sign-in are the same act.
- `POST /api/auth/request-link` always answers the same ("check your inbox"); no enumeration.
- The email link lands on `/auth/verify#token=...`. The token is in the URL **fragment** (never sent to
  a server, immune to mail-scanner GET prefetch); the client reads it, POSTs `/api/auth/redeem`, and the
  account service sets the session cookie. Then → `/dashboard`.
- GitHub OAuth is a full-page nav to `/api/auth/github/start`.

## Design

Inherits the marketing site's "Signal" identity (`apps/web/site/src/styles/global.css`): dark ground
`#07090b`, signal-green `#2bf0a0`, Poppins, `--radius` 16px, light/dark via `data-theme` stamped
pre-paint. Real icons only (Font Awesome Pro kit), never emoji.

## Build / run

`npm install` then `npm run build` (or `dev`). Requires Node 20+. `HOP_ACCOUNTD_URL` points at the
account service (`http://localhost:9446` in dev).

## Status

- **6a (this):** signup / sign-in / magic-link verify / a minimal signed-in landing. Builds clean.
- **6b (next):** the real dashboard — usage (BigQuery over `usage_history_current`), invoices, carriage
  keys, team, billing (Stripe Checkout/Portal via `/api/billing/*`), observability.
- **6c:** deploy (Cloud Run, same tofu state, `dashboard.hopme.sh`) — outward-facing, held for review.
