# HopBearerLan, the LAN transport as a CocoaPods pod. The MODULE it exposes is `HopBearerLan`.
#
# The CocoaPods face of the `HopBearerLan` library product in this directory's Package.swift: mDNS
# discovery of _hoplan._tcp plus framed TCP links, all through Network.framework.
# drivers/apple/HopDriver/Sources/HopDriver/HopBearer.swift line 13 does `import HopBearerLan`, so this
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
# ONE DEPENDENCY, HopContract, and that is load bearing rather than minimal. The bearers bind the pure
# Swift contract and never libhop, so a host driving the node through UniFFI does not link the Rust core a
# second time. Package.swift lines 50 to 52 of drivers/apple/HopDriver state the same rule for the driver.
#
# The version is read from the SDK's Package.swift for the reason given in sdk/apple/CHop.podspec: one
# source of truth that the release job already maintains. `../../../sdk/apple` is the same relative path
# this package's Package.swift already uses to reach the SDK.

manifest_path = File.expand_path("../../../sdk/apple/Package.swift", __dir__)
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopBearerLan.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopBearerLan"
  s.version = version
  s.summary = "The Hop LAN bearer: mDNS discovery plus framed TCP links over Network.framework."
  s.description = <<~DESC
    LanBearer: it advertises and browses the _hoplan._tcp service, dials peers through a gate that keeps
    two nodes from dialling each other into a duplicate pair, and carries the Hop link-frame grammar
    over framed TCP. It implements the HopContract Bearer protocol, so the driver's BearerManager
    surfaces its links exactly like every other transport.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # macOS 13 and iOS 16, matching this package's Package.swift.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopBearerLan/**/*.swift"
  s.swift_version = "5.9"

  # Exactly what LanBearer.swift imports.
  s.frameworks = "Foundation", "Network"

  s.dependency "HopContract", version
end
