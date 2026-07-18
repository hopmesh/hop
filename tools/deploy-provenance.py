#!/usr/bin/env python3
"""Trusted build provenance, immutable deployment input, and deployment lease logic."""

import base64
import datetime as dt
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


SHA_RE = re.compile(r"^[0-9a-f]{40}\Z")
SHA256_RE = re.compile(r"^[0-9a-f]{64}\Z")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}\Z")
DIGEST_IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}\Z")
BUILD_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\Z")
KMS_VERSION_RE = re.compile(
    r"^projects/([^/]+)/locations/([^/]+)/keyRings/([^/]+)/cryptoKeys/([^/]+)/cryptoKeyVersions/([1-9][0-9]*)\Z"
)
GCS_BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]\Z")
STATE_PREFIX_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*\Z")
SCHEMA = "hop.build-provenance.v1"
BOOTSTRAP_SCHEMA = "hop.bootstrap.v2"
LEASE_SCHEMA = "hop.deploy-lease.v1"
MAX_GITHUB_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_CONTROL_OBJECT_BYTES = 1024 * 1024
MAX_RUNTIME_ARCHIVE_BYTES = 100 * 1024 * 1024
MAX_RUNTIME_TREE_BYTES = 100 * 1024 * 1024
MIN_LEASE_TTL_SECONDS = 3900
MAX_LEASE_TTL_SECONDS = 14400
TERMINAL_BUILD_FAILURES = {
    "CANCELLED",
    "EXPIRED",
    "FAILURE",
    "INTERNAL_ERROR",
    "TIMEOUT",
}
BUILD_FORBIDDEN_PROJECT_PERMISSIONS = {
    "artifactregistry.repositories.delete",
    "artifactregistry.repositories.setIamPolicy",
    "artifactregistry.repositories.uploadArtifacts",
    "cloudbuild.builds.create",
    "cloudbuild.connections.update",
    "cloudbuild.repositories.accessReadToken",
    "cloudbuild.repositories.accessReadWriteToken",
    "cloudbuild.repositories.update",
    "cloudbuild.triggers.create",
    "cloudbuild.triggers.delete",
    "cloudbuild.triggers.run",
    "cloudbuild.triggers.update",
    "cloudkms.cryptoKeyVersions.useToSign",
    "datastore.databases.create",
    "datastore.entities.create",
    "datastore.entities.delete",
    "datastore.entities.get",
    "datastore.entities.update",
    "iam.roles.create",
    "iam.roles.delete",
    "iam.roles.update",
    "iam.serviceAccounts.actAs",
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.getAccessToken",
    "iam.serviceAccounts.setIamPolicy",
    "iam.serviceAccounts.update",
    "logging.buckets.create",
    "logging.exclusions.create",
    "logging.sinks.create",
    "pubsub.topics.publish",
    "pubsub.topics.setIamPolicy",
    "resourcemanager.projects.setIamPolicy",
    "run.services.create",
    "run.services.delete",
    "run.services.setIamPolicy",
    "run.services.update",
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.disable",
    "secretmanager.versions.enable",
    "serviceusage.services.disable",
    "serviceusage.services.enable",
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",
    "storage.objects.update",
}
DEPLOY_FORBIDDEN_PROJECT_PERMISSIONS = {
    "artifactregistry.repositories.delete",
    "artifactregistry.repositories.setIamPolicy",
    "cloudbuild.builds.create",
    "cloudbuild.connections.update",
    "cloudbuild.repositories.accessReadToken",
    "cloudbuild.repositories.accessReadWriteToken",
    "cloudbuild.repositories.update",
    "cloudbuild.triggers.create",
    "cloudbuild.triggers.delete",
    "cloudbuild.triggers.run",
    "cloudbuild.triggers.update",
    "cloudkms.cryptoKeyVersions.useToSign",
    "datastore.databases.create",
    "datastore.entities.create",
    "datastore.entities.delete",
    "datastore.entities.get",
    "datastore.entities.update",
    "iam.roles.create",
    "iam.roles.delete",
    "iam.roles.update",
    "iam.serviceAccounts.actAs",
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.getAccessToken",
    "iam.serviceAccounts.setIamPolicy",
    "iam.serviceAccounts.update",
    "pubsub.topics.setIamPolicy",
    "resourcemanager.projects.setIamPolicy",
    "run.services.setIamPolicy",
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.disable",
    "secretmanager.versions.enable",
    "serviceusage.services.disable",
    "serviceusage.services.enable",
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",
    "storage.objects.update",
}
SERVICE_ACCOUNT_SENSITIVE_PERMISSIONS = {
    "iam.serviceAccounts.actAs",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.disable",
    "iam.serviceAccounts.enable",
    "iam.serviceAccounts.getAccessToken",
    "iam.serviceAccounts.getOpenIdToken",
    "iam.serviceAccounts.implicitDelegation",
    "iam.serviceAccounts.setIamPolicy",
    "iam.serviceAccounts.signBlob",
    "iam.serviceAccounts.signJwt",
    "iam.serviceAccounts.undelete",
    "iam.serviceAccounts.update",
}
SECRET_SENSITIVE_PERMISSIONS = {
    "secretmanager.secrets.delete",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.disable",
    "secretmanager.versions.enable",
}
STORAGE_FORBIDDEN_BUILD_PERMISSIONS = {
    "storage.buckets.delete",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",
    "storage.objects.move",
    "storage.objects.restore",
    "storage.objects.update",
}
CONNECTION_SENSITIVE_PERMISSIONS = {
    "cloudbuild.connections.delete",
    "cloudbuild.connections.setIamPolicy",
    "cloudbuild.connections.update",
}
REPOSITORY_TOKEN_METHODS = (
    "accessReadToken",
    "accessReadWriteToken",
)
FORBIDDEN_RUNTIME_RESOURCE_PREFIXES = (
    "google_artifact_registry_repository",
    "google_cloudbuild_trigger",
    "google_cloudbuildv2_repository",
    "google_firestore_database",
    "google_firestore_field",
    "google_iam_deny_policy",
    "google_project_iam",
    "google_project_service",
    "google_secret_manager_secret",
    "google_service_account",
    "google_storage_bucket_iam",
    "null_resource",
    "terraform_data",
)
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


class ProvenanceError(RuntimeError):
    pass


class ConflictError(ProvenanceError):
    pass


def require(condition, message):
    if not condition:
        raise ProvenanceError(message)


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def parse_time(value):
    require(isinstance(value, str) and value, "timestamp is missing")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ProvenanceError(f"invalid timestamp: {value}") from error
    require(parsed.tzinfo is not None, f"timestamp has no timezone: {value}")
    return parsed


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def format_time(value):
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def required_env(name):
    value = os.environ.get(name, "")
    require(value, f"{name} is required")
    return value


def run(command, *, text=True):
    try:
        return subprocess.check_output(command, stderr=subprocess.STDOUT, text=text).strip()
    except subprocess.CalledProcessError as error:
        output = error.output.decode() if isinstance(error.output, bytes) else error.output
        raise ProvenanceError(f"command failed ({' '.join(command)}): {output}") from error


def access_token():
    return run(["gcloud", "auth", "print-access-token"])


