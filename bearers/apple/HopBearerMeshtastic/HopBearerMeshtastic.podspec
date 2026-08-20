# HopBearerMeshtastic, the Meshtastic/LoRa transport as a CocoaPods pod. The MODULE it exposes is
# `HopBearerMeshtastic`.
#
# The CocoaPods face of the `HopBearerMeshtastic` library product in this directory's Package.swift: Hop
# traffic relayed through a connected Meshtastic radio, so a link can form with no Wi-Fi, no cellular and
# no BLE peer in range.
# drivers/apple/HopDriver/Sources/HopDriver/HopBearer.swift line 16 does `import HopBearerMeshtastic`, so
# this needs its own pod: CocoaPods compiles one pod into one module, and folding these sources into
# HopDriver would rename the module and break that import.
#
# WHY CoreBluetooth IS DECLARED HERE TOO, given HopBearerBle also declares it. A Meshtastic radio is
# reached over its own GATT service, so MeshtasticBearer+Radio.swift talks CoreBluetooth directly and
# shares nothing with the BLE bearer ("1 isolated lib per bearer"). Two pods declaring the same system
# framework costs nothing: -framework is idempotent, unlike the -l"hop" collision documented in
# drivers/apple/HopDriver/HopFFIBindings.podspec, which is about two archives with one name.
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
raise "HopBearerMeshtastic.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopBearerMeshtastic"
  s.version = version
  s.summary = "The Hop Meshtastic bearer: Hop links relayed through a connected Meshtastic LoRa radio."
  s.description = <<~DESC
    MeshtasticBearer and its wire codec: the Meshtastic protobuf frames, the fragment and reassembly
    layer that fits Hop frames into LoRa payloads, and the Hop link-frame grammar on top, spoken over
    the radio's own GATT service. It implements the HopContract Bearer protocol, so a consumer sees the
    same linkUp, linkBytes and linkDown semantics it gets from BLE or LAN, on a radio with no
    infrastructure at all.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # macOS 13 and iOS 16, matching this package's Package.swift.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopBearerMeshtastic/**/*.swift"
  s.swift_version = "5.9"

  # Exactly what MeshtasticBearer.swift, MeshtasticWire.swift and MeshtasticBearer+Radio.swift import.
  s.frameworks = "Foundation", "CoreBluetooth"

  s.dependency "HopContract", version
end
