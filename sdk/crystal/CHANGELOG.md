# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- bind the C sample sinks to ABI 7 and settle formatter drift (3927543)
- handle service request acceptance and add persistent node constructor (ABI-002, ABI-003) (4721a7e)
- bind C ABI 7 surface and propagate rekey and request acceptance (ABI-002, ABI-004) (83b31cc)
- repoint the build identity and published metadata at hopmesh/hop (b2e6203)
- pass-5 audit remediation - DNSSEC name-hijack (CRITICAL) + Node reply UAF (HIGH) (#138) (ace223b)

### Chore
- bump version to 0.0.3 across workspace and SDKs (ABI-008) (e01ecbb)
- bind the v6 hps surface in the Node and Crystal wrappers (ea6f186)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (570c680)

### Documentation
- update prose claims and exclude changelog in check-abi-version (ABI-002, ABI-004, ABI-005) (903bc65)
- regenerate from conventional commits (f592a14)
- regenerate from conventional commits (ce99725)
- regenerate from conventional commits (0ba8f06)
- regenerate from conventional commits (288fb51)
- regenerate from conventional commits (f880b09)
- regenerate from conventional commits (adfd838)
- regenerate from conventional commits (9719166)
- regenerate from conventional commits (b185836)
- regenerate from conventional commits (0c6daf4)
- regenerate from conventional commits (8bd2185)
- regenerate from conventional commits (7c9cd96)
- regenerate from conventional commits (c563741)
- regenerate from conventional commits (9b0e086)
- regenerate from conventional commits (85aa20d)
- regenerate from conventional commits (f174097)
- regenerate from conventional commits (b49b07c)
- regenerate from conventional commits (0b7100d)
- regenerate from conventional commits (7eb4bed)

### Features
- run this repository's own CI, and repoint every canonical-repo gate at hopmesh/hop (d6f9618)
- expose the endpoint CP quorum setter in all six SDKs (#161) (3ce3c0c)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (865a687)
- Crystal endpoint SDK (lib bindings, zero shards) + block/channel surface (#132) (cc58756)

