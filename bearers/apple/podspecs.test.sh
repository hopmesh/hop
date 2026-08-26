#!/usr/bin/env bash
# Exercise the exported Apple bearer podspec contract without downloading pods.
#
# `pod ipc spec` evaluates the Ruby specification, which is enough to prove the
# package shape and, importantly, that the version derivation fails closed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v pod >/dev/null || {
  echo "podspec test requires CocoaPods' pod command" >&2
  exit 1
}

manifest_sdk_version() {
  ruby - "$1" <<'RUBY'
manifest_path = ARGV.fetch(0)
manifest = File.read(manifest_path)
versions = manifest.scan(/\.package\(\s*url:\s*"https:\/\/github\.com\/hopmesh\/hop-sdk-apple\.git"\s*,\s*from:\s*"([^"]+)"\s*\)/m)
abort "fixture did not contain exactly one hop-sdk-apple dependency" unless versions.length == 1
puts versions.first
RUBY
}

assert_spec() {
  local spec_path="$1"
  local name="$2"
  local source_files="$3"
  local frameworks="$4"
  local ios_frameworks="$5"
  local version="$6"
  local json="$tmp/${name}-${version}.json"

  if ! pod ipc spec "$spec_path" >"$json" 2>&1; then
    echo "FAIL: [$name] pod ipc spec failed" >&2
    cat "$json" >&2
    exit 1
  fi

  ruby -rjson - "$json" "$name" "$source_files" "$frameworks" "$ios_frameworks" "$version" <<'RUBY'
json_path, expected_name, expected_source_files, expected_frameworks, expected_ios_frameworks, expected_version = ARGV
spec = JSON.parse(File.read(json_path))

def assert_equal(actual, expected, label)
  return if actual == expected

  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
end

def as_array(value)
  value.nil? ? [] : Array(value)
end

match = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)/.match(expected_version)
raise "fixture version is not SemVer: #{expected_version.inspect}" unless match

major = match[1].to_i
minor = match[2].to_i
upper_bound = major.zero? ? "0.#{minor + 1}.0" : "#{major + 1}.0.0"
expected_compatibility = [">= #{expected_version}", "< #{upper_bound}"]

assert_equal(spec.fetch("name"), expected_name, "pod name")
assert_equal(spec.fetch("module_name"), expected_name, "module name")
assert_equal(spec.fetch("version").to_s, expected_version, "pod version")
assert_equal(spec.fetch("platforms").fetch("ios").to_s, "16.0", "iOS deployment target")
assert_equal(spec.fetch("platforms").fetch("osx").to_s, "13.0", "macOS deployment target")
assert_equal(spec.fetch("source").fetch("git"), "https://github.com/hopmesh/hop-bearers-apple.git", "source repository")
assert_equal(spec.fetch("source").fetch("tag"), "v#{expected_version}", "source tag")
assert_equal(as_array(spec.fetch("source_files")), [expected_source_files], "target-only source files")
assert_equal(as_array(spec["swift_versions"] || spec["swift_version"]).map(&:to_s), ["5.9"], "Swift version")
assert_equal(as_array(spec["frameworks"]).sort, expected_frameworks.split(",").sort, "frameworks")
assert_equal(as_array(spec.dig("ios", "frameworks")).sort, expected_ios_frameworks.split(",").reject(&:empty?).sort, "iOS-only frameworks")

dependencies = spec.fetch("dependencies")
assert_equal(dependencies.keys.sort, ["HopContract"], "pod dependencies")
assert_equal(as_array(dependencies.fetch("HopContract")), expected_compatibility, "HopContract compatibility")

%w[pod_target_xcconfig user_target_xcconfig xcconfig].each do |key|
  config = spec[key]
  next unless config.is_a?(Hash)

  raise "manual linker flags present in #{key}" if config.key?("OTHER_LDFLAGS")
end
RUBY

  echo "ok   [$name] evaluated target-only metadata and HopContract compatibility"
}

