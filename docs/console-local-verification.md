# Running and verifying the Hop console locally

A step-by-step walkthrough for bringing the customer console (signup + team dashboard) up on a
laptop, and the observed result of every check. Everything below was actually run on 2026-07-20
against `origin/main` (`f79b967`) plus the one fix described in "What was broken".

Two processes and a database:

- **`services/hop-accountd`** (Rust, `--features live`): auth, RBAC, keys, team, billing. Port 9446.
- **`apps/web/console`** (Next.js 16 App Router): the UI. Port 3000. Proxies `/api/*` to accountd.
- **Postgres 16**: the account store. Schema applies itself at accountd boot.

Toolchain used: cargo 1.97.0, node v26.5.0, npm 11.17.0, Docker (OrbStack).

---

## 1. Start Postgres

```bash
docker run -d --name hop-console-pg \
  -e POSTGRES_PASSWORD=hopdev -e POSTGRES_DB=hopconsole \
  -p 127.0.0.1:55433:5432 postgres:16
```

**Pick a port nothing else owns, and bind it to `127.0.0.1` explicitly.** Port 55432 was already
held by a local Postgres on this machine. Docker's wildcard publish (`-p 55432:5432`) still
"succeeded", but the pre-existing loopback listener won every `127.0.0.1` connection, so accountd
talked to the wrong database and failed with `database "hopconsole" does not exist`. Check first:

```bash
lsof -nP -iTCP:55433 -sTCP:LISTEN   # expect no output
```

## 2. Start hop-accountd

`HOP_API_TOKEN` (>= 16 bytes) and `STRIPE_ACCOUNT_KEY` are both mandatory or the process exits 2.
Everything here is a throwaway local value; none of it is a real credential.

```bash
export DATABASE_URL="postgresql://postgres:hopdev@127.0.0.1:55433/hopconsole"
export HOP_API_TOKEN="local-dev-token-0123456789abcdef"
export STRIPE_ACCOUNT_KEY="rk_test_local_placeholder_not_a_real_key"
export RESEND_API_KEY="re_local_placeholder"
export RESEND_FROM="Hop <console@localhost.test>"
export HOP_CONSOLE_BASE="http://localhost:3000"
export PORT=9446

cargo build -p hop-accountd --features live
./target/debug/hop-accountd
```

Observed startup log:

```
hop-accountd: HOP_TENANT_MAP empty or unset; every tenant will 404
hop-accountd: HOP_STRIPE_*_PRICES unset; /billing/* disabled
hop-accountd: /auth/* enabled (github oauth: off, billing: off)
hop-accountd: serving on 0.0.0.0:9446 (0 tenants mapped)
```

All three warnings are expected for a local run. `HOP_TENANT_MAP` only affects the legacy operator
`/v1/*` invoice surface, not the console. `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` are omitted, so
the GitHub button is inert locally; set both or neither (setting exactly one exits 2 on purpose).

`GET /healthz` returns `{"ok":true}` with 200.

The schema applies itself on boot (`PgStore::connect` runs `init_schema`, every statement is
`IF NOT EXISTS`). Verified with `\dt`: `invites`, `login_tokens`, `memberships`, `orgs`, `sessions`,
`users`. No manual migration step.

If `DATABASE_URL` is wrong, expect **up to 30 seconds of silence** before it gives up. That is
r2d2's connection timeout, not a hang. It exits 2 with
`postgres connect failed: store backend: timed out waiting for connection: db error`. The message
does not name the real cause (wrong database, wrong password, nothing listening), so check the URL
by hand with `psql` before assuming the service is broken.

## 3. Start the console

```bash
cd apps/web/console
npm ci
npm run build
HOP_ACCOUNTD_URL=http://127.0.0.1:9446 PORT=3000 npm run start
```

Build is clean: compiled in 636ms, TypeScript clean, 5 static routes (`/`, `/auth/verify`,
`/dashboard`, `/invite`, `/_not-found`).

`npm run start` prints a warning that it does not work with `output: standalone` and to use
`node .next/standalone/server.js` instead. In practice `npm run start` served every route and
proxied `/api/*` correctly, so it is fine for local verification, but the standalone server is what
production actually runs.

