from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DATETIME_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

GRADE_KEYS = (
    "source_quality",
    "validation_coverage",
    "business_readiness",
    "process_quality",
    "operational_readiness",
)
LETTER_GRADES = {
    "A+",
    "A",
    "A-",
    "B+",
    "B",
    "B-",
    "C+",
    "C",
    "C-",
    "D+",
    "D",
    "D-",
    "F",
    "Not graded",
}
OPERATIONAL_GRADES = {"Validated", "Partially validated", "Not validated", "Not graded"}
AUDIT_MODES = {"baseline", "closeout"}
CLASSIFICATIONS = {"public", "internal"}
PUBLICATION_BOUNDARIES = {"private_repository", "private_external", "public_repository"}
COVERAGE_STATUSES = {"reviewed", "scoped_out", "pending"}
DOMAINS = {"technical", "business", "operations", "process"}
PROVENANCE_CLASSES = {
    "repository",
    "external_fact",
    "owner_claim",
    "assumption",
    "counsel_required",
    "direct_observation",
}
SEVERITIES = {"critical", "high", "medium", "low", "info"}
CONFIDENCES = {"high", "medium", "low"}
FINDING_STATUSES = {
    "candidate",
    "open",
    "approved",
    "in_remediation",
    "source_closed",
    "operationally_validated",
    "accepted_risk",
    "deferred",
    "blocked",
    "duplicate",
}
PREVIOUS_FINDING_STATUSES = FINDING_STATUSES | {"new"}
VERIFICATION_RESULTS = {"passed", "failed", "not_run", "blocked"}
CLOSURE_STATE_KEYS = ("source", "deploy", "live", "registry", "hardware", "operational", "business")
CLOSURE_STATES = {"validated", "not_validated", "blocked", "not_applicable"}
APPROVAL_REQUIRED_STATUSES = {
    "approved",
    "in_remediation",
    "source_closed",
    "operationally_validated",
    "accepted_risk",
    "deferred",
}
DECISION_STATUSES = {"accepted_risk", "deferred", "blocked"}
SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


def load_ledger(path: str | Path) -> dict[str, Any]:
    with Path(path).open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("ledger root must be an object")
    return data


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _is_string_list(value: Any, *, allow_empty: bool = True) -> bool:
    if not isinstance(value, list):
        return False
    if not allow_empty and not value:
        return False
    return all(_is_nonempty_string(item) for item in value)


def _is_supported(value: Any, allowed: set[str]) -> bool:
    return isinstance(value, str) and value in allowed


def _require_string(errors: list[str], obj: dict[str, Any], key: str, prefix: str) -> None:
    if not _is_nonempty_string(obj.get(key)):
        errors.append(f"{prefix}.{key} must be a nonempty string")


def _require_list(errors: list[str], obj: dict[str, Any], key: str, prefix: str) -> list[Any]:
    value = obj.get(key)
    if not isinstance(value, list):
        errors.append(f"{prefix}.{key} must be an array")
        return []
    return value


def _validate_claim_metadata(
    errors: list[str], obj: dict[str, Any], prefix: str, audit_classification: Any
) -> None:
    visibility = obj.get("visibility")
    if not _is_supported(visibility, CLASSIFICATIONS):
        errors.append(f"{prefix}.visibility has an unsupported value")
    elif audit_classification == "public" and visibility == "internal":
        errors.append(f"{prefix} is internal but the ledger is public")
    provenance = obj.get("provenance")
    if not isinstance(provenance, list) or not provenance:
        errors.append(f"{prefix}.provenance must contain at least one provenance class")
    else:
        for value in provenance:
            if not _is_supported(value, PROVENANCE_CLASSES):
                errors.append(f"{prefix}.provenance has an unsupported value")
    external_sources = obj.get("external_sources")
    if isinstance(provenance, list) and "external_fact" in provenance:
        if not isinstance(external_sources, list) or not external_sources:
            errors.append(f"{prefix}.external_sources must cite every external fact")
            external_sources = []
    elif external_sources is None:
        external_sources = []
    elif not isinstance(external_sources, list):
        errors.append(f"{prefix}.external_sources must be an array")
        external_sources = []
    for index, source in enumerate(external_sources):
        source_prefix = f"{prefix}.external_sources[{index}]"
        if not isinstance(source, dict):
            errors.append(f"{source_prefix} must be an object")
            continue
        _require_string(errors, source, "location", source_prefix)
        retrieved_at = source.get("retrieved_at")
        if not _is_nonempty_string(retrieved_at) or not DATE_PATTERN.fullmatch(retrieved_at):
            errors.append(f"{source_prefix}.retrieved_at must use YYYY-MM-DD")


