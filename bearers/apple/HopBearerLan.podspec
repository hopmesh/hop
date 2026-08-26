require_relative "HopBearerPodspecSupport"

compatibility = HopBearerPodspecSupport.hop_contract_compatibility!

Pod::Spec.new do |s|
  # The fully qualified pod name produces libHopBearerLan.a, avoiding the libHop.a/libhop.a collision
  # that makes a pod named Hop unsafe next to CHop on default macOS volumes.
  s.name = "HopBearerLan"
  s.module_name = "HopBearerLan"
  s.version = compatibility.fetch(:version)
  s.summary = "Hop's mDNS and TCP LAN bearer for iOS and macOS."
  s.description = <<~DESC
    The LAN transport for Hop. It discovers peers with mDNS and exchanges opaque packet bytes over TCP.
    The module implements only the HopContract bearer seam and never links the Hop node or the compiled core.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-bearers-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-bearers-apple.git", :tag => "v#{s.version}" }

  # One target, one module, one source tree. Do not widen this glob to sibling bearers.
  s.source_files = "HopBearerLan/Sources/HopBearerLan/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation", "Network"

  # The pure Swift contract is intentionally the only Hop dependency. Pulling HopSDK or CHop here would
  # duplicate the Rust core in hosts that run their node through another native binding.
  s.dependency "HopContract", compatibility.fetch(:lower_bound), compatibility.fetch(:upper_bound)
end
