# docs/

Developer + design docs. Design rationale (`crash-reporting-design.md`, `identity-backup-restore-design.md`,
`libhop-architecture.md`, ...), positioning/pricing, release engineering, and `runbooks/`.

`DESIGN.md` and `MECHANISMS.md` at the repo root are the canonical protocol + mechanism references; this
directory is the surrounding developer material.

## Rules

- **`docs/` is scanned by `tools/docs-token-guard.sh` in CI.** No em-dashes, en-dashes, or lookalike
  dashes; say BLE, never the older radio-brand name; no removed terms (InternetEgress, Wi-Fi Direct)
  presented as live. Lines that document a REMOVAL are allowed.
- Keep claims grounded in the code. When a doc states a wire version, an ABI version, or a flag, verify
  it against the source (the audits have caught docs drifting two wire bumps behind reality).
