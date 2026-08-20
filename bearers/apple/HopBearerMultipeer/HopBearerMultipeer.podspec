# HopBearerMultipeer, the Wi-Fi P2P transport as a CocoaPods pod. The MODULE it exposes is
# `HopBearerMultipeer`.
#
# The CocoaPods face of the `HopBearerMultipeer` library product in this directory's Package.swift: peer
# discovery and links over MultipeerConnectivity, which brokers Wi-Fi Direct and infrastructure Wi-Fi
# without either side knowing which it got.
# drivers/apple/HopDriver/Sources/HopDriver/HopBearer.swift line 14 does `import HopBearerMultipeer`, so
# this needs its own pod: CocoaPods compiles one pod into one module, and folding these sources into
# HopDriver would rename the module and break that import.
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
raise "HopBearerMultipeer.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopBearerMultipeer"
  s.version = version
  s.summary = "The Hop Multipeer bearer: Wi-Fi P2P links over MultipeerConnectivity."
  s.description = <<~DESC
    MultipeerBearer: advertiser, browser and session delegates over MultipeerConnectivity, carrying the
    Hop link-frame grammar across whichever physical path the framework brokers. It implements the
    HopContract Bearer protocol, so the driver's BearerManager surfaces its links exactly like every
    other transport.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # macOS 13 and iOS 16, matching this package's Package.swift.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopBearerMultipeer/**/*.swift"
  s.swift_version = "5.9"

  # Exactly what MultipeerBearer.swift and MultipeerBearer+Radio.swift import.
  s.frameworks = "Foundation", "MultipeerConnectivity"

  s.dependency "HopContract", version
end
