---
name: hop-adversarial-audit
description: "Runs HOP's canonical two-phase, evidence-grounded adversarial audit and approved-finding remediation workflow across protocol, every code, platform, release, and infrastructure component, plus product, pricing, sales, legal, finance, support, and operations. Always use for a HOP or hopmesh/monorepo audit, red team, readiness grade, process-forensics review, prior-audit rerun, get-to-A campaign, immutable graded report, finding-ID remediation, closure, or reviewer and fix-agent fan-out, even when only business or one audit domain is named. Do not use for ordinary bug fixes, single PR or diff reviews, site-only full-stack audits, copywriting, report summaries, credential rotation, or other projects."
compatibility: "Requires filesystem and Git access. Subagents and worktrees are strongly recommended. Web access is optional for market and legal evidence."
metadata:
  project: hop
  workflow: audit-remediate
---

# HOP Adversarial Audit

Run one evidence system with two deliberately separate modes:

1. **Audit mode** discovers, challenges, adjudicates, and publishes an immutable baseline. It never edits product source.
2. **Remediation mode** starts only after a human approves findings. It isolates fix agents, verifies closure adversarially, ships the work, and publishes a closeout in the same format.

The separation matters. Mixing fixes into discovery changes the evidence while it is being measured, anchors later reviewers, and makes it impossible to tell what the original state was.

## Select the mode

Use **audit mode** when there is no current baseline, the user requests an audit or report, or approval is ambiguous. Even if the initial request says "audit and fix everything," finish the report and stop at the approval gate.

Use **remediation mode** only when the user explicitly approves finding IDs, an entire named severity set, or all open findings in a specific baseline. Expand the approved set into one ledger approval record per finding before mutation.

If the user requests only a technical, business, or process slice, keep the same method but mark every excluded domain as scoped out with a rationale. Never silently omit a domain.

## Read the bundled guidance

Load only what the current phase needs:

- `references/audit-vectors.md` for component discovery, reviewer lanes, technical vectors, and business vectors.
- `references/finding-schema.md` before creating or changing the canonical ledger.
- `references/report-design.md` before rendering or reviewing the report.
- `references/remediation-loop.md` only after the approval gate opens.
- `references/cross-harness-install.md` when installing or sharing the skill between harnesses.

Use `scripts/validate_ledger.py` to reject incomplete or contradictory evidence. Use `scripts/render_report.py` to produce the report from the validated ledger. In remediation mode, use `scripts/scope_guard.py` to digest every unapproved record plus the immutable fields of approved findings before mutation, then verify them before closeout. The JSON ledger is canonical; never hand-maintain counts in HTML.

## Audit mode

### Phase 0: Freeze the evidence basis

Record before fan-out:

- Full commit SHA, branch, remote, dirty state, and audit round.
- Wire, ABI, schema, package, and deployment contract versions that exist.
- Prior audit and closeout reports.
- Authorized evidence sources and unavailable systems.
- Repository visibility, output access controls, and every public build or publication pipeline that could expose a report.
- Whether live cloud, production, registries, customer systems, hardware, or private business records may be inspected.
- Prohibited operations. Audit mode is read-only and must not mutate live systems.

Read the root instructions and every nearest component instruction before assessing that component. Treat documentation as a claim to verify, not as proof.

Never enumerate environment values or place credentials in prompts, findings, reports, or logs. Presence checks report only `NAME=set` or `NAME=unset`.

### Phase 1: Build the live inventory

Discover the current repository from files and manifests rather than copying an old component list. Inventory at least:

- Root contracts, governance, licenses, versions, and security policy.
- Every workspace member, package manifest, service, SDK, bearer, driver, app, simulator, testkit, fuzz target, example, generated artifact, and public mirror.
- Every workflow, release producer, deployment root, CI guard, package publisher, and trust boundary.
- Business strategy, pricing, billing, sales surfaces, legal material, operations, support, and public claims.

Give every inventory item a stable ID, path, classification, owner class, and evidence sources. The final coverage ledger must account for every item as reviewed or explicitly scoped out.

### Phase 2: Fan out independent adversarial reviewers

Create independent lanes from the live inventory. Do not give finders the other lanes' findings before their first pass.

Use three intersecting reviewer shapes:

- **Vertical component reviewers** own one component end to end, including its tests, consumers, deployment, documentation, and business role.
- **Horizontal vector reviewers** trace one invariant across components, such as forward secrecy, durable acceptance, authority, resource bounds, package provenance, pricing consistency, or customer onboarding.
- **Business and operating reviewers** independently assess market, positioning, sales, pricing, unit economics, legal readiness, support, governance, and execution systems.

Read-only reviewers may share a checkout. If a reviewer must write working files, give it an isolated worktree or an external temporary directory.

Every lane returns:

- Evidence inspected and checks run.
- Candidate findings using the canonical schema.
- High-value hypotheses it tried and refuted.
- Coverage limits and unavailable evidence.
- Drift between implementation, tests, documentation, public claims, and business plans.

Tag every claim and finding evidence item as `repository`, `external_fact`, `owner_claim`, `assumption`, `counsel_required`, or `direct_observation`. An attributed owner statement is not a verified external fact. External facts carry a URL or source and retrieval date. Counsel-required issues remain issue spotting until counsel supplies the conclusion.

When a harness has no subagents, run the same lanes sequentially with fresh prompts and separate notes. Preserve independence by withholding earlier candidate findings until refutation.

### Phase 3: Refute before accepting

Assign a different reviewer to disprove every Critical or High candidate and a representative sample of lower-severity candidates. The refuter should look for an existing bound, authorization check, transaction, restart behavior, test, compensating control, or invalid threat assumption.

Then use separate adjudication passes:

- **Evidence judge:** Is the claim directly supported and reproducible?
- **Severity judge:** Does impact and reach justify the rating?
- **Actionability judge:** Is the remediation boundary concrete and repository-owned?
- **Completeness critic:** Which component, layer above the local fix, alternate backend, restart path, aggregate limit, consumer, or operating dependency did the sweep miss?

Reject vague findings. Record useful refutations so later audits do not repeat dead ends.

### Phase 4: Define closure contracts

Before publishing, define what would close each accepted finding. Include every applicable layer:

- Hostile immediate path and exact boundary values.
- Aggregate count, bytes, lifetime, sender, stream, and process limits.
- Concurrency, teardown, callback, and call-versus-close races.
- Atomicity, fault injection, restart, rehydration, migration, and clock behavior.
- Alternate stores, features, platforms, wrappers, and clean package consumers.
- Protected CI, artifact provenance, live systems, registries, and physical hardware.

A suggested code edit is not a closure contract. State the invariant that must hold and the evidence that must prove it.

### Phase 5: Grade without hiding uncertainty

Keep independent grades for:

- Source quality.
- Validation coverage.
- Business readiness.
- Process quality.
- Operational readiness as `Validated`, `Partially validated`, or `Not validated`.

Never average these into one score. A technically strong source tree can coexist with weak business readiness or an unsafe remediation process.

### Phase 6: Publish the baseline

Default integrated technical and business reports to a verified private boundary. A private repository may use:

```text
business/audits/YYYY-MM-DD-hop-adversarial-audit.json
business/audits/YYYY-MM-DD-hop-adversarial-audit.html
```

The path is not the boundary. Before writing there, verify that the repository is private, the intended audience has access, and public site, package, mirror, artifact, and documentation builds exclude it. If any condition is false, write to an authorized private external location and keep only a non-sensitive reference in the repository.

Do not put fundraising, customer, pricing strategy, internal operations, legal advice, or other confidential evidence in a public repository or publication pipeline. Produce a sanitized technical companion under `docs/audits/` only when explicitly requested and only from a separately validated public-classification ledger. Redaction removes confidential records before rendering; CSS, collapsed sections, and client-side hiding are not redaction.

The report must answer:

- What can fail, how, and why?
- Which claims are unsupported or internally inconsistent?
- What is already strong and verified clean?
- Where should HOP lean in next, in priority and dependency order?
- What evidence is missing?
- Which actions are source-owned, owner-held, operational, hardware-gated, or accepted risk?

Topologically order priorities: shared prerequisites and controls precede findings that depend on them. Record dependency cycles as a planning defect rather than inventing a linear order.

Render the HTML from the ledger, validate it, inspect it visually, and preserve the same structure in later rounds.

### Approval gate

Present the report path, grade summary, accepted finding count, top priorities, explicit limits, and the exact approval choices. Then stop.

Acceptable approval examples:

- `Approve CORE-001, INFRA-004, and BIZ-003.`
- `Approve all Critical and High findings in audit hop-2026-07-18.`
- `Approve every open finding in this baseline.`