---

## Getting a sign-in link locally

Resend has no valid API key locally, so **the email never sends**. `POST /auth/request-link` mints
the token, fails the send, and returns `502 {"error":"email_failed"}`. That is correct behavior.

There is **no honest way to recover the raw token from the logs**, by design: only the SHA-256 hash
is persisted, and the raw value is never logged (`auth_api.rs` returns 502 without printing it).
The local workaround is to mint a token with a raw value you already know, which is exactly what the
email would have carried:

```bash
mint_link() {
  RAW="devtok-$(openssl rand -hex 16)"
  HASH=$(printf '%s' "$RAW" | shasum -a 256 | cut -d' ' -f1)
  NOW=$(( $(date +%s) * 1000 )); EXP=$(( NOW + 900000 ))
  PGPASSWORD=hopdev psql -h 127.0.0.1 -p 55433 -U postgres -d hopconsole -q -c \
    "insert into login_tokens(token_hash,email,created_ms,expires_ms)
     values('$HASH','$1',$NOW,$EXP)"
  echo "http://localhost:3000/auth/verify#token=$RAW"
}

mint_link founder@example.test
```

This exercises the real redeem path end to end; only the delivery hop is stubbed.

---

## Verification results

### 1. accountd boots against real Postgres: PASS

Startup log above. `/healthz` 200. Six tables created at boot.

### 2. Signup and magic link: PASS

- `POST /auth/request-link` with `{"email":"owner@example.test"}` returned **502 `email_failed`**
  (Resend unreachable), and the `login_tokens` row was still minted:
  `4ee3cb52... | owner@example.test | 1784538444577`.
- A malformed address (`"nope"`) returned **400** without minting anything.
- `POST /auth/redeem` with a known-raw token returned **200** and set the session cookie:
  `Set-Cookie: __Host-hop_session=6d868d55...; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax; Secure`
  with body `{"ok":true,"created":true,"email":"owner@example.test"}`.
- Replaying the same token returned **410**. Single-use holds.

### 3. Account creation and idempotency: PASS

After the first redeem:

```
       email        | email_verified |       name        |            tenant_hex            | role
--------------------+----------------+-------------------+----------------------------------+-------
 owner@example.test | t              | owner's workspace | 00685441e92d1a631e370914cc0e5738 | owner
```

The click verified the address, `ensure_personal_workspace` created one org with a real 32-hex
tenant id, and the user is its Owner. A second redeem for the same address returned
`{"ok":true,"created":false,...}` and counts stayed at `users=1 orgs=1 memberships=1`. No duplicate
user, no duplicate workspace.

### 4. `/auth/me`: PASS

| Request | Result |
| --- | --- |
| With valid cookie | 200, `{"id":"f240f4dd...","email":"owner@example.test","email_verified":true}` |
| No cookie | 401 `{"error":"unauthenticated"}` |
| Garbage cookie | 401 `{"error":"unauthenticated"}` |

### 5. `/console/overview`: PASS

```json
{"user":{"email":"owner@example.test","id":"f240f4dd..."},
 "workspaces":[{"hasCarriageKey":false,"hasOtlp":false,
                "name":"owner's workspace","role":"owner",
                "tenant":"00685441e92d1a631e370914cc0e5738"}]}
```

401 without a cookie.

### 6. Carriage key registration: PASS

- Valid 64-hex pubkey: **200 `{"ok":true}`**, persisted to `orgs.carriage_pubkey`, and
  `hasCarriageKey` flipped to `true` on the next overview call.
- Rejected with **400** in every bad case: 8-char string, 64 chars containing non-hex (`zz...`),
  80 hex chars, and empty string.

Also verified through the browser UI, which generates the Ed25519 keypair client-side and posts only
the public half. The value shown in the UI
(`81f8b22b106bb9ec7c27944375999e1612ae1560d46615949255a41c6e023797`) matched the `orgs` row exactly.

### 7. OTLP endpoint and SSRF refusal: PASS

