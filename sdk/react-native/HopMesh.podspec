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

  # The native bridge owns BLE and LAN packet routing. These are local integration
  # pods today, so a consuming Podfile must provide their `:path` specs beside
  # HopContract. Declaring them here makes a missing bearer a resolution failure
  # instead of an `import HopBearerBle` compiler error in a later build phase.
  s.dependency "HopBearerBle"
  s.dependency "HopBearerLan"

  # New Architecture (Fabric/TurboModules) interop: the classic bridge module here runs under the
  # interop layer when the New Architecture is enabled, so no extra codegen is required.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  end
end
