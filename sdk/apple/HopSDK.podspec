# HopSDK, the Apple client SDK as a CocoaPods pod. The MODULE it exposes is `Hop`.
#
# The CocoaPods face of the `Hop` product in Package.swift: HopNode over the C ABI, plus HopRuntime. This is
# the pod the React Native SDK depends on, which is the whole reason these podspecs exist. Before them,
# sdk/react-native/HopMesh.podspec tried to reach the Apple SDK through `s.spm_dependency`, guarded by
# `if s.respond_to?(:spm_dependency)`. That method does not exist in CocoaPods 1.17.0, so the guard skipped
# silently and published a pod with no way to satisfy `import Hop`: every iOS build of the React Native SDK
# failed with "unable to resolve module dependency: 'Hop'". A guard that turns a missing capability into an
# incomplete artifact is worse than no guard, because it fails at the consumer instead of at the author.
#
# WHY THE POD IS NOT CALLED `Hop`, which is the interesting part and was found by measurement, not taste.
# CocoaPods builds each pod into a static library named after the pod, so a pod called `Hop` produces
# `libHop.a`. The CHop pod vendors the compiled core as `libhop.a`. macOS volumes are case-insensitive by
# default, so those two names are THE SAME FILE NAME, and `-l` resolves by name against an ordered search
# path. The observed results, both from real builds:
#
#   search path with libHop.a first  -> CocoaPods' own `-l"hop"` picked up the Swift wrapper, and every core
#                                       symbol stayed undefined ("Undefined symbols: _hop_abi_version")
#   adding the core by explicit path -> `-l"hop"` STILL picked up libHop.a, so the wrapper was linked twice
#                                       and the link failed with 129 duplicate Swift symbols
#
# Naming the pod `HopSDK` makes the archive `libHopSDK.a`, which cannot collide, and then CocoaPods' own
# `-l"hop"` plus its own search path resolve to the real core with no manual link flags at all.
#
# `s.module_name = "Hop"` keeps the Swift module called `Hop`, so `import Hop` is unchanged for every
# consumer and matches the SwiftPM product name. The pod name and the module name differ on purpose.
#
# The version is read from Package.swift for the reason given in CHop.podspec.

manifest_path = File.join(__dir__, "Package.swift")
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopSDK.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopSDK"
  s.module_name = "Hop"
  s.version = version
  s.summary = "The Hop Apple client SDK: a mesh node you can hold, over the libhop C ABI."
  s.description = <<~DESC
    HopNode, the idiomatic Swift face of libhop's C ABI, plus HopRuntime. Because the CHop pod carries the
    static library inside an xcframework, the whole stack builds and links for iOS devices, the simulator,
    and macOS with no manual linker flags. The pod is named HopSDK so its archive cannot collide with the
    core's libhop.a on a case-insensitive filesystem; the module it exposes is Hop.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-sdk-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # iOS 16 and macOS 13 match Package.swift's declared platforms. Consumers of the React Native SDK inherit
  # this floor, which is why sdk/react-native/HopMesh.podspec no longer claims iOS 15.1: it cannot honestly
  # support a version the SDK it wraps does not.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-sdk-apple.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/Hop/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation"

  # MEASURED, not defensive. Under `use_frameworks!` (the CocoaPods default, and what `pod trunk push`
  # lints with) this pod is built as its own linkage unit. The Hop symbols it calls live in the STATIC
  # libhop.a that CHop vendors, and a dynamic framework does not absorb a static dependency, so the
  # link ended with "Undefined symbols for architecture x86_64" while `pod lib lint --use-libraries`
  # on the identical sources passed. Declaring the pod static makes CocoaPods link libhop.a into it,
  # which is what the SwiftPM product does too. Without this line the pod lints only in static mode
  # and breaks for any consumer whose Podfile says `use_frameworks!`.
  s.static_framework = true

  s.dependency "CHop", version
  s.dependency "HopContract", version
end
