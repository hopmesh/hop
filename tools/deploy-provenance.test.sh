#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root/tools/deploy-provenance.py" <<'PY'
import copy
import datetime as dt
import importlib.util
import io
import pathlib
import shutil
import sys
import tempfile
import tarfile

spec = importlib.util.spec_from_file_location("provenance", sys.argv[1])
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
ROOT = pathlib.Path(sys.argv[1]).resolve().parents[1]

SHA = "a" * 40
BUILD_ID = "11111111-1111-1111-1111-111111111111"
PROJECT = "hop-mesh"
BUILDER = "hop-cloudbuild@hop-mesh.iam.gserviceaccount.com"
DEPLOYER = "hop-deploy@hop-mesh.iam.gserviceaccount.com"
KEY = "projects/hop-mesh/locations/us-central1/keyRings/hop-provenance/cryptoKeys/build-manifest/cryptoKeyVersions/1"
RELAY = "us-central1-docker.pkg.dev/hop-mesh/hop/hop-relayd"
EXAMPLE = "us-central1-docker.pkg.dev/hop-mesh/hop/hop-example"
DIGEST_A = "sha256:" + "1" * 64
DIGEST_B = "sha256:" + "2" * 64


def contract():
    return {
        "schema": p.BOOTSTRAP_SCHEMA,
        "project_id": PROJECT,
        "repository": "hopmesh/hop",
        "repository_id": 10,
        "actions_app_id": 15368,
        "ci_workflow_sha256": "4" * 64,
        "source_trigger_id": "trusted-trigger-id",
        "source_trigger_name": "hop-source-build",
        "builder_identity": BUILDER,
        "deploy_identity": DEPLOYER,
        "deployment_environment": "production",
        "kms_key_version": KEY,
        "provenance_bucket": "hop-deploy-control",
        "lease_object": "leases/global.json",
        "lease_ttl_seconds": 7200,
        "runtime_state_bucket": "hop-mesh-tfstate",
        "runtime_state_prefix": "relay-fleet",
        "image_repositories": {"relay": RELAY, "example": EXAMPLE},
    }


def manifest():
    return {
        "schema": p.SCHEMA,
        "source_sha": SHA,
        "repository": "hopmesh/hop",
        "repository_id": 10,
        "builder_identity": BUILDER,
        "build_id": BUILD_ID,
        "source_trigger_name": "hop-source-build",
        "deployment_environment": "production",
        "kms_key_version": KEY,
        "runtime_archive": {"object": f"provenance/{BUILD_ID}/runtime.tar.gz", "sha256": "3" * 64},
        "images": {
            "relay": {"tag": f"{RELAY}:{SHA}", "digest": f"{RELAY}@{DIGEST_A}"},
            "example": {"tag": f"{EXAMPLE}:{SHA}", "digest": f"{EXAMPLE}@{DIGEST_B}"},
        },
    }


def build():
    return {
        "id": BUILD_ID,
        "projectId": PROJECT,
        "status": "SUCCESS",
        "finishTime": "2026-07-16T00:10:00Z",
        "buildTriggerId": "trusted-trigger-id",
        "serviceAccount": f"projects/{PROJECT}/serviceAccounts/{BUILDER}",
        "substitutions": {
            "COMMIT_SHA": SHA,
            "REVISION_ID": SHA,
            "BRANCH_NAME": "main",
            "_TRUSTED_REPOSITORY": "hopmesh/hop",
            "_TRUSTED_REPOSITORY_ID": "10",
            "_TRUSTED_CI_SHA256": "4" * 64,
            "_TRUSTED_CONFIG_VERSION": "v2",
        },
        "images": [f"{RELAY}:{SHA}", f"{EXAMPLE}:{SHA}"],
        "results": {"images": [
            {"name": f"{RELAY}:{SHA}", "digest": DIGEST_A},
            {"name": f"{EXAMPLE}:{SHA}", "digest": DIGEST_B},
        ]},
        "options": {"requestedVerifyOption": "VERIFIED", "sourceProvenanceHash": ["SHA256"]},
        "sourceProvenance": {"resolvedConnectedRepository": {
            "revision": SHA,
            "repository": "projects/hop-mesh/locations/us-central1/connections/hop-github/repositories/hop",
        }},
    }


