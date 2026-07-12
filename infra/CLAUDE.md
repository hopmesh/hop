# infra/

GitOps deploy: OpenTofu state in GCS (`gs://hop-mesh-tfstate`), applied by a Cloud Build trigger. There
is no Spacelift, no GitHub Actions deploy. **Push to main = build images + `tofu apply` in one run**,
gated on CI being green for the commit.

## The pieces

- `cloudbuild.trigger.yaml` builds the relay + endpoint images, runs the `require-ci` deploy gate, then `tofu apply`. `cloudbuild_trigger.tf` defines the build SA + IAM. The fleet is currently OFF (`relays_enabled=false`); flip that one var to re-enable (same anycast IP/cert kept).
- Vars come from `TF_VAR_*` env on the apply step (`terraform.tfvars` is gitignored).

## Rules learned the hard way (the deploy was red for 40+ builds from these)

- **Cloud Build substitutions:** every shell `$var` inside a `- |` step script must be `$$`-escaped, or Cloud Build tries to resolve it as a build substitution at submit and hard-fails the build. Only genuine substitutions stay single-`$` (`$COMMIT_SHA`, `$SHORT_SHA`, `${_...}`). This applies to shell-`#`-comment lines inside a block scalar too.
- **`for_each` over an apply-time-unknown value fails to plan.** Use a MAP with STATIC keys; put the unknown (a created resource's id) on the value side only.
- **`prevent_destroy`** guards the anycast IPs + the relay-identity secret; a destroy+recreate there hands out a new public IP or loses the seed. They are not count-gated, so this does not fight the enable/disable cycle.
- **The deploy gate needs a token.** The repo is PRIVATE, so `require-ci` polls the check-runs API with a Secret Manager token (`hop-ci-readtoken`, resource-scoped IAM so the build SA still cannot read the relay seed). The `BRANCH_PROTECTION_TOKEN` PAT arms the branch-protection drift-detector.

## Verify before merging infra

`tofu -chdir=infra fmt -check -recursive` + `tofu -chdir=infra init -backend=false && tofu validate`.
Preview a real apply with a local `tofu plan` using the build's exact `TF_VAR_*` (needs ADC). A green
first apply after a red streak shows the stale `secretmanager.admin` grant being removed (infra-02).
`tools/check-required-checks.sh` keeps the CI job names, the gate allowlist, and branch protection in sync.
