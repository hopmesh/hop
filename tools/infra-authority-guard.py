#!/usr/bin/env python3
"""Enforce the bootstrap/runtime authority boundary for production deploys."""

import argparse
import hashlib
import re
import sys
from pathlib import Path


EXPECTED_DEPLOY_PROJECT_ROLES = {
    "roles/bigquery.dataEditor",
    "roles/certificatemanager.editor",
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
    "google_secret_manager_secret_version",
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
EXPECTED_DRIFT_PERMISSIONS = {
    "bigquery.datasets.get",
    "bigquery.tables.get",
    "bigquery.tables.list",
    "certificatemanager.certmapentries.get",
    "certificatemanager.certmapentries.list",
    "certificatemanager.certmaps.get",
    "certificatemanager.certmaps.list",
    "certificatemanager.certs.get",
    "certificatemanager.certs.list",
    "certificatemanager.dnsauthorizations.get",
    "certificatemanager.dnsauthorizations.list",
    "certificatemanager.locations.get",
    "certificatemanager.locations.list",
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.backendServices.get",
    "compute.backendServices.list",
    "compute.forwardingRules.get",
    "compute.forwardingRules.list",
    "compute.networkEndpointGroups.get",
    "compute.networkEndpointGroups.list",
    "compute.regions.get",
    "compute.regions.list",
    "compute.sslCertificates.get",
    "compute.sslCertificates.list",
    "compute.targetHttpProxies.get",
    "compute.targetHttpProxies.list",
    "compute.targetHttpsProxies.get",
    "compute.targetHttpsProxies.list",
    "compute.urlMaps.get",
    "compute.urlMaps.list",
    "dns.changes.get",
    "dns.managedZones.get",
    "dns.projects.get",
    "dns.resourceRecordSets.list",
    "logging.buckets.get",
    "logging.buckets.list",
    "logging.exclusions.get",
    "logging.exclusions.list",
    "logging.logMetrics.get",
    "logging.logMetrics.list",
    "logging.sinks.get",
    "logging.sinks.list",
    "monitoring.alertPolicies.get",
    "monitoring.alertPolicies.list",
    "monitoring.notificationChannels.get",
    "monitoring.notificationChannels.list",
    "resourcemanager.projects.get",
    "run.services.get",
    "run.services.list",
    "serviceusage.services.use",
}
LEGACY_CLEANUP_SHA256 = "5a0d2bb3ce619a904f32f0d347e0c9763c033b8197ff7f3e6ec969c0a95391b7"


def resource_types(text):
    return re.findall(r'^\s*resource\s+"([^"]+)"\s+"[^"]+"\s*\{', text, re.MULTILINE)


def local_role_set(text, name):
    clean = "\n".join(strip_hcl_comment(line) for line in text.splitlines())
    clean = strip_hcl_heredocs(clean)
    match = re.search(rf"^\s*{re.escape(name)}\s*=\s*toset\(\[(.*?)\]\)", clean, re.DOTALL | re.MULTILINE)
    if not match:
        return None
    return re.findall(r'"(roles/[^"\s]+)"', match.group(1))


def resource_block(text, resource_type, resource_name):
    return balanced_block(text, f'resource "{resource_type}" "{resource_name}"')


def variable_block(text, variable_name):
    return balanced_block(text, f'variable "{variable_name}"')

def strip_hcl_comment(line):
    """Blank line comments outside strings while preserving character offsets."""
    quoted = False
    escaped = False
    for index, char in enumerate(line):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "#" or line.startswith("//", index):
            return line[:index] + " " * (len(line) - index)
    return line


def top_level_assignment_pairs(block):
    """Return active single-line key/value assignments at depth one in an HCL block."""
    pairs = []
    depth = 0
    for raw_line in block.splitlines():
        line = strip_hcl_comment(raw_line)
        if depth == 1:
            match = re.fullmatch(r'\s*("[^"]+"|[A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.*?)\s*', line)
            if match:
                pairs.append((match.group(1), match.group(2)))
        quoted = False
        escaped = False
        for char in line:
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
    return pairs


def top_level_assignment_values(block, key):
    return [value for found_key, value in top_level_assignment_pairs(block) if found_key == key]
    return values


def has_exact_top_level_assignment(block, key, expected):
    return top_level_assignment_values(block, key) == [expected]


def balanced_block(text, marker):
    clean = "\n".join(strip_hcl_comment(line) for line in text.splitlines())
    match = re.search(rf'^\s*{re.escape(marker)}\s*\{{', clean, re.MULTILINE)
    if not match:
        return None
    start = match.start()
    brace = clean.find("{", match.start())
    depth = 0
    quoted = False
    escaped = False
    for index in range(brace, len(clean)):
        char = clean[index]
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

def top_level_block(block, marker):
    """Return one active nested block declared at depth one."""
    depth = 0
    offset = 0
    found = []
    for raw_line in block.splitlines(keepends=True):
        line = strip_hcl_comment(raw_line.rstrip("\r\n"))
        if depth == 1 and re.match(rf'^\s*{re.escape(marker)}\s*\{{', line):
            found.append(balanced_block(block[offset:], marker))
        quoted = False
        escaped = False
        for char in line:
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
        offset += len(raw_line)
    if len(found) != 1:
        return None
    return found[0]

def repeated_blocks(text, marker):
    blocks = []
    offset = 0
    while True:
        match = re.search(rf'^\s*{re.escape(marker)}\s*\{{', text[offset:], re.MULTILINE)
        if not match:
            return blocks
        start = offset + match.start()
        block = balanced_block(text[start:], marker)
        if block is None:
            return blocks
        blocks.append(block)
        offset = start + len(block)

def outside_hcl_strings(line):
    """Blank quoted string contents while preserving unquoted syntax offsets."""
    result = list(line)
    quoted = False
    escaped = False
    for index, char in enumerate(line):
        if quoted:
            result[index] = " "
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            result[index] = " "
    return "".join(result)

def strip_hcl_heredocs(text):
    """Blank heredoc bodies while preserving line and character offsets."""
    lines = text.splitlines(keepends=True)
    result = []
    terminator = None
    for line in lines:
        if terminator is not None:
            if re.fullmatch(rf'\s*{re.escape(terminator)}\s*(?:\r?\n)?', line):
                terminator = None
                result.append(" " * (len(line.rstrip("\r\n"))) + line[len(line.rstrip("\r\n")):])
            else:
                result.append(" " * (len(line.rstrip("\r\n"))) + line[len(line.rstrip("\r\n")):])
            continue
        active = outside_hcl_strings(strip_hcl_comment(line.rstrip("\r\n")))
        match = re.search(r'<<-?([A-Za-z_][A-Za-z0-9_]*)', active)
        result.append(line)
        if match:
            terminator = match.group(1)
    return "".join(result)


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
    runtime_parts = []
    for path in runtime_files:
        try:
            runtime_parts.append(path.read_text(encoding="utf-8"))
        except UnicodeDecodeError:
            errors.append(f"runtime configuration is not UTF-8 text: {path.relative_to(root)}")
    runtime_raw = "\n".join(runtime_parts)
    if any("/*" in outside_hcl_strings(strip_hcl_comment(line)) or "*/" in outside_hcl_strings(strip_hcl_comment(line)) for line in runtime_raw.splitlines()):
        errors.append("runtime root may not contain HCL block comments")
    runtime = strip_hcl_heredocs(runtime_raw)
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
    # Every executable image variable must REJECT anything that is not a digest. The check reads the
    # variable's own validation condition, not just "the block mentions @sha256 somewhere": the
    # error_message string mentions it too, so a looser search would pass a gutted condition.
    for image_variable in ("relay_image", "example_image", "accountd_image", "console_image"):
        block = variable_block(runtime, image_variable) or ""
        condition = re.search(r'^\s*condition\s*=\s*([^\n]+)$', block, re.MULTILINE)
        expression = condition.group(1) if condition else ""
        if "@sha256:[0-9a-f]{64}$" not in expression or f"var.{image_variable}" not in expression:
            errors.append(f"runtime {image_variable} does not require a sha256 digest")
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
    versions_raw = versions_path.read_text(encoding="utf-8") if versions_path.is_file() else ""
    versions = strip_hcl_heredocs(versions_raw)
    backend_block = balanced_block(versions, 'backend "gcs"') or ""
    backend_keys = [key for key, _ in top_level_assignment_pairs(backend_block)]
    if backend_keys != ["bucket", "prefix"]:
        errors.append("runtime GCS backend may configure only bucket and prefix")
    if not has_exact_top_level_assignment(backend_block, "bucket", '"hop-mesh-tfstate"') or not has_exact_top_level_assignment(backend_block, "prefix", '"relay-fleet"'):
        errors.append("runtime GCS backend values drifted")
    bootstrap_versions_path = root / "infra" / "bootstrap" / "versions.tf"
    bootstrap_versions_raw = bootstrap_versions_path.read_text(encoding="utf-8") if bootstrap_versions_path.is_file() else ""
    bootstrap_versions = strip_hcl_heredocs(bootstrap_versions_raw)
    bootstrap_backend = balanced_block(bootstrap_versions, 'backend "gcs"')
    cloud_run_declarations = [
        declaration for declaration in resource_declarations if declaration[0].startswith("google_cloud_run")
    ]
    if len(cloud_run_declarations) != 4 or set(cloud_run_declarations) != {
        ("google_cloud_run_v2_service", "relay"),
        ("google_cloud_run_v2_service", "example"),
        ("google_cloud_run_v2_service", "accountd"),
        ("google_cloud_run_v2_service", "console"),
    }:
        errors.append(f"runtime Cloud Run executable resources drifted: {sorted(cloud_run_declarations)}")
    image_bindings = [value.strip() for value in re.findall(r'^\s*image\s*=\s*([^\n#]+)', runtime, re.MULTILINE)]
    if len(image_bindings) != 4 or set(image_bindings) != {
        "var.relay_image",
        "var.example_image",
        "var.accountd_image",
        "var.console_image",
    }:
        errors.append(f"runtime image bindings drifted: {image_bindings}")
    service_accounts = [
        value.strip() for value in re.findall(r'^\s*service_account\s*=\s*([^\n#]+)', runtime, re.MULTILINE)
    ]
    if len(service_accounts) != 4 or set(service_accounts) != {
        "local.relay_service_account",
        "local.example_service_account",
        "local.accountd_service_account",
        "local.console_service_account",
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
    console_path = root / "infra" / "console.tf"
    if console_path.is_file():
        console = console_path.read_text(encoding="utf-8")
        for local_name in ("local.accountd_service_account", "local.console_service_account"):
            if f"service_account = {local_name}" not in console:
                errors.append(f"console services do not use {local_name}")
        for foreign in ("local.relay_service_account", "local.example_service_account"):
            if foreign in console:
                errors.append(f"console services reuse another service's identity: {foreign}")
    identities_path = root / "infra" / "data.tf"
    identities = identities_path.read_text(encoding="utf-8") if identities_path.is_file() else ""
    relay_identities = re.findall(r'^\s*relay_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    example_identities = re.findall(r'^\s*example_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    accountd_identities = re.findall(r'^\s*accountd_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    console_identities = re.findall(r'^\s*console_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    if relay_identities != ["hop-relay@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"relay runtime identity local drifted: {relay_identities}")
    if example_identities != ["hop-example@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"example runtime identity local drifted: {example_identities}")
    if accountd_identities != ["hop-accountd@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"accountd runtime identity local drifted: {accountd_identities}")
    if console_identities != ["hop-console@${var.project_id}.iam.gserviceaccount.com"]:
        errors.append(f"console runtime identity local drifted: {console_identities}")

    iam_path = root / "infra" / "bootstrap" / "iam.tf"
    if not iam_path.is_file():
        errors.append("bootstrap IAM definition is missing")
        return errors
    iam = iam_path.read_text(encoding="utf-8")

    deploy_roles = local_role_set(iam, "deploy_project_roles")
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

    relay_access = resource_block(iam, "google_secret_manager_secret_iam_member", "relay_identity") or ""
    example_access = resource_block(iam, "google_secret_manager_secret_iam_member", "example_identity") or ""
    seed_grants = (
        ("relay", relay_access, "google_secret_manager_secret.relay_identity.secret_id", '"serviceAccount:${google_service_account.relay.email}"'),
        ("example", example_access, "google_secret_manager_secret.example_identity.secret_id", '"serviceAccount:${google_service_account.example.email}"'),
    )
    for name, block, secret_id, member in seed_grants:
        if not has_exact_top_level_assignment(block, "secret_id", secret_id) or not has_exact_top_level_assignment(block, "role", '"roles/secretmanager.secretAccessor"') or not has_exact_top_level_assignment(block, "member", member):
            errors.append(f"{name} seed accessor grant drifted")
    # The relay seed's hard-deny policy was removed: GCP rejects roles/iam.denyAdmin at the
    # project level and forbids iam.denypolicies.* in custom roles, so the project-scoped
    # applier cannot manage a deny policy without an ORG-level grant. Protection now rests
    # on the allow side, asserted directly above: only the relay runtime holds the accessor,
    # and the deploy identity explicitly does not.
    deploy_state = resource_block(iam, "google_storage_bucket_iam_member", "deploy_state") or ""
    deploy_state_condition = top_level_block(deploy_state, "condition") or ""
    expected_runtime_state_condition = '"resource.name == \'projects/_/buckets/${var.runtime_state_bucket}\' || resource.name.startsWith(\'projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/\')"'
    if not has_exact_top_level_assignment(deploy_state, "bucket", "var.runtime_state_bucket") or not has_exact_top_level_assignment(deploy_state, "role", '"roles/storage.objectUser"') or not has_exact_top_level_assignment(deploy_state, "member", '"serviceAccount:${google_service_account.deploy.email}"') or not has_exact_top_level_assignment(deploy_state_condition, "expression", expected_runtime_state_condition):
        errors.append("deploy state access is not scoped exactly to the trusted runtime prefix")
    deploy_bucket_grants = []
    for name in [name for kind, name in re.findall(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', bootstrap if "bootstrap" in locals() else iam, re.MULTILINE) if kind == "google_storage_bucket_iam_member"]:
        block = resource_block(bootstrap if "bootstrap" in locals() else iam, "google_storage_bucket_iam_member", name) or ""
        if any("google_service_account.deploy.email" in value for value in top_level_assignment_values(block, "member")):
            deploy_bucket_grants.append(name)
    if deploy_bucket_grants and deploy_bucket_grants != ["deploy_state"]:
        errors.append(f"hop-deploy has additional storage grants: {sorted(deploy_bucket_grants)}")

    # Cutover invariants. These pin the complete state-owning surface, not only the four Cloud Run
    # addresses. An omitted load balancer, DNS, certificate, observability, or removed-state address
    # is a destruction just as surely as an omitted service.
    def load_manifest(relative, expected_count, expected_sha256):
        path = root / relative
        if not path.is_file() or path.is_symlink():
            errors.append(f"authority manifest is missing or not a regular file: {relative}")
            return []
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected_sha256:
            errors.append(f"authority manifest content drifted: {relative}")
        rows = raw.decode("utf-8").splitlines()
        if rows != sorted(set(rows)) or len(rows) != expected_count:
            errors.append(f"authority manifest {relative} must contain {expected_count} sorted unique entries")
        return rows

    resource_manifest = load_manifest(
        "infra/runtime-resource-manifest.txt",
        73,
        "13ae275e4c0fcd205eae4655404ec0ab8daa7e6da500e854d7dafe5fb18982da",
    )
    declared_resources = sorted(f"{kind}.{name}" for kind, name in resource_declarations)
    if declared_resources != resource_manifest:
        errors.append("runtime resource declarations differ from the 73-address authority manifest")
    removed_manifest = load_manifest(
        "infra/runtime-removed-manifest.txt",
        20,
        "76068a02042194ddd26a7d44ab49b98a0be6b0e2ad3060cc8b0e63a825f01857",
    )
    removed_addresses = sorted(re.findall(r'^\s*from\s*=\s*([^\s#]+)\s*$', runtime, re.MULTILINE))
    if removed_addresses != removed_manifest:
        errors.append("runtime removed addresses differ from the 20-address authority manifest")

    expected_data = {
        ("google_compute_regions", "available"),
        ("google_secret_manager_secret_version", "billing_price_ids"),
    }
    data_declarations = re.findall(r'^\s*data\s+"([^"]+)"\s+"([^"]+)"\s*\{', runtime, re.MULTILINE)
    if len(data_declarations) != len(expected_data) or set(data_declarations) != expected_data:
        errors.append(f"runtime data-source addresses drifted: {sorted(data_declarations)}")
    if "terraform_remote_state" in runtime:
        errors.append("runtime root may not read another OpenTofu state")
    price_data = balanced_block(runtime, 'data "google_secret_manager_secret_version" "billing_price_ids"') or ""
    for key, expected in (
        ("project", "var.project_id"),
        ("secret", '"hop-billing-price-ids"'),
        ("version", "var.billing_price_ids_version"),
    ):
        if not has_exact_top_level_assignment(price_data, key, expected):
            errors.append(f"billing price id data source drifted: {key}")
    price_version = variable_block(runtime, "billing_price_ids_version") or ""
    price_validation = top_level_block(price_version, "validation") or ""
    if not has_exact_top_level_assignment(
        price_validation,
        "condition",
        'can(regex("^[1-9][0-9]*$", var.billing_price_ids_version))',
    ):
        errors.append("billing_price_ids_version does not require a positive numeric version")
    accountd_runtime = resource_block(runtime, "google_cloud_run_v2_service", "accountd") or ""
    accountd_lifecycle = top_level_block(accountd_runtime, "lifecycle") or ""
    price_preconditions = repeated_blocks(accountd_lifecycle, "precondition")
    if len(price_preconditions) != 1:
        errors.append("accountd must have exactly one billing price provenance precondition")
    else:
        price_precondition = "\n".join(strip_hcl_comment(line) for line in price_preconditions[0].splitlines())
        for required in (
            'toset(keys(local.billing_prices)) == toset(["base", "reach", "observability", "private_source_sha"])',
            'alltrue([for key in ["base", "reach", "observability"] : can(regex("^price_[A-Za-z0-9]+$", local.billing_prices[key]))])',
            "local.billing_prices.private_source_sha == var.private_source_sha",
        ):
            if price_precondition.count(required) != 1:
                errors.append(f"billing price provenance precondition missing: {required}")
        if not has_exact_top_level_assignment(price_preconditions[0], "error_message", '"hop-billing-price-ids must contain the three Stripe price ids produced from the pinned private source commit."'):
            errors.append("billing price provenance failure is not explicit")

    drift_output = balanced_block(runtime, 'output "drift_inputs"') or ""
    drift_values = top_level_block(drift_output, "value =") or ""
    expected_drift_values = [
        ("relay_image", "var.relay_image"),
        ("example_image", "var.example_image"),
        ("accountd_image", "var.accountd_image"),
        ("console_image", "var.console_image"),
        ("deployment_source_sha", "var.deployment_source_sha"),
        ("private_source_sha", "var.private_source_sha"),
        ("billing_price_ids_version", "var.billing_price_ids_version"),
        ("deployment_environment", "var.deployment_environment"),
        ("relay_identity_version", "var.relay_identity_version"),
        ("example_identity_version", "var.example_identity_version"),
    ]
    if top_level_assignment_pairs(drift_values) != expected_drift_values or top_level_assignment_values(drift_output, "sensitive"):
        errors.append("runtime drift input output is incomplete or sensitive")
    service_contract = {
        "relay": ('"hop-relay-${each.value}"', "local.regions"),
        "example": ('"hop-example"', None),
        "accountd": ('"hop-accountd"', None),
        "console": ('"hop-console"', None),
    }
    for name, (expected_name, expected_for_each) in service_contract.items():
        block = resource_block(runtime, "google_cloud_run_v2_service", name) or ""
        header = block.split("template", 1)[0]
        if not has_exact_top_level_assignment(header, "name", expected_name):
            errors.append(f"runtime {name} service name drifted")
        if expected_for_each:
            if not has_exact_top_level_assignment(header, "for_each", expected_for_each) or top_level_assignment_values(header, "count"):
                errors.append(f"runtime {name} service cardinality drifted")
        elif top_level_assignment_values(header, "count") or top_level_assignment_values(header, "for_each"):
            errors.append(f"runtime singleton {name} gained count or for_each")
        labels = top_level_block(header, "labels =") or ""
        if not has_exact_top_level_assignment(labels, '"hop-source-sha"', "var.deployment_source_sha"):
            errors.append(f"runtime {name} lacks the canonical hop source label")
        if not has_exact_top_level_assignment(labels, '"hop-private-source-sha"', "var.private_source_sha"):
            errors.append(f"runtime {name} lacks the pinned private source label")
    private_source = variable_block(runtime, "private_source_sha") or ""
    private_validation = top_level_block(private_source, "validation") or ""
    if not has_exact_top_level_assignment(
        private_validation,
        "condition",
        'can(regex("^[0-9a-f]{40}$", var.private_source_sha))',
    ):
        errors.append("private_source_sha does not require a full lowercase commit")

    # The public repository may orchestrate a private checkout at runtime; the private source and
    # billing configuration must never become part of its committed or untracked tree.
    forbidden_public_paths = (
        "services/hop-accountd",
        "services/hop-billingd",
        "apps/web/console",
        "infra/billing",
    )
    for relative in forbidden_public_paths:
        if (root / relative).exists() or (root / relative).is_symlink():
            errors.append(f"public checkout contains private source path: {relative}")
    disclosure_patterns = (
        re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
        re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
        re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]+\b"),
        re.compile(r"\bwhsec_[A-Za-z0-9]+\b"),
        re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
        re.compile(r"\b(?:unit_amount|unit_amount_decimal|base_fee_cents|price_per_[a-z_]+_cents)\s*="),
        re.compile(r"\$[0-9]+\.[0-9]{2}\b"),
        re.compile(r'^\s*resource\s+"stripe_', re.MULTILINE),
    )
    for generated in (root / "infra" / ".terraform", root / "infra" / "bootstrap" / ".terraform"):
        if generated.is_symlink():
            errors.append(f"generated provider directory may not be a symlink: {generated.relative_to(root)}")
    disclosure_files = [
        path for path in (root / "infra").rglob("*") if ".terraform" not in path.parts
    ] + [
        root / "tools" / "private-source-pin.py",
        root / "tools" / "private-source-pin.test.sh",
    ]
    for path in disclosure_files:
        if path.is_symlink():
            errors.append(f"public cutover path may not be a symlink: {path.relative_to(root)}")
            continue
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"public cutover file is not UTF-8 text: {path.relative_to(root)}")
            continue
        if any(pattern.search(text) for pattern in disclosure_patterns):
            errors.append(f"public cutover file contains credential or private pricing material: {path.relative_to(root)}")

    # The administrator root is more privileged than runtime and gets the same strict provider,
    # alternate-config, override, auto-tfvars, and backend treatment.
    bootstrap_root = root / "infra" / "bootstrap"
    bootstrap_files = sorted(path for path in bootstrap_root.glob("*.tf") if path.is_file())
    bootstrap_parts = []
    for path in bootstrap_files:
        try:
            bootstrap_parts.append(path.read_text(encoding="utf-8"))
        except UnicodeDecodeError:
            errors.append(f"bootstrap configuration is not UTF-8 text: {path.relative_to(root)}")
    bootstrap_raw = "\n".join(bootstrap_parts)
    if any("/*" in outside_hcl_strings(strip_hcl_comment(line)) or "*/" in outside_hcl_strings(strip_hcl_comment(line)) for line in bootstrap_raw.splitlines()):
        errors.append("bootstrap root may not contain HCL block comments")
    bootstrap = strip_hcl_heredocs(bootstrap_raw)
    bootstrap_alternates = sorted(
        path.name for path in bootstrap_root.iterdir()
        if path.is_file() and (
            path.name.endswith((".tf.json", ".tofu", ".tofu.json"))
            or path.name in {
                "terraform.tfvars", "terraform.tfvars.json",
                "override.tf", "override.tofu", "override.tf.json", "override.tofu.json",
            }
            or path.name.endswith(("_override.tf", "_override.tofu", "_override.tf.json", "_override.tofu.json"))
            or path.name.endswith((".auto.tfvars", ".auto.tfvars.json"))
        )
    )
    if bootstrap_alternates:
        errors.append(f"bootstrap root contains uninspected configuration: {bootstrap_alternates}")
    bootstrap_sources = set(re.findall(r'^\s*source\s*=\s*"([^"]+)"', bootstrap, re.MULTILINE))
    if bootstrap_sources != {"hashicorp/google", "hashicorp/google-beta", "hashicorp/random"}:
        errors.append(f"bootstrap required provider sources drifted: {sorted(bootstrap_sources)}")
    bootstrap_providers_path = bootstrap_root / "providers.tf"
    bootstrap_providers_raw = bootstrap_providers_path.read_text(encoding="utf-8") if bootstrap_providers_path.is_file() else ""
    bootstrap_providers = "\n".join(strip_hcl_comment(line) for line in bootstrap_providers_raw.splitlines())
    if not re.fullmatch(
        r'\s*provider\s+"google"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*provider\s+"google-beta"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*',
        bootstrap_providers,
    ):
        errors.append("bootstrap Google providers contain credentials, impersonation, aliases, or endpoints")
    bootstrap_backends = re.findall(r'^\s*backend\s+"([^"]+)"\s*\{', bootstrap, re.MULTILINE)
    bootstrap_backend_block = balanced_block(bootstrap, 'backend "gcs"') or ""
    bootstrap_keys = [key for key, _ in top_level_assignment_pairs(bootstrap_backend_block)]
    if bootstrap_backends != ["gcs"] or bootstrap_keys != ["bucket", "prefix"]:
        errors.append("bootstrap GCS backend may configure only bucket and prefix")
    if not has_exact_top_level_assignment(bootstrap_backend_block, "bucket", '"hop-mesh-tfstate"') or not has_exact_top_level_assignment(bootstrap_backend_block, "prefix", '"bootstrap"'):
        errors.append("bootstrap GCS backend values drifted")

    provider = resource_block(bootstrap, "google_iam_workload_identity_pool_provider", "github") or ""
    if not has_exact_top_level_assignment(provider, "attribute_condition", "local.github_repository_conditions[var.github_authority_phase]"):
        errors.append("bootstrap WIF provider is not controlled by the closed authority phase")
    provider_dependencies_match = re.search(r"(?ms)^\s*depends_on\s*=\s*\[(.*?)^\s*\]", provider)
    provider_dependencies_raw = re.findall(r"\b(?:terraform_data|google_[a-z0-9_]+)\.[A-Za-z0-9_]+", provider_dependencies_match.group(1)) if provider_dependencies_match else []
    expected_provider_dependencies = {
        "terraform_data.remove_legacy_iam_bindings",
        "google_project_iam_member.infra_drift_viewer",
        "google_storage_bucket_iam_member.infra_drift_state_reader",
        "google_secret_manager_secret_iam_member.infra_drift_price_ids_accessor",
        "google_secret_manager_secret_iam_member.infra_drift_price_ids_viewer",
        "google_secret_manager_secret_iam_member.billing_catalog_price_ids_writer",
        "google_secret_manager_secret_iam_member.billing_catalog_resend_api_key_reader",
        "google_secret_manager_secret_iam_member.billing_catalog_stripe_api_key_reader",
        "google_secret_manager_secret_iam_member.deploy_billing_price_ids_accessor",
        "google_secret_manager_secret_iam_member.deploy_billing_price_ids_viewer",
    }
    if set(provider_dependencies_raw) != expected_provider_dependencies or len(provider_dependencies_raw) != len(expected_provider_dependencies):
        errors.append("bootstrap WIF provider can advance before non-authority prerequisites")
    if top_level_assignment_values(provider, "jwks_json") or top_level_assignment_values(provider, "allowed_audiences"):
        errors.append("bootstrap WIF provider may not set top-level JWKS or audiences")
    if not has_exact_top_level_assignment(provider, "disabled", "false"):
        errors.append("bootstrap WIF provider must remain enabled")
    mapping = top_level_block(provider, "attribute_mapping =") or ""
    if top_level_assignment_pairs(mapping) != [
        ('"google.subject"', '"assertion.sub"'),
        ('"attribute.repository"', '"assertion.repository"'),
        ('"attribute.ref"', '"assertion.ref"'),
        ('"attribute.workflow"', '"assertion.workflow_ref"'),
    ]:
        errors.append("bootstrap WIF attribute mapping drifted")
    oidc = top_level_block(provider, "oidc") or ""
    if not has_exact_top_level_assignment(oidc, "issuer_uri", '"https://token.actions.githubusercontent.com"') or not has_exact_top_level_assignment(oidc, "allowed_audiences", "[]") or top_level_assignment_values(oidc, "jwks_json"):
        errors.append("bootstrap WIF OIDC verification settings drifted")
    phase = variable_block(bootstrap, "github_authority_phase") or ""
    phase_validation = top_level_block(phase, "validation") or ""
    if not has_exact_top_level_assignment(phase, "default", '"hop"') or not has_exact_top_level_assignment(phase_validation, "condition", 'contains(["handoff", "hop"], var.github_authority_phase)'):
        errors.append("bootstrap authority phase is not hop-only by default")
    for expected_line in (
        'github_platform_repository = "hopmesh/platform"',
        'github_hop_repository      = "hopmesh/hop"',
        'handoff = "assertion.repository == \\\"${local.github_platform_repository}\\\" || assertion.repository == \\\"${local.github_hop_repository}\\\""',
        'hop     = "assertion.repository == \\\"${local.github_hop_repository}\\\""',
        'runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/runtime-deploy.yml@refs/heads/main"',
        'bootstrap = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/bootstrap-apply.yml@refs/heads/main"',
        'billing   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/billing-catalog.yml@refs/heads/main"',
        'drift     = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/infra-drift.yml@refs/heads/main"',
        'runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/runtime-deploy.yml@refs/heads/main"',
        'bootstrap = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/handoff-deploy-authority.yml@refs/heads/main"',
        'billing   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/billing-catalog.yml@refs/heads/main"',
    ):
        if len(re.findall(rf'^\s*{re.escape(expected_line)}\s*$', bootstrap, re.MULTILINE)) != 1:
            errors.append(f"bootstrap authority state machine drifted: {expected_line}")
    github_repository = variable_block(bootstrap, "github_repository") or ""
    github_validation = top_level_block(github_repository, "validation") or ""
    if not has_exact_top_level_assignment(github_repository, "default", '"hopmesh/hop"') or not has_exact_top_level_assignment(github_validation, "condition", 'var.github_repository == "hopmesh/hop"'):
        errors.append("bootstrap github_repository is not fixed to hopmesh/hop")
    for var_name, expected in (("runtime_state_bucket", '"hop-mesh-tfstate"'), ("runtime_state_prefix", '"relay-fleet"')):
        block = variable_block(bootstrap, var_name) or ""
        validation = top_level_block(block, "validation") or ""
        if not has_exact_top_level_assignment(block, "default", expected) or not has_exact_top_level_assignment(validation, "condition", f"var.{var_name} == {expected}"):
            errors.append(f"bootstrap {var_name} is not fixed")
    hop_bindings = {
        "deploy_runtime_wif": ("google_service_account.deploy.name", "local.github_workflow_members.runtime"),
        "bootstrap_apply_wif": ("google_service_account.bootstrap_apply.name", "local.github_workflow_members.bootstrap"),
        "billing_catalog_wif_main": ("google_service_account.billing_catalog_apply.name", "local.github_workflow_members.billing"),
        "infra_drift_wif": ("google_service_account.infra_drift.name", "local.github_workflow_members.drift"),
    }
    rollback_bindings = {
        "deploy_runtime_wif_platform_rollback": ("google_service_account.deploy.name", "local.platform_rollback_workflow_members.runtime"),
        "bootstrap_apply_wif_platform_rollback": ("google_service_account.bootstrap_apply.name", "local.platform_rollback_workflow_members.bootstrap"),
        "billing_catalog_wif_platform_rollback": ("google_service_account.billing_catalog_apply.name", "local.platform_rollback_workflow_members.billing"),
    }
    for name, (service_account, member) in hop_bindings.items():
        block = resource_block(bootstrap, "google_service_account_iam_member", name) or ""
        lifecycle = top_level_block(block, "lifecycle") or ""
        needs_replacement_safety = name != "infra_drift_wif"
        if not has_exact_top_level_assignment(block, "service_account_id", service_account) or not has_exact_top_level_assignment(block, "role", '"roles/iam.workloadIdentityUser"') or not has_exact_top_level_assignment(block, "member", member) or not has_exact_top_level_assignment(block, "depends_on", "[google_iam_workload_identity_pool_provider.github]") or top_level_block(block, "condition") or (needs_replacement_safety and not has_exact_top_level_assignment(lifecycle, "create_before_destroy", "true")):
            errors.append(f"bootstrap workflow-scoped WIF binding drifted or risks lockout: {name}")
    for name, (service_account, member) in rollback_bindings.items():
        block = resource_block(bootstrap, "google_service_account_iam_member", name) or ""
        if not has_exact_top_level_assignment(block, "count", 'var.github_authority_phase == "handoff" ? 1 : 0') or not has_exact_top_level_assignment(block, "service_account_id", service_account) or not has_exact_top_level_assignment(block, "role", '"roles/iam.workloadIdentityUser"') or not has_exact_top_level_assignment(block, "member", member) or not has_exact_top_level_assignment(block, "depends_on", "[google_iam_workload_identity_pool_provider.github]") or top_level_block(block, "condition"):
            errors.append(f"bootstrap rollback WIF binding drifted: {name}")
    bootstrap_resources = re.findall(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', bootstrap, re.MULTILINE)
    wif_grants = []
    for kind, name in bootstrap_resources:
        if kind != "google_service_account_iam_member":
            continue
        block = resource_block(bootstrap, kind, name) or ""
        if top_level_assignment_values(block, "role") == ['"roles/iam.workloadIdentityUser"']:
            wif_grants.append(name)
    expected_wif_grants = sorted(set(hop_bindings) | set(rollback_bindings))
    if sorted(wif_grants) != expected_wif_grants:
        errors.append(f"bootstrap WIF grant set drifted: {sorted(wif_grants)}")

    price_secret = resource_block(bootstrap, "google_secret_manager_secret", "billing_price_ids") or ""
    price_replication = top_level_block(price_secret, "replication") or ""
    price_lifecycle = top_level_block(price_secret, "lifecycle") or ""
    if not has_exact_top_level_assignment(price_secret, "secret_id", '"hop-billing-price-ids"') or top_level_block(price_replication, "auto") is None or not has_exact_top_level_assignment(price_lifecycle, "prevent_destroy", "true"):
        errors.append("billing price id secret container drifted")
    expected_price_grants = {
        "billing_catalog_price_ids_writer": ("google_service_account.billing_catalog_apply.email", '"roles/secretmanager.secretVersionAdder"'),
        "deploy_billing_price_ids_accessor": ("google_service_account.deploy.email", '"roles/secretmanager.secretAccessor"'),
        "deploy_billing_price_ids_viewer": ("google_service_account.deploy.email", '"roles/secretmanager.viewer"'),
        "infra_drift_price_ids_accessor": ("google_service_account.infra_drift.email", '"roles/secretmanager.secretAccessor"'),
        "infra_drift_price_ids_viewer": ("google_service_account.infra_drift.email", '"roles/secretmanager.viewer"'),
    }
    for name, (member_name, role) in expected_price_grants.items():
        block = resource_block(bootstrap, "google_secret_manager_secret_iam_member", name) or ""
        if not has_exact_top_level_assignment(block, "secret_id", "google_secret_manager_secret.billing_price_ids.secret_id") or not has_exact_top_level_assignment(block, "role", role) or not has_exact_top_level_assignment(block, "member", f'"serviceAccount:${{{member_name}}}"'):
            errors.append(f"billing price id secret grant drifted: {name}")
    vendor_readers = {
        "billing_catalog_stripe_api_key_reader": "google_secret_manager_secret.stripe_api_key.secret_id",
        "billing_catalog_resend_api_key_reader": '"hop-resend-apikey"',
    }
    for name, secret_id in vendor_readers.items():
        block = resource_block(bootstrap, "google_secret_manager_secret_iam_member", name) or ""
        if not has_exact_top_level_assignment(block, "secret_id", secret_id) or not has_exact_top_level_assignment(block, "role", '"roles/secretmanager.secretAccessor"') or not has_exact_top_level_assignment(block, "member", '"serviceAccount:${google_service_account.billing_catalog_apply.email}"'):
            errors.append(f"billing catalog vendor credential reader drifted: {name}")
    secret_iam_names = [name for kind, name in re.findall(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', bootstrap, re.MULTILINE) if kind == "google_secret_manager_secret_iam_member"]
    deploy_secret_grants = []
    drift_secret_grants = []
    catalog_price_writers = []
    catalog_direct_readers = []
    for name in secret_iam_names:
        block = resource_block(bootstrap, "google_secret_manager_secret_iam_member", name) or ""
        member = top_level_assignment_values(block, "member")
        role = top_level_assignment_values(block, "role")
        if any("google_service_account.deploy.email" in value for value in member):
            deploy_secret_grants.append(name)
        if any("google_service_account.infra_drift.email" in value for value in member):
            drift_secret_grants.append(name)
        if role == ['"roles/secretmanager.secretVersionAdder"']:
            catalog_price_writers.append(name)
        if role == ['"roles/secretmanager.secretAccessor"'] and any("google_service_account.billing_catalog_apply.email" in value for value in member):
            catalog_direct_readers.append(name)
    if sorted(deploy_secret_grants) != ["deploy_billing_price_ids_accessor", "deploy_billing_price_ids_viewer"]:
        errors.append(f"hop-deploy secret grants are not exclusive to billing price ids: {sorted(deploy_secret_grants)}")
    if sorted(drift_secret_grants) != ["infra_drift_price_ids_accessor", "infra_drift_price_ids_viewer"]:
        errors.append(f"infra drift secret grants drifted: {sorted(drift_secret_grants)}")
    if catalog_price_writers != ["billing_catalog_price_ids_writer"]:
        errors.append(f"SecretVersionAdder grants drifted: {sorted(catalog_price_writers)}")
    if sorted(catalog_direct_readers) != sorted(vendor_readers):
        errors.append(f"billing catalog vendor credential reader set drifted: {sorted(catalog_direct_readers)}")
    forbidden_secret_iam = [
        f"{kind}.{name}" for kind, name in bootstrap_resources
        if kind in {"google_secret_manager_secret_iam_binding", "google_secret_manager_secret_iam_policy"}
    ]
    if forbidden_secret_iam:
        errors.append(f"bootstrap uses authoritative secret IAM resources: {sorted(forbidden_secret_iam)}")
    rollback_reader = resource_block(bootstrap, "google_storage_bucket_iam_member", "deploy_billing_state_reader") or ""
    rollback_condition = top_level_block(rollback_reader, "condition") or ""
    if not has_exact_top_level_assignment(rollback_reader, "count", 'var.github_authority_phase == "handoff" ? 1 : 0') or not has_exact_top_level_assignment(rollback_reader, "bucket", "var.runtime_state_bucket") or not has_exact_top_level_assignment(rollback_reader, "role", '"roles/storage.objectViewer"') or not has_exact_top_level_assignment(rollback_reader, "member", '"serviceAccount:${google_service_account.deploy.email}"') or not has_exact_top_level_assignment(rollback_condition, "title", '"billing-state-read-only"') or not has_exact_top_level_assignment(rollback_condition, "expression", '"resource.name.startsWith(\\"projects/_/buckets/${var.runtime_state_bucket}/objects/billing/\\")"'):
        errors.append("rollback billing state reader is not exact and phase-bound")
    billing_state = resource_block(bootstrap, "google_storage_bucket_iam_member", "billing_catalog_state") or ""
    billing_condition = top_level_block(billing_state, "condition") or ""
    if not has_exact_top_level_assignment(billing_state, "bucket", "var.runtime_state_bucket") or not has_exact_top_level_assignment(billing_state, "role", '"roles/storage.objectAdmin"') or not has_exact_top_level_assignment(billing_state, "member", '"serviceAccount:${google_service_account.billing_catalog_apply.email}"') or not has_exact_top_level_assignment(billing_condition, "expression", '"resource.name == \\\"projects/_/buckets/${var.runtime_state_bucket}\\\" || resource.name.startsWith(\\\"projects/_/buckets/${var.runtime_state_bucket}/objects/billing/\\\")"'):
        errors.append("billing catalog state access drifted")
    drift_sa = resource_block(bootstrap, "google_service_account", "infra_drift") or ""
    drift_role = resource_block(bootstrap, "google_project_iam_custom_role", "infra_drift") or ""
    drift_role_clean = "\n".join(strip_hcl_comment(line) for line in drift_role.splitlines())
    drift_permissions_match = re.search(r"(?ms)^\s*permissions\s*=\s*\[(.*?)^\s*\]", drift_role_clean)
    drift_permissions = set(re.findall(r'"([^"]+)"', drift_permissions_match.group(1))) if drift_permissions_match else set()
    drift_project = resource_block(bootstrap, "google_project_iam_member", "infra_drift_viewer") or ""
    drift_state = resource_block(bootstrap, "google_storage_bucket_iam_member", "infra_drift_state_reader") or ""
    drift_condition = top_level_block(drift_state, "condition") or ""
    if not has_exact_top_level_assignment(drift_sa, "account_id", '"hop-infra-drift"') or not has_exact_top_level_assignment(drift_role, "role_id", '"hopInfraDriftViewer"') or drift_permissions != EXPECTED_DRIFT_PERMISSIONS or not has_exact_top_level_assignment(drift_project, "role", "google_project_iam_custom_role.infra_drift.id") or not has_exact_top_level_assignment(drift_project, "member", '"serviceAccount:${google_service_account.infra_drift.email}"'):
        errors.append("read-only drift service account, custom role, or project grant drifted")
    if not has_exact_top_level_assignment(drift_state, "bucket", "var.runtime_state_bucket") or not has_exact_top_level_assignment(drift_state, "role", '"roles/storage.objectViewer"') or not has_exact_top_level_assignment(drift_state, "member", '"serviceAccount:${google_service_account.infra_drift.email}"') or not has_exact_top_level_assignment(drift_condition, "title", '"runtime-drift-state-read-only"') or not has_exact_top_level_assignment(drift_condition, "expression", '"resource.name == \\\"projects/_/buckets/${var.runtime_state_bucket}\\\" || resource.name.startsWith(\\\"projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/\\\")"'):
        errors.append("read-only drift state access drifted")
    drift_project_grants = []
    for kind, name in bootstrap_resources:
        if kind != "google_project_iam_member":
            continue
        block = resource_block(bootstrap, kind, name) or ""
        if any("google_service_account.infra_drift.email" in value for value in top_level_assignment_values(block, "member")):
            drift_project_grants.append(name)
    if drift_project_grants != ["infra_drift_viewer"]:
        errors.append(f"infra drift project grant set drifted: {sorted(drift_project_grants)}")
    deploy_bucket_grants = []
    for kind, name in bootstrap_resources:
        if kind != "google_storage_bucket_iam_member":
            continue
        block = resource_block(bootstrap, kind, name) or ""
        if any("google_service_account.deploy.email" in value for value in top_level_assignment_values(block, "member")):
            deploy_bucket_grants.append(name)
    if sorted(deploy_bucket_grants) != ["deploy_billing_state_reader", "deploy_state"]:
        errors.append(f"hop-deploy storage grant set drifted: {sorted(deploy_bucket_grants)}")

    terraform_data_names = [name for kind, name in bootstrap_resources if kind == "terraform_data"]
    cleanup = resource_block(bootstrap, "terraform_data", "remove_legacy_iam_bindings") or ""
    cleanup_input = top_level_block(cleanup, "input =") or ""
    cleanup_provisioner = top_level_block(cleanup, 'provisioner "local-exec"') or ""
    cleanup_environment = top_level_block(cleanup_provisioner, "environment =") or ""
    cleanup_script = bootstrap_root / "remove_legacy_state_bindings.py"
    cleanup_digest = hashlib.sha256(cleanup_script.read_bytes()).hexdigest() if cleanup_script.is_file() and not cleanup_script.is_symlink() else ""
    expected_cleanup_environment = [
        ("PROJECT_ID", "var.project_id"),
        ("STATE_BUCKET", "var.runtime_state_bucket"),
        ("BOOTSTRAP_SERVICE_ACCOUNT", "google_service_account.bootstrap_apply.email"),
        ("BILLING_SERVICE_ACCOUNT", "google_service_account.billing_catalog_apply.email"),
    ]
    if terraform_data_names != ["remove_legacy_iam_bindings"] or not has_exact_top_level_assignment(cleanup_input, "migration", '"remove-legacy-deploy-iam-v1"') or not has_exact_top_level_assignment(cleanup, "triggers_replace", f'["{LEGACY_CLEANUP_SHA256}"]') or not has_exact_top_level_assignment(cleanup_provisioner, "command", '"python3 ${path.module}/remove_legacy_state_bindings.py"') or top_level_assignment_pairs(cleanup_environment) != expected_cleanup_environment or cleanup_digest != LEGACY_CLEANUP_SHA256:
        errors.append("planned legacy state IAM cleanup resource or script drifted")

    bootstrap_removed_blocks = repeated_blocks(bootstrap, "removed")
    if len(bootstrap_removed_blocks) != 1:
        errors.append(f"bootstrap removed block count drifted: {len(bootstrap_removed_blocks)}")
    for block in bootstrap_removed_blocks:
        lifecycle = top_level_block(block, "lifecycle") or ""
        if not has_exact_top_level_assignment(lifecycle, "destroy", "false"):
            errors.append("every bootstrap removed address must keep lifecycle destroy = false")

    removed_blocks = repeated_blocks(runtime, "removed")
    if len(removed_blocks) != 20:
        errors.append(f"runtime removed block count drifted: {len(removed_blocks)}")
    for block in removed_blocks:
        lifecycle = top_level_block(block, "lifecycle") or ""
        if not has_exact_top_level_assignment(lifecycle, "destroy", "false"):
            errors.append("every removed address must keep lifecycle destroy = false")
            break
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
