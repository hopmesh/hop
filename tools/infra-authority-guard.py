#!/usr/bin/env python3
"""Enforce the bootstrap/runtime authority boundary for production deploys."""

import argparse
import re
import sys
from pathlib import Path


EXPECTED_BUILD_PROJECT_ROLES = {
    "roles/logging.logWriter",
}
EXPECTED_DEPLOY_PROJECT_ROLES = {
    "roles/certificatemanager.editor",
    "roles/cloudbuild.builds.viewer",
    "roles/compute.loadBalancerAdmin",
    "roles/dns.admin",
    "roles/logging.configWriter",
    "roles/logging.logWriter",
    "roles/monitoring.editor",
    "roles/run.developer",
    "roles/serviceusage.serviceUsageConsumer",
}
EXPECTED_RUNTIME_PROVIDER_SOURCES = {
    "hashicorp/google",
    "hashicorp/google-beta",
    "hashicorp/time",
}
EXPECTED_RUNTIME_PROVIDER_BLOCKS = ["google", "google-beta"]
ALLOWED_RUNTIME_DATA_SOURCES = {
    "google_compute_regions",
    "google_project",
}
FORBIDDEN_RUNTIME_RESOURCE_PREFIXES = (
    "google_artifact_registry_repository",
    "google_cloudbuild_trigger",
    "google_cloudbuildv2_repository",
    "google_firestore_database",
    "google_firestore_field",
    "google_iam_deny_policy",
    "google_iam_workload_identity_pool",
    "google_project_iam",
    "google_project_service",
    "google_secret_manager_secret",
    "google_service_account",
    "google_storage_bucket_iam",
)
FORBIDDEN_DEPLOY_ROLES = {
    "roles/editor",
    "roles/owner",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.securityAdmin",
    "roles/run.admin",
    "roles/storage.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/cloudbuild.builds.editor",
}


def resource_types(text):
    return re.findall(r'^\s*resource\s+"([^"]+)"\s+"[^"]+"\s*\{', text, re.MULTILINE)


def local_role_set(text, name):
    match = re.search(rf"\b{name}\s*=\s*toset\(\[(.*?)\]\)", text, re.DOTALL)
    if not match:
        return None
    return re.findall(r'"(roles/[^"\s]+)"', match.group(1))


