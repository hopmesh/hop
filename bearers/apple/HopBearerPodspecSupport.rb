# Shared CocoaPods metadata for the Apple bearer pods.
#
# `Package.swift` is the public aggregate manifest that the standalone bearer mirror exports. Its
# hop-sdk-apple dependency is the authoritative compatibility floor for every bearer. Keep that
# declaration as the one source of truth: a hardcoded podspec version would let SwiftPM and CocoaPods
# silently describe different supported SDK ranges.
module HopBearerPodspecSupport
  MANIFEST_PATH = File.join(__dir__, "Package.swift")
  HOP_SDK_URL = "https://github.com/hopmesh/hop-sdk-apple.git"
  SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

  def self.hop_contract_compatibility!
    unless File.file?(MANIFEST_PATH)
      raise "HopBearerPodspecSupport: missing aggregate manifest at #{MANIFEST_PATH}"
    end

    manifest = File.read(MANIFEST_PATH)
    matches = manifest.scan(
      /\.package\(\s*url:\s*"#{Regexp.escape(HOP_SDK_URL)}"\s*,\s*from:\s*"([^"]+)"\s*\)/m
    )

    unless matches.length == 1
      raise "HopBearerPodspecSupport: expected exactly one Hop SDK minimum version in #{MANIFEST_PATH}, found #{matches.length}"
    end

    version = matches.first.first
    semver = SEMVER.match(version)
    unless semver
      raise "HopBearerPodspecSupport: invalid Hop SDK minimum version #{version.inspect} in #{MANIFEST_PATH}"
    end

    next_major = semver[1].to_i + 1
    {
      version: version,
      lower_bound: ">= #{version}",
      upper_bound: "< #{next_major}.0.0",
    }
  end
end
