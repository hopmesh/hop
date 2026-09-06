from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ledger import load_ledger, validate_ledger
from render_report import render_report
from scope_guard import build_scope_manifest, canonical_digest, verify_scope


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
REPO_ROOT = SKILL_DIR.parents[2]
FIXTURE = SKILL_DIR / "fixtures" / "sample-ledger.json"
AUDIT_SHA = "a" * 40


def approval(finding_id: str, approved_at: str = "2026-07-18T20:00:00Z") -> dict[str, str]:
    return {
        "finding_id": finding_id,
        "approved_by": "repository owner",
        "approved_at": approved_at,
        "scope": "Full closure contract",
    }


def passed_verification(scope: str) -> dict[str, str]:
    return {
        "name": f"Passed {scope}",
        "command": f"verify-{scope}",
        "result": "passed",
        "commit": AUDIT_SHA,
        "scope": scope,
        "visibility": "internal",
        "provenance": ["direct_observation"],
        "notes": "Representative fixture evidence.",
    }


def as_closeout(data: dict[str, object]) -> dict[str, object]:
    closeout = copy.deepcopy(data)
    audit = closeout["audit"]
    audit["mode"] = "closeout"
    audit["id"] = f'{audit["id"]}-closeout'
    audit["baseline"] = {
        "id": data["audit"]["id"],
        "commit": data["audit"]["commit"],
    }
    for key, grade in closeout["grades"].items():
        grade["previous"] = data["grades"][key]["grade"]
    baseline_findings = {finding["id"]: finding for finding in data["findings"]}
    for finding in closeout["findings"]:
        finding["previous_status"] = baseline_findings[finding["id"]]["status"]
    return closeout


class LedgerValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.data = load_ledger(FIXTURE)

    def assert_error_contains(self, fragment: str) -> None:
        errors = validate_ledger(self.data)
        self.assertTrue(any(fragment in error for error in errors), errors)

    def test_sample_ledger_is_valid(self) -> None:
        self.assertEqual(validate_ledger(self.data), [])

    def test_final_ledger_rejects_pending_coverage_and_candidates(self) -> None:
        self.data["coverage"][0]["status"] = "pending"
        self.data["findings"][0]["status"] = "candidate"
        final_errors = validate_ledger(self.data)
        self.assertTrue(any("still pending" in error for error in final_errors))
        self.assertTrue(any("still a candidate" in error for error in final_errors))
        self.assertEqual(validate_ledger(self.data, allow_incomplete=True), [])

    def test_public_ledger_rejects_internal_inventory_and_findings(self) -> None:
        self.data["audit"]["classification"] = "public"
        errors = validate_ledger(self.data)
        self.assertTrue(any("inventory[1] is internal" in error for error in errors))
        self.assertTrue(any("findings[1] is internal" in error for error in errors))
        self.assertTrue(any("executive_summary.assessment is internal" in error for error in errors))
        self.assertTrue(any("limits[0] is internal" in error for error in errors))

    def test_every_inventory_item_has_exactly_one_final_coverage_entry(self) -> None:
        self.data["coverage"].append(copy.deepcopy(self.data["coverage"][0]))
        self.assert_error_contains("multiple coverage entries: core-hop-core")

    def test_contract_names_are_unique(self) -> None:
        self.data["contracts"].append(copy.deepcopy(self.data["contracts"][0]))
        self.assert_error_contains("duplicate contract name: wire")

    def test_internal_ledger_requires_a_nonpublic_publication_boundary(self) -> None:
        self.data["publication"]["boundary"] = "public_repository"
        self.assert_error_contains("internal ledger cannot use a public repository")
        self.data["publication"]["boundary"] = "private_repository"
        self.data["publication"]["public_build_excluded"] = False
        self.assert_error_contains("must be excluded from public build")

    def test_grades_and_strengths_require_evidence_references(self) -> None:
        self.data["grades"]["source_quality"]["evidence"] = []
        self.data["executive_summary"]["strengths"][0]["evidence"] = []
        errors = validate_ledger(self.data)
        self.assertTrue(any("source_quality.evidence" in error for error in errors))
        self.assertTrue(any("strengths[0].evidence" in error for error in errors))

    def test_finding_evidence_requires_explicit_provenance(self) -> None:
        del self.data["findings"][0]["evidence"][0]["provenance"]
        self.assert_error_contains("evidence[0].provenance must be a nonempty string")

    def test_external_fact_requires_retrieval_date(self) -> None:
        evidence = self.data["findings"][1]["evidence"][0]
        evidence["provenance"] = "external_fact"
        self.assert_error_contains("retrieved_at is required for external facts")
        evidence["retrieved_at"] = "2026-07-18"
        self.assertEqual(validate_ledger(self.data), [])

    def test_closeout_requires_previous_grades(self) -> None:
        self.data["audit"]["mode"] = "closeout"
        self.assert_error_contains("previous is required for a closeout")

    def test_complete_closeout_records_baseline_deltas_and_status_transitions(self) -> None:
        closeout = as_closeout(self.data)
        self.assertEqual(validate_ledger(closeout), [])
        report = render_report(closeout)
        self.assertIn("Delta: Unchanged", report)
        self.assertIn("hop-2026-07-18-sample", report)
        self.assertIn("open -&gt; open", report)

    def test_remediation_status_requires_explicit_approval(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "source_closed"
        finding["closure_evidence"] = ["Passed protected_ci: verify-protected_ci passed at the audit commit."]
        finding["closure_state"]["source"] = "validated"
        self.data["verification"].append(passed_verification("protected_ci"))
        self.assert_error_contains("status source_closed requires an approval record")
        self.data["approvals"].append(approval(finding["id"]))
        self.assertEqual(validate_ledger(self.data), [])

    def test_approval_timestamp_must_be_explicit_utc(self) -> None:
        self.data["findings"][0]["status"] = "approved"
        self.data["approvals"].append(approval("CORE-001", "2026-07-18"))
        self.assert_error_contains("approved_at must use UTC")

    def test_operational_validation_requires_direct_operational_evidence(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "operationally_validated"
        finding["closure_evidence"] = ["Physical matrix completed."]
        finding["closure_state"]["source"] = "validated"
        finding["closure_state"]["operational"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.assert_error_contains("operational validation requires passed")
        self.data["verification"].append(passed_verification("protected_ci"))
        self.data["verification"].append(passed_verification("operational"))
        self.assertEqual(validate_ledger(self.data), [])

    def test_operational_finding_can_validate_without_source_closure(self) -> None:
        finding = self.data["findings"][1]
        finding["status"] = "operationally_validated"
        finding["closure_evidence"] = ["The operating control was exercised directly."]
        finding["closure_state"]["operational"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.data["verification"].append(passed_verification("operational"))
        self.assertEqual(validate_ledger(self.data), [])

    def test_closed_status_requires_verification_at_audit_commit(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "source_closed"
        finding["closure_evidence"] = ["cargo test -p hop-core"]
        finding["closure_state"]["source"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.data["verification"][0]["commit"] = "b" * 40
        self.assert_error_contains("closed status requires passed verification at audit.commit")
    def test_source_closed_requires_matching_verification_record(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "source_closed"
        finding["closure_evidence"] = ["Fabricated string without test."]
        finding["closure_state"]["source"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.data["verification"].append(passed_verification("protected_ci"))
        self.assert_error_contains(
            "requires closure_evidence to reference at least one verification entry ID or test command"
        )

        # Unmatched test command
        finding["closure_evidence"] = ["cargo test -p nonexistent-crate"]
        self.assert_error_contains(
            "requires closure_evidence to reference at least one verification entry ID or test command"
        )

        # Matching test command that ran and passed at audit commit
        finding["closure_evidence"] = ["Executed cargo test -p hop-core successfully."]
        self.assertEqual(validate_ledger(self.data), [])

    def test_source_closed_rejects_failed_or_stale_referenced_verification(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "source_closed"
        finding["closure_evidence"] = ["cargo test -p hop-core"]
        finding["closure_state"]["source"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.data["verification"].append(passed_verification("protected_ci"))

        # When the referenced test failed
        self.data["verification"][0]["result"] = "failed"
        self.assert_error_contains(
            "requires referenced verification to be passed at audit.commit"
        )

        # When the referenced test ran at another commit
        self.data["verification"][0]["result"] = "passed"
        self.data["verification"][0]["commit"] = "c" * 40
        self.assert_error_contains(
            "requires referenced verification to be passed at audit.commit"
        )

        # Restoring commit passes
        self.data["verification"][0]["commit"] = AUDIT_SHA
        self.assertEqual(validate_ledger(self.data), [])

    def test_source_closed_accepts_verification_entry_id(self) -> None:
        finding = self.data["findings"][0]
        finding["status"] = "source_closed"
        finding["closure_evidence"] = ["V-001 passed in CI at audit.commit."]
        finding["closure_state"]["source"] = "validated"
        self.data["approvals"].append(approval(finding["id"]))
        self.data["verification"].append(passed_verification("protected_ci"))
        self.data["verification"][0]["id"] = "V-001"
        self.assertEqual(validate_ledger(self.data), [])

    def test_closure_state_must_agree_with_status_and_evidence(self) -> None:
        self.data["findings"][0]["closure_state"]["source"] = "validated"
        errors = validate_ledger(self.data)
        self.assertTrue(any("closure_state.source must agree" in error for error in errors))
        self.assertTrue(any("requires passed protected_ci evidence" in error for error in errors))

    def test_decision_status_requires_recorded_residual(self) -> None:
        self.data["findings"][1]["residual"] = []
        self.assert_error_contains("must record the decision, dependency, or blocker")

    def test_unknown_priority_finding_is_rejected(self) -> None:
        self.data["executive_summary"]["lean_in"][0]["finding_id"] = "CORE-999"
        self.assert_error_contains("references unknown finding id: CORE-999")

    def test_duplicate_finding_must_reference_a_real_canonical_finding(self) -> None:
        duplicate = copy.deepcopy(self.data["findings"][0])
        duplicate["id"] = "CORE-DUP-001"
        duplicate["status"] = "duplicate"
        duplicate["relationships"] = ["CORE-999"]
        self.data["findings"].append(duplicate)
        self.assert_error_contains("relationships must reference a canonical finding ID")
        duplicate["relationships"] = ["CORE-001"]
        self.assertEqual(validate_ledger(self.data), [])

    def test_duplicate_findings_cannot_canonize_each_other(self) -> None:
        first = copy.deepcopy(self.data["findings"][0])
        first["id"] = "CORE-DUP-001"
        first["status"] = "duplicate"
        first["relationships"] = ["CORE-DUP-002"]
        second = copy.deepcopy(first)
        second["id"] = "CORE-DUP-002"
        second["relationships"] = ["CORE-DUP-001"]
        self.data["findings"].extend([first, second])
        errors = validate_ledger(self.data)
        self.assertEqual(
            sum("relationships must reference a canonical finding ID" in error for error in errors),
            2,
        )

    def test_malformed_verification_scope_reports_an_error_instead_of_crashing(self) -> None:
        self.data["verification"][0]["scope"] = ["source"]
        errors = validate_ledger(self.data)
        self.assertTrue(any("verification[0].scope must be a nonempty string" in error for error in errors))

    def test_malformed_statuses_and_boolean_round_report_errors(self) -> None:
        self.data["audit"]["round"] = True
        self.data["coverage"][0]["status"] = ["reviewed"]
        self.data["findings"][0]["status"] = ["open"]
        errors = validate_ledger(self.data)
        self.assertTrue(any("audit.round must be a positive integer" in error for error in errors))
        self.assertTrue(any("coverage[0].status has an unsupported value" in error for error in errors))
        self.assertTrue(any("findings[0].status has an unsupported value" in error for error in errors))

    def test_external_claim_provenance_requires_dated_sources(self) -> None:
        self.data["grades"]["source_quality"]["provenance"] = ["external_fact"]
        self.assert_error_contains("source_quality.external_sources must cite every external fact")

    def test_executive_external_fact_accepts_a_dated_source(self) -> None:
        self.data["executive_summary"]["assessment_provenance"] = ["external_fact"]
        self.data["executive_summary"]["assessment_external_sources"] = [
            {"location": "https://example.test/evidence", "retrieved_at": "2026-07-18"}
        ]
        self.assertEqual(validate_ledger(self.data), [])

    def test_malformed_audit_commit_reports_an_error_instead_of_crashing(self) -> None:
        self.data["audit"]["commit"] = [AUDIT_SHA]
        errors = validate_ledger(self.data)
        self.assertTrue(any("audit.commit must be a nonempty string" in error for error in errors))


class RendererTests(unittest.TestCase):
    def setUp(self) -> None:
        self.data = load_ledger(FIXTURE)

    def test_render_is_deterministic_and_escapes_ledger_content(self) -> None:
        first = render_report(self.data)
        second = render_report(copy.deepcopy(self.data))
        self.assertEqual(first, second)
        self.assertIn("Evidence &lt;must&gt; survive escaping", first)
        self.assertNotIn("Evidence <must> survive escaping", first)

    def test_report_contains_all_landscape_axes_and_contracts(self) -> None:
        report = render_report(self.data)
        self.assertIn("By domain", report)
        self.assertIn("By status", report)
        self.assertIn("By component", report)
        self.assertIn("c-abi", report)
        self.assertIn("Apple BLE bearer", report)
        self.assertIn("Private Repository", report)
        self.assertIn("Repository:", report)
        self.assertIn("Closure state", report)
        self.assertIn("Not Validated", report)

    def test_report_orders_findings_by_severity(self) -> None:
        report = render_report(self.data)
        self.assertLess(report.index("CORE-001"), report.index("BIZ-001"))

    def test_report_preserves_external_fact_retrieval_date(self) -> None:
        evidence = self.data["findings"][0]["evidence"][0]
        evidence["provenance"] = "external_fact"
        evidence["retrieved_at"] = "2026-07-18"
        self.assertIn("Retrieved: 2026-07-18", render_report(self.data))

    def test_report_includes_refutation_evidence(self) -> None:
        report = render_report(self.data)
        self.assertIn("core/hop-core/vectors/bundle-v10.json", report)
        self.assertIn("Peers cannot reject an unsupported wire layout before decoding it.", report)

    def test_not_graded_transitions_are_not_directional(self) -> None:
        closeout = as_closeout(self.data)
        closeout["grades"]["source_quality"]["previous"] = "Not graded"
        report = render_report(closeout)
        self.assertIn("Delta: Not comparable", report)

    def test_report_is_standalone_and_print_safe(self) -> None:
        report = render_report(self.data)
        self.assertNotIn('src="http', report)
        self.assertNotIn('href="http', report)
        self.assertIn("@media print", report)
        self.assertIn("prefers-reduced-motion", report)
        self.assertIn('role="group" aria-label="Finding filters"', report)
        self.assertIn('role="status" aria-live="polite"', report)

    def test_renderer_refuses_an_invalid_ledger(self) -> None:
        self.data["audit"]["commit"] = "not-a-sha"
        with self.assertRaisesRegex(ValueError, "ledger is invalid"):
            render_report(self.data)

    def test_cli_writes_the_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.html"
            result = subprocess.run(
                [sys.executable, str(SCRIPT_DIR / "render_report.py"), str(FIXTURE), str(output)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output.is_file())
            self.assertIn("HOP Adversarial Audit Sample", output.read_text(encoding="utf-8"))


class PackagingTests(unittest.TestCase):
    def test_claude_alias_resolves_to_the_canonical_skill(self) -> None:
        alias = REPO_ROOT / ".claude" / "skills" / "hop-adversarial-audit"
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.resolve(), SKILL_DIR.resolve())

    def test_skill_sources_do_not_contain_banned_dash_codepoints(self) -> None:
        banned = {chr(codepoint) for codepoint in range(0x2012, 0x2016)}
        for path in SKILL_DIR.rglob("*"):
            if path.is_file() and path.suffix in {".md", ".py", ".json"}:
                text = path.read_text(encoding="utf-8")
                self.assertFalse(banned.intersection(text), path)

    def test_fixture_remains_valid_json(self) -> None:
        with FIXTURE.open(encoding="utf-8") as handle:
            self.assertIsInstance(json.load(handle), dict)

    def test_eval_files_remain_valid_and_complete(self) -> None:
        evals = json.loads((SKILL_DIR / "evals" / "evals.json").read_text(encoding="utf-8"))
        triggers = json.loads((SKILL_DIR / "evals" / "trigger-evals.json").read_text(encoding="utf-8"))
        self.assertEqual(evals["skill_name"], "hop-adversarial-audit")
        self.assertEqual(len(evals["evals"]), 3)
        eval_ids = [item["id"] for item in evals["evals"]]
        self.assertEqual(len(eval_ids), len(set(eval_ids)))
        for item in evals["evals"]:
            self.assertIsInstance(item["id"], int)
            self.assertTrue(item["prompt"].strip())
            self.assertTrue(item["expected_output"].strip())
            self.assertIsInstance(item["files"], list)
            self.assertTrue(item["assertions"])
            self.assertTrue(all(isinstance(assertion, str) and assertion.strip() for assertion in item["assertions"]))
        self.assertEqual(len(triggers), 20)
        self.assertEqual(len({item["query"] for item in triggers}), len(triggers))
        self.assertTrue(all(isinstance(item["query"], str) and item["query"].strip() for item in triggers))
        self.assertTrue(all(isinstance(item["should_trigger"], bool) for item in triggers))
        self.assertEqual(sum(1 for item in triggers if item["should_trigger"]), 10)


class ScopeGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baseline = load_ledger(FIXTURE)
        self.campaign_approvals = [approval("CORE-001")]
        self.manifest = build_scope_manifest(
            self.baseline, ["CORE-001"], self.campaign_approvals
        )

    def candidate(self) -> dict[str, object]:
        candidate = copy.deepcopy(self.baseline)
        candidate["approvals"].extend(copy.deepcopy(self.campaign_approvals))
        return candidate

    def test_approved_finding_may_change(self) -> None:
        candidate = self.candidate()
        candidate["findings"][0]["status"] = "approved"
        self.assertEqual(verify_scope(self.baseline, candidate, self.manifest), [])

    def test_candidate_approval_records_must_match_scope(self) -> None:
        self.assertIn(
            "candidate approvals must preserve history and match campaign_approvals exactly",
            verify_scope(self.baseline, self.baseline, self.manifest),
        )
        candidate = self.candidate()
        candidate["approvals"].append(approval("BIZ-001"))
        self.assertIn(
            "candidate approvals must preserve history and match campaign_approvals exactly",
            verify_scope(self.baseline, candidate, self.manifest),
        )

    def test_approved_finding_immutable_fields_cannot_change(self) -> None:
        candidate = self.candidate()
        candidate["findings"][0]["invariant"] = "Weakened invariant"
        self.assertEqual(
            verify_scope(self.baseline, candidate, self.manifest),
            ["approved finding immutable fields changed: CORE-001"],
        )

    def test_unapproved_finding_change_is_rejected(self) -> None:
        candidate = self.candidate()
        candidate["findings"][1]["title"] = "Changed outside approved scope"
        self.assertEqual(
            verify_scope(self.baseline, candidate, self.manifest),
            ["protected finding changed: BIZ-001"],
        )

    def test_missing_unapproved_finding_is_rejected(self) -> None:
        candidate = self.candidate()
        candidate["findings"] = candidate["findings"][:1]
        candidate["executive_summary"]["lean_in"] = candidate["executive_summary"]["lean_in"][:1]
        self.assertEqual(
            verify_scope(self.baseline, candidate, self.manifest),
            ["protected finding is missing: BIZ-001"],
        )

    def test_refuted_candidate_change_is_rejected(self) -> None:
        candidate = self.candidate()
        candidate["refuted_candidates"][0]["disproof"] = "Changed disproof"
        self.assertEqual(
            verify_scope(self.baseline, candidate, self.manifest),
            ["protected refuted candidate changed: CAND-001"],
        )

    def test_incomplete_manifest_fails_closed(self) -> None:
        self.assertEqual(
            verify_scope(self.baseline, self.baseline, {"manifest_version": 1}),
            ["scope manifest fields are incomplete or unsupported"],
        )

    def test_duplicate_finding_shadow_is_rejected(self) -> None:
        candidate = self.candidate()
        candidate["findings"].append(copy.deepcopy(candidate["findings"][0]))
        errors = verify_scope(self.baseline, candidate, self.manifest)
        self.assertTrue(any("duplicate finding id: CORE-001" in error for error in errors))

    def test_duplicate_refuted_candidate_shadow_is_rejected(self) -> None:
        candidate = self.candidate()
        candidate["refuted_candidates"].append(copy.deepcopy(candidate["refuted_candidates"][0]))
        errors = verify_scope(self.baseline, candidate, self.manifest)
        self.assertTrue(any("duplicate refuted candidate id: CAND-001" in error for error in errors))

    def test_closeout_history_is_bound_to_baseline(self) -> None:
        candidate = as_closeout(self.baseline)
        candidate["approvals"].append(approval("CORE-001"))
        self.assertEqual(verify_scope(self.baseline, candidate, self.manifest), [])
        candidate["findings"][1]["previous_status"] = "open"
        self.assertIn(
            "finding previous_status does not match baseline: BIZ-001",
            verify_scope(self.baseline, candidate, self.manifest),
        )
        candidate = as_closeout(self.baseline)
        candidate["approvals"].append(approval("CORE-001"))
        candidate["grades"]["source_quality"]["previous"] = "A"
        self.assertIn(
            "grade previous value does not match baseline: source_quality",
            verify_scope(self.baseline, candidate, self.manifest),
        )

    def test_new_closeout_finding_uses_explicit_new_transition(self) -> None:
        candidate = as_closeout(self.baseline)
        candidate["approvals"].append(approval("CORE-001"))
        finding = copy.deepcopy(candidate["findings"][0])
        finding["id"] = "CORE-NEW-001"
        finding["title"] = "Newly discovered boundary"
        finding["previous_status"] = "new"
        candidate["findings"].append(finding)
        self.assertEqual(verify_scope(self.baseline, candidate, self.manifest), [])

    def test_refuted_finding_cannot_enter_remediation_scope(self) -> None:
        campaign = [approval("CAND-001")]
        with self.assertRaisesRegex(ValueError, "absent from the baseline: CAND-001"):
            build_scope_manifest(self.baseline, ["CAND-001"], campaign)

    def test_sequential_campaign_preserves_approval_history(self) -> None:
        baseline = copy.deepcopy(self.baseline)
        historical = approval("BIZ-001", "2026-07-18T19:00:00Z")
        baseline["approvals"].append(historical)
        campaign = [approval("CORE-001")]
        manifest = build_scope_manifest(baseline, ["CORE-001"], campaign)
        candidate = copy.deepcopy(baseline)
        candidate["approvals"].extend(campaign)
        self.assertEqual(verify_scope(baseline, candidate, manifest), [])
        candidate["approvals"][0]["scope"] = "Rewritten history"
        self.assertIn(
            "candidate approvals must preserve history and match campaign_approvals exactly",
            verify_scope(baseline, candidate, manifest),
        )

    def test_recomputed_but_incomplete_manifest_is_rejected_against_baseline(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["protected_findings"] = {}
        manifest["manifest_digest"] = canonical_digest(
            {key: value for key, value in manifest.items() if key != "manifest_digest"}
        )
        self.assertEqual(
            verify_scope(self.baseline, self.baseline, manifest),
            ["scope manifest does not match the immutable baseline"],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
