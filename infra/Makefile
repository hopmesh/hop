# Manual image build helpers and a break-glass runtime plan/apply.
# Normal production deploys run in GitHub Actions: a merge to main that goes green triggers
# .github/workflows/runtime-deploy.yml, which builds + pushes the images and applies the runtime
# root via WIF as hop-deploy. infra/bootstrap is applied only by .github/workflows/bootstrap-apply.yml.
# There is deliberately no bootstrap target here.
#
# A local apply is dangerous, not merely unsupported: against GCS-backed state from a
# checkout that is behind, everything in remote state but absent from your local files
# is planned for DELETION. The apply target below therefore refuses unless you set
# LOCAL_APPLY_ACK=1 in the same command, and you should reconcile with origin/main
# first.
PROJECT ?= hop-mesh
REGION  ?= us-central1
REPO    ?= $(REGION)-docker.pkg.dev/$(PROJECT)/hop
TAG     ?= $(shell git rev-parse HEAD)
IMAGE   ?= $(REPO)/hop-relayd:$(TAG)
ROOT    := $(shell git rev-parse --show-toplevel)
TF      ?= tofu

.PHONY: auth image push plan apply seed-identity

auth:
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet

# Build for linux/amd64 (Cloud Run) regardless of host arch.
image:
	docker build --platform linux/amd64 \
	  -f $(ROOT)/services/hop-relayd/Dockerfile \
	  -t $(IMAGE) $(ROOT)

push: image
	docker push $(IMAGE)
	@echo "pushed $(IMAGE)"

# Seed the shared relay identity ONCE (32 random bytes). Idempotency is on you:
# running again rotates the relay's address.
seed-identity:
	head -c 32 /dev/urandom \
	  | gcloud secrets versions add hop-relay-identity --project $(PROJECT) --data-file=-

plan:
	@test -n "$(TFVARS)" || { echo "set TFVARS to a verified image-digest tfvars file" >&2; exit 1; }
	$(TF) plan -var-file="$(TFVARS)"

apply:
	@test -n "$(TFVARS)" || { echo "set TFVARS to a verified image-digest tfvars file" >&2; exit 1; }
	@test "$(LOCAL_APPLY_ACK)" = "1" || { \
	  echo "refusing: a local apply from a stale checkout plans a partial DESTROY." >&2; \
	  echo "normal path: push to main (runtime) or dispatch bootstrap-apply.yml (bootstrap)." >&2; \
	  echo "break glass: git fetch && git status against origin/main, then re-run with LOCAL_APPLY_ACK=1." >&2; \
	  exit 1; }
	$(TF) apply -var-file="$(TFVARS)"
