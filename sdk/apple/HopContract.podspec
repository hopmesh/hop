# HopContract, the pure Swift bearer contract as a CocoaPods pod.
#
# The CocoaPods face of the `HopContract` product in Package.swift: the Bearer / LinkSink / BearerManager
# contract, HopRole, and the transport helpers. No libhop, by design, so a bearer can depend on the contract
# without linking the Rust core twice.
#
# WHY IT IS ITS OWN POD rather than a subspec of Hop. CocoaPods compiles one pod into one module, and
# `Hop.swift` does `import HopContract`. A subspec would collapse both source trees into a single `Hop`
# module and that import would stop resolving, so packaging convenience would have forced a change to
# shipping SDK sources. Separate pods keep the module names, and they line up one to one with the two
# SwiftPM products.
#
# The version is read from Package.swift for the reason given in CHop.podspec: one source of truth that the
# release job already maintains.

manifest_path = File.join(__dir__, "Package.swift")
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopContract.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "HopContract"
  s.version = version
  s.summary = "The pure Swift Hop bearer contract: Bearer, LinkSink, BearerManager, HopRole, transports."
  s.description = <<~DESC
    The contract every Hop bearer implements, with no dependency on libhop. Bearers depend on this so an
    app driving a node through UniFFI does not link the Rust core a second time. It also carries the
    LinkId mint, route and dedup logic that every Apple bearer routes through.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-sdk-apple"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop-sdk-apple.git", :tag => "v#{s.version}" }

  s.source_files = "Sources/HopContract/**/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation", "Security"
end