def validate_ledger(data: dict[str, Any], *, allow_incomplete: bool = False) -> list[str]:
    errors: list[str] = []
    if data.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must equal {SCHEMA_VERSION}")

    audit = data.get("audit")
    if not isinstance(audit, dict):
        errors.append("audit must be an object")
        audit = {}
    for key in ("id", "title", "date", "commit", "branch", "remote", "scope"):
        _require_string(errors, audit, key, "audit")
    if _is_nonempty_string(audit.get("date")) and not DATE_PATTERN.fullmatch(audit["date"]):
        errors.append("audit.date must use YYYY-MM-DD")
    if _is_nonempty_string(audit.get("commit")) and not SHA_PATTERN.fullmatch(audit["commit"]):
        errors.append("audit.commit must be a lowercase 40-character Git SHA")
    if not _is_supported(audit.get("mode"), AUDIT_MODES):
        errors.append(f"audit.mode must be one of: {', '.join(sorted(AUDIT_MODES))}")
    if not _is_supported(audit.get("classification"), CLASSIFICATIONS):
        errors.append(f"audit.classification must be one of: {', '.join(sorted(CLASSIFICATIONS))}")
    if (
        not isinstance(audit.get("round"), int)
        or isinstance(audit.get("round"), bool)
        or audit.get("round", 0) < 1
    ):
        errors.append("audit.round must be a positive integer")
    if not isinstance(audit.get("dirty"), bool):
        errors.append("audit.dirty must be a boolean")
    baseline = audit.get("baseline")
    if audit.get("mode") == "closeout":
        if not isinstance(baseline, dict):
            errors.append("audit.baseline must identify the immutable baseline for a closeout")
        else:
            _require_string(errors, baseline, "id", "audit.baseline")
            _require_string(errors, baseline, "commit", "audit.baseline")
            if _is_nonempty_string(baseline.get("commit")) and not SHA_PATTERN.fullmatch(baseline["commit"]):
                errors.append("audit.baseline.commit must be a lowercase 40-character Git SHA")
    elif baseline is not None:
        errors.append("audit.baseline must be null for a baseline audit")

    contracts = _require_list(errors, data, "contracts", "ledger")
    contract_names: set[str] = set()
    for index, item in enumerate(contracts):
        prefix = f"contracts[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("name", "version", "location"):
            _require_string(errors, item, key, prefix)
        name = item.get("name")
        if _is_nonempty_string(name):
            if name in contract_names:
                errors.append(f"duplicate contract name: {name}")
            contract_names.add(name)

    publication = data.get("publication")
    if not isinstance(publication, dict):
        errors.append("publication must be an object")
        publication = {}
    for key in ("output_root", "redaction_policy"):
        _require_string(errors, publication, key, "publication")
    if not _is_supported(publication.get("boundary"), PUBLICATION_BOUNDARIES):
        errors.append("publication.boundary has an unsupported value")
    if not isinstance(publication.get("public_build_excluded"), bool):
        errors.append("publication.public_build_excluded must be a boolean")
    if audit.get("classification") == "internal":
        if publication.get("boundary") == "public_repository":
            errors.append("an internal ledger cannot use a public repository publication boundary")
        if publication.get("public_build_excluded") is not True:
            errors.append("an internal ledger must be excluded from public build and publication pipelines")

    grades = data.get("grades")
    if not isinstance(grades, dict):
        errors.append("grades must be an object")
        grades = {}
    for key in GRADE_KEYS:
        item = grades.get(key)
        if not isinstance(item, dict):
            errors.append(f"grades.{key} must be an object")
            continue
        grade = item.get("grade")
        allowed = OPERATIONAL_GRADES if key == "operational_readiness" else LETTER_GRADES
        if not _is_supported(grade, allowed):
            errors.append(f"grades.{key}.grade has an unsupported value")
        _require_string(errors, item, "rationale", f"grades.{key}")
        _validate_claim_metadata(errors, item, f"grades.{key}", audit.get("classification"))
        if not _is_string_list(item.get("evidence"), allow_empty=grade == "Not graded"):
            errors.append(f"grades.{key}.evidence must contain evidence references")
        previous = item.get("previous")
        if previous is not None and not _is_supported(previous, allowed):
            errors.append(f"grades.{key}.previous has an unsupported value")
        if audit.get("mode") == "closeout" and previous is None:
            errors.append(f"grades.{key}.previous is required for a closeout")
        if audit.get("mode") == "baseline" and previous is not None:
            errors.append(f"grades.{key}.previous must be null for a baseline")

    summary = data.get("executive_summary")
    if not isinstance(summary, dict):
        errors.append("executive_summary must be an object")
        summary = {}
    _require_string(errors, summary, "assessment", "executive_summary")
    assessment_metadata = {
        "visibility": summary.get("assessment_visibility"),
        "provenance": summary.get("assessment_provenance"),
        "external_sources": summary.get("assessment_external_sources"),
    }
    _validate_claim_metadata(
        errors, assessment_metadata, "executive_summary.assessment", audit.get("classification")
    )
    strengths = _require_list(errors, summary, "strengths", "executive_summary")
    for index, item in enumerate(strengths):
        prefix = f"executive_summary.strengths[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        _require_string(errors, item, "claim", prefix)
        _validate_claim_metadata(errors, item, prefix, audit.get("classification"))
        if not _is_string_list(item.get("evidence"), allow_empty=False):
            errors.append(f"{prefix}.evidence must contain at least one reference")
    lean_in = _require_list(errors, summary, "lean_in", "executive_summary")

    inventory = _require_list(errors, data, "inventory", "ledger")
    inventory_ids: set[str] = set()
    for index, item in enumerate(inventory):
        prefix = f"inventory[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("id", "path", "name", "kind", "owner_class"):
            _require_string(errors, item, key, prefix)
        item_id = item.get("id")
        if _is_nonempty_string(item_id):
            if item_id in inventory_ids:
                errors.append(f"duplicate inventory id: {item_id}")
            inventory_ids.add(item_id)
        if not _is_supported(item.get("classification"), CLASSIFICATIONS):
            errors.append(f"{prefix}.classification has an unsupported value")
        if not _is_string_list(item.get("evidence_sources"), allow_empty=False):
            errors.append(f"{prefix}.evidence_sources must contain at least one string")
        if audit.get("classification") == "public" and item.get("classification") == "internal":
            errors.append(f"{prefix} is internal but the ledger is public")

    coverage = _require_list(errors, data, "coverage", "ledger")
    coverage_by_inventory: dict[str, list[dict[str, Any]]] = {}
    for index, item in enumerate(coverage):
        prefix = f"coverage[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        inventory_id = item.get("inventory_id")
        if not _is_nonempty_string(inventory_id):
            errors.append(f"{prefix}.inventory_id must be a nonempty string")
            continue
        if inventory_id not in inventory_ids:
            errors.append(f"{prefix} references unknown inventory id: {inventory_id}")
        coverage_by_inventory.setdefault(inventory_id, []).append(item)
        status = item.get("status")
        if not _is_supported(status, COVERAGE_STATUSES):
            errors.append(f"{prefix}.status has an unsupported value")
        if status == "pending" and not allow_incomplete:
            errors.append(f"{prefix} is still pending")
        if status == "scoped_out" and not _is_nonempty_string(item.get("rationale")):
            errors.append(f"{prefix}.rationale is required when scoped out")
        for key in ("reviewers", "vectors", "evidence"):
            if not _is_string_list(item.get(key), allow_empty=status == "scoped_out"):
                errors.append(f"{prefix}.{key} must be an array of strings")

    if not allow_incomplete:
        for inventory_id in sorted(inventory_ids):
            items = coverage_by_inventory.get(inventory_id, [])
            if not items:
                errors.append(f"inventory item has no coverage entry: {inventory_id}")
            elif len(items) > 1:
                errors.append(f"inventory item has multiple coverage entries: {inventory_id}")
            elif not any(_is_supported(item.get("status"), {"reviewed", "scoped_out"}) for item in items):
                errors.append(f"inventory item has no completed coverage entry: {inventory_id}")

    findings = _require_list(errors, data, "findings", "ledger")
    finding_ids: set[str] = set()
    findings_by_id = {
        finding["id"]: finding
        for finding in findings
        if isinstance(finding, dict) and _is_nonempty_string(finding.get("id"))
    }
    for index, finding in enumerate(findings):
        prefix = f"findings[{index}]"
        if not isinstance(finding, dict):
            errors.append(f"{prefix} must be an object")
            continue
        required_strings = (
            "id",
            "domain",
            "status",
            "severity",
            "original_severity",
            "confidence",
            "visibility",
            "component",
            "vector",
            "title",
            "invariant",
            "threat_model",
            "impact",
            "business_impact",
            "scenario",
            "root_cause",
            "coverage_gap",
            "remediation_boundary",
            "owner_class",
        )
        for key in required_strings:
            _require_string(errors, finding, key, prefix)
        finding_id = finding.get("id")
        if _is_nonempty_string(finding_id):
            if finding_id in finding_ids:
                errors.append(f"duplicate finding id: {finding_id}")
            finding_ids.add(finding_id)
        if not _is_supported(finding.get("domain"), DOMAINS):
            errors.append(f"{prefix}.domain has an unsupported value")
        if not _is_supported(finding.get("status"), FINDING_STATUSES):
            errors.append(f"{prefix}.status has an unsupported value")
        if finding.get("status") == "candidate" and not allow_incomplete:
            errors.append(f"{prefix} is still a candidate")
        if not _is_supported(finding.get("severity"), SEVERITIES):
            errors.append(f"{prefix}.severity has an unsupported value")
        if not _is_supported(finding.get("original_severity"), SEVERITIES):
            errors.append(f"{prefix}.original_severity has an unsupported value")
        if not _is_supported(finding.get("confidence"), CONFIDENCES):
            errors.append(f"{prefix}.confidence has an unsupported value")
        if not _is_supported(finding.get("visibility"), CLASSIFICATIONS):
            errors.append(f"{prefix}.visibility has an unsupported value")
        if audit.get("classification") == "public" and finding.get("visibility") == "internal":
            errors.append(f"{prefix} is internal but the ledger is public")
        evidence = _require_list(errors, finding, "evidence", prefix)
        if not evidence:
            errors.append(f"{prefix}.evidence must not be empty")
        for evidence_index, evidence_item in enumerate(evidence):
            evidence_prefix = f"{prefix}.evidence[{evidence_index}]"
            if not isinstance(evidence_item, dict):
                errors.append(f"{evidence_prefix} must be an object")
                continue
            for key in ("kind", "provenance", "location", "detail"):
                _require_string(errors, evidence_item, key, evidence_prefix)
            provenance = evidence_item.get("provenance")
            if not _is_supported(provenance, PROVENANCE_CLASSES):
                errors.append(f"{evidence_prefix}.provenance has an unsupported value")
            retrieved_at = evidence_item.get("retrieved_at")
            if provenance == "external_fact":
                if not _is_nonempty_string(retrieved_at) or not DATE_PATTERN.fullmatch(retrieved_at):
                    errors.append(f"{evidence_prefix}.retrieved_at is required for external facts")
            elif retrieved_at is not None and (
                not _is_nonempty_string(retrieved_at) or not DATE_PATTERN.fullmatch(retrieved_at)
            ):
                errors.append(f"{evidence_prefix}.retrieved_at must use YYYY-MM-DD")
        for key in ("closure_contract", "relationships", "closure_evidence", "residual"):
            if not _is_string_list(finding.get(key), allow_empty=key != "closure_contract"):
                errors.append(f"{prefix}.{key} must be an array of strings")
        if isinstance(finding.get("status"), str) and finding.get("status") in {
            "source_closed",
            "operationally_validated",
        } and not finding.get("closure_evidence"):
            errors.append(f"{prefix}.closure_evidence is required for closed findings")
        if isinstance(finding.get("status"), str) and finding.get("status") in DECISION_STATUSES and not finding.get(
            "residual"
        ):
            errors.append(f"{prefix}.residual must record the decision, dependency, or blocker")
        if finding.get("status") == "duplicate" and not finding.get("relationships"):
            errors.append(f"{prefix}.relationships must identify the canonical finding")
        closure_state = finding.get("closure_state")
        if not isinstance(closure_state, dict):
            errors.append(f"{prefix}.closure_state must be an object")
        else:
            unknown_keys = sorted(set(closure_state) - set(CLOSURE_STATE_KEYS))
            if unknown_keys:
                errors.append(f"{prefix}.closure_state has unknown keys: {', '.join(unknown_keys)}")
            for key in CLOSURE_STATE_KEYS:
                if not _is_supported(closure_state.get(key), CLOSURE_STATES):
                    errors.append(f"{prefix}.closure_state.{key} has an unsupported value")
            source_validated = closure_state.get("source") == "validated"
            source_status = isinstance(finding.get("status"), str) and finding.get("status") in {
                "source_closed",
                "operationally_validated",
            }
            if source_validated and not source_status:
                errors.append(f"{prefix}.closure_state.source must agree with the finding status")
            if finding.get("status") == "source_closed" and not source_validated:
                errors.append(f"{prefix}.closure_state.source must agree with the finding status")
            operational_validated = closure_state.get("operational") == "validated"
            if operational_validated != (finding.get("status") == "operationally_validated"):
                errors.append(f"{prefix}.closure_state.operational must agree with operational status")
        previous_status = finding.get("previous_status")
        if audit.get("mode") == "closeout":
            if not _is_supported(previous_status, PREVIOUS_FINDING_STATUSES):
                errors.append(f"{prefix}.previous_status is required for a closeout")
        elif previous_status is not None:
            errors.append(f"{prefix}.previous_status must be null for a baseline")

    for index, finding in enumerate(findings):
        if not isinstance(finding, dict) or finding.get("status") != "duplicate":
            continue
        relationships = finding.get("relationships")
        canonical_targets = (
            [
                target
                for target in relationships
                if isinstance(target, str)
                and target in finding_ids
                and target != finding.get("id")
                and findings_by_id[target].get("status") != "duplicate"
            ]
            if isinstance(relationships, list)
            else []
        )
        if not canonical_targets:
            errors.append(f"findings[{index}].relationships must reference a canonical finding ID")

    for index, item in enumerate(lean_in):
        prefix = f"executive_summary.lean_in[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("finding_id", "why_now", "next_control", "owner_class"):
            _require_string(errors, item, key, prefix)
        _validate_claim_metadata(errors, item, prefix, audit.get("classification"))
        if not _is_string_list(item.get("dependencies"), allow_empty=True):
            errors.append(f"{prefix}.dependencies must be an array of strings")
        if _is_nonempty_string(item.get("finding_id")) and item["finding_id"] not in finding_ids:
            errors.append(f"{prefix} references unknown finding id: {item['finding_id']}")

    refuted = _require_list(errors, data, "refuted_candidates", "ledger")
    refuted_ids: set[str] = set()
    for index, item in enumerate(refuted):
        prefix = f"refuted_candidates[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("id", "title", "component", "hypothesis", "disproof"):
            _require_string(errors, item, key, prefix)
        item_id = item.get("id")
        if _is_nonempty_string(item_id):
            if item_id in refuted_ids:
                errors.append(f"duplicate refuted candidate id: {item_id}")
            refuted_ids.add(item_id)
        _validate_claim_metadata(errors, item, prefix, audit.get("classification"))
        if not _is_string_list(item.get("evidence"), allow_empty=False):
            errors.append(f"{prefix}.evidence must contain at least one string")

    verification = _require_list(errors, data, "verification", "ledger")
    passed_commits: set[str] = set()
    passed_scopes_by_commit: dict[str, set[str]] = {}
    verification_records: list[dict[str, Any]] = []
    for index, item in enumerate(verification):
        prefix = f"verification[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("name", "command", "commit", "scope"):
            _require_string(errors, item, key, prefix)
        if item.get("id") is not None and not _is_nonempty_string(item.get("id")):
            errors.append(f"{prefix}.id must be a nonempty string")
        _validate_claim_metadata(errors, item, prefix, audit.get("classification"))
        if _is_nonempty_string(item.get("commit")) and not SHA_PATTERN.fullmatch(item["commit"]):
            errors.append(f"{prefix}.commit must be a lowercase 40-character Git SHA")
        if not _is_supported(item.get("result"), VERIFICATION_RESULTS):
            errors.append(f"{prefix}.result has an unsupported value")
        if (
            item.get("result") == "passed"
            and _is_nonempty_string(item.get("commit"))
            and _is_nonempty_string(item.get("scope"))
        ):
            passed_commits.add(item["commit"])
            passed_scopes_by_commit.setdefault(item["commit"], set()).add(item["scope"])
        verification_records.append(item)
    for key in ("limits", "operational_actions"):
        claims = _require_list(errors, data, key, "ledger")
        for index, item in enumerate(claims):
            prefix = f"{key}[{index}]"
            if not isinstance(item, dict):
                errors.append(f"{prefix} must be an object")
                continue
            _require_string(errors, item, "text", prefix)
            _validate_claim_metadata(errors, item, prefix, audit.get("classification"))

    approvals = _require_list(errors, data, "approvals", "ledger")
    approved_finding_ids: set[str] = set()
    for index, item in enumerate(approvals):
        prefix = f"approvals[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("finding_id", "approved_by", "approved_at", "scope"):
            _require_string(errors, item, key, prefix)
        if _is_nonempty_string(item.get("finding_id")) and item["finding_id"] not in finding_ids:
            errors.append(f"{prefix} references unknown finding id: {item['finding_id']}")
        elif _is_nonempty_string(item.get("finding_id")):
            approved_finding_ids.add(item["finding_id"])
        if _is_nonempty_string(item.get("approved_at")) and not DATETIME_PATTERN.fullmatch(item["approved_at"]):
            errors.append(f"{prefix}.approved_at must use UTC YYYY-MM-DDTHH:MM:SSZ")

    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            continue
        finding_id = finding.get("id")
        status = finding.get("status")
        if isinstance(status, str) and status in APPROVAL_REQUIRED_STATUSES and finding_id not in approved_finding_ids:
            errors.append(f"findings[{index}] status {status} requires an approval record")
        audit_commit = audit.get("commit") if _is_nonempty_string(audit.get("commit")) else ""
        if isinstance(status, str) and status in {
            "source_closed",
            "operationally_validated",
        } and audit_commit not in passed_commits:
            errors.append(f"findings[{index}] closed status requires passed verification at audit.commit")
        passed_scopes = passed_scopes_by_commit.get(audit_commit, set())
        closure_state = finding.get("closure_state")
        source_validated = isinstance(closure_state, dict) and closure_state.get("source") == "validated"
        if source_validated and "protected_ci" not in passed_scopes:
            errors.append(f"findings[{index}] source closure requires passed protected_ci evidence")
        if status == "source_closed":
            closure_evidence = finding.get("closure_evidence") or []
            evidence_text = "\n".join(str(item) for item in closure_evidence)
            matched_verifications = []
            for v in verification_records:
                v_id = v.get("id")
                v_cmd = v.get("command")
                v_name = v.get("name")
                if _is_nonempty_string(v_id) and v_id in evidence_text:
                    matched_verifications.append(v)
                elif _is_nonempty_string(v_cmd) and v_cmd in evidence_text:
                    matched_verifications.append(v)
                elif _is_nonempty_string(v_name) and v_name in evidence_text:
                    matched_verifications.append(v)
            if not matched_verifications:
                errors.append(
                    f"findings[{index}] status source_closed requires closure_evidence to reference at least one verification entry ID or test command"
                )
            elif not any(
                v.get("result") == "passed" and v.get("commit") == audit_commit
                for v in matched_verifications
            ):
                errors.append(
                    f"findings[{index}] status source_closed requires referenced verification to be passed at audit.commit"
                )
        if status == "operationally_validated" and "operational" not in passed_scopes:
            errors.append(f"findings[{index}] operational validation requires passed operational evidence")
        if isinstance(closure_state, dict):
            for key in CLOSURE_STATE_KEYS:
                if closure_state.get(key) == "validated":
                    required_scope = "protected_ci" if key == "source" else key
                    if required_scope not in passed_scopes:
                        errors.append(
                            f"findings[{index}].closure_state.{key} requires passed {required_scope} evidence"
                        )

    return errors


def summarize_ledger(data: dict[str, Any]) -> dict[str, Counter[str]]:
    findings = data.get("findings", [])
    return {
        "severity": Counter(item.get("severity", "unknown") for item in findings),
        "status": Counter(item.get("status", "unknown") for item in findings),
        "domain": Counter(item.get("domain", "unknown") for item in findings),
        "component": Counter(item.get("component", "unknown") for item in findings),
    }


def sorted_findings(data: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(
        data.get("findings", []),
        key=lambda item: (
            SEVERITY_ORDER.get(item.get("severity", "info"), 99),
            item.get("domain", ""),
            item.get("id", ""),
        ),
    )