def expect_ok(name, b=None, m=None, c=None, sha=SHA):
    result = p.validate_build_and_manifest(b or build(), m or manifest(), c or contract(), sha, BUILD_ID)
    assert result["relay_image"].endswith(DIGEST_A)
    print(f"ok [{name}]")


def expect_bad(name, mutate_build=None, mutate_manifest=None, mutate_contract=None, sha=SHA):
    b, m, c = build(), manifest(), contract()
    if mutate_build:
        mutate_build(b)
    if mutate_manifest:
        mutate_manifest(m)
    if mutate_contract:
        mutate_contract(c)
    try:
        p.validate_build_and_manifest(b, m, c, sha, BUILD_ID)
    except p.ProvenanceError as error:
        print(f"ok [{name}] rejected: {error}")
        return
    raise AssertionError(f"{name} was accepted")


expect_ok("matching_manifest")
expect_bad("manifest_sha_mismatch", mutate_manifest=lambda m: m.__setitem__("source_sha", "b" * 40))
expect_bad("manifest_build_mismatch", mutate_manifest=lambda m: m.__setitem__("build_id", "22222222-2222-2222-2222-222222222222"))
expect_bad("builder_mismatch", mutate_manifest=lambda m: m.__setitem__("builder_identity", "attacker@example.com"))
expect_bad("repository_mismatch", mutate_manifest=lambda m: m.__setitem__("repository_id", 99))
expect_bad("result_digest_mismatch", mutate_build=lambda b: b["results"]["images"][0].__setitem__("digest", "sha256:" + "9" * 64))
expect_bad("mutable_latest_tag", mutate_manifest=lambda m: m["images"]["relay"].__setitem__("tag", f"{RELAY}:latest"))
expect_bad("short_sha_tag", mutate_manifest=lambda m: m["images"]["relay"].__setitem__("tag", f"{RELAY}:{SHA[:7]}"))
expect_bad("mutable_deploy_reference", mutate_manifest=lambda m: m["images"]["relay"].__setitem__("digest", f"{RELAY}:{SHA}"))
expect_bad("wrong_source_trigger", mutate_build=lambda b: b.__setitem__("buildTriggerId", "attacker-trigger"))
expect_bad("wrong_build_service_account", mutate_build=lambda b: b.__setitem__("serviceAccount", "projects/hop-mesh/serviceAccounts/attacker@example.com"))
expect_bad("stale_bootstrap_schema", mutate_contract=lambda c: c.__setitem__("schema", "hop.bootstrap.v1"))
expect_bad("invalid_bootstrap_ci_digest", mutate_contract=lambda c: c.__setitem__("ci_workflow_sha256", "4" * 63))
expect_bad("source_build_ci_digest_mismatch", mutate_build=lambda b: b["substitutions"].__setitem__("_TRUSTED_CI_SHA256", "5" * 64))
expect_bad("stale_trusted_config_version", mutate_build=lambda b: b["substitutions"].__setitem__("_TRUSTED_CONFIG_VERSION", "v1"))
expect_bad("build_not_success", mutate_build=lambda b: b.__setitem__("status", "WORKING"))
expect_bad("missing_verified_provenance", mutate_build=lambda b: b["options"].__setitem__("requestedVerifyOption", "NOT_VERIFIED"))
expect_bad("wrong_source_provenance_sha", mutate_build=lambda b: b["sourceProvenance"]["resolvedConnectedRepository"].__setitem__("revision", "b" * 40))
expect_bad("ambiguous_source_provenance", mutate_build=lambda b: b["sourceProvenance"].__setitem__("resolvedGitSource", {"revision": "b" * 40}))
expect_bad("unrecognized_source_provenance", mutate_build=lambda b: b.__setitem__("sourceProvenance", {"untrustedSource": {"revision": SHA}}))
expect_bad("empty_environment", mutate_contract=lambda c: c.__setitem__("deployment_environment", ""))
expect_bad("empty_runtime_state_bucket", mutate_contract=lambda c: c.__setitem__("runtime_state_bucket", ""))
expect_bad("control_bucket_reused_for_state", mutate_contract=lambda c: c.__setitem__("runtime_state_bucket", c["provenance_bucket"]))
expect_bad("empty_runtime_state_prefix", mutate_contract=lambda c: c.__setitem__("runtime_state_prefix", ""))
expect_bad("bootstrap_state_prefix_reused", mutate_contract=lambda c: c.__setitem__("runtime_state_prefix", "bootstrap"))
expect_bad("lease_shorter_than_build_timeout", mutate_contract=lambda c: c.__setitem__("lease_ttl_seconds", 3600))
for bad_sha in ("", SHA[:7], "A" * 40, SHA + "a"):
    expect_bad(f"full_sha_{len(bad_sha)}", sha=bad_sha)

