# Report Design And Information Architecture

Generate the report from the canonical ledger. Keep the structure identical between baseline and closeout rounds so deltas are meaningful.

## Classification and paths

An integrated report containing business, customer, fundraising, legal, pricing strategy, or internal operations defaults to `internal`. Store it in an authorized private external location or under `business/audits/` only after verifying that the repository is private, intended readers have access, and no public site, package, mirror, documentation, or artifact pipeline includes that path.

A directory named `internal` or `business` is not an access-control boundary. If repository visibility or publication exclusion cannot be verified, do not commit the confidential ledger or report.

A report under `docs/audits/` must use a `public` ledger and omit internal evidence. Redaction means removing the confidential item and summarizing the limitation, not hiding it with CSS or client-side JavaScript.

## Required sections

1. **Signal header**
   - Audit name, date, round, mode, branch, full SHA, and classification.
   - One-sentence assessment grounded in evidence.

2. **Independent scorecard**
   - Source quality.
   - Validation coverage.
   - Business readiness.
   - Process quality.
   - Operational readiness.
   - Previous grade and delta in closeout rounds.

3. **Where to lean in**
   - Topologically sorted dependency order, not a timeline. Shared prerequisites precede dependents.
   - Finding ID, why now, next control, owner class, and dependencies.
   - Separate source work from owner-held and operational work.

4. **Finding landscape**
   - Counts by severity, domain, status, and component.
   - Filters must not hide counts or change printed output.

5. **Finding ledger**
   - Stable ID, severity, confidence, status, component, and vector.
   - Invariant, impact, business impact, scenario, root cause, evidence, gap, remediation boundary, closure contract, residuals, and closure evidence.
   - Expand all cards in print mode.
   - Show independent source, deploy, live, registry, hardware, operational, and business closure states.

6. **Coverage map**
   - Every inventory item.
   - Reviewer lanes, vectors, evidence, and scoped-out rationale.
   - Gaps are visually obvious.

7. **Verified clean and refuted**
   - Valuable hypotheses tested and disproved.
   - Existing strengths with direct evidence.

8. **Verification and chronology**
   - Exact command, result, scope, and SHA.
   - Clearly label evidence run before a merge or rebase.

9. **Limits and external actions**
   - Missing cloud, hardware, registry, customer, legal, financial, and owner evidence.
   - Blocked, accepted, and deferred work.

10. **Method**
    - Inventory basis, reviewer topology, refutation, adjudication, and grading.

## Visual direction

Use a signal-intelligence field report rather than a generic dashboard:

- Deep graphite and ink background with subtle mesh or topographic line texture.
- Signal green for verified controls, cyan for evidence, amber for uncertainty, orange for High, and red for Critical.
- Strong typographic contrast: compact display headings, readable sans body, monospace for IDs, paths, SHAs, commands, and measurements.
- Dense information can use cards and tables, but the executive path should remain obvious.
- Use inline SVG icons when useful. Never use emoji as icons.
- No network fonts, external JavaScript, tracking, or runtime dependencies.
- Responsive from narrow mobile to wide desktop.
- Accessible contrast, keyboard-operable details and filters, semantic headings, visible focus, and reduced-motion support.
- Print and PDF output must preserve evidence, expand findings, remove controls, and avoid clipped cards.

The bundled renderer implements this visual family. If a prior report exists, preserve its exact section order and dimensions unless the ledger schema requires a new field.

## Content rules

- Every grade and claim cites evidence.
- Every finding evidence item declares whether it is repository evidence, an external fact, an owner claim, an assumption, counsel-required issue spotting, or a direct observation. External facts include retrieval dates.
- Every count is generated from the ledger.
- Avoid stock assurance language such as "enterprise-grade" without proof.
- State unknowns directly.
- Use dependency phases without time estimates.
- Do not use em dashes or en dashes in HOP artifacts.
- Do not expose secret values, customer identities, private contact data, or confidential financial details in a public report.
- Illustrative imagery is allowed only when labeled and never substitutes for evidence.

## Closeout differences

Keep the baseline structure, then add:

- Previous grades and deltas.
- Status transitions by original finding ID.
- Commit and PR evidence.
- Named hostile regressions.
- Integrated and protected-CI evidence for the exact final SHA.
- Deploy, registry, hardware, and external-setting status.
- Residual and newly discovered findings.

Never overwrite the baseline. A closeout is a new immutable report linked back to it.
