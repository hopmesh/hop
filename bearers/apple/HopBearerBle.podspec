require_relative "HopBearerPodspecSupport"

compatibility = HopBearerPodspecSupport.hop_contract_compatibility!

Pod::Spec.new do |s|
  # The pod and module intentionally share the fully qualified bearer name. CocoaPods therefore emits
  # libHopBearerBle.a, which cannot collide with CHop's libhop.a on a case-insensitive volume.
  s.name = "HopBearerBle"
  s.module_name = "HopBearerBle"
  s.version = compatibility.fetch(:version)
  s.summary = "Hop's CoreBluetooth bearer for iOS and macOS."
  s.description = <<~DESC
    The BLE transport for Hop. It uses GATT for the PSM handshake, L2CAP for opaque packet bytes, and
    iBeacon wake on iOS. The module implements only the HopContract bearer seam and never links the Hop
    node or the compiled core.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-bearers-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-bearers-apple.git", :tag => "v#{s.version}" }

  # One target, one module, one source tree. Do not widen this glob to sibling bearers.
  s.source_files = "HopBearerBle/Sources/HopBearerBle/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation", "CoreBluetooth", "Security"
  s.ios.frameworks = "CoreLocation", "UIKit"

  # The pure Swift contract is intentionally the only Hop dependency. Pulling HopSDK or CHop here would
  # duplicate the Rust core in hosts that run their node through another native binding.
  s.dependency "HopContract", compatibility.fetch(:lower_bound), compatibility.fetch(:upper_bound)
end
