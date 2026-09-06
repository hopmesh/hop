# Audit history, and what the F-xx / SVC-xxx / PROC-xxx identifiers mean

Code and comments across this repository cite finding identifiers: `F-01`, `SVC-002`, `PROC-001`,
`GT-04`, `PLAT-003`, and similar. They are real, and this file is where they resolve.

## Where the reports are

The adversarial-audit corpus lives in a **private** companion repository, `hopmesh/internal`, not here.
That is deliberate and it is not about hiding defects.

A published security advisory is a scoped artifact: one issue, the affected and fixed versions, a
pointer to the fix, written for an outside reader. The corpus is none of those things. It is a set of
dated internal working documents, including remediation-process forensics and grading narratives, whose
own index concedes it contains statements that "were already false by later commits" and a finding
count that "does not reconcile". Publishing raw internal notes costs the same disclosure as an advisory
while providing none of its clarity, because a reader cannot tell from them what is still open.

`GAP-ANALYSIS.md` in that corpus says so directly:

> **HISTORICAL SNAPSHOT.** This document is a point-in-time audit narrative from the 2026-07 pass, not a
> live status board. Most of the High items below were remediated after it was written.

"Most" is not "all", and the report does not say which. That is precisely why it is not a public
document, and equally why it is not deleted.

## How to read a citation you find in the code

A comment like `// GT-04: hopmesh/platform/services/hop-billingd's live feature carries the Stripe HTTP transport` is telling you
WHY a piece of code or a guard exists. The reasoning is in the comment; the identifier is provenance,
not a required lookup. Nothing in this repository needs the corpus to be understood.

Several guards in `tools/` exist BECAUSE of a finding and encode it permanently, which is the durable
form of an audit result. `mailbox-prefix-doc-guard.sh` (PROTO-004) and the retired dash-guard carve-out
(PROC-001) are the clearest examples: the finding became an enforced check rather than a paragraph.

## Reporting something new

See `SECURITY.md`. Report privately; do not open a public issue for a suspected vulnerability.

## Fixed issues and security disclosure policy

Fixed vulnerabilities are worth publishing, and silence is a worse signal than disclosure.
Advisory publication follows a clear division of responsibility:

- **Externally-reported vulnerabilities:** For vulnerabilities reported through coordinated disclosure
  channels (see `SECURITY.md`), GitHub Security Advisories (GHSAs) are reserved for future post-1.0
  production releases and will be published against this repository upon remediation, naming the affected
  versions, remediation commits, and crediting reporters. During pre-1.0 development, security fixes
  are documented in `CHANGELOG.md` and accompanied by regression tests and wire vectors.
- **Internal dogfooding and adversarial audit findings:** Severity-labeled findings originating from
  internal audit rounds (such as F-xx, SVC-xxx, PROC-xxx, or pre-release items such as the pass-5 DNSSEC
  name-hijack fix and Node reply UAF in commit `ace223bc`, originally hopmesh/monorepo#138) are resolved pre-release
  and tracked directly in `CHANGELOG.md` and repository test vectors rather than as retrospective GHSAs. Where an advisory
  corresponds to a corpus identifier, it cites it, so the two reconcile without the raw notes being public.
