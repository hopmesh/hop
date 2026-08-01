#!/usr/bin/env bash
# bootstrap-mirrors.sh: create or update the standalone component repositories.
# Covers the Apache-2.0 SDKs and the FSL-1.1-ALv2 core, service, bearer, and driver components (FSL is
# source-available, so those are public too). RUN THIS YOURSELF: creating public repositories is a human
# action, not something CI or an agent does for you. Idempotent and safe to re-run.
#
# Requires: `gh` authenticated with repo + admin rights on the hopmesh org.
#
# The SDKs are Apache-2.0, so the mirrors are public. Creating an empty public repo publishes nothing
# yet; the source only appears once you SEED it (the last section), which you do after the Copybara
# configs for each component land. See tools/copybara/README.md.
set -euo pipefail

ORG="hopmesh"

# "repo|description" per public repo. The SDK repos are Apache-2.0; the core, service, bearer, and
# driver repos are FSL-1.1-ALv2 (source-available, so still public). Descriptions say what each thing IS
# with no reference to any private source of truth. Kept bash-3.2 safe (no associative arrays) so it runs
# on stock macOS.
MIRRORS="
hop-sdk-node|Receive Hop mesh messages in Node with an Express/Fastify-shaped API over the libhop C ABI. npm: @hop-mesh/endpoint.
hop-sdk-python|Receive Hop mesh messages in Python: an embeddable endpoint over the libhop C ABI (ctypes). On PyPI.
hop-sdk-go|Receive Hop mesh messages in Go with a net/http-shaped surface over the libhop C ABI (cgo). A Go module.
hop-sdk-ruby|Receive Hop mesh messages in Ruby with a Sinatra/Rails-shaped surface over the libhop C ABI (Fiddle). On RubyGems.
hop-sdk-crystal|Receive Hop mesh messages in Crystal with a Sinatra/Rails-shaped surface over the libhop C ABI. On shards.
hop-sdk-elixir|Receive Hop mesh messages in Elixir with a Phoenix/Plug-shaped surface over hop-core via a Rustler NIF. On Hex.
hop-sdk-apple|The Hop client SDK for Apple platforms: run a node on iOS/macOS. SwiftPM + xcframework.
hop-sdk-android|The Hop client SDK for Android: run a node on-device. Maven (AAR).
hop-sdk-react-native|The Hop client SDK for React Native: run a node in a cross-platform app over the native iOS and Android SDKs. npm: @hop-mesh/react-native.
hop-embedded|Hop for microcontrollers: an Arduino/ESP-IDF C++ library over the libhop C ABI (ESP32). On the PlatformIO registry.
hop-core|The Hop protocol in pure Rust: bundles, the wire format, Noise links, epidemic routing, the untraceable metadata path, and the crypto.
libhop|The Hop C ABI (hop.h) over hop-core: the universal client and bearer contract every non-Rust SDK binds. Prebuilt binaries + a crate.
hop-wasm|hop-core compiled to WASM: a real Hop node in the browser.
hop-store-sqlite|SQLite + SQLCipher persistence for Hop, behind the Store trait.
hop-store-firestore|Firestore persistence for the Hop cloud relay and mailbox.
hop-bearers-apple|Hop transport bearers for Apple platforms: BLE, LAN, and Relay. SwiftPM.
hop-bearers-android|Hop transport bearers for Android: BLE, LAN, and Relay. Maven.
hop-driver-apple|The Hop app-facing client for Apple platforms: a node plus bearers plus the UI glue. SwiftPM.
hop-driver-android|The Hop app-facing client for Android: a node plus bearers plus the UI glue. Maven.
hop-relayd|The Hop relay: store-and-forward for offline peers, the most internet-exposed process in the mesh.
hop-endpoint|The Hop hops:// origin endpoint: HTTP-over-mesh bound to one domain.
hop-gateway|The Hop gateway.
"

echo "== 1. create / publish the mirror repos =="
printf '%s\n' "$MIRRORS" | while IFS='|' read -r repo desc; do
  [ -z "$repo" ] && continue
  full="$ORG/$repo"
  if gh repo view "$full" >/dev/null 2>&1; then
    echo "  exists: $full  (ensuring public + description)"
    gh repo edit "$full" --visibility public --accept-visibility-change-consequences >/dev/null || true
    gh repo edit "$full" --description "$desc" >/dev/null || true
  else
    echo "  creating (public): $full"
    gh repo create "$full" --public --description "$desc" >/dev/null
  fi
done

echo
echo "== 2. configure the three GitHub Apps =="
echo "  Sync App: install on $ORG/hop and every mirror; Actions read/write, Contents read/write, Pull requests read."
echo "  Store HOP_SYNC_APP_ID and HOP_SYNC_APP_PRIVATE_KEY only in protected component-sync environments."
echo "  Source App: install only on $ORG/hop; Actions, Attestations, Checks, and Contents read."
echo "  Store HOP_SOURCE_APP_ID and HOP_SOURCE_APP_PRIVATE_KEY in each publishing mirror's release environment."
echo "  Release App: install only on $ORG/libhop with Contents write; store its credentials in $ORG/hop's release environment."
echo "  Do not create COPYBARA_TOKEN or HOP_SYNC_TOKEN PAT secrets."

echo
echo "== 3. protect authority environments =="
echo "  Create component-sync on $ORG/hop and every mirror; restrict it to main, require a different reviewer, and prevent self-review."
echo "  For every mirror with release.yml, create environment 'release' with a required reviewer."
echo "  Configure registry trusted publishers with environment 'release'."

echo
echo "== 4. seed each mirror (one-time, per component) =="
echo "  The FIRST export of a component passes init_history=true:"
echo "      gh workflow run sync-components.yml -f component=hop-sdk-node -f direction=export -f init_history=true"
echo "  Repeat per component (hop-sdk-python, hop-core, libhop, hop-relayd, ...); later exports omit it."

echo
echo "== 5. enable security features on every repo =="
# All free on public repos, idempotent, and tolerant: a repo whose only language CodeQL does not support
# (Crystal, Elixir) simply skips the code-scanning step. Run this after the repos exist.
printf '%s\n' "$MIRRORS" | while IFS='|' read -r repo _; do
  [ -z "$repo" ] && continue
  full="$ORG/$repo"
  echo "  $full:"
  gh api -X PUT "repos/$full/vulnerability-alerts" >/dev/null 2>&1 && echo "    dependabot alerts: on" || echo "    dependabot alerts: skipped"
  gh api -X PUT "repos/$full/automated-security-fixes" >/dev/null 2>&1 && echo "    dependabot security updates: on" || true
  gh api -X PUT "repos/$full/private-vulnerability-reporting" >/dev/null 2>&1 && echo "    private vulnerability reporting: on" || echo "    private vulnerability reporting: skipped"
  gh api -X PATCH "repos/$full" \
    -f 'security_and_analysis[secret_scanning][status]=enabled' \
    -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null 2>&1 \
    && echo "    secret scanning + push protection: on" || echo "    secret scanning: skipped"
  gh api -X PATCH "repos/$full/code-scanning/default-setup" -f state=configured >/dev/null 2>&1 \
    && echo "    codeql default setup: configured" || echo "    codeql: skipped (e.g. crystal/elixir have no CodeQL support)"
done

echo
echo "Done."
