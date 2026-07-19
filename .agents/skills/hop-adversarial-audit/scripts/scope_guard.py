from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

from ledger import DATETIME_PATTERN, GRADE_KEYS, SHA_PATTERN, load_ledger, validate_ledger


MANIFEST_VERSION = 1
APPROVED_MUTABLE_FIELDS = {"status", "previous_status", "closure_evidence", "closure_state", "residual"}
UNAPPROVED_MUTABLE_FIELDS = {"previous_status"}
REMEDIATION_ELIGIBLE_STATUSES = {"open", "blocked", "deferred"}
MANIFEST_KEYS = {
    "manifest_version",
    "manifest_digest",
    "baseline_audit_id",
    "baseline_commit",
    "approved_findings",
    "campaign_approvals",
    "approved_immutable",
    "protected_findings",
    "protected_refutations",
}


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def immutable_approved_record(finding: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in finding.items() if key not in APPROVED_MUTABLE_FIELDS}


def immutable_unapproved_record(finding: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in finding.items() if key not in UNAPPROVED_MUTABLE_FIELDS}


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def validate_manifest(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if set(manifest) != MANIFEST_KEYS:
        errors.append("scope manifest fields are incomplete or unsupported")
        return errors
    if manifest.get("manifest_version") != MANIFEST_VERSION:
        errors.append(f"manifest_version must equal {MANIFEST_VERSION}")
    if not isinstance(manifest.get("baseline_audit_id"), str) or not manifest["baseline_audit_id"].strip():
        errors.append("baseline_audit_id must be a nonempty string")
    if not isinstance(manifest.get("baseline_commit"), str) or not SHA_PATTERN.fullmatch(manifest["baseline_commit"]):
        errors.append("baseline_commit must be a lowercase 40-character Git SHA")

    approved = manifest.get("approved_findings")
    if not isinstance(approved, list) or not approved or not all(isinstance(item, str) and item for item in approved):
        errors.append("approved_findings must contain finding IDs")
        approved_set: set[str] = set()
    else:
        approved_set = set(approved)
        if len(approved_set) != len(approved) or approved != sorted(approved):
            errors.append("approved_findings must be unique and sorted")

    digest_maps: dict[str, dict[str, str]] = {}
    for key in ("approved_immutable", "protected_findings", "protected_refutations"):
        value = manifest.get(key)
        if not isinstance(value, dict) or not all(
            isinstance(item_id, str) and item_id and _is_digest(digest)
            for item_id, digest in value.items()
        ):
            errors.append(f"{key} must map IDs to SHA-256 digests")
            digest_maps[key] = {}
        else:
            digest_maps[key] = value

    if set(digest_maps["approved_immutable"]) != approved_set:
        errors.append("approved_immutable must match approved_findings exactly")
    if approved_set.intersection(digest_maps["protected_findings"]):
        errors.append("approved and protected finding sets must not overlap")

    campaign_approvals = manifest.get("campaign_approvals")
    if not isinstance(campaign_approvals, list):
        errors.append("campaign_approvals must be an array")
        campaign_approvals = []
    campaign_ids: list[str] = []
    for index, item in enumerate(campaign_approvals):
        prefix = f"campaign_approvals[{index}]"
        if not isinstance(item, dict) or set(item) != {"finding_id", "approved_by", "approved_at", "scope"}:
            errors.append(f"{prefix} must contain the canonical approval fields")
            continue
        if not all(isinstance(item[key], str) and item[key].strip() for key in item):
            errors.append(f"{prefix} fields must be nonempty strings")
            continue
        if not DATETIME_PATTERN.fullmatch(item["approved_at"]):
            errors.append(f"{prefix}.approved_at must use UTC YYYY-MM-DDTHH:MM:SSZ")
        campaign_ids.append(item["finding_id"])
    if sorted(campaign_ids) != sorted(approved_set) or len(campaign_ids) != len(approved_set):
        errors.append("campaign_approvals must contain exactly one record per approved finding")

    expected_digest = canonical_digest({key: value for key, value in manifest.items() if key != "manifest_digest"})
    if manifest.get("manifest_digest") != expected_digest:
        errors.append("manifest_digest does not match the scope manifest")
    return errors


def build_scope_manifest(
    data: dict[str, Any], approved_ids: list[str], campaign_approvals: list[dict[str, str]]
) -> dict[str, Any]:
    errors = validate_ledger(data)
    if errors:
        raise ValueError("baseline ledger is invalid:\n" + "\n".join(errors))

    approved = set(approved_ids)
    finding_ids = {item["id"] for item in data["findings"]}
    unknown = sorted(approved - finding_ids)
    if unknown:
        raise ValueError(f"approved finding IDs are absent from the baseline: {', '.join(unknown)}")
    if not approved:
        raise ValueError("at least one approved finding ID is required")
    findings_by_id = {item["id"]: item for item in data["findings"]}
    ineligible = sorted(
        finding_id
        for finding_id in approved
        if findings_by_id[finding_id]["status"] not in REMEDIATION_ELIGIBLE_STATUSES
    )
    if ineligible:
        raise ValueError(f"approved finding IDs are not eligible for remediation: {', '.join(ineligible)}")

    protected_findings = {
        item["id"]: canonical_digest(immutable_unapproved_record(item))
        for item in data["findings"]
        if item["id"] not in approved
    }
    protected_refutations = {
        item["id"]: canonical_digest(item) for item in data["refuted_candidates"]
    }
    approved_immutable = {
        item["id"]: canonical_digest(immutable_approved_record(item))
        for item in data["findings"]
        if item["id"] in approved
    }
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "baseline_audit_id": data["audit"]["id"],
        "baseline_commit": data["audit"]["commit"],
        "approved_findings": sorted(approved),
        "campaign_approvals": campaign_approvals,
        "approved_immutable": approved_immutable,
        "protected_findings": protected_findings,
        "protected_refutations": protected_refutations,
    }
    manifest["manifest_digest"] = canonical_digest(manifest)
    manifest_errors = validate_manifest(manifest)
    if manifest_errors:
        raise ValueError("scope manifest is invalid:\n" + "\n".join(manifest_errors))
    return manifest


