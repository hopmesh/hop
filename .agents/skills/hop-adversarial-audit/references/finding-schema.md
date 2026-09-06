# Canonical Ledger And Finding Schema

The JSON ledger is the source of truth for baseline and closeout reports. Preserve IDs, original severity, and original evidence across rounds.

## Top-level shape

```json
{
  "schema_version": 2,
  "audit": {
    "id": "hop-2026-07-18-round-1",
    "title": "HOP Adversarial Audit",
    "date": "2026-07-18",
    "commit": "40-character-git-sha",
    "branch": "main",
    "remote": "git@github.com:hopmesh/monorepo.git",
    "dirty": false,
    "round": 1,
    "mode": "baseline",
    "classification": "internal",
    "baseline": null,
    "scope": "Technical, business, and operating readiness"
  },
  "contracts": [
    {"name": "wire", "version": "10", "location": "core/hop-core/src/bundle.rs"}
  ],
  "publication": {
    "boundary": "private_repository",
    "output_root": "business/audits",
    "public_build_excluded": true,
    "redaction_policy": "Remove confidential evidence before any public companion is rendered."
  },
  "grades": {
    "source_quality": {"grade": "C", "previous": null, "visibility": "public", "provenance": ["repository"], "rationale": "...", "evidence": ["CORE-001"]},
    "validation_coverage": {"grade": "B", "previous": null, "visibility": "internal", "provenance": ["direct_observation"], "rationale": "...", "evidence": ["verification:Rust workspace"]},
    "business_readiness": {"grade": "C-", "previous": null, "visibility": "internal", "provenance": ["repository", "owner_claim"], "rationale": "...", "evidence": ["BIZ-003"]},
    "process_quality": {"grade": "B-", "previous": null, "visibility": "internal", "provenance": ["repository"], "rationale": "...", "evidence": ["coverage ledger"]},
    "operational_readiness": {"grade": "Not validated", "previous": null, "visibility": "internal", "provenance": ["direct_observation"], "rationale": "...", "evidence": ["limit:live access unavailable"]}
  },
  "executive_summary": {
    "assessment": "...",
    "assessment_visibility": "internal",
    "assessment_provenance": ["repository", "direct_observation"],
    "strengths": [{"claim": "...", "visibility": "public", "provenance": ["repository"], "evidence": ["file:line"]}],
    "lean_in": [
      {
        "finding_id": "CORE-001",
        "why_now": "...",
        "next_control": "...",
        "owner_class": "engineering",
        "visibility": "public",
        "provenance": ["repository"],
        "dependencies": ["Store fault-injection harness"]
      }
    ]
  },
  "inventory": [],
  "coverage": [],
  "findings": [],
  "refuted_candidates": [],
  "verification": [],
  "limits": [],
  "operational_actions": [],
  "approvals": []
}
```

Publication boundaries are `private_repository`, `private_external`, and `public_repository`. An internal ledger cannot use a public repository boundary and must be excluded from public builds. Verify the declared boundary outside the ledger: a directory name does not prove repository visibility, access control, or build exclusion.

## Inventory item

```json
{
  "id": "core-hop-core",
  "path": "core/hop-core",
  "name": "hop-core",
  "kind": "protocol-crate",
  "classification": "public",
  "owner_class": "engineering",
  "evidence_sources": ["Cargo.toml", "core/hop-core/CLAUDE.md"]
}
```

Use `internal` for business, customer, fundraising, legal, security-sensitive, or operating evidence that must not enter a public report.

## Coverage item

```json
{
  "inventory_id": "core-hop-core",
  "status": "reviewed",
  "reviewers": ["protocol-finder", "crypto-refuter"],
  "vectors": ["wire", "ratchet", "resource-bounds", "fuzzing"],
  "evidence": ["core/hop-core/src/bundle.rs:1-240", "cargo test -p hop-core"],
  "rationale": ""
}
```

Statuses are `reviewed` and `scoped_out`. A scoped-out item needs a nonempty rationale. `pending` is allowed only in working ledgers and fails final validation. Each inventory item has exactly one final coverage entry; combine independent reviewer names, vectors, and evidence in that entry.

## Finding

