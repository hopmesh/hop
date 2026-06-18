# Build & push the hop-relayd image, then apply the fleet.
PROJECT ?= hop-mesh
REGION  ?= us-central1
REPO    ?= $(REGION)-docker.pkg.dev/$(PROJECT)/hop
TAG     ?= $(shell git rev-parse --short HEAD)
IMAGE   ?= $(REPO)/hop-relayd:$(TAG)
ROOT    := $(shell git rev-parse --show-toplevel)

.PHONY: auth image push deploy plan apply seed-identity

auth:
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet

# Build for linux/amd64 (Cloud Run) regardless of host arch.
image:
	docker build --platform linux/amd64 \
	  -f $(ROOT)/crates/hop-relayd/Dockerfile \
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
	terraform plan -var relay_image=$(IMAGE)

apply: push
	terraform apply -var relay_image=$(IMAGE)
