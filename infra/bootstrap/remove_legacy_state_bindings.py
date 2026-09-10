#!/usr/bin/env python3
"""Remove exact legacy IAM bindings and disable the retired deploy identity."""

from __future__ import annotations

import json
import os
import subprocess

PROJECT = "hop-mesh"
PROJECT_NUMBER = "149923095434"
BUCKET = "hop-mesh-tfstate"
BOOTSTRAP_SA = "bootstrap-apply@hop-mesh.iam.gserviceaccount.com"
BILLING_SA = "billing-catalog-apply@hop-mesh.iam.gserviceaccount.com"
CLOUDBUILD_SA = "hop-cloudbuild@hop-mesh.iam.gserviceaccount.com"
CLOUDBUILD_MEMBER = f"serviceAccount:{CLOUDBUILD_SA}"
CLOUDBUILD_SERVICE_AGENT = (
    f"serviceAccount:service-{PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
)
CLOUDBUILD_ROLES = (
    f"projects/{PROJECT}/roles/hopCloudBuildSecrets",
    "roles/artifactregistry.writer",
    "roles/cloudbuild.builds.builder",
    "roles/cloudbuild.connectionAdmin",
    "roles/editor",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/logging.admin",
    "roles/logging.logWriter",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/storage.admin",
)
DEFAULT_COMPUTE_MEMBER = f"serviceAccount:{PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
DEFAULT_COMPUTE_ROLES = (
    "roles/artifactregistry.writer",
    "roles/editor",
    "roles/iam.serviceAccountUser",
    "roles/logging.logWriter",
    "roles/run.admin",
)
LEGACY_CLOUDBUILD_MEMBER = f"serviceAccount:{PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
LEGACY_CLOUDBUILD_ROLES = ("roles/cloudbuild.builds.builder",)
RETIRED_PROJECT_GRANTS = (
    (CLOUDBUILD_MEMBER, CLOUDBUILD_ROLES),
    (DEFAULT_COMPUTE_MEMBER, DEFAULT_COMPUTE_ROLES),
    (LEGACY_CLOUDBUILD_MEMBER, LEGACY_CLOUDBUILD_ROLES),
)
STORAGE_ROLE = "roles/storage.objectAdmin"
SECRET_ADMIN_ROLE = "roles/secretmanager.admin"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def load_mapping(*args: str, failure: str) -> dict:
    result = run(*args)
    if result.returncode != 0:
        raise SystemExit(failure)
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or not isinstance(value.get("bindings", []), list):
        raise SystemExit(f"{failure}: malformed policy")
    return value


def load_list(*args: str, failure: str) -> list:
    result = run(*args)
    if result.returncode != 0:
        raise SystemExit(failure)
    value = json.loads(result.stdout)
    if not isinstance(value, list):
        raise SystemExit(f"{failure}: malformed list")
    return value


def load_bucket_policy() -> dict:
    return load_mapping(
        "gcloud",
        "storage",
        "buckets",
        "get-iam-policy",
        f"gs://{BUCKET}",
        "--format=json",
        failure="legacy IAM cleanup could not read the bucket policy",
    )


def load_project_policy() -> dict:
    return load_mapping(
        "gcloud",
        "projects",
        "get-iam-policy",
        PROJECT,
        "--format=json",
        failure="legacy IAM cleanup could not read the project policy",
    )


def load_cloudbuild_accounts() -> list:
    return load_list(
        "gcloud",
        "iam",
        "service-accounts",
        "list",
        "--project",
        PROJECT,
        "--filter",
        f"email={CLOUDBUILD_SA}",
        "--format=json",
        failure="legacy IAM cleanup could not read the retired service account",
    )


def remove_project_role(member: str, role: str, failure: str) -> None:
    result = run(
        "gcloud",
        "projects",
        "remove-iam-policy-binding",
        PROJECT,
        "--member",
        member,
        "--role",
        role,
        "--quiet",
    )
    if result.returncode != 0:
        raise SystemExit(failure)