```json
{
  "id": "CORE-001",
  "domain": "technical",
  "status": "open",
  "previous_status": null,
  "severity": "high",
  "original_severity": "high",
  "confidence": "high",
  "visibility": "public",
  "component": "core/hop-core",
  "vector": "durability",
  "title": "Acceptance precedes durable ratchet commit",
  "invariant": "A message is accepted only after authenticated durable state advances atomically.",
  "threat_model": "A local crash or storage fault occurs between acknowledgement and ratchet persistence.",
  "impact": "The sender observes success while restart permits state rollback or message loss.",
  "business_impact": "The managed delivery guarantee becomes unprovable.",
  "scenario": "1. ... 2. ... 3. ...",
  "root_cause": "Acknowledgement is not transactionally bound to ratchet persistence.",
  "evidence": [
    {
      "kind": "source",
      "provenance": "repository",
      "location": "core/hop-core/src/example.rs:10-40",
      "detail": "..."
    }
  ],
  "coverage_gap": "Existing tests exercise success but not a fault between writes.",
  "remediation_boundary": "Commit message and ratchet state atomically before acknowledgement.",
  "closure_contract": [
    "Fault injection at every durable write boundary",
    "Restart proves no accepted message can roll state back",
    "All supported stores pass the same hostile regression"
  ],
  "relationships": [],
  "closure_evidence": [],
  "closure_state": {
    "source": "not_validated",
    "deploy": "not_validated",
    "live": "not_validated",
    "registry": "not_validated",
    "hardware": "not_validated",
    "operational": "not_validated",
    "business": "not_applicable"
  },
  "residual": [],
  "owner_class": "engineering"
}
```

Domains are `technical`, `business`, `operations`, and `process`.

Visibilities are `public` and `internal`. A public ledger cannot contain internal findings.

Evidence provenance is one of:

- `repository`: source, tests, configuration, tracked documents, or generated artifacts from the frozen snapshot.
- `external_fact`: a sourced external record with `retrieved_at` in `YYYY-MM-DD` form.
- `owner_claim`: an attributed statement that remains a claim until corroborated.
- `assumption`: an explicit model input or hypothesis, never a verified fact.
- `counsel_required`: legal issue spotting that cannot be promoted to a legal conclusion without counsel evidence.
- `direct_observation`: command output or authorized live, registry, hardware, customer, or operating evidence directly observed by the auditor.

Keep the provenance value on each evidence item. Do not merge owner claims, assumptions, or counsel-required issues into a generic evidence paragraph that reads as established fact.

Grade rationales, the executive assessment, strengths, priorities, refuted hypotheses, verification records, limits, and operational actions also carry `visibility` plus a nonempty `provenance` array. Any claim whose provenance includes `external_fact` carries a nonempty `external_sources` array of `{"location": "URL or source", "retrieved_at": "YYYY-MM-DD"}` objects. Limits and actions use objects shaped as `{"text": "...", "visibility": "internal", "provenance": ["direct_observation"]}`. Public ledgers reject any internal claim metadata.

Every finding carries a closure-state matrix with exactly these axes: `source`, `deploy`, `live`, `registry`, `hardware`, `operational`, and `business`. Each value is `validated`, `not_validated`, `blocked`, or `not_applicable`. A validated axis requires passed verification with the matching scope at the audit commit. Source validation requires `protected_ci` evidence. The matrix keeps source closure from silently promoting deployment, live, hardware, customer, or business claims.

## Finding statuses

- `candidate`: working hypothesis, never publish as accepted.
- `open`: accepted and not approved for remediation.
- `approved`: human approved and not yet assigned.
- `in_remediation`: isolated implementation is active.
- `source_closed`: source control, hostile regression, integrated suite, and protected CI are complete.
- `operationally_validated`: direct live, registry, settings, or hardware evidence exists.
- `accepted_risk`: owner, rationale, and review trigger are recorded.
- `deferred`: dependency or priority decision is recorded.
- `blocked`: missing authority, hardware, data, credential, or owner decision is explicit.
- `duplicate`: at least one relationship names a different, existing canonical finding ID.

Refuted hypotheses live only in `refuted_candidates`, where disproof and evidence are required. They do not appear in the accepted `findings` array and cannot enter remediation scope.

## Severity

- `critical`: feasible compromise or systemic failure of a foundational safety, identity, confidentiality, financial, or business-survival control.
- `high`: material cross-user, cross-tenant, durable-loss, authority, privacy, revenue, legal, or go-to-market failure.
- `medium`: bounded but real correctness, reliability, readiness, cost, sales, or process weakness.
- `low`: narrow hardening, maintainability, clarity, or localized experience issue.
- `info`: verified observation, strength, or future consideration without a current defect.

Severity measures impact and reach, not implementation effort. Preserve `original_severity`; use a separate current assessment if later evidence changes risk.

## Refuted candidate

```json
{
  "id": "CAND-014",
  "title": "...",
  "component": "...",
  "hypothesis": "...",
  "disproof": "...",
  "visibility": "public",
  "provenance": ["repository", "direct_observation"],
  "evidence": ["file:line", "exact command and result"]
}
```

## Verification item

