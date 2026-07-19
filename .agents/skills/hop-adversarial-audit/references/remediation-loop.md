# Approved Remediation Loop

Load this reference only after explicit approval.

## 1. Freeze scope

Validate the exact canonical baseline ledger and approval records. If the ledger, full SHA, approved finding evidence, or closure contract is unavailable, stop rather than infer it from examples or reports. Produce a work map containing:

- Approved finding IDs.
- Closure contract for each ID.
- Owning subsystem and release surface.
- Dependencies between controls.
- Required focused, integrated, live, registry, and hardware evidence.
- Paths and systems each mutator may change.

Create a scope manifest before mutation:

```text
python3 scripts/scope_guard.py snapshot baseline.json approval-records.json scope-manifest.json --approved CORE-001
```

`approval-records.json` is a JSON array with exactly one canonical approval record per finding in this campaign. The manifest freezes those full records, preserves all historical baseline approvals, fully digests every refuted candidate, and separately digests finding fields according to their allowed transitions. Verify it against the working ledger before integration and against the closeout ledger before publication.

Reject scope drift. A new independent finding gets a new ID and an explicit decision; it is not silently absorbed into a current lane.

## 2. Split work by coherent surface

Good lanes share one control boundary and verification path. Examples:

- Core wire and ratchet invariant.
- One durable store contract across implementations.
- One platform driver and its app consumer.
- One SDK publication surface.
- One workflow authority or provenance boundary.
- Pricing catalog and billing semantics.
- Sales qualification and design-partner operating artifact.

Bad lanes combine unrelated services, platforms, release systems, business artifacts, and live infrastructure because they happened to appear in one report.

## 3. Isolate mutators

For each lane:

1. Fetch the requested base.
2. Create one dedicated branch and worktree from the pinned SHA.
3. Give one mutating agent ownership.
4. Include finding evidence and closure contract in the prompt.
5. Require focused verification and a coherent commit before handoff.
6. Keep the worktree clean.

The lane packet contains concrete values, not references: full base SHA, branch name, worktree path, explicit allowed paths, prohibited paths, verbatim finding evidence, verbatim invariant, every closure-contract item, focused verification, and stop conditions.

Read-only auditors may share a checkout. Never let multiple mutators share a dirty worktree.

## 4. Implement the boundary, not the symptom

Use the closure contract as the test plan. Common incomplete fixes include:

- Per-object bound without process-global count or bytes.
- In-memory fix without durable restart behavior.
- Default backend fix without optional stores.
- Core fix without wrapper and package consumers.
- Timer tied to inbound traffic rather than independent liveness.
- Authentication without tenant, role, route, or contextual authorization.
- Build success without exact package export and clean installation.
- Source configuration without live settings evidence.
- Pricing copy without billing catalog and enforcement.
- Sales plan without owner, stage definitions, evidence capture, and exit criteria.

## 5. Require hostile regressions

A closure test should recreate the dangerous state or timeline and fail against unsafe behavior. Cover applicable:

- N-1, N, N+1, malformed, maximum, and high-bit boundaries.
- Crash or fault between every durable step.
- Restart and rehydration.
- Concurrent call, close, retry, and callback orderings.
- Sustained load without fresh input.
- Alternate backends and features.
- Cross-language and clean-consumer behavior.
- Guard bypasses and false positives.
- Business artifact consistency across public copy, catalog, contract, and operating process.

## 6. Independent closure attack

Do not ask the implementer to certify its own fix. Assign another reviewer to disprove closure by checking:

- The original scenario still reproduces elsewhere.
- The layer above or below remains unsafe.
- A second backend, platform, wrapper, or consumer bypasses the control.
- Aggregate state remains unbounded.
- Failure handling becomes fail-open or ephemeral.
- Tests assert implementation detail rather than invariant.
- The report claim exceeds direct evidence.

Reopen the finding when any required layer fails.

## 7. Integrate deliberately

Integrate committed lane branches in a separate integration worktree. Resolve conflicts as an integration task, not inside arbitrary fix lanes.

Run:

- Focused checks in each lane.
- The repository's current full verification suite on the integrated branch.
- Protected CI on the exact final SHA.
- Artifact, provenance, package export, and clean-consumer checks where affected.
- Direct live, registry, or hardware checks only with authority.

If the branch changes after evidence was produced, rerun affected checks and disclose chronology.

## 8. Ship in reviewable units

Use separate PRs or MRs for independent release surfaces and unrelated CI failures. Merge only on trustworthy green checks. Confirm deployment when merge triggers deployment.

Do not rewrite shared history or force-push without explicit approval.

## 9. Update the ledger

For each finding, record:

- Status transition.
- Commit and PR or MR.
- Implemented boundary.
- Source paths.
- Named hostile regression.
- Focused command and result.
- Integrated suite and protected-CI evidence.
- Deploy, package, live, registry, and hardware evidence.
- Residual and blocked work.
- Independent closure states for source, deploy, live, registry, hardware, operational, and business validation.

Run the scope guard before closeout:

```text
python3 scripts/scope_guard.py verify baseline.json closeout.json scope-manifest.json
```

Only use `source_closed` when source and CI closure are complete. Only use `operationally_validated` with direct operational evidence.

## 10. Publish the closeout

Render a new report from the updated ledger. Preserve the baseline format, original IDs, and original severities. Show previous grades, deltas, open external work, newly discovered findings, and evidence chronology.

Technical closure does not imply validated demand, legal approval, customer readiness, live deployment, or hardware proof. Keep each claim in its own axis.
