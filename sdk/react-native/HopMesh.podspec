require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "HopMesh"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors      = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms    = { :ios => "15.1", :osx => "12.0" }
  s.source       = { :git => "https://github.com/hopmesh/hop-sdk-react-native.git", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.swift_version = "5.9"

  # The React Native runtime this module bridges to.
  s.dependency "React-Core"

  # The Hop Apple client SDK (sdk/apple, mirrored to hopmesh/hop-sdk-apple) is a Swift package. Pull it
  # in as a Swift Package Manager dependency when the CocoaPods/React Native toolchain supports it
  # (CocoaPods 1.16+, React Native 0.75+). Older toolchains: add the hop-sdk-apple package to the app
  # target directly (see README) and this bridge's `import Hop` resolves against it.
  if s.respond_to?(:spm_dependency)
    s.spm_dependency(
      url: "https://github.com/hopmesh/hop-sdk-apple",
      requirement: { kind: "upToNextMajorVersion", minimumVersion: package["version"] },
      products: ["Hop"]
    )
  end

  # New Architecture (Fabric/TurboModules) interop: the classic bridge module here runs under the
  # interop layer when the New Architecture is enabled, so no extra codegen is required.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  end
end
