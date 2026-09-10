# Hop production infrastructure

All production deployment workflows live in `hopmesh/hop`. The private `hopmesh/platform` repository
stores commercial source and billing configuration at the exact commit in `private-source.lock`; it
has no deployment authority after cutover. The frozen legacy monorepo remains readable pending
archive, then remains only as a historical ref and release trust anchor.

## State ownership

| Root | State prefix | Purpose |
|---|---|---|
| `infra/` | `relay-fleet` | Runtime services, load balancer, DNS, certificates, observability, usage data |
| `infra/bootstrap/` | `bootstrap` | APIs, IAM, WIF, service accounts, secret containers, Cloud SQL, Firestore policy |
| pinned platform `infra/billing/` | `billing` | Stripe catalog, Resend domain, billing outputs |

All three use the versioned `hop-mesh-tfstate` bucket. The bucket and prefixes are authority
boundaries and are pinned by `tools/infra-authority-guard.py`.

## Source boundary

The public repository builds relay and example images before checking out private source. It then
checks out `hopmesh/platform` at the full commit in `private-source.lock`, verifies the repository,
commit, cleanliness, regular-file contract, and 57-file source manifest, and stages accountd,
billingd, and console into the exact public commit. No branch or short SHA is accepted.

A commercial source change requires two reviewed merges: the private source change, then a hop PR
updating `private-source.lock`. Only the second merge can deploy.

## Runtime apply

`runtime-deploy.yml` runs after the required `CI gate` succeeds on a push to hop `main`, or by a typed
manual dispatch from hop `main`. It builds all four runtime images, resolves immutable digests, plans
against the `relay-fleet` state, rejects unintended deletion or replacement, applies the saved plan,
and reads back both source labels from every live Cloud Run service.

The relay fleet stays disabled unless the owner explicitly sets `RELAYS_ENABLED=true` after the
preconditions in `docs/runbooks/relay-enable-disable.md` are satisfied. The example, account backend,
and console remain managed while relays are disabled.

## Bootstrap and billing

`bootstrap-apply.yml` is manual for cloud plans and applies. Its final state admits only hop main to
runtime, bootstrap, and billing service accounts. Bootstrap inputs are non-secret repository
variables, fixed defaults, and enabled Secret Manager version numbers queried after authentication.
There is no opaque `BOOTSTRAP_TFVARS` blob.

`billing-catalog.yml` and `resend-domain.yml` originate in hop but use the pinned private billing root.
Vendor credentials are fetched from Secret Manager after billing WIF authentication. The billing
catalog publishes only `{base,reach,observability}` Stripe price identifiers to a new numeric version
of `hop-billing-price-ids`; runtime pins that version and never reads billing state.

## Verification

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false -input=false
tofu -chdir=infra validate
tofu -chdir=infra/bootstrap init -backend=false -input=false
tofu -chdir=infra/bootstrap validate
python3 tools/infra-authority-guard.py
bash tools/infra-authority-guard.test.sh
python3 tools/private-source-pin.py verify-lock --lock infra/private-source.lock
bash tools/private-source-pin.test.sh
```

Never run a local apply. A local plan against remote state is also avoided during cutover because it
can acquire the production lock and because a stale checkout turns missing source into deletion.