make_fixture() {
  local fixture="$1"
  local mutation="$2"
  mkdir -p "$fixture"
  cp "$here/Package.swift" "$here/HopBearerPodspecSupport.rb" "$here/HopBearerBle.podspec" "$fixture/"

  ruby - "$fixture/Package.swift" "$mutation" <<'RUBY'
path, mutation = ARGV
text = File.read(path)
pattern = /(\.package\(\s*url:\s*"https:\/\/github\.com\/hopmesh\/hop-sdk-apple\.git"\s*,\s*from:\s*")[^"]+(")/m

case mutation
when "valid-version"
  changed = text.sub!(pattern) { "#{Regexp.last_match(1)}1.2.3#{Regexp.last_match(2)}" }
  raise "fixture did not replace the SDK version" unless changed
when "missing-sdk"
  changed = text.sub!("https://github.com/hopmesh/hop-sdk-apple.git", "https://example.invalid/hop-sdk-apple.git")
  raise "fixture did not remove the SDK URL" unless changed
when "duplicate-sdk"
  text << "\n.package(url: \"https://github.com/hopmesh/hop-sdk-apple.git\", from: \"1.2.3\")\n"
when "malformed-sdk"
  changed = text.sub!(pattern) { "#{Regexp.last_match(1)}not-a-semver#{Regexp.last_match(2)}" }
  raise "fixture did not corrupt the SDK version" unless changed
else
  raise "unknown fixture mutation: #{mutation}"
end

File.write(path, text)
RUBY
}

expect_derivation_failure() {
  local label="$1"
  local fixture="$2"
  local needle="$3"
  local output="$tmp/${label}.log"

  if pod ipc spec "$fixture/HopBearerBle.podspec" >"$output" 2>&1; then
    echo "FAIL: [$label] malformed manifest evaluated successfully" >&2
    exit 1
  fi

  grep -Fq "$needle" "$output" || {
    echo "FAIL: [$label] did not name its derivation error" >&2
    cat "$output" >&2
    exit 1
  }

  echo "ok   [$label] failed closed with a named derivation error"
}

sdk_version="$(manifest_sdk_version "$here/Package.swift")"
assert_spec "$here/HopBearerBle.podspec" "HopBearerBle" "HopBearerBle/Sources/HopBearerBle/**/*.swift" "Foundation,Security,CoreBluetooth" "CoreLocation,UIKit" "$sdk_version"
assert_spec "$here/HopBearerLan.podspec" "HopBearerLan" "HopBearerLan/Sources/HopBearerLan/**/*.swift" "Foundation,Network" "" "$sdk_version"
assert_spec "$here/HopBearerRelay.podspec" "HopBearerRelay" "HopBearerRelay/Sources/HopBearerRelay/**/*.swift" "Foundation,Network,CryptoKit" "" "$sdk_version"

make_fixture "$tmp/valid-version" "valid-version"
assert_spec "$tmp/valid-version/HopBearerBle.podspec" "HopBearerBle" "HopBearerBle/Sources/HopBearerBle/**/*.swift" "Foundation,Security,CoreBluetooth" "CoreLocation,UIKit" "1.2.3"
echo "ok   [valid version] manifest version propagated to the pod and compatibility range"

make_fixture "$tmp/missing-sdk" "missing-sdk"
expect_derivation_failure "missing SDK dependency" "$tmp/missing-sdk" "expected exactly one hop-sdk-apple from: declaration"

make_fixture "$tmp/duplicate-sdk" "duplicate-sdk"
expect_derivation_failure "duplicate SDK dependency" "$tmp/duplicate-sdk" "expected exactly one hop-sdk-apple from: declaration"

make_fixture "$tmp/malformed-sdk" "malformed-sdk"
expect_derivation_failure "malformed SDK version" "$tmp/malformed-sdk" "malformed hop-sdk-apple version"

ruby - <<'RUBY'
pod_names = %w[CHop HopSDK HopContract HopBearerBle HopBearerLan HopBearerRelay]
archives = pod_names.map { |name| "lib#{name}.a".downcase }
raise "case-folded pod archives collide: #{archives.inspect}" unless archives.uniq.length == archives.length
RUBY

echo "Apple bearer podspecs evaluate with target-only sources, HopContract-only dependencies, and unique archives"
