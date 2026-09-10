#!/usr/bin/env python3
"""Remove exact legacy IAM bindings left by the retired deployment roots."""

from __future__ import annotations

import json
import os
import subprocess

PROJECT = "hop-mesh"
PROJECT_NUMBER = "149923095434"
BUCKET = "hop-mesh-tfstate"
BOOTSTRAP_SA = "bootstrap-apply@hop-mesh.iam.gserviceaccount.com"
BILLING_SA = "billing-catalog-apply@hop-mesh.iam.gserviceaccount.com"
CLOUDBUILD_MEMBER = (
    f"serviceAccount:service-{PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
)
STORAGE_ROLE = "roles/storage.objectAdmin"
SECRET_ADMIN_ROLE = "roles/secretmanager.admin"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def load_json(*args: str, failure: str) -> dict:
    result = run(*args)
    if result.returncode != 0:
        raise SystemExit(failure)
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or not isinstance(value.get("bindings", []), list):
        raise SystemExit(f"{failure}: malformed policy")
    return value


def load_bucket_policy() -> dict:
    return load_json(
        "gcloud",
        "storage",
        "buckets",
        "get-iam-policy",
        f"gs://{BUCKET}",
        "--format=json",
        failure="legacy IAM cleanup could not read the bucket policy",
    )


def load_project_policy() -> dict:
    return load_json(
        "gcloud",
        "projects",
        "get-iam-policy",
        PROJECT,
        "--format=json",
        failure="legacy IAM cleanup could not read the project policy",
    )


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

    project_policy = load_project_policy()
    secret_admin_matches = [
        binding
        for binding in project_policy.get("bindings", [])
        if binding.get("role") == SECRET_ADMIN_ROLE
        and CLOUDBUILD_MEMBER in binding.get("members", [])
        and binding.get("condition") in (None, {})
    ]
    if len(secret_admin_matches) > 1:
        raise SystemExit("legacy IAM cleanup found duplicate Cloud Build secret admin grants")
    if secret_admin_matches:
        result = run(
            "gcloud",
            "projects",
            "remove-iam-policy-binding",
            PROJECT,
            "--member",
            CLOUDBUILD_MEMBER,
            "--role",
            SECRET_ADMIN_ROLE,
            "--quiet",
        )
        if result.returncode != 0:
            raise SystemExit("legacy Cloud Build secret admin cleanup failed")

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

    remaining_project = load_project_policy()
    if any(
        binding.get("role") == SECRET_ADMIN_ROLE
        and CLOUDBUILD_MEMBER in binding.get("members", [])
        for binding in remaining_project.get("bindings", [])
    ):
        raise SystemExit("legacy IAM cleanup did not remove the Cloud Build secret admin grant")


if __name__ == "__main__":
    main()
