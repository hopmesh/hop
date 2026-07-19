# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- address adversarial review of the auth wiring (3 DoS findings) (c90f64e)
- address adversarial review of the auth API (8a48a4d)
- address adversarial review of the auth foundation (73ae5a9)
- close the invoice-existence oracle and add a head-read deadline (a3b8ce5)

### Build
- Dockerfiles for hop-billingd and hop-accountd (20d6d81)

### Features
- serve /auth/* + GitHub OAuth (console phase 3b) (67d591e)
- passwordless auth API + email seam (console phase 3a) (736e9da)
- Postgres Store binding + schema (console phase 2) (3363640)
- console foundation, passwordless auth + storage layer (81f8c68)
- hop-accountd, the native invoice backend (stripe-account-key consumer) (62dbaef)