```json
{
  "name": "Rust workspace",
  "command": "cargo test --workspace",
  "result": "passed",
  "commit": "40-character-git-sha",
  "scope": "source",
  "visibility": "internal",
  "provenance": ["direct_observation"],
  "notes": ""
}
```

Results are `passed`, `failed`, `not_run`, and `blocked`. Do not record `passed` without direct output for the exact SHA.

## Approval

```json
{
  "finding_id": "CORE-001",
  "approved_by": "repository owner",
  "approved_at": "2026-07-18T20:00:00Z",
  "scope": "Full closure contract"
}
```

Approval is not closure. Remediation mode may mutate only findings represented by approval records or an explicit, recorded group approval.

Expand a group approval into one approval record per matching finding. Use a UTC timestamp in `YYYY-MM-DDTHH:MM:SSZ` form. The validator rejects `approved`, `in_remediation`, `source_closed`, `operationally_validated`, `accepted_risk`, and `deferred` statuses without a matching approval record.

`source_closed` requires closure evidence referencing at least one specific verification entry ID or test command that ran and passed at the audit commit, plus passed protected-CI verification. `operationally_validated` requires closure evidence and passed `operational` verification. A technical finding may retain `source: validated`, which independently requires protected CI; an operational finding may use `source: not_applicable`. `accepted_risk`, `deferred`, and `blocked` findings record the decision, dependency, or blocker in `residual`.

## Closeout transitions

A closeout sets `audit.mode` to `closeout` and adds the immutable baseline identity:

```json
"baseline": {
  "id": "hop-2026-07-18-round-1",
  "commit": "40-character-baseline-git-sha"
}
```

Every grade records `previous`, and every existing finding records its exact baseline status in `previous_status`. A finding discovered during remediation uses `previous_status: "new"`. The scope guard compares these values with the immutable baseline. The renderer computes and displays grade deltas plus status transitions; transitions to or from `Not graded` are labeled `Not comparable`. A baseline audit uses `baseline: null`, `previous: null`, and `previous_status: null`.

The scope manifest includes a self-digest, immutable-field digests for every finding, and full digests for refuted candidates. Status, closure evidence, closure state, residuals, and the baseline-bound transition marker may evolve only where the schema permits; IDs, original severity, evidence, invariants, and closure contracts may not. Verification requires the candidate approval-record IDs to match the manifest exactly, re-derives the manifest from the immutable baseline, validates the candidate ledger, rejects incomplete manifests and duplicate IDs, and binds a closeout to the exact baseline ID and commit. Refuted, duplicate, closed, and otherwise ineligible finding statuses cannot enter a new remediation scope.

## Tool checks

Run both commands before publishing a ledger or report:

```text
python3 scripts/validate_ledger.py path/to/audit.json
python3 scripts/render_report.py path/to/audit.json path/to/audit.html
python3 scripts/scope_guard.py snapshot baseline.json approval-records.json scope.json --approved CORE-001
python3 scripts/scope_guard.py verify baseline.json closeout.json scope.json
```

The bundled `fixtures/sample-ledger.json` is a complete representative input. `scripts/test_tools.py` verifies validation contradictions, approval integrity, immutable unapproved records, closure-state separation, deterministic rendering, HTML escaping, print behavior, and cross-harness discovery.

## Grade rubric

### Source quality

- `A`: no known source failure; every accepted finding has its boundary and hostile regression.
- `A-`: no Critical or High source finding; only bounded minor residuals remain.
- `B`: open Medium findings or a material boundary is partial.
- `C`: open High finding, fail-open behavior, or an unenforced core invariant.
- `D` or `F`: open Critical finding or foundational controls are absent.

### Validation coverage

- `A`: every applicable source, integration, durability, packaging, live, and hardware class was exercised on the exact snapshot.
- `A-`: source and cross-platform evidence are complete; explicit live or hardware work remains.
- `B`: material layers remain static-only or representative-only.
- `C` or lower: broad domains are untested or the hostile scenario is absent.

### Business readiness

- `A`: coherent ICP, validated demand, consistent pricing, defensible economics, repeatable GTM, and required commercial controls have direct evidence.
- `B`: direction is coherent but one or more material assumptions remain weakly validated.
- `C`: strategy spans conflicting buyers or pricing and operating claims do not match product state.
- `D` or `F`: no credible path from product to customer, revenue, or compliant operation is evidenced.

### Process quality

Grade Git recovery, agent isolation, scope control, verification granularity, secret handling, evidence chronology, and source-versus-live discipline.

### Operational readiness

Use only `Validated`, `Partially validated`, and `Not validated`. This axis requires direct operational evidence and is not a letter grade.
