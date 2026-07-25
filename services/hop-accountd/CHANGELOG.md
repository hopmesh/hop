# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- land logins in the app; center the dashboard content (7023e3f)
- stop the per-peer limiter from throttling all logins at once (e3a4e39)
- route the GitHub OAuth callback through the /api proxy (0b9b103)
- point the magic-link email at /auth/verify, the page that exists (b230638)
- make the last-Owner floor atomic (team review) (52b3804)
- make first-checkout idempotent + guard against double-subscribe (8d7056e)
- refuse a partially-malformed Stripe price catalog (c1e64ea)
- address adversarial review of the auth wiring (3 DoS findings) (c90f64e)
- address adversarial review of the auth API (8a48a4d)
- address adversarial review of the auth foundation (73ae5a9)
- close the invoice-existence oracle and add a head-read deadline (a3b8ce5)

### Build
- Dockerfiles for hop-billingd and hop-accountd (20d6d81)

### Chore
- purge em-dashes and en-dashes from source (d222435)

### Documentation
- regenerate from conventional commits (a355901)

### Features
- organization management (create + switch, persisted) (1392ae1)
- store subscription/plan state from a Stripe webhook (59b16e0)
- team invites via Resend (create + accept) (6b P1c-invite) (6678a59)
- live subscription-state read for the console (6b P1d) (91beadb)
- near-realtime console usage read (6b P1b) (0bc06b9)
- console team management (6b P1c) (e4a6678)
- console read APIs — overview + invoices + card (6b P1a) (0fa2476)
- project the tenant registry to Firestore (phase 5b, writer) (e73d8d9)
- wire the billing endpoints into the console dispatch (4d) (2c7f561)
- carriage-key + OTLP registration endpoints (console phase 5a) (3a3d396)
- console billing endpoints (checkout + portal, phase 4c) (27ead52)
- Stripe write layer, self-serve checkout + portal (phase 4b) (119ab84)
- org/workspace bootstrap + tenant registry (console phase 4a) (46acd6d)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- serve /auth/* + GitHub OAuth (console phase 3b) (67d591e)
- passwordless auth API + email seam (console phase 3a) (736e9da)
- Postgres Store binding + schema (console phase 2) (3363640)
- console foundation, passwordless auth + storage layer (81f8c68)
- hop-accountd, the native invoice backend (stripe-account-key consumer) (62dbaef)

### Other
- rustfmt the oauth redirect_uri assertion (6ee3865)
- accountd firestore image + the deploy plan (P4) (d51be5d)
- reject internal/metadata OTLP endpoints (5a review) (8518833)

### Refactor
- fold billing authz onto the shared authorize_tenant (9f529dd)

