# HopDriver, the reusable Apple driver as a CocoaPods pod. The MODULE it exposes is `HopDriver`.
#
# The CocoaPods face of the `HopDriver` library product in this directory's Package.swift: the whole Hop
# bearer (CoreBluetooth, Multipeer, LAN, cloud relay, Meshtastic, plus the node) so a host app is a thin
# consumer. It exists so sdk/react-native can bridge the DRIVER instead of only the node primitives.
# Without it, a React Native app gets `linkUp`/`bytesReceived`/`startPump` and has to supply its own
# transport, which JavaScript cannot do: that is why the React Native demo showed one loopback peer,
# never asked for Bluetooth, and could not send.
#
# WHY THE POD NAME MATCHES THE MODULE NAME HERE, unlike HopSDK. The rename to HopSDK was forced by an
# archive-name collision: a pod called `Hop` builds `libHop.a`, which on a case-insensitive volume (the
# macOS default) is the same file name as the core's `libhop.a`, and `-l"hop"` then resolves to the
# wrong archive. `HopDriver` builds `libHopDriver.a`, which cannot collide with either, so the pod and
# the module can share a name.
#
# WHY THIS FILE MOVED HERE FROM sdk/apple, which is worth recording because the first version of it could
# not be installed at all. It declared `source_files` as the repo-root-relative
# "drivers/apple/HopDriver/Sources/HopDriver/**/*.swift" while sitting in sdk/apple. CocoaPods resolves
# file patterns against the POD ROOT, and for a `:path` pod the root is the directory named in the
# Podfile, so `:path => sdk/apple` matched no files at all. The `:podspec` alternative cannot rescue it
# either: `:podspec` still downloads `s.source`, and `git ls-remote --tags origin` returns NO TAGS, so the
# `v#{version}` tag below does not exist and never resolves. Every monorepo pod here has to be a `:path`
# development pod, which means every podspec belongs beside the Package.swift it mirrors with
# package-root-relative patterns, exactly as sdk/apple's podspecs already were. Do not reach for
# `:podspec` again expecting a git checkout.
#
# The version is read from the SDK's Package.swift for the reason given in sdk/apple/CHop.podspec: one
# source of truth that the release job already maintains.

manifest_path = File.expand_path("../../../sdk/apple/Package.swift", __dir__)
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopDriver.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopDriver"
  s.version = version
  s.summary = "The reusable Hop Apple driver: radios, peers, chat threads and the node in one bearer."
  s.description = <<~DESC
    HopBearer and the value types around it: CoreBluetooth plus L2CAP, Multipeer Wi-Fi, LAN, the cloud
    relay, hops:// endpoints and hps:// topics, over a node driven through UniFFI. A host supplies a
    db path, an identity seed, an app secret and a display name, and gets published peer, message and
    transport state back. This is the same code apps/apple/HopDemo runs, so a consumer of this pod is
    a peer on the same mesh as the native demo rather than a separate implementation of it.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # iOS 16 and macOS 13, matching this directory's Package.swift and the SDK pods it depends on.
  s.platforms = { :ios => "16.0", :osx => "13.0" }

  # The monorepo, not hop-sdk-apple: the driver is not part of the exported Apple SDK repo.
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopDriver/**/*.swift"
  s.swift_version = "5.9"

  # Everything HopBearer and its siblings import directly. CoreLocation is absent on purpose: the
  # iBeacon background wake lives in the BLE bearer, not here.
  s.frameworks = "Foundation", "CoreBluetooth", "MultipeerConnectivity", "Network",
                 "UserNotifications", "CryptoKit", "Security"

  # THE WHOLE GRAPH, one pod per module the driver's sources import.
  #
  # CocoaPods compiles one pod into one module, and these sources do `import HopObjC`,
  # `@_exported import HopFFIBindings` and `import HopBearer{Ble,Lan,Multipeer,Relay,Meshtastic}`.
  # Folding those source trees into this pod would collapse them into the `HopDriver` module and every
  # one of those imports would stop resolving, which is why each is its own podspec beside its own
  # Package.swift, exactly as HopContract is its own pod rather than a subspec of HopSDK.
  #
  # HopFFIBindings is the ONE pod in the whole graph that vendors the Hop core, and it vendors the
  # SQLCipher build. That pod's comments carry the nm measurements behind the rule; the short version is
  # that two same-named libhop.a archives cannot coexist under a single -l"hop", so sdk/apple/CHop.podspec
  # now carries only the `CHop` module face and depends on HopFFIBindings for the library.
  s.dependency "HopContract", version
  s.dependency "HopObjC", version
  s.dependency "HopFFIBindings", version
  s.dependency "HopBearerBle", version
  s.dependency "HopBearerLan", version
  s.dependency "HopBearerMultipeer", version
  s.dependency "HopBearerRelay", version
  s.dependency "HopBearerMeshtastic", version
end