def resource_block(text, resource_type, resource_name):
    marker = f'resource "{resource_type}" "{resource_name}"'
    start = text.find(marker)
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0:
        return None
    depth = 0
    quoted = False
    escaped = False
    for index in range(brace, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    return None


def check(root):
    root = Path(root)
    errors = []
    runtime_files = sorted(path for path in (root / "infra").glob("*.tf") if path.is_file())
    if not runtime_files:
        return ["runtime Terraform root is missing"]
    alternative_config_files = sorted(
        path.name
        for path in (root / "infra").iterdir()
        if path.is_file() and path.name.endswith((".tf.json", ".tofu", ".tofu.json"))
    )
    if alternative_config_files:
        errors.append(f"runtime root contains uninspected alternative OpenTofu configuration: {alternative_config_files}")
    runtime = "\n".join(path.read_text(encoding="utf-8") for path in runtime_files)
    auto_var_files = sorted(
        path.name
        for path in (root / "infra").iterdir()
        if path.is_file()
        and (
            path.name in {"terraform.tfvars", "terraform.tfvars.json"}
            or path.name.endswith(".auto.tfvars")
            or path.name.endswith(".auto.tfvars.json")
        )
    )
    if auto_var_files:
        errors.append(f"runtime root contains automatically loaded variable files: {auto_var_files}")
    override_files = sorted(
        path.name
        for path in (root / "infra").iterdir()
        if path.is_file()
        and (
            path.name in {"override.tf", "override.tofu", "override.tf.json", "override.tofu.json"}
            or path.name.endswith(("_override.tf", "_override.tofu", "_override.tf.json", "_override.tofu.json"))
        )
    )
    if override_files:
        errors.append(f"runtime root contains OpenTofu override files: {override_files}")
    resource_declarations = re.findall(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', runtime, re.MULTILINE)
    parsed_resources = [resource_type for resource_type, _ in resource_declarations]
    if len(resource_declarations) != len(re.findall(r'^\s*resource\b', runtime, re.MULTILINE)):
        errors.append("runtime root contains an unparseable resource declaration")
    for resource_type in parsed_resources:
        if not resource_type.startswith("google_") and resource_type != "time_sleep":
            errors.append(f"runtime root uses an untrusted provider resource: {resource_type}")
        if resource_type.startswith(FORBIDDEN_RUNTIME_RESOURCE_PREFIXES):
            errors.append(f"runtime root contains bootstrap authority resource: {resource_type}")
        if re.match(r"google_cloud_run.*_iam_", resource_type):
            errors.append(f"runtime root contains Cloud Run IAM mutation: {resource_type}")
    for forbidden in ("SHORT_SHA", ":latest", "deploy_image_sha", "substr(var.deployment_source_sha"):
        if forbidden in runtime:
            errors.append(f"runtime root contains mutable deployment input: {forbidden}")
    if not re.search(r'variable\s+"relay_image".*?@sha256:', runtime, re.DOTALL):
        errors.append("runtime relay_image does not require a sha256 digest")
    if not re.search(r'variable\s+"example_image".*?@sha256:', runtime, re.DOTALL):
        errors.append("runtime example_image does not require a sha256 digest")
    data_sources = re.findall(r'^\s*data\s+"([^"]+)"\s+"[^"]+"\s*\{', runtime, re.MULTILINE)
    if len(data_sources) != len(re.findall(r'^\s*data\b', runtime, re.MULTILINE)) or not set(data_sources) <= ALLOWED_RUNTIME_DATA_SOURCES:
        errors.append(f"runtime data sources drifted: {data_sources}")
    if re.search(r'^\s*ephemeral\b', runtime, re.MULTILINE):
        errors.append("runtime root contains an uninspected ephemeral provider resource")
    if re.search(r'\b(?:cloud|encryption)\s*\{', runtime):
        errors.append("runtime root replaces or extends trusted state handling")
    provider_sources = set(re.findall(r'\bsource\s*=\s*"([^"]+)"', runtime))
    if provider_sources != EXPECTED_RUNTIME_PROVIDER_SOURCES:
        errors.append(f"runtime provider sources drifted: {sorted(provider_sources)}")
    provider_blocks = re.findall(r'^\s*provider\s+"([^"]+)"\s*\{', runtime, re.MULTILINE)
    if provider_blocks != EXPECTED_RUNTIME_PROVIDER_BLOCKS:
        errors.append(f"runtime provider configuration drifted: {provider_blocks}")
    providers_path = root / "infra" / "providers.tf"
    providers = providers_path.read_text(encoding="utf-8") if providers_path.is_file() else ""
    if not re.fullmatch(
        r'\s*provider\s+"google"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*provider\s+"google-beta"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*',
        providers,
    ):
        errors.append("runtime Google provider configuration contains untrusted credentials, impersonation, aliases, or endpoints")
    backends = re.findall(r'^\s*backend\s+"([^"]+)"\s*\{', runtime, re.MULTILINE)
    if backends != ["gcs"]:
        errors.append(f"runtime backend drifted: {backends}")
    versions_path = root / "infra" / "versions.tf"
    versions = versions_path.read_text(encoding="utf-8") if versions_path.is_file() else ""
    backend = re.search(r'backend\s+"gcs"\s*\{([^{}]*)\}', versions, re.DOTALL)
    backend_keys = re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=', backend.group(1), re.MULTILINE) if backend else []
    if len(backend_keys) != 2 or set(backend_keys) != {"bucket", "prefix"}:
        errors.append("runtime GCS backend may configure only the bootstrap-overridden bucket and prefix")
    cloud_run_declarations = [
        declaration for declaration in resource_declarations if declaration[0].startswith("google_cloud_run")
    ]
    if len(cloud_run_declarations) != 2 or set(cloud_run_declarations) != {
        ("google_cloud_run_v2_service", "relay"),
        ("google_cloud_run_v2_service", "example"),
    }:
        errors.append(f"runtime Cloud Run executable resources drifted: {sorted(cloud_run_declarations)}")
    image_bindings = [value.strip() for value in re.findall(r'^\s*image\s*=\s*([^\n#]+)', runtime, re.MULTILINE)]
    if len(image_bindings) != 2 or set(image_bindings) != {"var.relay_image", "var.example_image"}:
        errors.append(f"runtime image bindings drifted: {image_bindings}")
    service_accounts = [
        value.strip() for value in re.findall(r'^\s*service_account\s*=\s*([^\n#]+)', runtime, re.MULTILINE)
    ]
    if len(service_accounts) != 2 or set(service_accounts) != {
        "local.relay_service_account",
        "local.example_service_account",
    }:
        errors.append(f"runtime executable identities drifted: {service_accounts}")
    example_path = root / "infra" / "example.tf"
    relay_path = root / "infra" / "cloud_run.tf"
    if example_path.is_file():
        example = example_path.read_text(encoding="utf-8")
        if "service_account = local.example_service_account" not in example or "local.relay_service_account" in example:
            errors.append("public example does not use only its dedicated runtime identity")
        if 'secret = "hop-example-identity"' not in example or "hop-relay-identity" in example:
            errors.append("public example does not use only its dedicated identity secret")
        if "version = var.example_identity_version" not in example:
            errors.append("public example identity version is not bootstrap pinned")
    if relay_path.is_file():
        relay = relay_path.read_text(encoding="utf-8")
        if "service_account = local.relay_service_account" not in relay:
            errors.append("relay service does not use its dedicated runtime identity")
    identities_path = root / "infra" / "data.tf"
    identities = identities_path.read_text(encoding="utf-8") if identities_path.is_file() else ""
    relay_identities = re.findall(r'^\s*relay_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    example_identities = re.findall(r'^\s*example_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    if relay_identities != ["hop-relay@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"relay runtime identity local drifted: {relay_identities}")
    if example_identities != ["hop-example@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"example runtime identity local drifted: {example_identities}")

    iam_path = root / "infra" / "bootstrap" / "iam.tf"
    triggers_path = root / "infra" / "bootstrap" / "triggers.tf"
    if not iam_path.is_file() or not triggers_path.is_file():
        errors.append("bootstrap IAM or trigger definition is missing")
        return errors
    iam = iam_path.read_text(encoding="utf-8")
    triggers = triggers_path.read_text(encoding="utf-8")
    for script_name in ("require-ci-verdict.py", "deploy-provenance.py"):
        script_path = root / "tools" / script_name
        if not script_path.is_file():
            errors.append(f"trusted inline script is missing: {script_name}")
        elif "$" in script_path.read_text(encoding="utf-8"):
            errors.append(f"trusted inline script contains a Cloud Build substitution token: {script_name}")

    build_roles = local_role_set(iam, "build_project_roles")
    deploy_roles = local_role_set(iam, "deploy_project_roles")
    if build_roles is None or set(build_roles) != EXPECTED_BUILD_PROJECT_ROLES or len(build_roles) != len(set(build_roles)):
        errors.append(f"build project roles drifted: {build_roles}")
    if deploy_roles is None or set(deploy_roles) != EXPECTED_DEPLOY_PROJECT_ROLES or len(deploy_roles) != len(set(deploy_roles)):
        errors.append(f"deploy project roles drifted: {deploy_roles}")
    for role in FORBIDDEN_DEPLOY_ROLES:
        if role in (deploy_roles or []):
            errors.append(f"deploy identity has forbidden role: {role}")

    legacy_role = resource_block(iam, "google_project_iam_custom_role", "build_secrets")
    if not legacy_role:
        errors.append("legacy secret custom role is not pinned in bootstrap")
    else:
        for permission in ("secretmanager.secrets.setIamPolicy", "secretmanager.versions.access"):
            if permission in legacy_role:
                errors.append(f"legacy secret role has forbidden permission: {permission}")

    relay_access = resource_block(iam, "google_secret_manager_secret_iam_member", "relay_identity")
    example_access = resource_block(iam, "google_secret_manager_secret_iam_member", "example_identity")
    if not relay_access or "google_service_account.relay.email" not in relay_access:
        errors.append("relay seed accessor is not the relay runtime identity")
    if relay_access and ("google_service_account.build.email" in relay_access or "google_service_account.deploy.email" in relay_access):
        errors.append("build or deploy identity can read the relay seed")
    if not example_access or "google_service_account.example.email" not in example_access:
        errors.append("example secret accessor is not the dedicated example identity")
    deny = resource_block(iam, "google_iam_deny_policy", "relay_seed")
    if not deny or "principalSet://goog/public:all" not in deny or "google_service_account.relay.email" not in deny:
        errors.append("relay seed deny policy does not deny all except the relay runtime")
    if deny and "secretmanager.googleapis.com/versions.access" not in deny:
        errors.append("relay seed deny policy does not deny version access")
    deploy_state = resource_block(iam, "google_storage_bucket_iam_member", "deploy_state")
    if not deploy_state or "objects/${var.runtime_state_prefix}/" not in deploy_state:
        errors.append("deploy state access is not scoped to the trusted runtime prefix")
    deploy_lease = resource_block(iam, "google_storage_bucket_iam_member", "deploy_lease")
    if not deploy_lease or "objects/${local.lease_object}'" not in deploy_lease:
        errors.append("deploy lease access is not scoped to the single global lease")

    source = resource_block(triggers, "google_cloudbuild_trigger", "source")
    deploy = resource_block(triggers, "google_cloudbuild_trigger", "deploy")
    if not source or not deploy:
        errors.append("trusted source or deploy trigger is missing")
    else:
        if "filename" in source or "filename" in deploy:
            errors.append("active trigger loads a build definition from candidate source")
        if "service_account = google_service_account.build.id" not in source:
            errors.append("source trigger does not use the low-privilege build identity")
        if "service_account = google_service_account.deploy.id" not in deploy:
            errors.append("deploy trigger does not use the separate deploy identity")
        if not re.search(r"approval_config\s*\{\s*approval_required\s*=\s*true", deploy, re.DOTALL):
            errors.append("deploy trigger does not require control-plane approval")
        if "script     = local.ci_gate_script" not in source or "script     = local.ci_gate_script" not in deploy:
            errors.append("trusted CI gate is not embedded in both control-plane triggers")
        if "AUTHORITY_PROFILE=build" not in source or 'wait_for = ["authority-preflight"]' not in source:
            errors.append("candidate source can run before the effective-authority preflight")
        if "CONTROL_BUCKET=" not in source or "RUNTIME_STATE_BUCKET=" not in source:
            errors.append("build authority preflight does not inspect control and state buckets")
        if "BUILD_REPOSITORY_RESOURCE=" not in source or "BUILD_REPOSITORY_RESOURCE=" not in deploy:
            errors.append("effective-authority preflight does not inspect source repository token access")
        if "AUTHORITY_PROFILE=deploy" not in deploy:
            errors.append("deploy trigger is missing its effective-authority preflight")
        for required in ("verify-provenance", "init-runtime", "acquire-deploy-lease", "main-after-lease", "main-before-apply", "renew-deploy-lease"):
            if required not in deploy:
                errors.append(f"deploy trigger is missing trusted stage: {required}")
        if "DEPLOY_BACKEND_CONFIG_FILE=/workspace/runtime-backend.tfbackend" not in deploy:
            errors.append("deploy verifier does not write the trusted backend config")
        if not re.search(
            r'id\s*=\s*"verify-provenance"\s+wait_for\s*=\s*\["require-ci"\]\s+script\s*=\s*local\.provenance_script\s+secret_env\s*=\s*\["GH_TOKEN"\]',
            deploy,
        ):
            errors.append("deploy provenance verifier cannot fetch the exact GitHub source")
        if "tofu init -input=false -backend-config=/workspace/runtime-backend.tfbackend" not in deploy:
            errors.append("runtime init does not consume the trusted backend config")
    for forbidden in ("SHORT_SHA", ":latest", "--all-tags"):
        if forbidden in triggers:
            errors.append(f"trusted trigger contains mutable image behavior: {forbidden}")
    images = re.findall(r'"([^"\s]+@sha256:[0-9a-f]{64})"', triggers)
    if len(set(images)) < 3:
        errors.append("trusted trigger images are not all pinned by digest")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    errors = check(Path(args.root).resolve())
    for error in errors:
        print(f"ERROR: {error}")
    if errors:
        raise SystemExit(1)
    print("infra authority guard passed")


if __name__ == "__main__":
    main()
