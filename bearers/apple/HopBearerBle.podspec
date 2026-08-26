# HopBearerBle, the Apple BLE bearer as one CocoaPods module.
#
# The pod mirrors the matching SwiftPM target only. It deliberately depends on
# HopContract rather than HopSDK or CHop, so adding a radio does not link the
# Rust core a second time.
require_relative "HopBearerPodspecSupport"

metadata = HopBearerPodspecSupport.load!(__dir__)

Pod::Spec.new do |s|
  s.name = "HopBearerBle"
  s.module_name = "HopBearerBle"
  s.version = metadata.version
  s.summary = "Hop's Apple BLE bearer: GATT discovery and L2CAP data links."
  s.description = <<~DESC
    The Hop BLE bearer for iOS and macOS. It owns CoreBluetooth discovery and
    links while carrying only opaque bytes through the HopContract interface.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-bearers-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-bearers-apple.git", :tag => "v#{s.version}" }

  s.source_files = "HopBearerBle/Sources/HopBearerBle/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation", "Security", "CoreBluetooth"
  s.ios.frameworks = "CoreLocation", "UIKit"

  s.dependency "HopContract", *metadata.compatibility
end