assert p.render_backend_config(contract()) == 'bucket = "hop-mesh-tfstate"\nprefix = "relay-fleet"\n'
print("ok [trusted_backend_config]")

signing_input = p.canonical_json(manifest())
original_run = p.run
def fake_sign(command, **_kwargs):
    input_path = pathlib.Path(command[command.index("--input-file") + 1])
    signature_path = pathlib.Path(command[command.index("--signature-file") + 1])
    assert input_path.read_bytes() == signing_input
    signature_path.write_bytes(b"kms-signature")
    return ""
try:
    p.run = fake_sign
    assert p.sign_manifest(signing_input, KEY) == b"kms-signature"
finally:
    p.run = original_run
print("ok [kms_signs_manifest_not_prehashed_digest]")

with tempfile.TemporaryDirectory() as directory:
    crypto = pathlib.Path(directory)
    private_key = crypto / "private.pem"
    public_key = crypto / "public.pem"
    signature = crypto / "manifest.sig"
    manifest_path = crypto / "manifest.json"
    manifest_path.write_bytes(signing_input)
    p.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(private_key)])
    p.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)])
    p.run(["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature), str(manifest_path)])
    p.verify_signature_with_pem(signing_input, signature.read_bytes(), public_key.read_text(encoding="utf-8"))
print("ok [manifest_signature_round_trip]")

runtime_archive = p.runtime_archive(ROOT / "infra")
for candidate_config in ("evil.tf.json", "evil.tofu", "evil.auto.tfvars"):
    assert p.runtime_path_included(pathlib.PurePosixPath(candidate_config)), f"candidate config was silently omitted: {candidate_config}"
print("ok [candidate_configuration_reaches_policy]")
with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "runtime"
    p.safe_extract(runtime_archive, runtime)
    source_files = p.extracted_runtime_files(runtime)
    source_buffer = io.BytesIO()
    with tarfile.open(fileobj=source_buffer, mode="w:gz") as source_tar:
        for path, content in source_files.items():
            info = tarfile.TarInfo(f"hop-source/infra/{path}")
            info.size = len(content)
            source_tar.addfile(info, io.BytesIO(content))
    source_archive = source_buffer.getvalue()
    p.validate_runtime_source(runtime, source_archive)
    print("ok [runtime_archive_matches_exact_github_source]")
    auto_vars = runtime / "evil.auto.tfvars"
    auto_vars.write_text("relays_enabled = true\n", encoding="utf-8")
    try:
        p.validate_runtime_source(runtime, source_archive)
    except p.ProvenanceError:
        print("ok [automatic_variable_override_rejected]")
    else:
        raise AssertionError("an automatically loaded variable override was accepted")
    auto_vars.unlink()
    first_path = next(iter(source_files))
    (runtime / first_path).write_bytes(b"forged")
    try:
        p.validate_runtime_source(runtime, source_archive)
    except p.ProvenanceError:
        print("ok [forged_runtime_archive_rejected]")
    else:
        raise AssertionError("runtime content not present in GitHub source was accepted")

now = dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc)
metadata = {"generation": "7", "timeCreated": "2026-07-16T00:00:00Z"}
live = p.lease_document("newer", "b" * 40, "4" * 64, now, now + dt.timedelta(minutes=30))
expired = p.lease_document("older", SHA, "3" * 64, now - dt.timedelta(hours=3), now - dt.timedelta(hours=1))
owned = p.lease_document("current", SHA, "3" * 64, now - dt.timedelta(minutes=1), now + dt.timedelta(minutes=30))
unbounded = p.lease_document("newer", SHA, "3" * 64, now, now + dt.timedelta(days=365))
assert p.lease_decision(live, metadata, now, 7200, "current")[0] == "contended"
assert p.lease_decision(expired, metadata, now, 7200, "current")[0] == "recover-expired"
assert p.lease_decision(owned, metadata, now, 7200, "current")[0] == "owned"
assert p.lease_decision(unbounded, metadata, now, 7200, "current")[0] == "contended-malformed"
assert p.lease_decision(unbounded, metadata, now + dt.timedelta(hours=3), 7200, "current")[0] == "recover-malformed"
assert p.lease_decision(None, metadata, now + dt.timedelta(hours=3), 7200, "current")[0] == "recover-malformed"
assert p.lease_decision(None, metadata, now + dt.timedelta(minutes=10), 7200, "current")[0] == "contended-malformed"
print("ok [lease_contention_expiry_and_recovery]")

p.validate_runtime_policy(ROOT / "infra")
print("ok [trusted_runtime_policy]")
with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    example_path = runtime / "example.tf"
    example_path.write_text(
        example_path.read_text(encoding="utf-8").replace(
            "service_account = local.example_service_account",
            "service_account = local.relay_service_account",
            1,
        ),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_relay_reuse]")
    else:
        raise AssertionError("trusted runtime policy accepted relay identity reuse")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    versions_path = runtime / "versions.tf"
    versions_path.write_text(
        versions_path.read_text(encoding="utf-8").replace('backend "gcs"', 'backend "local"', 1),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_backend_retargeting]")
    else:
        raise AssertionError("trusted runtime policy accepted a non-GCS backend")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil.tf").write_text('  resource "google_project_iam_member" "evil" {}\n', encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_indented_authority]")
    else:
        raise AssertionError("trusted runtime policy accepted an indented authority resource")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    versions_path = runtime / "versions.tf"
    versions_path.write_text(
        versions_path.read_text(encoding="utf-8").replace("hashicorp/google", "attacker/google", 1),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_provider_retargeting]")
    else:
        raise AssertionError("trusted runtime policy accepted a retargeted provider")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    providers_path = runtime / "providers.tf"
    providers_path.write_text(
        providers_path.read_text(encoding="utf-8").replace(
            "project = var.project_id",
            'project = var.project_id\n  storage_custom_endpoint = "https://attacker.example"',
            1,
        ),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_provider_custom_endpoint]")
    else:
        raise AssertionError("trusted runtime policy accepted a provider credential endpoint")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    versions_path = runtime / "versions.tf"
    versions_path.write_text(
        versions_path.read_text(encoding="utf-8").replace(
            'prefix = "relay-fleet"',
            'prefix = "relay-fleet"\n    storage_custom_endpoint = "https://attacker.example"',
            1,
        ),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_backend_custom_endpoint]")
    else:
        raise AssertionError("trusted runtime policy accepted a backend credential endpoint")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    relay_path = runtime / "cloud_run.tf"
    relay_path.write_text(
        relay_path.read_text(encoding="utf-8").replace(
            "image = var.relay_image",
            'image = "us-central1-docker.pkg.dev/attacker/repo/image@sha256:' + "9" * 64 + '"',
            1,
        ),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_unsigned_runtime_image]")
    else:
        raise AssertionError("trusted runtime policy accepted an image outside signed provenance")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil.tf").write_text('resource "google_cloud_run_v2_job" "evil" {}\n', encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_extra_executable]")
    else:
        raise AssertionError("trusted runtime policy accepted an extra executable resource")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil.tofu").write_text('resource "google_project_iam_member" "evil" {}\n', encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_tofu_precedence_bypass]")
    else:
        raise AssertionError("trusted runtime policy accepted an uninspected .tofu file")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil_override.tf").write_text('locals { relay_service_account = "attacker@example.com" }\n', encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_override_merge]")
    else:
        raise AssertionError("trusted runtime policy accepted an OpenTofu override file")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    identities_path = runtime / "data.tf"
    identities_path.write_text(
        identities_path.read_text(encoding="utf-8").replace(
            'hop-relay@${var.project_id}.iam.gserviceaccount.com',
            "attacker@example.com",
            1,
        ),
        encoding="utf-8",
    )
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_identity_local_retargeting]")
    else:
        raise AssertionError("trusted runtime policy accepted a retargeted runtime identity local")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil.tf").write_text('ephemeral "google_service_account_access_token" "evil" {}\n', encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_ephemeral_provider_resource]")
    else:
        raise AssertionError("trusted runtime policy accepted an ephemeral provider resource")