`https://otlp.datadoghq.com/v1/traces` accepted (200, persisted). All twelve hostile endpoints were
refused with **400 `invalid_endpoint`**, and the stored value was unchanged afterward:

| Endpoint | Result |
| --- | --- |
| `http://169.254.169.254/latest/meta-data/` | 400 |
| `https://169.254.169.254/v1/traces` | 400 |
| `http://localhost:9446/v1/traces` | 400 |
| `https://127.0.0.1/v1/traces` | 400 |
| `https://10.0.0.5/v1/traces` | 400 |
| `https://192.168.1.10/v1/traces` | 400 |
| `https://172.16.0.9/v1/traces` | 400 |
| `https://user:pass@evil.test@otlp.good.com/v1` | 400 |
| `http://otlp.plaintext.com/v1/traces` (plaintext) | 400 |
| `https://[::1]/v1/traces` | 400 |
| `file:///etc/passwd` | 400 |
| `https://metadata.google.internal/v1` | 400 |

### 8. Team: PASS

- **List:** 200 with the single Owner.
- **Invite:** `POST /console/team/invite` returned **502 `email_failed`** (Resend down), and the
  `invites` row was still created (`teammate@example.test | user | 1785142415832`). The failure is
  handled sanely: a clear retryable status, no 500, no panic. Note the invite row survives the send
  failure, so the invitee cannot be reached until the operator retries with a working provider.
- **Accept:** a second user signed up, and accepting a minted invite returned
  `{"ok":true,"tenant":"00685441e9..."}`. Roster went to two members.
- **Role change:** Owner promoting the teammate `user` to `admin` returned 200; demoting back to
  `user` returned 200; removing them returned 200 and the roster returned to one.
- **Last-Owner floor:** demoting the sole Owner returned **409 `last_owner`**; removing the sole
  Owner returned **409 `last_owner`**. The membership row was unchanged (`role = owner`). Correct,
  recorded as a pass.
- **Privilege escalation refused:** an Admin promoting themselves to Owner returned **403**; an
  Admin demoting the Owner returned **403**.
- **Cross-tenant probe:** a member requesting a tenant they do not belong to returned **404**, not
  403, so tenant existence does not leak.

### 9. Billing degradation: PASS

With no `HOP_STRIPE_*_PRICES` configured:

| Endpoint | Result |
| --- | --- |
| `POST /billing/checkout` | 503 `{"error":"billing_unavailable"}` |
| `POST /billing/portal` | 503 `{"error":"billing_unavailable"}` |
| `GET /console/subscription` | 503 `{"error":"billing_unavailable"}` |
| `GET /console/invoices` | 200 `{"invoices":[]}` |
| `GET /console/card` | 200 `{"card":null}` |
| unknown `/console/*` route | 404 |

No 500s, no panics in the log, and `/healthz` still 200 afterward.

Worth knowing: `/console/invoices` and `/console/card` are backed by the always-present Stripe
transport, so with a placeholder key they swallow the upstream rejection and return empty rather
than surfacing a configuration error. Good for the page, quiet about a real misconfiguration in
production.

### 10. Frontend: PASS

`npm ci && npm run build` clean. Serving against accountd:

| Route | Status |
| --- | --- |
| `/` | 200, signup screen renders (title `Hop Console`, email field `you@company.com`) |
| `/auth/verify` | 200 |
| `/dashboard` | 200 |
| `/invite` | 200 |

The `/api` proxy is live and passes the session cookie through in both directions:

- `GET /api/auth/me` with cookie: 200 with the user. Without: 401.
- `GET /api/console/overview` with cookie: 200 with the workspace.
- `POST /api/auth/redeem` through Next returned 200 **and forwarded the `Set-Cookie`** intact.

**Full browser walkthrough** (Chrome, `http://localhost:3000`). `__Host-` cookies require `Secure`,
and Chrome treats `localhost` as a secure context, so the real cookie flow works over plain HTTP
locally:

1. `/` rendered the signup card: Hop wordmark, one email field, "Send me a sign-in link",
   "Continue with GitHub", and the "No password" explainer.