def verify_scope(
    baseline: dict[str, Any], candidate: dict[str, Any], manifest: dict[str, Any]
) -> list[str]:
    errors = validate_manifest(manifest)
    if errors:
        return errors

    try:
        expected_manifest = build_scope_manifest(
            baseline, manifest["approved_findings"], manifest["campaign_approvals"]
        )
    except ValueError as error:
        return [str(error)]
    if manifest != expected_manifest:
        return ["scope manifest does not match the immutable baseline"]

    candidate_errors = validate_ledger(candidate)
    if candidate_errors:
        return [f"candidate ledger: {error}" for error in candidate_errors]

    audit = candidate["audit"]
    baseline_matches = (
        audit["mode"] == "baseline"
        and audit["id"] == manifest["baseline_audit_id"]
        and audit["commit"] == manifest["baseline_commit"]
    )
    closeout_matches = (
        audit["mode"] == "closeout"
        and audit["baseline"]["id"] == manifest["baseline_audit_id"]
        and audit["baseline"]["commit"] == manifest["baseline_commit"]
    )
    if not baseline_matches and not closeout_matches:
        errors.append("candidate ledger does not identify the scope manifest baseline")

    expected_approvals = baseline["approvals"] + manifest["campaign_approvals"]
    if candidate["approvals"] != expected_approvals:
        errors.append("candidate approvals must preserve history and match campaign_approvals exactly")

    findings = {item.get("id"): item for item in candidate.get("findings", []) if isinstance(item, dict)}
    baseline_findings = {item["id"]: item for item in baseline["findings"]}
    for finding_id, expected_digest in manifest["approved_immutable"].items():
        item = findings.get(finding_id)
        if item is None:
            errors.append(f"approved finding is missing: {finding_id}")
        elif canonical_digest(immutable_approved_record(item)) != expected_digest:
            errors.append(f"approved finding immutable fields changed: {finding_id}")
    for finding_id, expected_digest in manifest["protected_findings"].items():
        item = findings.get(finding_id)
        if item is None:
            errors.append(f"protected finding is missing: {finding_id}")
        elif canonical_digest(immutable_unapproved_record(item)) != expected_digest:
            errors.append(f"protected finding changed: {finding_id}")

    if audit["mode"] == "closeout":
        for finding_id, baseline_finding in baseline_findings.items():
            candidate_finding = findings.get(finding_id)
            if candidate_finding and candidate_finding.get("previous_status") != baseline_finding["status"]:
                errors.append(f"finding previous_status does not match baseline: {finding_id}")
        for finding_id, candidate_finding in findings.items():
            if finding_id not in baseline_findings and candidate_finding.get("previous_status") != "new":
                errors.append(f"new finding must use previous_status new: {finding_id}")
        for key in GRADE_KEYS:
            if candidate["grades"][key].get("previous") != baseline["grades"][key]["grade"]:
                errors.append(f"grade previous value does not match baseline: {key}")

    refutations = {
        item.get("id"): item for item in candidate.get("refuted_candidates", []) if isinstance(item, dict)
    }
    for candidate_id, expected_digest in manifest["protected_refutations"].items():
        item = refutations.get(candidate_id)
        if item is None:
            errors.append(f"protected refuted candidate is missing: {candidate_id}")
        elif canonical_digest(item) != expected_digest:
            errors.append(f"protected refuted candidate changed: {candidate_id}")

    return errors


def write_manifest(manifest: dict[str, Any], output: str | Path) -> None:
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Protect HOP audit finding invariants during remediation")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot", help="Record full and immutable-field finding digests")
    snapshot.add_argument("ledger", help="Canonical baseline ledger")
    snapshot.add_argument("approval_records", help="JSON array with one canonical record per approved finding")
    snapshot.add_argument("output", help="Output scope manifest")
    snapshot.add_argument("--approved", action="append", required=True, help="Approved finding ID")

    verify = subparsers.add_parser("verify", help="Verify protected records against a scope manifest")
    verify.add_argument("baseline", help="Canonical immutable baseline ledger")
    verify.add_argument("ledger", help="Working or closeout ledger")
    verify.add_argument("manifest", help="Scope manifest created before remediation")

    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            with Path(args.approval_records).open(encoding="utf-8") as handle:
                approval_records = json.load(handle)
            if not isinstance(approval_records, list):
                raise ValueError("approval records root must be an array")
            write_manifest(
                build_scope_manifest(load_ledger(args.ledger), args.approved, approval_records),
                args.output,
            )
            print(f"scope manifest written: {args.output}")
            return 0

        baseline = load_ledger(args.baseline)
        candidate = load_ledger(args.ledger)
        manifest = load_ledger(args.manifest)
        errors = verify_scope(baseline, candidate, manifest)
    except (OSError, ValueError) as error:
        print(f"scope guard failed: {error}", file=sys.stderr)
        return 1

    if errors:
        print(f"scope guard failed with {len(errors)} error(s):", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("scope guard: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
