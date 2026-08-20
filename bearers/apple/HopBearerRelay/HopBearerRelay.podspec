# HopBearerRelay, the cloud-relay transport as a CocoaPods pod. The MODULE it exposes is `HopBearerRelay`.
#
# The CocoaPods face of the `HopBearerRelay` library product in this directory's Package.swift: one
# outbound WebSocket to a relay, with a stable derived peer id, exponential backoff, Retry-After handling
# and jittered reconnect.
# drivers/apple/HopDriver/Sources/HopDriver/HopBearer.swift line 15 does `import HopBearerRelay`, so this
# needs its own pod: CocoaPods compiles one pod into one module, and folding these sources into HopDriver
# would rename the module and break that import.
#
# WHY THE PODSPEC SITS AT THE PACKAGE ROOT. CocoaPods resolves file patterns against the POD ROOT, which
# for a `:path` pod is the directory named in the Podfile, and that is also the only directory CocoaPods
# searches for `<name>.podspec`. Every monorepo pod here has to be a `:path` development pod, because
# `git ls-remote --tags origin` returns no tags at all, so no `s.source` tag exists for CocoaPods to
# download. Putting the podspec beside the Package.swift it mirrors keeps every pattern package-root
# relative, exactly as sdk/apple's podspecs are.
#
# ONE DEPENDENCY, HopContract, and that is load bearing rather than minimal. This package's Package.swift
# makes the point explicitly at lines 21 to 25: its TEST target additionally links the libhop node so one
# case can drive failover through the real pool, while the LIBRARY target depends on HopContract alone so
# a consumer driving the node via UniFFI does not double-link the Rust core. This pod is the library
# target, so it carries the library's dependency and not the test target's.
#
# The version is read from the SDK's Package.swift for the reason given in sdk/apple/CHop.podspec: one
# source of truth that the release job already maintains. `../../../sdk/apple` is the same relative path
# this package's Package.swift already uses to reach the SDK.

manifest_path = File.expand_path("../../../sdk/apple/Package.swift", __dir__)
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopBearerRelay.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopBearerRelay"
  s.version = version
  s.summary = "The Hop relay bearer: one outbound WebSocket link to a cloud relay, with backoff."
  s.description = <<~DESC
    RelayBearer: a single outbound WebSocket carrying the Hop link-frame grammar to a cloud relay, with
    a stable derived peer id, exponential backoff, a 429 Retry-After parse and a jittered reconnect
    delay. It implements the HopContract Bearer protocol, so the driver's BearerManager surfaces its
    links exactly like every other transport, which is what lets two nodes that never see each other on
    a radio still form a link.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # macOS 13 and iOS 16, matching this package's Package.swift.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopBearerRelay/**/*.swift"
  s.swift_version = "5.9"

  # Exactly what RelayBearer.swift imports. CryptoKit is here for the derived peer id, not boilerplate.
  s.frameworks = "Foundation", "Network", "CryptoKit"

  s.dependency "HopContract", version
end