2. Navigating to a minted `/auth/verify#token=...` redeemed the token client-side and redirected to
   `/dashboard`, which rendered **"founder's workspace"**, "Workspace 9410dede... you are owner",
   the four stat tiles, the nav, and `founder@example.test` with "Sign out" in the footer. This was
   a brand-new address, so it exercised signup, workspace creation, and sign-in in one pass.
3. **Team** rendered the live roster from the backend (`founder@example.test`, role Owner) plus the
   invite form.
4. **Keys** generated an Ed25519 keypair in the browser, downloaded the private half, registered the
   public half, and flipped to "A carriage key is registered." The DB row matched the displayed key.

Screenshots were captured for the signup screen, dashboard, team page, and keys page.

### Extra checks (not on the original list)

- **Logout:** with a cookie, 204 plus a clearing `Set-Cookie`, and `/auth/me` went 401 afterward.
  With no cookie, 204 and **no** `Set-Cookie`, which is the deliberate guard against a third-party
  page force-logging-out a visitor.

---

## What was broken, and the fix

**The emailed sign-in link pointed at a page that does not exist.** `email.rs::login_link_url` built
`{base}/auth/link#token=...`, but the console serves the redeem page at `/auth/verify`
(`apps/web/console/app/auth/verify/page.tsx`), which is also what `apps/web/console/CLAUDE.md`
documents as the locked contract. Proven against the running server:

```
/auth/verify -> 200
/auth/link   -> 404
```

Every magic-link click in production would have landed on a 404. Since magic link is the only
signup path, that is the whole funnel. The backend was the drifted side (the page, the frontend
tests, and the frontend's own CLAUDE.md all agreed on `/auth/verify`), so `login_link_url` now
builds `/auth/verify`, with a comment naming the page it must stay in step with. The two unit tests
that asserted the old path and the `auth_api.rs` test helper that scrapes the link out of the
email body were updated with it.

After the fix, the emailed path resolves 200 and the full browser signup flow above works.

## Still open, or not verifiable locally

- **Rate limiting could not be verified end to end.** Six rapid `request-link` calls for one address
  all returned 502 and none were throttled, because the send failure refunds the rate-limit hit by
  design ("a provider outage must not consume the caller's attempts"). With Resend unreachable the
  limiter therefore never engages. The unit tests cover the limiter directly; this is a local
  observability gap, not evidence of a broken limiter.
- **Related, and a real decision for the owner:** because the refund happens but the mint does not
  roll back, each failed attempt still leaves a `login_tokens` row. Six attempts left six rows.
  During a sustained email-provider outage, `/auth/request-link` is an unbounded INSERT vector (and
  an unbounded outbound-request vector at Resend). Harm is bounded (the tokens are useless without
  inbox access and expire in 15 minutes) but it is worth deciding whether to refund the peer limiter
  only, or cap live tokens per address. Not changed here, because it is a design call.
- **GitHub OAuth was not exercised.** No client id or secret locally, so `/auth/github/start` and
  the callback are untested. They need a real GitHub OAuth app.
- **Stripe was not exercised.** No real key and no price catalog, so Checkout, Portal, subscription,
  invoices, and card were only verified in their degraded state. Real billing needs live Stripe
  config.
- **Email delivery was not exercised.** No Resend key. Send failure handling was verified; actual
  delivery and the rendered email were not.
- **Firestore tenant sync was not exercised.** Built without `--features firestore`, so
  `/console/usage` and the registry projection are untested here.
- **Deploy is untested.** Out of scope; it needs the owner's GCP credentials.
- **Cosmetic:** on the Keys page, the status dot stays amber after a key is registered while the
  text correctly reads "A carriage key is registered." Left alone as a design call.

## Verify loop

Run from the repo root after any change:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

All three pass on this branch: clippy clean, 27 test binaries green, `hop-accountd` alone 106 tests.
`git diff origin/main -- core/hop-core/src/bundle.rs` is empty, so the wire format is untouched.

## Teardown

```bash
pkill -f 'target/debug/hop-accountd'
docker rm -f hop-console-pg
```