def request_json(url, token, *, method="GET", body=None, content_type="application/json", expected=(200,)):
    headers = {"Authorization": f"Bearer {token}", "User-Agent": "hop-trusted-deployer/1"}
    if body is not None:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            status = response.status
            response_headers = dict(response.headers)
    except urllib.error.HTTPError as error:
        raw = error.read()
        if error.code == 412:
            raise ConflictError("atomic object precondition failed") from error
        raise ProvenanceError(f"HTTP {error.code} for {url}: {raw[:500]!r}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ProvenanceError(f"transport error for {url}: {error}") from error
    require(status in expected, f"unexpected HTTP {status} for {url}")
    if not raw:
        return None, response_headers
    try:
        return json.loads(raw), response_headers
    except (TypeError, ValueError) as error:
        raise ProvenanceError(f"non-JSON response from {url}") from error


def test_iam_permissions(url, permissions, token):
    value, _ = request_json(
        url,
        token,
        method="POST",
        body=canonical_json({"permissions": sorted(permissions)}),
    )
    require(isinstance(value, dict), "testIamPermissions response is malformed")
    granted = value.get("permissions", [])
    require(isinstance(granted, list) and all(isinstance(item, str) for item in granted), "testIamPermissions permissions are malformed")
    return set(granted)


def test_gcs_permissions(bucket, permissions, token):
    query = urllib.parse.urlencode([("permissions", permission) for permission in sorted(permissions)])
    encoded_bucket = urllib.parse.quote(bucket, safe="")
    value, _ = request_json(
        f"https://storage.googleapis.com/storage/v1/b/{encoded_bucket}/iam/testPermissions?{query}",
        token,
    )
    require(isinstance(value, dict), "GCS testIamPermissions response is malformed")
    granted = value.get("permissions", [])
    require(isinstance(granted, list) and all(isinstance(item, str) for item in granted), "GCS testIamPermissions permissions are malformed")
    return set(granted)


def require_denied_request(url, token, label):
    request = urllib.request.Request(
        url,
        data=b"",
        method="POST",
        headers={"Authorization": f"Bearer {token}", "User-Agent": "hop-trusted-deployer/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response.read(1)
    except urllib.error.HTTPError as error:
        require(error.code == 403, f"{label} denial returned unexpected HTTP {error.code}")
        return
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ProvenanceError(f"cannot verify {label} denial: {error}") from error
    raise ProvenanceError(f"{label} unexpectedly succeeded")


def validate_forbidden_permissions(granted, forbidden, label):
    unexpected = sorted(set(granted) & set(forbidden))
    require(not unexpected, f"{label} has forbidden effective permissions: {', '.join(unexpected)}")


def validate_exact_permissions(granted, expected, label):
    granted = set(granted)
    expected = set(expected)
    require(granted == expected, f"{label} effective permissions are wrong: {', '.join(sorted(granted)) or 'none'}")


def gcs_object_url(bucket, object_name, *, media=False):
    encoded = urllib.parse.quote(object_name, safe="")
    suffix = "?alt=media" if media else ""
    return f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{encoded}{suffix}"


def gcs_upload_url(bucket, object_name, generation):
    query = urllib.parse.urlencode(
        {"uploadType": "media", "name": object_name, "ifGenerationMatch": str(generation)}
    )
    return f"https://storage.googleapis.com/upload/storage/v1/b/{bucket}/o?{query}"


def gcs_get_bytes(bucket, object_name, token, max_bytes=MAX_CONTROL_OBJECT_BYTES):
    url = gcs_object_url(bucket, object_name, media=True)
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "User-Agent": "hop-trusted-deployer/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            require(response.status == 200, f"unexpected HTTP {response.status} for {object_name}")
            content = response.read(max_bytes + 1)
            require(len(content) <= max_bytes, f"GCS object exceeds the trusted size bound: {object_name}")
            return content
    except urllib.error.HTTPError as error:
        raise ProvenanceError(f"cannot read gs://{bucket}/{object_name}: HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ProvenanceError(f"cannot read gs://{bucket}/{object_name}: {error}") from error


def gcs_upload(bucket, object_name, content, token, generation=0, content_type="application/octet-stream"):
    value, _ = request_json(
        gcs_upload_url(bucket, object_name, generation),
        token,
        method="POST",
        body=content,
        content_type=content_type,
    )
    require(isinstance(value, dict) and value.get("name") == object_name, "GCS upload response is incomplete")
    return value


def gcs_metadata(bucket, object_name, token):
    value, _ = request_json(gcs_object_url(bucket, object_name), token)
    require(isinstance(value, dict), "GCS object metadata is missing")
    return value


def gcs_delete(bucket, object_name, token, generation):
    encoded = urllib.parse.quote(object_name, safe="")
    url = f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{encoded}?ifGenerationMatch={generation}"
    request = urllib.request.Request(
        url,
        method="DELETE",
        headers={"Authorization": f"Bearer {token}", "User-Agent": "hop-trusted-deployer/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            require(response.status == 204, f"unexpected HTTP {response.status} deleting lease")
    except urllib.error.HTTPError as error:
        if error.code == 412:
            raise ConflictError("lease generation changed before delete") from error
        if error.code == 404:
            return
        raise ProvenanceError(f"cannot delete lease: HTTP {error.code}") from error


def image_digest_for_tag(tag):
    digest = run(
        [
            "gcloud",
            "artifacts",
            "docker",
            "images",
            "describe",
            tag,
            "--format=value(image_summary.digest)",
        ]
    )
    require(DIGEST_RE.fullmatch(digest), f"Artifact Registry returned an invalid digest for {tag}")
    return digest


def runtime_path_included(relative):
    if relative.parts and relative.parts[0] in {"bootstrap", ".terraform"}:
        return False
    return not (
        relative.name.endswith(".tfstate")
        or ".tfstate." in relative.name
    )


def runtime_archive(source_dir):
    source = pathlib.Path(source_dir).resolve()
    require(source.is_dir(), f"runtime source directory does not exist: {source}")
    members = []
    total_size = 0
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if not runtime_path_included(relative):
            continue
        require(not path.is_symlink(), f"runtime archive rejects symlink: {relative}")
        if path.is_file():
            total_size += path.stat().st_size
            require(total_size <= MAX_RUNTIME_TREE_BYTES, "runtime source exceeds the trusted size bound")
            members.append((path, relative))
        elif not path.is_dir():
            raise ProvenanceError(f"runtime archive rejects special file: {relative}")
    require(members, "runtime archive is empty")
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for path, relative in members:
            info = archive.gettarinfo(str(path), arcname=str(relative))
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            with path.open("rb") as handle:
                archive.addfile(info, handle)
    content = output.getvalue()
    require(len(content) <= MAX_RUNTIME_ARCHIVE_BYTES, "runtime archive exceeds the trusted size bound")
    return content


def github_source_archive(repository, source_sha, token):
    require(REPOSITORY_RE.fullmatch(repository or ""), "GitHub repository must use owner/name form")
    require(SHA_RE.fullmatch(source_sha or ""), "GitHub source SHA must be full length")
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/tarball/{source_sha}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "hop-trusted-deployer/1",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            require(response.status == 200, f"GitHub source archive returned HTTP {response.status}")
            final_url = urllib.parse.urlparse(response.geturl())
            require(
                final_url.scheme == "https" and final_url.hostname in {"api.github.com", "codeload.github.com"},
                "GitHub source archive redirected outside trusted hosts",
            )
            content = response.read(MAX_GITHUB_ARCHIVE_BYTES + 1)
    except urllib.error.HTTPError as error:
        raise ProvenanceError(f"GitHub source archive request failed with HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ProvenanceError(f"GitHub source archive request failed: {error}") from error
    require(0 < len(content) <= MAX_GITHUB_ARCHIVE_BYTES, "GitHub source archive is empty or exceeds the trusted bound")
    return content


def source_runtime_files(source_archive):
    files = {}
    try:
        archive = tarfile.open(fileobj=io.BytesIO(source_archive), mode="r:gz")
    except tarfile.TarError as error:
        raise ProvenanceError("GitHub source archive is not a valid tarball") from error
    with archive:
        roots = set()
        for member in archive.getmembers():
            path = pathlib.PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts and path.parts, "GitHub source archive contains an unsafe path")
            roots.add(path.parts[0])
        require(len(roots) == 1, "GitHub source archive must have one root directory")
        root = next(iter(roots))
        total_size = 0
        for member in archive.getmembers():
            path = pathlib.PurePosixPath(member.name)
            if len(path.parts) < 3 or path.parts[:2] != (root, "infra"):
                continue
            relative = pathlib.PurePosixPath(*path.parts[2:])
            if not runtime_path_included(relative):
                continue
            if member.isdir():
                continue
            require(member.isfile() and not member.issym() and not member.islnk(), f"GitHub runtime source contains a non-file entry: {relative}")
            total_size += member.size
            require(total_size <= MAX_RUNTIME_TREE_BYTES, "GitHub runtime source expands beyond the trusted size bound")
            key = str(relative)
            require(key not in files, f"GitHub runtime source contains a duplicate path: {relative}")
            source = archive.extractfile(member)
            require(source is not None, f"cannot read GitHub runtime source file: {relative}")
            files[key] = source.read()
    require(files, "GitHub source archive contains no runtime files")
    return files


def extracted_runtime_files(destination):
    root = pathlib.Path(destination).resolve()
    files = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        require(runtime_path_included(relative), f"runtime archive contains an excluded path: {relative}")
        require(not path.is_symlink(), f"runtime archive contains a link: {relative}")
        if path.is_dir():
            continue
        require(path.is_file(), f"runtime archive contains a special file: {relative}")
        files[str(pathlib.PurePosixPath(*relative.parts))] = path.read_bytes()
    require(files, "runtime archive is empty")
    return files


def validate_runtime_source(destination, source_archive):
    runtime_files = extracted_runtime_files(destination)
    source_files = source_runtime_files(source_archive)
    require(set(runtime_files) == set(source_files), "runtime archive paths do not match the exact GitHub source tree")
    for path in sorted(runtime_files):
        require(runtime_files[path] == source_files[path], f"runtime archive content differs from GitHub source: {path}")


def safe_extract(archive_bytes, destination):
    destination = pathlib.Path(destination).resolve()
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
        members = archive.getmembers()
        require(members, "runtime archive is empty")
        require(sum(member.size for member in members) <= MAX_RUNTIME_TREE_BYTES, "runtime archive expands beyond the trusted size bound")
        for member in members:
            require(member.isfile(), f"runtime archive contains non-file entry: {member.name}")
            require(not member.issym() and not member.islnk(), f"runtime archive contains link: {member.name}")
            target = (destination / member.name).resolve()
            require(target == destination or destination in target.parents, f"runtime archive escapes destination: {member.name}")
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            require(source is not None, f"cannot extract runtime file: {member.name}")
            with target.open("wb") as output:
                shutil.copyfileobj(source, output)


def validate_runtime_policy(destination):
    root = pathlib.Path(destination)
    alternative_config = sorted(
        path.name
        for path in root.iterdir()
        if path.is_file() and path.name.endswith((".tf.json", ".tofu", ".tofu.json"))
    )
    require(not alternative_config, "runtime archive may use only statically inspected native .tf configuration")
    auto_var_files = sorted(
        path.name
        for path in root.iterdir()
        if path.is_file()
        and (
            path.name in {"terraform.tfvars", "terraform.tfvars.json"}
            or path.name.endswith(".auto.tfvars")
            or path.name.endswith(".auto.tfvars.json")
        )
    )
    require(not auto_var_files, "runtime archive may not provide automatically loaded variable values")
    override_files = sorted(
        path.name
        for path in root.iterdir()
        if path.is_file()
        and (
            path.name in {"override.tf", "override.tofu", "override.tf.json", "override.tofu.json"}
            or path.name.endswith(("_override.tf", "_override.tofu", "_override.tf.json", "_override.tofu.json"))
        )
    )
    require(not override_files, "runtime archive may not use OpenTofu override files")
    tf_files = sorted(root.glob("*.tf"))
    require(tf_files, "runtime archive has no root Terraform files")
    text = "\n".join(path.read_text(encoding="utf-8") for path in tf_files)
    resource_declarations = re.findall(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', text, re.MULTILINE)
    require(len(resource_declarations) == len(re.findall(r'^\s*resource\b', text, re.MULTILINE)), "runtime archive contains an unparseable resource declaration")
    for resource_type, _ in resource_declarations:
        require(resource_type.startswith("google_") or resource_type == "time_sleep", f"runtime archive uses an untrusted provider resource: {resource_type}")
        require(
            not resource_type.startswith(FORBIDDEN_RUNTIME_RESOURCE_PREFIXES),
            f"runtime archive contains bootstrap authority resource: {resource_type}",
        )
        require(not re.match(r"google_cloud_run.*_iam_", resource_type), f"runtime archive contains Cloud Run IAM mutation: {resource_type}")
    data_sources = re.findall(r'^\s*data\s+"([^"]+)"\s+"[^"]+"\s*\{', text, re.MULTILINE)
    require(len(data_sources) == len(re.findall(r'^\s*data\b', text, re.MULTILINE)), "runtime archive contains an unparseable data declaration")
    require(set(data_sources) <= ALLOWED_RUNTIME_DATA_SOURCES, "runtime archive contains an untrusted data source")
    require(not re.search(r'^\s*module\b', text, re.MULTILINE), "runtime archive may not load Terraform modules")
    require(not re.search(r'^\s*ephemeral\b', text, re.MULTILINE), "runtime archive may not execute ephemeral provider resources")
    require(not re.search(r'\bprovisioner\s+"', text), "runtime archive may not execute Terraform provisioners")
    require(not re.search(r'\b(?:cloud|encryption)\s*\{', text), "runtime archive may not replace or extend trusted state handling")
    provider_sources = set(re.findall(r'\bsource\s*=\s*"([^"]+)"', text))
    require(provider_sources == EXPECTED_RUNTIME_PROVIDER_SOURCES, "runtime provider sources do not match the trusted set")
    provider_blocks = re.findall(r'^\s*provider\s+"([^"]+)"\s*\{', text, re.MULTILINE)
    require(provider_blocks == EXPECTED_RUNTIME_PROVIDER_BLOCKS, "runtime provider configuration does not match the trusted set")
    providers = (root / "providers.tf").read_text(encoding="utf-8")
    require(
        re.fullmatch(
            r'\s*provider\s+"google"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*provider\s+"google-beta"\s*\{\s*project\s*=\s*var\.project_id\s*\}\s*',
            providers,
        ),
        "runtime Google provider configuration contains untrusted credentials, impersonation, aliases, or endpoints",
    )
    backends = re.findall(r'^\s*backend\s+"([^"]+)"\s*\{', text, re.MULTILINE)
    require(backends == ["gcs"], "runtime archive must declare exactly one GCS backend")
    versions = (root / "versions.tf").read_text(encoding="utf-8")
    backend = re.search(r'backend\s+"gcs"\s*\{([^{}]*)\}', versions, re.DOTALL)
    require(backend, "runtime GCS backend configuration is not statically inspectable")
    backend_keys = re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=', backend.group(1), re.MULTILINE)
    require(
        len(backend_keys) == 2 and set(backend_keys) == {"bucket", "prefix"},
        "runtime GCS backend may configure only the bootstrap-overridden bucket and prefix",
    )
    cloud_run_declarations = [
        declaration for declaration in resource_declarations if declaration[0].startswith("google_cloud_run")
    ]
    require(
        len(cloud_run_declarations) == 2
        and set(cloud_run_declarations)
        == {
            ("google_cloud_run_v2_service", "relay"),
            ("google_cloud_run_v2_service", "example"),
        },
        "runtime archive contains an untrusted Cloud Run executable resource",
    )
    image_bindings = [
        value.strip()
        for value in re.findall(r'^\s*image\s*=\s*([^\n#]+)', text, re.MULTILINE)
    ]
    require(
        len(image_bindings) == 2 and set(image_bindings) == {"var.relay_image", "var.example_image"},
        "runtime Cloud Run images are not bound only to the signed provenance variables",
    )
    service_accounts = [
        value.strip()
        for value in re.findall(r'^\s*service_account\s*=\s*([^\n#]+)', text, re.MULTILINE)
    ]
    require(
        len(service_accounts) == 2
        and set(service_accounts) == {"local.relay_service_account", "local.example_service_account"},
        "runtime executable identities are not bound only to the dedicated runtime accounts",
    )

    example = (root / "example.tf").read_text(encoding="utf-8")
    relay = (root / "cloud_run.tf").read_text(encoding="utf-8")
    identities = (root / "data.tf").read_text(encoding="utf-8")
    require("service_account = local.example_service_account" in example, "public example does not use its dedicated runtime identity")
    require('secret = "hop-example-identity"' in example, "public example does not use its dedicated identity secret")
    require("version = var.example_identity_version" in example, "public example identity version is not bootstrap pinned")
    require("local.relay_service_account" not in example, "public example reuses the relay runtime identity")
    require("hop-relay-identity" not in example, "public example references the relay seed")
    require("service_account = local.relay_service_account" in relay, "relay service does not use the relay runtime identity")
    require('secret = "hop-relay-identity"' in relay, "relay service does not mount the relay identity")
    require("version = var.relay_identity_version" in relay, "relay identity version is not bootstrap pinned")
    expected_relay_identity = "hop-relay@" + chr(36) + "{var.project_id}.iam.gserviceaccount.com"
    expected_example_identity = "hop-example@" + chr(36) + "{var.project_id}.iam.gserviceaccount.com"
    relay_identities = re.findall(r'^\s*relay_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    example_identities = re.findall(r'^\s*example_service_account\s*=\s*"([^"]+)"', identities, re.MULTILINE)
    require(relay_identities == [expected_relay_identity], "dedicated relay identity is not pinned")
    require(example_identities == [expected_example_identity], "dedicated example identity is not pinned")


def create_manifest(values, image_digests, archive_digest, archive_object):
    sha = values["source_sha"]
    require(SHA_RE.fullmatch(sha), "source SHA must be a full 40-character lowercase SHA")
    manifest = {
        "schema": SCHEMA,
        "source_sha": sha,
        "repository": values["repository"],
        "repository_id": values["repository_id"],
        "builder_identity": values["builder_identity"],
        "build_id": values["build_id"],
        "source_trigger_name": values["source_trigger_name"],
        "deployment_environment": values["deployment_environment"],
        "kms_key_version": values["kms_key_version"],
        "runtime_archive": {
            "object": archive_object,
            "sha256": archive_digest,
        },
        "images": {
            name: {
                "tag": f"{repository}:{sha}",
                "digest": f"{repository}@{image_digests[name]}",
            }
            for name, repository in values["image_repositories"].items()
        },
    }
    validate_manifest_shape(manifest)
    return manifest


def validate_manifest_shape(manifest):
    require(isinstance(manifest, dict), "provenance manifest must be an object")
    expected_keys = {
        "schema",
        "source_sha",
        "repository",
        "repository_id",
        "builder_identity",
        "build_id",
        "source_trigger_name",
        "deployment_environment",
        "kms_key_version",
        "runtime_archive",
        "images",
    }
    require(set(manifest) == expected_keys, "provenance manifest fields are incomplete or unexpected")
    require(manifest.get("schema") == SCHEMA, "provenance manifest schema is wrong")
    require(SHA_RE.fullmatch(manifest.get("source_sha", "")), "manifest source SHA is not full length")
    require(REPOSITORY_RE.fullmatch(manifest.get("repository", "")), "manifest repository is invalid")
    require(isinstance(manifest.get("repository_id"), int) and manifest["repository_id"] > 0, "manifest repository id is invalid")
    require(EMAIL_RE.fullmatch(manifest.get("builder_identity", "")), "manifest builder identity is invalid")
    require(BUILD_ID_RE.fullmatch(manifest.get("build_id", "")), "manifest build id is invalid")
    require(KMS_VERSION_RE.fullmatch(manifest.get("kms_key_version", "")), "manifest KMS key version is invalid")
    archive = manifest.get("runtime_archive")
    require(isinstance(archive, dict) and set(archive) == {"object", "sha256"}, "runtime archive provenance is invalid")
    require(DIGEST_RE.fullmatch(f"sha256:{archive.get('sha256', '')}"), "runtime archive SHA-256 is invalid")
    images = manifest.get("images")
    require(isinstance(images, dict) and set(images) == {"relay", "example"}, "manifest must contain relay and example images")
    for name, image in images.items():
        require(isinstance(image, dict) and set(image) == {"tag", "digest"}, f"{name} image provenance is invalid")
        require(image["tag"].endswith(f":{manifest['source_sha']}"), f"{name} image tag is not the full source SHA")
        require(":latest" not in image["tag"], f"{name} image uses a mutable latest tag")
        require(DIGEST_IMAGE_RE.fullmatch(image["digest"]), f"{name} deployment image is not digest pinned")
    return manifest


def validate_bootstrap_contract(contract):
    require(isinstance(contract, dict), "bootstrap contract must be an object")
    required = {
        "schema",
        "project_id",
        "repository",
        "repository_id",
        "actions_app_id",
        "ci_workflow_sha256",
        "source_trigger_id",
        "source_trigger_name",
        "builder_identity",
        "deploy_identity",
        "deployment_environment",
        "kms_key_version",
        "provenance_bucket",
        "lease_object",
        "lease_ttl_seconds",
        "runtime_state_bucket",
        "runtime_state_prefix",
        "image_repositories",
    }
    require(set(contract) == required, "bootstrap contract fields are incomplete or unexpected")
    require(contract.get("schema") == BOOTSTRAP_SCHEMA, "bootstrap contract schema is wrong")
    for field in ("repository_id", "actions_app_id", "lease_ttl_seconds"):
        require(isinstance(contract.get(field), int) and contract[field] > 0, f"bootstrap {field} is invalid")
    for field in ("builder_identity", "deploy_identity"):
        require(EMAIL_RE.fullmatch(contract.get(field, "")), f"bootstrap {field} is invalid")
    require(contract.get("source_trigger_id"), "bootstrap source trigger id is absent")
    require(
        SHA256_RE.fullmatch(contract.get("ci_workflow_sha256", "")),
        "bootstrap CI workflow digest is invalid",
    )
    require(REPOSITORY_RE.fullmatch(contract.get("repository", "")), "bootstrap repository is invalid")
    require(contract.get("deployment_environment"), "bootstrap deployment environment is absent")
    require(KMS_VERSION_RE.fullmatch(contract.get("kms_key_version", "")), "bootstrap provenance key is invalid")
    images = contract.get("image_repositories")
    require(isinstance(images, dict) and set(images) == {"relay", "example"}, "bootstrap image repositories are invalid")
    for image in images.values():
        require(isinstance(image, str) and ":" not in image.split("/")[-1] and "@" not in image, "bootstrap image repository must not include a tag or digest")
    require(
        MIN_LEASE_TTL_SECONDS <= contract["lease_ttl_seconds"] <= MAX_LEASE_TTL_SECONDS,
        "bootstrap lease TTL must exceed the deploy timeout and remain within the bounded range",
    )
    require(GCS_BUCKET_RE.fullmatch(contract.get("runtime_state_bucket", "")), "bootstrap runtime state bucket is invalid")
    require(contract["runtime_state_bucket"] != contract.get("provenance_bucket"), "bootstrap runtime state and control buckets must be distinct")
    state_prefix = contract.get("runtime_state_prefix")
    require(
        isinstance(state_prefix, str)
        and STATE_PREFIX_RE.fullmatch(state_prefix)
        and 0 < len(state_prefix) <= 1024
        and not state_prefix.endswith("/")
        and "//" not in state_prefix,
        "bootstrap runtime state prefix is invalid",
    )
    require(state_prefix.split("/", 1)[0] not in {"bootstrap", "billing"}, "bootstrap runtime state prefix uses a reserved namespace")
    return contract


def render_backend_config(contract):
    contract = validate_bootstrap_contract(contract)
    return (
        f"bucket = {json.dumps(contract['runtime_state_bucket'])}\n"
        f"prefix = {json.dumps(contract['runtime_state_prefix'])}\n"
    )


def source_provenance_revisions(value):
    require(isinstance(value, dict), "Cloud Build source provenance is malformed")
    revisions = set()
    for source_name, revision_name in (
        ("resolvedConnectedRepository", "revision"),
        ("resolvedGitSource", "revision"),
        ("resolvedRepoSource", "commitSha"),
    ):
        source = value.get(source_name)
        if source is None:
            continue
        require(isinstance(source, dict), f"Cloud Build {source_name} provenance is malformed")
        revision = source.get(revision_name)
        require(
            isinstance(revision, str) and SHA_RE.fullmatch(revision),
            f"Cloud Build {source_name} revision is malformed",
        )
        revisions.add(revision)
    return revisions


def validate_build_and_manifest(build, manifest, contract, source_sha, source_build_id):
    contract = validate_bootstrap_contract(contract)
    manifest = validate_manifest_shape(manifest)
    require(SHA_RE.fullmatch(source_sha or ""), "source SHA must be exactly 40 lowercase hexadecimal characters")
    require(BUILD_ID_RE.fullmatch(source_build_id or ""), "source build id is invalid")
    require(isinstance(build, dict), "Cloud Build record is missing")
    require(build.get("id") == source_build_id, "Cloud Build id does not match the deployment request")
    require(build.get("projectId") == contract["project_id"], "Cloud Build project is wrong")
    require(build.get("status") == "SUCCESS", "source build did not conclude SUCCESS")
    require(build.get("buildTriggerId") == contract["source_trigger_id"], "source build used the wrong trusted trigger")
    expected_service_account = f"projects/{contract['project_id']}/serviceAccounts/{contract['builder_identity']}"
    require(build.get("serviceAccount") == expected_service_account, "source build used the wrong builder identity")
    require(build.get("finishTime"), "successful source build has no finish time")

    substitutions = build.get("substitutions")
    require(isinstance(substitutions, dict), "source build substitutions are missing")
    require(substitutions.get("COMMIT_SHA") == source_sha, "source build COMMIT_SHA is wrong")
    require(substitutions.get("REVISION_ID") == source_sha, "source build REVISION_ID is wrong")
    require(substitutions.get("BRANCH_NAME") == "main", "source build branch is not main")
    require(substitutions.get("_TRUSTED_REPOSITORY") == contract["repository"], "source build repository is wrong")
    require(str(substitutions.get("_TRUSTED_REPOSITORY_ID")) == str(contract["repository_id"]), "source build repository id is wrong")
    require(substitutions.get("_TRUSTED_CI_SHA256") == contract["ci_workflow_sha256"], "source build CI workflow digest is wrong")
    require(substitutions.get("_TRUSTED_CONFIG_VERSION") == "v2", "source build trusted config version is wrong")

    require(manifest["source_sha"] == source_sha, "manifest source SHA does not match the deployment request")
    require(manifest["build_id"] == source_build_id, "manifest build id does not match the deployment request")
    require(manifest["repository"] == contract["repository"], "manifest repository is wrong")
    require(manifest["repository_id"] == contract["repository_id"], "manifest repository id is wrong")
    require(manifest["builder_identity"] == contract["builder_identity"], "manifest builder identity is wrong")
    require(manifest["source_trigger_name"] == contract["source_trigger_name"], "manifest trigger name is wrong")
    require(manifest["deployment_environment"] == contract["deployment_environment"], "manifest deployment environment is wrong")
    require(manifest["kms_key_version"] == contract["kms_key_version"], "manifest signing key is wrong")

    expected_tags = {
        name: f"{repository}:{source_sha}" for name, repository in contract["image_repositories"].items()
    }
    build_images = build.get("images")
    require(isinstance(build_images, list) and set(build_images) == set(expected_tags.values()), "source build image tags are incomplete or mutable")
    results = build.get("results")
    require(isinstance(results, dict), "source build results are missing")
    result_images = results.get("images")
    require(isinstance(result_images, list) and len(result_images) == len(expected_tags), "source build image results are incomplete")
    result_by_name = {}
    for image in result_images:
        require(isinstance(image, dict), "source build image result is malformed")
        name = image.get("name")
        digest = image.get("digest")
        require(name in expected_tags.values(), "source build reported an unexpected image tag")
        require(name not in result_by_name, "source build reported a duplicate image tag")
        require(DIGEST_RE.fullmatch(digest or ""), "source build reported an invalid image digest")
        result_by_name[name] = digest
    for name, tag in expected_tags.items():
        require(tag in result_by_name, f"source build omitted the {name} image")
        require(manifest["images"][name]["tag"] == tag, f"manifest {name} tag is wrong")
        require(manifest["images"][name]["digest"] == f"{contract['image_repositories'][name]}@{result_by_name[tag]}", f"manifest {name} digest does not match Cloud Build")

    options = build.get("options")
    require(isinstance(options, dict), "source build options are missing")
    require(options.get("requestedVerifyOption") == "VERIFIED", "source build did not request verified provenance")
    hashes = options.get("sourceProvenanceHash")
    require(isinstance(hashes, list) and "SHA256" in hashes, "source build did not request SHA-256 source provenance")
    source_provenance = build.get("sourceProvenance")
    require(isinstance(source_provenance, dict), "Cloud Build source provenance is absent")
    require(
        source_provenance_revisions(source_provenance) == {source_sha},
        "Cloud Build source provenance does not resolve only the exact source SHA",
    )
    return {
        "relay_image": manifest["images"]["relay"]["digest"],
        "example_image": manifest["images"]["example"]["digest"],
        "deployment_source_sha": source_sha,
        "deployment_build_id": source_build_id,
        "deployment_environment": contract["deployment_environment"],
    }


def sign_manifest(manifest_bytes, key_version):
    match = KMS_VERSION_RE.fullmatch(key_version)
    require(match, "KMS key version is malformed")
    project, location, keyring, key, version = match.groups()
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        manifest_file = root / "manifest.json"
        signature_file = root / "manifest.sig"
        manifest_file.write_bytes(manifest_bytes)
        run(
            [
                "gcloud",
                "kms",
                "asymmetric-sign",
                "--project",
                project,
                "--location",
                location,
                "--keyring",
                keyring,
                "--key",
                key,
                "--version",
                version,
                "--digest-algorithm",
                "sha256",
                "--input-file",
                str(manifest_file),
                "--signature-file",
                str(signature_file),
            ]
        )
        return signature_file.read_bytes()


def verify_signature_with_pem(manifest_bytes, signature, public_key_pem):
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        (root / "manifest.json").write_bytes(manifest_bytes)
        (root / "manifest.sig").write_bytes(signature)
        (root / "public.pem").write_text(public_key_pem, encoding="utf-8")
        run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(root / "public.pem"),
                "-signature",
                str(root / "manifest.sig"),
                str(root / "manifest.json"),
            ]
        )


def verify_signature(manifest_bytes, signature, key_version, token):
    match = KMS_VERSION_RE.fullmatch(key_version)
    require(match, "KMS key version is malformed")
    url = f"https://cloudkms.googleapis.com/v1/{key_version}:getPublicKey"
    value, _ = request_json(url, token)
    require(isinstance(value, dict) and isinstance(value.get("pem"), str), "KMS public key response is incomplete")
    require(value.get("algorithm") == "EC_SIGN_P256_SHA256", "KMS signing algorithm is not the bootstrap P-256 SHA-256 algorithm")
    verify_signature_with_pem(manifest_bytes, signature, value["pem"])


def source_handoff():
    project = required_env("BUILD_PROJECT_ID")
    values = {
        "source_sha": required_env("SOURCE_SHA"),
        "build_id": required_env("SOURCE_BUILD_ID"),
        "repository": required_env("TRUSTED_REPOSITORY"),
        "repository_id": int(required_env("TRUSTED_REPOSITORY_ID")),
        "builder_identity": required_env("BUILDER_IDENTITY"),
        "source_trigger_name": required_env("SOURCE_TRIGGER_NAME"),
        "deployment_environment": required_env("DEPLOYMENT_ENVIRONMENT"),
        "kms_key_version": required_env("KMS_KEY_VERSION"),
        "image_repositories": {
            "relay": required_env("RELAY_IMAGE_REPOSITORY"),
            "example": required_env("EXAMPLE_IMAGE_REPOSITORY"),
        },
    }
    validate_manifest_shape(
        create_manifest(
            values,
            {"relay": "sha256:" + "0" * 64, "example": "sha256:" + "0" * 64},
            "0" * 64,
            f"provenance/{values['build_id']}/runtime.tar.gz",
        )
    )
    bucket = required_env("PROVENANCE_BUCKET")
    topic = required_env("DEPLOY_REQUEST_TOPIC")
    archive_object = f"provenance/{values['build_id']}/runtime.tar.gz"
    manifest_object = f"provenance/{values['build_id']}/manifest.json"
    signature_object = f"provenance/{values['build_id']}/manifest.sig"
    archive = runtime_archive(required_env("RUNTIME_SOURCE_DIR"))
    archive_digest = hashlib.sha256(archive).hexdigest()
    image_digests = {
        name: image_digest_for_tag(f"{repository}:{values['source_sha']}")
        for name, repository in values["image_repositories"].items()
    }
    manifest = create_manifest(values, image_digests, archive_digest, archive_object)
    manifest_bytes = canonical_json(manifest)
    key_match = KMS_VERSION_RE.fullmatch(values["kms_key_version"])
    require(key_match and key_match.group(1) == project, "KMS signing key is outside the build project")

    signature = sign_manifest(manifest_bytes, values["kms_key_version"])

    token = access_token()
    gcs_upload(bucket, archive_object, archive, token, content_type="application/gzip")
    gcs_upload(bucket, signature_object, signature, token)
    gcs_upload(bucket, manifest_object, manifest_bytes, token, content_type="application/json")
    message = canonical_json({"build_id": values["build_id"], "source_sha": values["source_sha"]}).decode().strip()
    run(["gcloud", "pubsub", "topics", "publish", topic, "--project", project, f"--message={message}"])
    print(f"published signed provenance for {values['source_sha']} from build {values['build_id']}")


def authority_preflight():
    project = required_env("BUILD_PROJECT_ID")
    profile = required_env("AUTHORITY_PROFILE")
    expected_identity = required_env("EXPECTED_IDENTITY")
    require(profile in {"build", "deploy"}, "authority profile must be build or deploy")
    active_identity = run(["gcloud", "auth", "list", "--filter=status:ACTIVE", "--format=value(account)"])
    require(active_identity == expected_identity, "Cloud Build is running as the wrong service account")
    token = access_token()
    forbidden = BUILD_FORBIDDEN_PROJECT_PERMISSIONS if profile == "build" else DEPLOY_FORBIDDEN_PROJECT_PERMISSIONS
    project_url = f"https://cloudresourcemanager.googleapis.com/v1/projects/{project}:testIamPermissions"
    granted = test_iam_permissions(project_url, forbidden, token)
    validate_forbidden_permissions(granted, forbidden, f"{profile} identity")

    for account in ("hop-cloudbuild", "hop-deploy", "hop-relay", "hop-example"):
        email = f"{account}@{project}.iam.gserviceaccount.com"
        encoded_email = urllib.parse.quote(email, safe="")
        account_url = f"https://iam.googleapis.com/v1/projects/{project}/serviceAccounts/{encoded_email}:testIamPermissions"
        account_granted = test_iam_permissions(account_url, SERVICE_ACCOUNT_SENSITIVE_PERMISSIONS, token)
        account_expected = {"iam.serviceAccounts.actAs"} if profile == "deploy" and account in {"hop-relay", "hop-example"} else set()
        validate_exact_permissions(account_granted, account_expected, f"{profile} identity on {account}")

    for secret in ("hop-relay-identity", "hop-example-identity", "hop-ci-readtoken"):
        secret_url = f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret}:testIamPermissions"
        secret_granted = test_iam_permissions(secret_url, SECRET_SENSITIVE_PERMISSIONS, token)
        secret_expected = {"secretmanager.versions.access"} if secret == "hop-ci-readtoken" else set()
        validate_exact_permissions(secret_granted, secret_expected, f"{profile} identity on {secret}")

    connection = required_env("BUILD_CONNECTION_RESOURCE")
    expected_connection_prefix = f"projects/{project}/locations/"
    require(connection.startswith(expected_connection_prefix) and "/connections/" in connection, "Cloud Build connection resource is invalid")
    connection_url = f"https://cloudbuild.googleapis.com/v2/{connection}:testIamPermissions"
    connection_granted = test_iam_permissions(connection_url, CONNECTION_SENSITIVE_PERMISSIONS, token)
    validate_forbidden_permissions(connection_granted, CONNECTION_SENSITIVE_PERMISSIONS, f"{profile} identity on source connection")

    repository = required_env("BUILD_REPOSITORY_RESOURCE")
    expected_repository_prefix = connection + "/repositories/"
    require(repository.startswith(expected_repository_prefix), "Cloud Build repository resource is invalid")
    for method in REPOSITORY_TOKEN_METHODS:
        require_denied_request(
            f"https://cloudbuild.googleapis.com/v2/{repository}:{method}",
            token,
            f"{profile} identity source repository {method}",
        )

    if profile == "build":
        for label, bucket in (
            ("control bucket", required_env("CONTROL_BUCKET")),
            ("runtime state bucket", required_env("RUNTIME_STATE_BUCKET")),
        ):
            bucket_granted = test_gcs_permissions(bucket, STORAGE_FORBIDDEN_BUILD_PERMISSIONS, token)
            validate_forbidden_permissions(bucket_granted, STORAGE_FORBIDDEN_BUILD_PERMISSIONS, f"build identity on {label}")
    print(f"effective authority preflight passed for {profile} identity {expected_identity}")


def source_build_record(build_id, project, location, deadline_seconds=600):
    deadline = time.monotonic() + deadline_seconds
    while True:
        raw = run(
            [
                "gcloud",
                "builds",
                "describe",
                build_id,
                "--project",
                project,
                "--region",
                location,
                "--format=json",
            ]
        )
        try:
            build = json.loads(raw)
        except ValueError as error:
            raise ProvenanceError("Cloud Build describe returned invalid JSON") from error
        status = build.get("status") if isinstance(build, dict) else None
        if status == "SUCCESS":
            return build
        if status in TERMINAL_BUILD_FAILURES:
            raise ProvenanceError(f"source build concluded {status}")
        require(status in {"PENDING", "QUEUED", "WORKING"}, f"source build status is invalid: {status}")
        if time.monotonic() >= deadline:
            raise ProvenanceError("source build did not finish before the provenance deadline")
        time.sleep(5)


def deploy_verify():
    source_sha = required_env("SOURCE_SHA")
    source_build_id = required_env("SOURCE_BUILD_ID")
    project = required_env("BUILD_PROJECT_ID")
    location = required_env("BUILD_LOCATION")
    bucket = required_env("PROVENANCE_BUCKET")
    contract_object = required_env("BOOTSTRAP_CONTRACT_OBJECT")
    token = access_token()

    contract_bytes = gcs_get_bytes(bucket, contract_object, token)
    try:
        contract = json.loads(contract_bytes)
    except ValueError as error:
        raise ProvenanceError("bootstrap contract is not valid JSON") from error
    contract = validate_bootstrap_contract(contract)
    require(contract["project_id"] == project, "bootstrap contract project is wrong")
    require(contract["provenance_bucket"] == bucket, "bootstrap contract provenance bucket is wrong")
    require(contract["deploy_identity"] == required_env("DEPLOY_IDENTITY"), "active deploy identity does not match bootstrap")
    require(contract["deployment_environment"] == required_env("DEPLOYMENT_ENVIRONMENT"), "active deployment environment does not match bootstrap")

    prefix = f"provenance/{source_build_id}"
    manifest_bytes = gcs_get_bytes(bucket, f"{prefix}/manifest.json", token)
    signature = gcs_get_bytes(bucket, f"{prefix}/manifest.sig", token)
    try:
        manifest = json.loads(manifest_bytes)
    except ValueError as error:
        raise ProvenanceError("provenance manifest is not valid JSON") from error
    require(canonical_json(manifest) == manifest_bytes, "provenance manifest is not canonical JSON")
    verify_signature(manifest_bytes, signature, contract["kms_key_version"], token)
    build = source_build_record(source_build_id, project, location)
    tfvars = validate_build_and_manifest(build, manifest, contract, source_sha, source_build_id)

    archive_object = manifest["runtime_archive"]["object"]
    require(archive_object == f"{prefix}/runtime.tar.gz", "runtime archive object is not bound to the source build")
    archive = gcs_get_bytes(bucket, archive_object, token, max_bytes=MAX_RUNTIME_ARCHIVE_BYTES)
    require(hashlib.sha256(archive).hexdigest() == manifest["runtime_archive"]["sha256"], "runtime archive digest does not match signed provenance")
    source_archive = github_source_archive(contract["repository"], source_sha, required_env("GH_TOKEN"))
    runtime_dir = required_env("RUNTIME_DESTINATION")
    safe_extract(archive, runtime_dir)
    validate_runtime_source(runtime_dir, source_archive)
    validate_runtime_policy(runtime_dir)
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    tfvars["deployment_manifest_sha256"] = manifest_digest
    pathlib.Path(runtime_dir, "deployment.auto.tfvars.json").write_text(
        json.dumps(tfvars, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    pathlib.Path(required_env("DEPLOY_BACKEND_CONFIG_FILE")).write_text(
        render_backend_config(contract),
        encoding="utf-8",
    )
    context = {
        "source_sha": source_sha,
        "source_build_id": source_build_id,
        "deploy_build_id": required_env("DEPLOY_BUILD_ID"),
        "bucket": bucket,
        "lease_object": contract["lease_object"],
        "lease_ttl_seconds": contract["lease_ttl_seconds"],
        "manifest_sha256": manifest_digest,
    }
    pathlib.Path(required_env("DEPLOY_CONTEXT_FILE")).write_text(
        json.dumps(context, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"verified build, signature, exact GitHub runtime source, archive, and image digests for {source_sha}")


def lease_document(owner, source_sha, manifest_sha256, acquired_at, expires_at):
    return {
        "schema": LEASE_SCHEMA,
        "owner": owner,
        "source_sha": source_sha,
        "manifest_sha256": manifest_sha256,
        "acquired_at": format_time(acquired_at),
        "expires_at": format_time(expires_at),
    }


def lease_decision(document, metadata, now, ttl_seconds, owner):
    require(isinstance(metadata, dict), "lease metadata is missing")
    generation = metadata.get("generation")
    require(isinstance(generation, str) and generation.isdigit(), "lease generation is invalid")
    generation_time = parse_time(metadata.get("updated") or metadata.get("timeCreated"))
    generation_expiry = generation_time + dt.timedelta(seconds=ttl_seconds)
    if isinstance(document, dict) and document.get("schema") == LEASE_SCHEMA:
        try:
            expires = parse_time(document.get("expires_at"))
        except ProvenanceError:
            expires = None
        if expires is not None and expires <= generation_expiry:
            if document.get("owner") == owner and expires > now:
                return "owned", generation
            if expires > now:
                return "contended", generation
            return "recover-expired", generation
    if generation_expiry > now:
        return "contended-malformed", generation
    return "recover-malformed", generation


def load_context():
    path = pathlib.Path(required_env("DEPLOY_CONTEXT_FILE"))
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ProvenanceError("trusted deploy context is missing or invalid") from error
    require(isinstance(value, dict), "trusted deploy context is invalid")
    require(SHA_RE.fullmatch(value.get("source_sha", "")), "deploy context source SHA is invalid")
    require(BUILD_ID_RE.fullmatch(value.get("deploy_build_id", "")), "deploy context build id is invalid")
    ttl = value.get("lease_ttl_seconds")
    require(
        isinstance(ttl, int) and MIN_LEASE_TTL_SECONDS <= ttl <= MAX_LEASE_TTL_SECONDS,
        "deploy context lease TTL is invalid",
    )
    return value


def load_existing_lease(context, token):
    metadata = gcs_metadata(context["bucket"], context["lease_object"], token)
    raw = gcs_get_bytes(context["bucket"], context["lease_object"], token)
    try:
        document = json.loads(raw)
    except ValueError:
        document = None
    return document, metadata


def audit(event, context, **extra):
    value = {
        "event": event,
        "time": format_time(now_utc()),
        "owner": context.get("deploy_build_id"),
        "source_sha": context.get("source_sha"),
    }
    value.update(extra)
    print(json.dumps(value, sort_keys=True), flush=True)


def lease_acquire():
    context = load_context()
    token = access_token()
    wait_seconds = int(os.environ.get("LEASE_WAIT_SECONDS", "1800"))
    require(0 <= wait_seconds <= 3600, "lease wait is outside the trusted bound")
    deadline = time.monotonic() + wait_seconds
    while True:
        now = now_utc()
        document = lease_document(
            context["deploy_build_id"],
            context["source_sha"],
            context["manifest_sha256"],
            now,
            now + dt.timedelta(seconds=context["lease_ttl_seconds"]),
        )
        try:
            result = gcs_upload(
                context["bucket"],
                context["lease_object"],
                canonical_json(document),
                token,
                generation=0,
                content_type="application/json",
            )
            lease = {"generation": result["generation"], "document": document}
            pathlib.Path(required_env("LEASE_FILE")).write_text(json.dumps(lease, sort_keys=True) + "\n", encoding="utf-8")
            audit("lease-acquired", context, generation=result["generation"], expires_at=document["expires_at"])
            return
        except ConflictError:
            existing, metadata = load_existing_lease(context, token)
            decision, generation = lease_decision(existing, metadata, now, context["lease_ttl_seconds"], context["deploy_build_id"])
            if decision == "owned":
                raise ProvenanceError("deploy build already owns an unexpected duplicate lease")
            if decision.startswith("recover-"):
                audit("lease-recovery", context, reason=decision, previous_generation=generation, previous=existing)
                try:
                    gcs_delete(context["bucket"], context["lease_object"], token, generation)
                except ConflictError:
                    pass
                continue
            if time.monotonic() >= deadline:
                raise ProvenanceError("global deployment lease remained contended beyond the bounded wait")
            audit("lease-contended", context, generation=generation, holder=existing)
            time.sleep(10)


def read_lease_file():
    try:
        value = json.loads(pathlib.Path(required_env("LEASE_FILE")).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ProvenanceError("trusted lease file is missing or invalid") from error
    require(isinstance(value, dict) and isinstance(value.get("generation"), str), "trusted lease file is invalid")
    return value


def lease_assert():
    context = load_context()
    gate_result_file = os.environ.get("GATE_RESULT_FILE")
    if gate_result_file:
        try:
            gate_rc = pathlib.Path(gate_result_file).read_text(encoding="ascii").strip()
        except OSError as error:
            raise ProvenanceError("canonical-main recheck result is missing") from error
        if gate_rc != "0":
            lease_release()
            raise ProvenanceError("canonical main changed after the deployment lease was acquired")
    trusted = read_lease_file()
    token = access_token()
    existing, metadata = load_existing_lease(context, token)
    decision, generation = lease_decision(existing, metadata, now_utc(), context["lease_ttl_seconds"], context["deploy_build_id"])
    require(decision == "owned", f"deployment lease is no longer owned by this build: {decision}")
    require(generation == trusted["generation"], "deployment lease generation changed unexpectedly")
    require(existing.get("source_sha") == context["source_sha"], "deployment lease source SHA changed")
    require(existing.get("manifest_sha256") == context["manifest_sha256"], "deployment lease manifest changed")
    now = now_utc()
    renewed = lease_document(
        context["deploy_build_id"],
        context["source_sha"],
        context["manifest_sha256"],
        parse_time(existing["acquired_at"]),
        now + dt.timedelta(seconds=context["lease_ttl_seconds"]),
    )
    result = gcs_upload(
        context["bucket"],
        context["lease_object"],
        canonical_json(renewed),
        token,
        generation=generation,
        content_type="application/json",
    )
    pathlib.Path(required_env("LEASE_FILE")).write_text(
        json.dumps({"generation": result["generation"], "document": renewed}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    audit("lease-renewed", context, generation=result["generation"], expires_at=renewed["expires_at"])


def lease_release():
    context = load_context()
    trusted = read_lease_file()
    token = access_token()
    existing, metadata = load_existing_lease(context, token)
    require(existing.get("owner") == context["deploy_build_id"], "refusing to release another deployment's lease")
    require(metadata.get("generation") == trusted["generation"], "refusing to release a changed deployment lease")
    gcs_delete(context["bucket"], context["lease_object"], token, trusted["generation"])
    audit("lease-released", context, generation=trusted["generation"])


def fixture_mode():
    document = json.load(sys.stdin)
    operation = document.get("operation")
    if operation == "validate":
        result = validate_build_and_manifest(
            document.get("build"),
            document.get("manifest"),
            document.get("contract"),
            document.get("source_sha"),
            document.get("source_build_id"),
        )
        print(json.dumps(result, sort_keys=True))
        return
    if operation == "lease-decision":
        decision = lease_decision(
            document.get("document"),
            document.get("metadata"),
            parse_time(document.get("now")),
            document.get("ttl_seconds"),
            document.get("owner"),
        )
        print(json.dumps(decision))
        return
    raise ProvenanceError("unknown fixture operation")


def main():
    mode = os.environ.get("TRUSTED_PROVENANCE_MODE", "fixture")
    operations = {
        "authority-preflight": authority_preflight,
        "source-handoff": source_handoff,
        "deploy-verify": deploy_verify,
        "lease-acquire": lease_acquire,
        "lease-assert": lease_assert,
        "lease-release": lease_release,
        "fixture": fixture_mode,
    }
    require(mode in operations, f"unknown trusted provenance mode: {mode}")
    operations[mode]()


if __name__ == "__main__":
    try:
        main()
    except ProvenanceError as error:
        print(f"FAIL {error}", file=sys.stderr)
        sys.exit(1)
