require_relative "HopBearerPodspecSupport"

compatibility = HopBearerPodspecSupport.hop_contract_compatibility!

Pod::Spec.new do |s|
  # The fully qualified pod name produces libHopBearerRelay.a, avoiding the libHop.a/libhop.a collision
  # that makes a pod named Hop unsafe next to CHop on default macOS volumes.
  s.name = "HopBearerRelay"
  s.module_name = "HopBearerRelay"
  s.version = compatibility.fetch(:version)
  s.summary = "Hop's WebSocket relay bearer for iOS and macOS."
  s.description = <<~DESC
    The relay transport for Hop. It keeps one outbound WebSocket to a configured relay and routes opaque
    packet bytes through the HopContract bearer seam. It never links the Hop node or the compiled core.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-bearers-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-bearers-apple.git", :tag => "v#{s.version}" }

  # One target, one module, one source tree. Do not widen this glob to sibling bearers.
  s.source_files = "HopBearerRelay/Sources/HopBearerRelay/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation", "Network", "CryptoKit"

  # The pure Swift contract is intentionally the only Hop dependency. Pulling HopSDK or CHop here would
  # duplicate the Rust core in hosts that run their node through another native binding.
  s.dependency "HopContract", compatibility.fetch(:lower_bound), compatibility.fetch(:upper_bound)
end
