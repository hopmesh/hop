# CHop, the compiled Hop core as a CocoaPods pod.
#
# This is the CocoaPods face of the `CHop` binaryTarget in Package.swift: the same libhop.xcframework, from
# the same immutable release asset, verified against the same checksum. It exists so `Hop` can be a pod, so
# the React Native SDK can depend on it the ordinary way instead of through a Swift Package Manager
# dependency that CocoaPods cannot resolve.
#
# WHY A SEPARATE POD rather than folding the binary into Hop.podspec. CocoaPods compiles one pod into one
# module, and `Hop.swift` does `import CHop`. Keeping the binary in its own pod preserves that module name,
# so no Swift source has to change to be packageable. It is the same reason SwiftPM models it as a separate
# binaryTarget.
#
# THE VERSION AND CHECKSUM ARE READ FROM Package.swift, never restated here. Package.swift is where the
# release job already rewrites both, and tools/package-export-smoke.py asserts that its URL points at the
# workspace anchor version, so parsing it means a version bump cannot leave this pod pointing at a stale
# asset. A second hardcoded copy would be a second thing to forget.

manifest_path = File.join(__dir__, "Package.swift")
manifest = File.read(manifest_path)

asset_url = manifest[%r{(https://\S+/releases/download/v[0-9][^/\s"]*/libhop\.xcframework\.zip)}, 1]
version = manifest[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
checksum = manifest[/checksum:\s*"([0-9a-f]{64})"/, 1]
license_path = File.join(__dir__, "LICENSE.md")

# Raise rather than fall back. A nil here would produce a pod with no version or an unverified download,
# which is exactly the kind of silent degradation this repo keeps having to dig out.
raise "CHop.podspec: no libhop.xcframework release URL found in #{manifest_path}" if asset_url.nil?
raise "CHop.podspec: no version in the release URL in #{manifest_path}" if version.nil?
raise "CHop.podspec: no 64 character checksum found in #{manifest_path}" if checksum.nil?
raise "CHop.podspec: no license file at #{license_path}" unless File.exist?(license_path)

Pod::Spec.new do |s|
  s.name = "CHop"
  s.version = version
  s.summary = "The compiled Hop core (libhop) as an xcframework, exposing the C ABI as the CHop module."
  s.description = <<~DESC
    libhop built for ios-arm64, the iOS simulator, and macOS, packaged as an xcframework whose header
    directory carries a module map naming the module CHop. Swift code imports CHop and links the static
    library with no manual -L or -l flags. This is the same artifact the Swift package resolves as its
    CHop binaryTarget.
  DESC
  s.homepage = "https://github.com/hopmesh/hop-sdk-apple"
  # :text, not :file. The other two pods point :file at the LICENSE.md in their git checkout, but this
  # pod's source is the release ZIP, which carries the xcframework and nothing else, so a :file would
  # resolve inside the archive and find nothing. That is not cosmetic: `pod spec lint` reported
  # "WARN | license: Unable to find a license file", and CocoaPods generates the consumer's
  # acknowledgements from this attribute, so an app shipping the Hop core would have carried no Apache
  # notice at all. Reading the sibling file keeps one copy of the license in the tree and bakes the
  # text into the published spec, which is what the registry stores.
  s.license = { :type => "Apache-2.0", :text => File.read(license_path) }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }

  # The pod's source IS the release archive, not a git checkout: the xcframework is a build output and is
  # not committed. :sha256 makes CocoaPods verify the download, so the pod fails loudly on a corrupted or
  # substituted asset instead of building against unverified bytes. Measured: `swift package
  # compute-checksum` on this archive equals its plain SHA-256, so the one pinned value in Package.swift is
  # correct for both package managers.
  s.source = { :http => asset_url, :sha256 => checksum }
  s.vendored_frameworks = "libhop.xcframework"

  # NO MANUAL LINK FLAGS, and that is a deliberate result rather than an omission.
  #
  # This xcframework wraps STATIC LIBRARIES (a libhop.a plus a Headers directory per slice), not .framework
  # bundles. CocoaPods handles that: its generated CHop-xcframeworks.sh calls
  # `install_xcframework ... "library" ...`, copies the slice matching the current platform to
  # ${PODS_XCFRAMEWORKS_BUILD_DIR}/CHop/libhop.a, puts that directory on LIBRARY_SEARCH_PATHS, and adds
  # -l"hop" to the consumer's OTHER_LDFLAGS. Slice selection is worth keeping, so nothing here overrides it.
  #
  # What broke was NAME RESOLUTION, not these flags. The Swift wrapper pod used to be called `Hop`, so it
  # built libHop.a, and on a case-insensitive volume (the macOS default) that is the same file name as this
  # library's libhop.a. Measured twice: with the wrapper's directory earlier in the search path, -l"hop"
  # picked up libHop.a and every core symbol stayed undefined; adding the core by explicit path as well then
  # linked the wrapper twice and failed with 129 duplicate Swift symbols. The fix was to rename that pod to
  # HopSDK (module_name stays "Hop"), which makes the two archive names genuinely different and lets
  # CocoaPods' own flags resolve correctly. Do not rename it back.
end
