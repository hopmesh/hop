#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/executable-reference-guard.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_case() {
  name="$1"
  rm -rf "${tmp:?}/$name"
  mkdir -p "$tmp/$name/.github/workflows"
}

make_case good
cat >"$tmp/good/.github/workflows/ci.yml" <<'YAML'
jobs:
  test:
    container: example/tool:1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v4.3.1
      - run: python -m pip install --require-hashes -r requirements.txt
      - run: npm install -g npm@11.5.1
      - run: cargo install thing --locked --version 1.2.3
      - run: |
          apt-get update
          apt-get install -y ca-certificates=1.2.3
          command --flag that-is-not-a-package
      - run: |
          curl --fail --location \
            https://example.test/tool-1.2.3.tar.gz \
            --output /tmp/tool.tar.gz
          printf '%s  %s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /tmp/tool.tar.gz | sha256sum -c -
YAML
cat >"$tmp/good/Dockerfile" <<'DOCKER'
FROM example/base:1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RUN apt-get update && apt-get install -y ca-certificates=1.2.3 && rm -rf /var/lib/apt/lists/*
DOCKER
cat >"$tmp/good/main.tf" <<'TF'
locals {
  builder_image = "example/base@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
resource "google_cloudbuild_trigger" "example" {
  build {
    step {
      name = local.builder_image
    }
  }
}
TF
for example in blink_send service_rpc; do
  mkdir -p "$tmp/good/sdk/embedded/examples/$example"
  cat >"$tmp/good/sdk/embedded/examples/$example/platformio.ini" <<'INI'
[env]
platform = platformio/espressif32@7.0.1
platform_packages =
    platformio/framework-arduinoespressif32@3.20017.241212+sha.dcc1105b
    framework = arduino
INI
done
cat >"$tmp/good/sdk/embedded/platformio-packages.lock.json" <<'JSON'
{
  "schema": 1,
  "system": "linux_x86_64",
  "packages": [
    {
      "filename": "espressif32.tar.gz",
      "kind": "platform",
      "metadata": "https://api.registry.platformio.org/v3/packages/platformio/platform/espressif32",
      "reference": "platformio/espressif32@7.0.1",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "url": "https://dl.registry.platformio.org/download/platformio/platform/espressif32/7.0.1/espressif32.tar.gz"
    },
    {
      "filename": "framework.tar.gz",
      "kind": "package",
      "metadata": "https://api.registry.platformio.org/v3/packages/platformio/tool/framework-arduinoespressif32",
      "reference": "platformio/framework-arduinoespressif32@3.20017.241212+sha.dcc1105b",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "url": "https://dl.registry.platformio.org/download/platformio/tool/framework-arduinoespressif32/3.20017.241212/framework.tar.gz"
    }
  ]
}
JSON
mkdir -p "$tmp/good/gradle/wrapper"
cat >"$tmp/good/gradle/wrapper/gradle-wrapper.properties" <<'PROPS'
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip
distributionSha256Sum=d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab
PROPS
python3 "$guard" --root "$tmp/good" >/dev/null

expect_bad() {
  name="$1"
  content="$2"
  make_case "$name"
  printf '%s\n' "$content" >"$tmp/$name/.github/workflows/ci.yml"
  if python3 "$guard" --root "$tmp/$name" >/dev/null 2>&1; then
    echo "guard accepted negative fixture: $name" >&2
    exit 1
  fi
}

expect_bad action-ref 'jobs: {x: {steps: [{uses: actions/checkout@v4}]}}'
expect_bad action-comment 'jobs: {x: {steps: [{uses: actions/checkout@1111111111111111111111111111111111111111}]}}'
expect_bad mutable-secondary-action $'jobs:\n  x:\n    steps:\n      - uses: esp-rs/xtensa-toolchain@1111111111111111111111111111111111111111 # v1.5'
expect_bad image-tag $'jobs:\n  x:\n    container: example/tool:1.2.3\n    steps: []'
expect_bad remote-exec $'jobs:\n  x:\n    steps:\n      - run: curl -fsSL https://example.test/install.sh | sh'
expect_bad no-checksum $'jobs:\n  x:\n    steps:\n      - run: curl -fsSLo /tmp/tool.tar.gz https://example.test/tool.tar.gz'
expect_bad npm-latest $'jobs:\n  x:\n    steps:\n      - run: npm install -g npm@latest'
expect_bad pip-floating $'jobs:\n  x:\n    steps:\n      - run: pipx install platformio'
expect_bad pip-unhashed $'jobs:\n  x:\n    steps:\n      - run: pip install build==1.5.0'
expect_bad pip-download-unhashed $'jobs:\n  x:\n    steps:\n      - run: pip download build==1.5.0'
expect_bad cargo-floating $'jobs:\n  x:\n    steps:\n      - run: cargo install wasm-pack'
expect_bad wasm-secondary-download $'jobs:\n  x:\n    steps:\n      - run: wasm-pack build --release --target web'
expect_bad apt-floating $'jobs:\n  x:\n    steps:\n      - run: |\n          apt-get install -y ca-certificates\n          command --flag'
expect_bad split-download $'jobs:\n  x:\n    steps:\n      - run: |\n          curl --fail --location \\\n            https://example.test/tool.tar.gz \\\n            --output /tmp/tool.tar.gz'
expect_bad release-combined $'name: release\njobs:\n  publish:\n    environment: release\n    steps:\n      - run: npm ci\n      - run: npm publish'
expect_bad hex-api-combined $'name: release\njobs:\n  publish:\n    environment: release\n    steps:\n      - run: mix test\n      - run: python3 -c "print(\"https://hex.pm/api/packages/hop_endpoint/releases\")"'
expect_bad crates-api-combined $'name: release\njobs:\n  publish:\n    environment: release\n    steps:\n      - run: cargo test\n      - run: python3 .github/crates-publish.py publish --crate fixture.crate --metadata metadata.json'

make_case platformio-floating-platform
mkdir -p "$tmp/platformio-floating-platform/sdk/embedded/examples/blink_send"
cat >"$tmp/platformio-floating-platform/sdk/embedded/examples/blink_send/platformio.ini" <<'INI'
[env]
platform = espressif32
platform_packages =
    platformio/framework-arduinoespressif32@3.20017.241212+sha.dcc1105b
INI
if python3 "$guard" --root "$tmp/platformio-floating-platform" >/dev/null 2>&1; then
  echo "guard accepted a floating PlatformIO platform" >&2
  exit 1
fi

make_case platformio-floating-package
mkdir -p "$tmp/platformio-floating-package/sdk/embedded/examples/blink_send"
cat >"$tmp/platformio-floating-package/sdk/embedded/examples/blink_send/platformio.ini" <<'INI'
[env]
platform = platformio/espressif32@7.0.1
platform_packages =
    platformio/framework-arduinoespressif32
INI
if python3 "$guard" --root "$tmp/platformio-floating-package" >/dev/null 2>&1; then
  echo "guard accepted a floating PlatformIO package" >&2
  exit 1
fi

make_case platformio-second-example
for example in blink_send service_rpc; do
  mkdir -p "$tmp/platformio-second-example/sdk/embedded/examples/$example"
  cat >"$tmp/platformio-second-example/sdk/embedded/examples/$example/platformio.ini" <<'INI'
[env]
platform = platformio/espressif32@7.0.1
platform_packages =
    platformio/framework-arduinoespressif32@3.20017.241212+sha.dcc1105b
INI
done
printf '%s\n' '[env]' 'platform = espressif32@^7.0.0' 'platform_packages =' \
  '    platformio/framework-arduinoespressif32@3.20017.241212+sha.dcc1105b' \
  >"$tmp/platformio-second-example/sdk/embedded/examples/service_rpc/platformio.ini"
if python3 "$guard" --root "$tmp/platformio-second-example" >/dev/null 2>&1; then
  echo "guard did not scan the service_rpc PlatformIO example" >&2
  exit 1
fi

make_case terraform-latest
printf '%s\n' 'locals { image = "example/base:latest" }' >"$tmp/terraform-latest/main.tf"
if python3 "$guard" --root "$tmp/terraform-latest" >/dev/null 2>&1; then
  echo "guard accepted a Terraform latest image" >&2
  exit 1
fi

make_case terraform-builder-tag
printf '%s\n' 'locals {' '  builder_image = "example/base:1.2.3"' '}' >"$tmp/terraform-builder-tag/main.tf"
if python3 "$guard" --root "$tmp/terraform-builder-tag" >/dev/null 2>&1; then
  echo "guard accepted a Terraform Cloud Build image without a digest" >&2
  exit 1
fi

make_case gradle-no-hash
mkdir -p "$tmp/gradle-no-hash/gradle/wrapper"
printf '%s\n' 'distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip' \
  >"$tmp/gradle-no-hash/gradle/wrapper/gradle-wrapper.properties"
if python3 "$guard" --root "$tmp/gradle-no-hash" >/dev/null 2>&1; then
  echo "guard accepted Gradle wrapper without checksum" >&2
  exit 1
fi

echo "executable reference guard tests passed"
