# HopObjC, the Objective-C exception catcher as a CocoaPods pod. The MODULE it exposes is `HopObjC`.
#
# The CocoaPods face of the `HopObjC` Clang target in Package.swift: one class that runs a block inside
# @try/@catch and hands Swift an NSError instead of an abort(). CoreBluetooth raises NSExceptions through
# NSAssert (openL2CAPChannel against a peripheral in a transient bad state) and Swift has no language
# construct to catch those, so without this shim the driver takes a SIGABRT.
# Sources/HopDriver/HopBearer.swift line 7 does `import HopObjC`, which is why this is its own pod rather
# than extra files folded into HopDriver: CocoaPods compiles one pod into one module, so folding it in
# would rename the module to HopDriver and that import would stop resolving. Same reason HopContract is
# its own pod rather than a subspec of HopSDK.
#
# WHY THIS FILE SITS AT THE PACKAGE ROOT rather than beside the SDK's podspecs in sdk/apple.
# CocoaPods resolves file patterns against the POD ROOT, and for a `:path` pod the root is the directory
# named in the Podfile, which is also the only directory CocoaPods searches for `<name>.podspec`. Every
# monorepo pod here HAS to be a `:path` development pod: `git ls-remote --tags origin` returns nothing at
# all, so no `s.source` tag exists for CocoaPods to download, and `Sources/HopFFIBindings/hop.swift` plus
# `Frameworks/HopFFI.xcframework` are gitignored build outputs no tag could ever carry. Do not reach for
# `:podspec` here expecting a git checkout; it cannot resolve. So the podspec lives next to the
# Package.swift it mirrors and its patterns are package-root relative, exactly as sdk/apple's are
# (`Sources/Hop/**/*.swift`, consumed as `:path => sdk/apple`).
#
# The version is read from the SDK's Package.swift for the reason given in sdk/apple/CHop.podspec: one
# source of truth that the release job already maintains. `../../../sdk/apple` is the same relative path
# each bearer's Package.swift already uses to reach the SDK.

manifest_path = File.expand_path("../../../sdk/apple/Package.swift", __dir__)
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopObjC.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopObjC"
  s.version = version
  s.summary = "The Objective-C exception catcher that keeps CoreBluetooth NSExceptions from aborting Hop."
  s.description = <<~DESC
    HopObjCExceptionCatcher.runBlock(_:error:) runs a block inside @try/@catch and reports an
    Objective-C exception as an NSError. CoreBluetooth raises NSExceptions that Swift cannot catch, so
    calls like openL2CAPChannel(_:options:) against a peripheral in a transient bad state would
    otherwise abort the process. This replaces the host app's bridging header, so the driver is
    packageable without asking every consumer to add one.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # iOS 16 and macOS 13, matching drivers/apple/HopDriver/Package.swift and every pod in this graph.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  # BOTH the header and the implementation, and the split below is what makes the module exist.
  #
  # `source_files` is what gets compiled, and it is also what lands in Headers/Private, so the .m file's
  # quoted `#import "HopObjCExceptionCatcher.h"` resolves even though the header sits in include/.
  # `public_header_files` is what CocoaPods lists in the generated HopObjC-umbrella.h, and that umbrella
  # is what its generated module map names. Omitting the public split is the failure mode worth naming:
  # the pod still compiles and the archive still carries the class, while `import HopObjC` fails at every
  # consumer because the module has no umbrella to expose. SwiftPM infers all of this from the include/
  # directory name; CocoaPods needs it said out loud.
  s.source_files = "Sources/HopObjC/**/*.{h,m}"
  s.public_header_files = "Sources/HopObjC/include/**/*.h"

  # Keeps the public header at Headers/Public/HopObjC/, so an angle-bracket
  # `#import <HopObjC/HopObjCExceptionCatcher.h>` works for an Objective-C consumer as well as the Swift
  # `import HopObjC` the driver uses.
  s.header_dir = "HopObjC"

  # THE LINE THAT MAKES `import HopObjC` COMPILE, and it belongs here rather than in every Podfile.
  #
  # Pods integrate as STATIC LIBRARIES by default, and CocoaPods only generates a module map for a
  # static-library pod if it is told to. Without this, `pod install` refuses the whole graph with "The
  # Swift pod `HopDriver` depends upon `HopObjC`, which does not define modules", and its suggested fixes
  # are both consumer-side: `use_modular_headers!` globally, which changes header semantics for every
  # unrelated pod in the app including React Native's, or `:modular_headers => true` on this one
  # dependency, which every consumer then has to remember. CocoaPods 1.17.0 lets the SPEC opt in instead
  # (see PodTarget#defines_module? in pod_target.rb, which checks exactly this key), so the pod carries
  # its own requirement and any consumer that just writes `pod 'HopObjC'` gets a working module.
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }

  s.frameworks = "Foundation"
end
