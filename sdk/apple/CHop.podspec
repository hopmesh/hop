# CHop, the C ABI module face of the Hop core. This pod VENDORS NOTHING and CARRIES NO SOURCES.
#
# It exists so `s.dependency "CHop"` in HopSDK.podspec keeps resolving, and so that dependency now points
# at the one pod that owns the core. `import CHop` in Sources/Hop/Hop.swift resolves against the module map
# inside the xcframework that drivers/apple/HopDriver/HopFFIBindings.podspec vendors, which declares BOTH
# `hopFFI` (the UniFFI face) and `CHop` (this one) over a single libhop.a.
#
# WHY THIS POD STOPPED FETCHING libhop.xcframework, which was settled by measurement.
#
# There are two builds of one ABI, and BOTH static libraries are named `libhop.a`:
#   drivers/apple/HopDriver/Frameworks/HopFFI.xcframework   built by tools/build-xcframework.sh, which
#                                                           defaults HOP_SQLCIPHER=1, so hop.db is
#                                                           encrypted at rest under the Keychain-derived
#                                                           key the driver passes to open_keyed
#   the libhop.xcframework release asset this pod fetched    a default-features build that ACCEPTS a db
#                                                           key and leaves every page in plaintext
#
# Measured with nm on the ios-arm64 slice of each: they export the SAME 257 symbols matching
# ^_(hop|uniffi|ffi), 160 of them uniffi_ scaffolding, including _hop_abi_version and _hop_link_up. So one
# archive satisfies both module faces. `nm -a` finds 98 sqlcipher references in the driver's artifact and 0
# in the release asset, so the two are interchangeable at LINK time and not at RUNTIME.
#
# Vendoring both was therefore never an option. CocoaPods puts each vendoring pod's slice directory on
# LIBRARY_SEARCH_PATHS and emits exactly ONE -l"hop" for the aggregate target, so with two same-named
# archives present that flag resolves to whichever search path sorts first, the build still succeeds, and
# at-rest encryption is silently off if the release asset wins. Forcing both onto the link line instead
# duplicates all 257 symbols. One owner is the only sound shape, and it has to be the SQLCipher build
# because the driver opens its store with a key.
#
# WHY THE MODULE COMES FROM THE XCFRAMEWORK RATHER THAN FROM hop.h AS A PUBLIC HEADER HERE. That was tried
# first and CocoaPods cannot do it. A pod whose only files are headers has no compilable source, so
# PodTarget#should_build? is false, and BuildSettings#module_map_file_to_import returns nil for any target
# that does not build (cocoapods 1.17.0, target/build_settings.rb line 894). The result was a pod with no
# umbrella header and no module map, and a build that failed at
# `sdk/apple/Sources/Hop/Hop.swift:7:8: error: unable to resolve module dependency: 'CHop'`. A Clang module
# with no compiled source can only reach a consumer through a Headers directory carrying its own
# module.modulemap, which is exactly what a vendored xcframework provides and how this module used to
# arrive. So tools/build-xcframework.sh now packages hop.h beside hopFFI.h and declares both modules in the
# one module map; the two headers share no declarations.
#
# THE PUBLISHED libhop RELEASE ASSET IS THE NON-ENCRYPTED BUILD. That is a release-pipeline gap this file
# cannot close: build-xcframework.sh in this directory cross-compiles with default features and never
# passes --features sqlcipher, so the artifact whose checksum Package.swift pins has no SQLCipher at all
# (measured: 0 sqlcipher references in Frameworks/libhop.xcframework as well). Closing it means publishing
# a SQLCipher core, or one core serving both module faces, as a checksummed asset.
#
# The version is still read from Package.swift, never restated here: that is where the release job already
# rewrites it, so a version bump cannot leave this pod disagreeing with the package.

manifest_path = File.join(__dir__, "Package.swift")
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]

# Raise rather than fall back. A nil here would produce a pod with no version, which is exactly the kind
# of silent degradation this repo keeps having to dig out.
raise "CHop.podspec: no version in the release URL in #{manifest_path}" if version.nil?

Pod::Spec.new do |s|
  s.name = "CHop"
  s.version = version
  s.summary = "The CHop module face of the Hop core, resolved from the one xcframework in the graph."
  s.description = <<~DESC
    The C ABI face of libhop, as the module name Hop.swift imports. This pod carries no files: the
    module map that names CHop lives in the xcframework HopFFIBindings vendors, alongside the UniFFI
    hopFFI module, so both faces resolve against a single libhop.a. That single archive is the
    SQLCipher build, which is what keeps the driver's store encrypted at rest.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0", :file => "LICENSE.md" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  # The one pod that owns the core, and with it the Headers directory that declares this module.
  s.dependency "HopFFIBindings", version
end
