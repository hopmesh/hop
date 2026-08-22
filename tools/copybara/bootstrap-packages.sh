#!/usr/bin/env bash
# bootstrap-packages.sh: RETIRED. This script has no work left to do.
#
# It existed to first-publish a package to each registry from its clean mirror clone, then point that
# package's Trusted Publisher at the mirror's release.yml. Every mirror it published FROM was retired
# in the 2026-08 mirror retirement: hop-sdk-node and hop-wasm (npm), hop-sdk-python (PyPI),
# hop-sdk-ruby (RubyGems), hop-sdk-elixir (Hex), hop-core and the two stores (crates.io), the Android
# repos (Maven), and hop-embedded (PlatformIO). All of those repos are deleted, so every clone,
# publish, and set-secret step here would target a repository that no longer exists.
#
# Several of those publishes never happened at all. What IS live is two npm packages under the
# @hop-mesh scope and three crates published under the renamed hop-mesh-* scheme, all of which name
# hopmesh/monorepo in their repository field. Nothing of ours is on PyPI, RubyGems, Hex, pub.dev, or
# PlatformIO, and the bare hop-core and hop crates on crates.io belong to unrelated third parties.
#
# The components that mirror (hop-sdk-go, hop-sdk-crystal, hop-sdk-apple, and the restored
# hop-bearers-apple) publish by pushing a git tag: the repo IS the package. They need no registry
# account, no registry token, and no trusted-publisher configuration, which is exactly why nothing
# replaced this script.
#
# The full record is docs/repo-catalog.md, under "Registry fallout of the mirror retirement".
set -euo pipefail

cat >&2 <<'EOF'
bootstrap-packages.sh is retired and does nothing.

The mirror fleet it published from was retired in 2026-08 and those repos are deleted. The live
mirrors (hop-sdk-go, hop-sdk-crystal, hop-sdk-apple, hop-bearers-apple) publish by git tag and need
no registry account, token, or trusted publisher.

For what is published and what is not, see docs/repo-catalog.md, section
"Registry fallout of the mirror retirement".
EOF
exit 1
