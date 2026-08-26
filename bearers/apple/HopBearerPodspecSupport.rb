# frozen_string_literal: true

# Shared release metadata for the Apple bearer podspecs.
#
# The aggregate SwiftPM manifest is the only version information that survives
# into the bearer mirror. Its hop-sdk-apple `from:` declaration is a
# compatibility floor, so derive the matching CocoaPods interval here rather
# than duplicating it in every target podspec.
module HopBearerPodspecSupport
  SDK_URL = "https://github.com/hopmesh/hop-sdk-apple.git"
  SDK_DEPENDENCY = /\.package\(\s*url:\s*"#{Regexp.escape(SDK_URL)}"\s*,\s*from:\s*"([^"]+)"\s*\)/m
  SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/

  Metadata = Struct.new(:version, :compatibility, keyword_init: true)

  def self.load!(directory)
    manifest_path = File.join(directory, "Package.swift")
    raise "HopBearerPodspecSupport: missing manifest #{manifest_path}" unless File.file?(manifest_path)

    versions = File.read(manifest_path).scan(SDK_DEPENDENCY).map do |match|
      match.is_a?(Array) ? match.fetch(0) : match
    end
    unless versions.length == 1
      raise "HopBearerPodspecSupport: expected exactly one hop-sdk-apple from: declaration in #{manifest_path}, found #{versions.length}"
    end

    version = versions.first
    match = SEMVER.match(version)
    unless match
      raise "HopBearerPodspecSupport: malformed hop-sdk-apple version #{version.inspect} in #{manifest_path}"
    end

    major = match[1].to_i
    minor = match[2].to_i
    upper_bound = major.zero? ? "0.#{minor + 1}.0" : "#{major + 1}.0.0"

    Metadata.new(
      version: version,
      compatibility: [">= #{version}", "< #{upper_bound}"]
    )
  end
end
