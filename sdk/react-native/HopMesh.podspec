require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "HopMesh"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors      = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  # iOS 16 and macOS 13, matching the Hop pod this module depends on. It previously claimed iOS 15.1 and
  # macOS 12.0, which it could not honour: sdk/apple declares iOS 16 and macOS 13, so a 15.1 consumer could
  # never have linked the SDK. Claiming a floor you cannot support is a promise that breaks at the consumer.
  s.platforms    = { :ios => "16.0", :osx => "13.0" }
  s.source       = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.swift_version = "5.9"

  # The React Native runtime this module bridges to.
  s.dependency "React-Core"

  # The Hop Apple client SDK, as an ordinary pod dependency.
  #
  # This replaces an `s.spm_dependency` call guarded by `if s.respond_to?(:spm_dependency)`. That guard was a
  # silent no-op: CocoaPods 1.17.0 has no `spm_dependency` method at all (calling it raises "undefined
  # method 'spm_dependency' for an instance of Pod::Specification"), so `pod ipc spec` on this file evaluated
  # to a spec with React-Core as its ONLY dependency and no way to satisfy `import Hop`. Every iOS build
  # failed at the consumer with "unable to resolve module dependency: 'Hop'", which is the worst place to
  # discover a packaging decision.
  #
  # sdk/apple now ships Hop.podspec, HopContract.podspec and CHop.podspec, one per SwiftPM target, so the
  # dependency is expressible the ordinary way and CocoaPods resolves the whole graph.
  #
  # Inside this monorepo the app's Podfile points these at sdk/apple by path. An app outside the monorepo
  # declares them in its Podfile from the hop-sdk-apple repo; see sdk/react-native/README.md.
  # HopSDK, not "Hop". The pod is named HopSDK because a pod called Hop builds libHop.a, which is the same
  # file name as the core's libhop.a on a case-insensitive filesystem, and -l resolution then picks the
  # wrong archive. The MODULE is still Hop, so `import Hop` in ios/HopMesh.swift is unchanged.
  s.dependency "HopSDK"

  # The Apple platform driver, which ios/HopDriverBridge.swift bridges to JavaScript as a second native
  # module named `HopDriver`. Not a replacement for HopMesh: HopMesh exposes the node and link primitives
  # and a host that only wants those still gets them. The driver is here because primitives alone left
  # JavaScript responsible for a transport it does not have, so the React Native demo could only ever see
  # an in-process loopback peer, never prompted for Bluetooth, and could not send a message.
  #
  # TWO THINGS THE APP'S Podfile MUST KNOW, because a podspec cannot decide either one.
  #
  # First, HopDriver's own graph is incomplete on purpose: its HopObjC, HopFFIBindings and five
  # HopBearer* modules have no podspecs yet, so resolving this dependency fails at the author and names
  # them. sdk/apple/HopDriver.podspec lists what each one needs.
  #
  # Second, the driver reaches the node through UniFFI, whose core is HopFFI.xcframework, while HopSDK
  # above pulls in CHop, the C-ABI build. Measured with `nm`: both archives are named libhop.a and both
  # export the full C ABI plus all 241 UniFFI symbols, so CocoaPods' -l"hop" resolves to whichever search
  # path comes first and only ONE of them can be on the link line. The driver's build is the one carrying
  # SQLCipher at-rest encryption, so choosing CHop silently disables it.
  s.dependency "HopDriver"

  # New Architecture (Fabric/TurboModules) interop: the classic bridge module here runs under the
  # interop layer when the New Architecture is enabled, so no extra codegen is required.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  end
end