with tempfile.TemporaryDirectory() as directory:
    runtime = pathlib.Path(directory) / "infra"
    shutil.copytree(ROOT / "infra", runtime, ignore=shutil.ignore_patterns("bootstrap", ".terraform"))
    (runtime / "evil.tf").write_text("terraform { encryption {} }\n", encoding="utf-8")
    try:
        p.validate_runtime_policy(runtime)
    except p.ProvenanceError:
        print("ok [trusted_runtime_policy_rejects_state_encryption_override]")
    else:
        raise AssertionError("trusted runtime policy accepted untrusted state encryption")

try:
    p.validate_forbidden_permissions(
        {"resourcemanager.projects.setIamPolicy"},
        p.BUILD_FORBIDDEN_PROJECT_PERMISSIONS,
        "build identity",
    )
except p.ProvenanceError:
    print("ok [effective_admin_permission_rejected]")
else:
    raise AssertionError("effective project IAM authority was accepted")

p.validate_exact_permissions({"iam.serviceAccounts.actAs"}, {"iam.serviceAccounts.actAs"}, "deploy relay identity")
try:
    p.validate_exact_permissions(
        {"iam.serviceAccounts.actAs", "iam.serviceAccounts.getAccessToken"},
        {"iam.serviceAccounts.actAs"},
        "deploy relay identity",
    )
