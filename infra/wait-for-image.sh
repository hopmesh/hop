#!/usr/bin/env bash
# Spacelift before_apply hook: wait until THIS commit's relay image exists in Artifact
# Registry before applying. The GitHub push that triggered this run also triggered a
# Cloud Build that builds hop-relayd:$SHORT_SHA in parallel (~2-3 min); without this
# wait, an autodeploy could try to deploy a tag that isn't pushed yet and fail.
#
# Auth: the run already has the Spacelift OIDC token mounted; exchange it for a GCP
# token via STS + SA impersonation (no gcloud on the runner — curl + jq only).
set -euo pipefail

SHA="$(printf '%s' "${TF_VAR_spacelift_commit_sha:-}" | cut -c1-7)"
if [ -z "$SHA" ]; then echo "wait-for-image: no commit sha; skipping"; exit 0; fi

PROJECT_NUM=149923095434
AUD="//iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/spacelift/providers/spacelift-oidc"
SA="spacelift@hop-mesh.iam.gserviceaccount.com"
OIDC="$(cat /mnt/workspace/spacelift.oidc)"

fed="$(curl -sS -X POST https://sts.googleapis.com/v1/token \
  --data-urlencode "audience=${AUD}" \
  --data-urlencode "grantType=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requestedTokenType=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "scope=https://www.googleapis.com/auth/cloud-platform" \
  --data-urlencode "subjectTokenType=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "subjectToken=${OIDC}" | jq -r .access_token)"

sa_tok="$(curl -sS -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SA}:generateAccessToken" \
  -H "Authorization: Bearer ${fed}" -H "Content-Type: application/json" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' | jq -r .accessToken)"

echo "wait-for-image: waiting for hop-relayd:${SHA} ..."
for i in $(seq 1 60); do
  tags="$(curl -sS -H "Authorization: Bearer ${sa_tok}" \
    "https://us-central1-docker.pkg.dev/v2/hop-mesh/hop/hop-relayd/tags/list" || echo '{}')"
  if printf '%s' "$tags" | jq -e --arg t "$SHA" '(.tags // []) | index($t)' >/dev/null 2>&1; then
    echo "wait-for-image: hop-relayd:${SHA} is ready"; exit 0
  fi
  echo "  not ready yet (${i}/60)"; sleep 10
done
echo "wait-for-image: ERROR hop-relayd:${SHA} not in registry after 10 min"; exit 1