def main() -> None:
    expected_environment = {
        "PROJECT_ID": PROJECT,
        "STATE_BUCKET": BUCKET,
        "BOOTSTRAP_SERVICE_ACCOUNT": BOOTSTRAP_SA,
        "BILLING_SERVICE_ACCOUNT": BILLING_SA,
    }
    for name, expected in expected_environment.items():
        if os.environ.get(name) != expected:
            raise SystemExit(f"legacy IAM cleanup received an invalid {name}")

    storage_targets = (
        (
            f"serviceAccount:{BOOTSTRAP_SA}",
            "bootstrap-state-prefix-only",
            f'resource.name == "projects/_/buckets/{BUCKET}" || resource.name.startsWith("projects/_/buckets/{BUCKET}/objects/bootstrap/")',
        ),
        (
            f"serviceAccount:{BILLING_SA}",
            "billing-state-prefix-only",
            f'resource.name == "projects/_/buckets/{BUCKET}" || resource.name.startsWith("projects/_/buckets/{BUCKET}/objects/billing/")',
        ),
    )

    bucket_policy = load_bucket_policy()
    for member, title, expression in storage_targets:
        condition = {"title": title, "expression": expression}
        matches = [
            binding
            for binding in bucket_policy.get("bindings", [])
            if binding.get("role") == STORAGE_ROLE
            and member in binding.get("members", [])
            and binding.get("condition") == condition
        ]
        if len(matches) > 1:
            raise SystemExit("legacy IAM cleanup found duplicate legacy state bindings")
        if not matches:
            continue
        result = run(
            "gcloud",
            "storage",
            "buckets",
            "remove-iam-policy-binding",
            f"gs://{BUCKET}",
            "--member",
            member,
            "--role",
            STORAGE_ROLE,
            "--condition",
            f"expression={expression},title={title}",
            "--quiet",
        )
        if result.returncode != 0:
            raise SystemExit("legacy state IAM cleanup failed")

    retired_bucket_matches = [
        binding
        for binding in bucket_policy.get("bindings", [])
        if binding.get("role") == STORAGE_ROLE
        and CLOUDBUILD_MEMBER in binding.get("members", [])
        and binding.get("condition") in (None, {})
    ]
    if len(retired_bucket_matches) > 1:
        raise SystemExit("legacy IAM cleanup found duplicate retired state grants")
    if retired_bucket_matches:
        result = run(
            "gcloud", "storage", "buckets", "remove-iam-policy-binding", f"gs://{BUCKET}",
            "--member", CLOUDBUILD_MEMBER, "--role", STORAGE_ROLE, "--quiet",
        )
        if result.returncode != 0:
            raise SystemExit("retired Cloud Build state admin cleanup failed")

    project_policy = load_project_policy()
    service_agent_matches = [
        binding
        for binding in project_policy.get("bindings", [])
        if binding.get("role") == SECRET_ADMIN_ROLE
        and CLOUDBUILD_SERVICE_AGENT in binding.get("members", [])
        and binding.get("condition") in (None, {})
    ]
    if len(service_agent_matches) > 1:
        raise SystemExit("legacy IAM cleanup found duplicate Cloud Build secret admin grants")
    if service_agent_matches:
        remove_project_role(
            CLOUDBUILD_SERVICE_AGENT,
            SECRET_ADMIN_ROLE,
            "legacy Cloud Build service agent secret admin cleanup failed",
        )

    for member, roles in RETIRED_PROJECT_GRANTS:
        for role in roles:
            matches = [
                binding
                for binding in project_policy.get("bindings", [])
                if binding.get("role") == role
                and member in binding.get("members", [])
                and binding.get("condition") in (None, {})
            ]
            if len(matches) > 1:
                raise SystemExit("legacy IAM cleanup found duplicate retired deploy grants")
            if matches:
                remove_project_role(
                    member,
                    role,
                    "retired deploy role cleanup failed",
                )

    accounts = load_cloudbuild_accounts()
    if len(accounts) > 1:
        raise SystemExit("legacy IAM cleanup found duplicate retired service accounts")
    if accounts and accounts[0].get("disabled") is not True:
        result = run(
            "gcloud",
            "iam",
            "service-accounts",
            "disable",
            CLOUDBUILD_SA,
            "--project",
            PROJECT,
            "--quiet",
        )
        if result.returncode != 0:
            raise SystemExit("retired Cloud Build deploy identity disable failed")

    remaining_bucket = load_bucket_policy()
    for member, title, expression in storage_targets:
        condition = {"title": title, "expression": expression}
        if any(
            binding.get("role") == STORAGE_ROLE
            and member in binding.get("members", [])
            and binding.get("condition") == condition
            for binding in remaining_bucket.get("bindings", [])
        ):
            raise SystemExit("legacy IAM cleanup did not remove an exact state binding")
    if any(
        CLOUDBUILD_MEMBER in binding.get("members", [])
        for binding in remaining_bucket.get("bindings", [])
    ):
        raise SystemExit("legacy IAM cleanup did not remove the retired state admin")

    remaining_project = load_project_policy()
    if any(
        CLOUDBUILD_SERVICE_AGENT in binding.get("members", [])
        and binding.get("role") == SECRET_ADMIN_ROLE
        for binding in remaining_project.get("bindings", [])
    ):
        raise SystemExit("legacy IAM cleanup did not remove the Cloud Build service agent secret admin grant")
    retired_members = {member for member, _ in RETIRED_PROJECT_GRANTS}
    if any(
        retired_members.intersection(binding.get("members", []))
        for binding in remaining_project.get("bindings", [])
    ):
        raise SystemExit("legacy IAM cleanup did not remove every retired deploy role")

    remaining_accounts = load_cloudbuild_accounts()
    if len(remaining_accounts) > 1 or (
        remaining_accounts and remaining_accounts[0].get("disabled") is not True
    ):
        raise SystemExit("legacy IAM cleanup did not disable the retired deploy identity")


if __name__ == "__main__":
    main()