Do not infer approval from silence, urgency, or the original audit request.

## Remediation mode

### Phase 7: Freeze approved scope

Read and validate the exact canonical baseline, then record the approval. If the baseline, full SHA, finding evidence, or closure contract cannot be read directly, stop before designing or assigning a fix. Do not infer a finding from an example fixture, an HTML report, a prior audit, or a similarly named ID. Refuse IDs that do not exist, are refuted, or belong to another snapshot. Preserve original IDs and severities throughout remediation.

Create a scope manifest from the immutable baseline and the exact campaign approval records before any ledger or source mutation. It freezes the current approver, UTC timestamp, scope, all historical approvals, canonical digests for refuted candidates, and immutable-field digests for findings. Verify it against the working ledger and closeout so "approved," "untouched," and "preserved" are evidence, not promises.

Group approved findings by coherent subsystem and release surface. Split unrelated technical, business, operational, and live-infrastructure actions instead of growing one campaign.

### Phase 8: Fan out isolated fix agents

For every mutating lane:

- Fetch and pin the requested base SHA.
- Use one branch and one dedicated worktree per mutator.
- Give the agent the finding, violated invariant, closure contract, permitted paths, and focused verification commands.
- Require a coherent commit and clean-worktree handoff.
- Keep live infrastructure changes out of source remediation unless separately authorized.

Write a concrete mutator packet before assignment. It contains the literal base SHA, actual branch name, actual worktree path, explicit path allowlist, verbatim finding evidence, verbatim invariant, every closure-contract item, focused commands, prohibited paths, and stop conditions. References such as "the pinned SHA" or "the closure contract" are not a handoff.

Business remediation can produce strategy, pricing, sales, legal-review, or operating artifacts, but it must not invent customer evidence, legal approval, financial results, or market facts.

### Phase 9: Integrate and attack the fixes

Integrate committed lanes deliberately. After each lane:

- Run focused checks for the affected component.
- Assign an independent closure auditor to refute the fix.
- Reopen the finding when the control fails at restart, aggregate, alternate-backend, consumer, or operating boundaries.
- Add a regression that fails against the unsafe behavior and passes with the control.

Run the repository's full current verification suite once on the integrated branch, then protected CI for the exact final SHA. Re-run affected evidence after any merge or rebase.

### Phase 10: Ship and close out

Ship reviewable PRs or MRs, merge only on trustworthy green checks, and confirm deploys when merging deploys. Keep owner-held and externally blocked work open.

Update the canonical ledger with:

- Commit, PR or MR, source paths, and named regressions.
- Exact focused, integrated, CI, artifact, package, live, and hardware evidence.
- Evidence chronology, including anything run before branch reconciliation.
- Residual risk and unrun operational validation.

Maintain the per-finding closure-state matrix for `source`, `deploy`, `live`, `registry`, `hardware`, `operational`, and `business`. Each axis is independently `validated`, `not_validated`, `blocked`, or `not_applicable`; one validated axis never promotes another.

Render a closeout report in the identical format with previous grades and deltas. Source closure, deployed closure, business validation, and operational readiness remain separate claims.

## Finding status discipline

Use only the statuses defined in `references/finding-schema.md`. In particular:

- `source_closed` means the source control and hostile regression exist and protected CI passed.
- `operationally_validated` requires direct operational evidence.
- `accepted_risk` requires an owner, rationale, and review trigger.
- `blocked` names the missing authority, hardware, data, or decision.
- Refuted hypotheses live in `refuted_candidates` with their disproof and evidence; they are not accepted finding statuses.

Never mark a finding closed merely because code was edited or a broad suite was green.

## Communication

Report discoveries and blockers while work proceeds, but do not narrate routine reads. Use priority order and dependency-based phases, never time estimates.

Ask only for decisions that genuinely require the owner: approval scope, live-system authority, business assertions unavailable in evidence, accepted risk, legal signoff, credential rotation, or destructive operations.

## Definition of done

Audit mode is done when the inventory is complete, independent review and refutation finished, the ledger validates, the HTML was visually inspected, limits are explicit, and the human approval gate is waiting.

Remediation mode is done when approved source work is merged on green, exact closure evidence is recorded, deploys are confirmed where observable, unresolved external work remains honest, and the closeout report is generated from the same ledger format.