except p.ProvenanceError:
    print("ok [effective_service_account_escalation_rejected]")
else:
    raise AssertionError("effective service account escalation was accepted")

original_urlopen = p.urllib.request.urlopen
def forbidden_urlopen(request, timeout):
    raise p.urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, io.BytesIO(b""))
try:
    p.urllib.request.urlopen = forbidden_urlopen
    p.require_denied_request("https://cloudbuild.googleapis.com/v2/repository:accessReadToken", "token", "repository token")
finally:
    p.urllib.request.urlopen = original_urlopen
print("ok [repository_token_denial_verified]")

class UnexpectedTokenResponse:
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return False
    def read(self, _size):
        return b"{"

try:
    p.urllib.request.urlopen = lambda _request, timeout: UnexpectedTokenResponse()
    try:
        p.require_denied_request("https://cloudbuild.googleapis.com/v2/repository:accessReadToken", "token", "repository token")
    except p.ProvenanceError:
        print("ok [effective_repository_token_access_rejected]")
    else:
        raise AssertionError("effective source repository token access was accepted")
finally:
    p.urllib.request.urlopen = original_urlopen

stale = manifest()
stale["source_sha"] = "b" * 40
try:
    p.validate_build_and_manifest(build(), stale, contract(), SHA, BUILD_ID)
except p.ProvenanceError:
    print("ok [stale_build_ordering_rejected]")
else:
    raise AssertionError("stale build ordering was accepted")
PY

echo "deploy provenance tests passed"
