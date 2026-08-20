# HopFFIBindings, the UniFFI-generated Swift API as a CocoaPods pod, and THE SINGLE OWNER OF THE HOP CORE.
# The MODULE this pod's own sources expose is `HopFFIBindings`; the xcframework it vendors additionally
# exposes the C module `hopFFI`.
#
# The CocoaPods face of two SwiftPM targets at once, and the pairing is not a shortcut:
#   .binaryTarget(name: "hopFFI", path: "Frameworks/HopFFI.xcframework")
#   .target(name: "HopFFIBindings", dependencies: ["hopFFI"])
# SwiftPM can name a binary target separately because a binaryTarget is not a compilation unit. CocoaPods
# has no equivalent: a pod that vendors an xcframework wrapping a static library contributes the library
# to the link line and its Headers directory to HEADER_SEARCH_PATHS, so the `hopFFI` module arrives with
# the archive. Splitting them into two pods would buy nothing and add a second pod that could be pointed
# somewhere else later, which is exactly the failure this file exists to prevent.
#
# THE HOP CORE IS VENDORED EXACTLY ONCE, HERE, AND IT IS THE SQLCIPHER BUILD. This is the whole reason
# the pod graph looks the way it does, and it was settled by measurement, not preference.
#
# There are two builds of one ABI in this repo, and both static libraries are named `libhop.a`:
#   drivers/apple/HopDriver/Frameworks/HopFFI.xcframework  built by tools/build-xcframework.sh, which
#                                                          defaults HOP_SQLCIPHER=1, so the database is
#                                                          encrypted at rest with the Keychain-derived
#                                                          key the driver passes to open_keyed
#   the libhop.xcframework release asset CHop used to fetch  a default-features build: it ACCEPTS a db
#                                                          key and leaves every page in plaintext
#
# Measured with nm on the ios-arm64 slice of each: both export the SAME 257 symbols matching
# ^_(hop|uniffi|ffi), 160 of them uniffi_ scaffolding, including _hop_abi_version and _hop_link_up. So
# either archive satisfies BOTH module faces, the C ABI face `CHop` and the UniFFI face `hopFFI`. The only
# difference is encryption: `nm -a` finds 98 sqlcipher references in this artifact and 0 in the release
# asset.
#
# That is why two cores cannot coexist rather than merely being untidy. CocoaPods puts each vendoring
# pod's slice directory on LIBRARY_SEARCH_PATHS and emits ONE -l"hop" (see the app's generated
# Pods-HopDemo.release.xcconfig). With two same-named archives present, that single flag resolves to
# whichever search path happens to come first, the build still succeeds, and if it picks the release asset
# then at-rest encryption is silently off. Forcing both onto the link line instead duplicates all 257
# symbols. Neither outcome is acceptable, so the graph is arranged so only one archive exists: this one.
# sdk/apple/CHop.podspec now carries only the `CHop` module face and depends on this pod for the library.
#
# The published libhop release asset being the NON-encrypted build is a real release-pipeline gap, not
# something this podspec can fix: closing it means publishing a SQLCipher core (or one core that serves
# both faces) as a checksummed asset the way sdk/apple/Package.swift already pins one.
#
# BOTH ARTIFACTS BELOW ARE GITIGNORED BUILD OUTPUTS, so this pod can only ever be consumed as a `:path`
# development pod from a monorepo checkout that has run the build script. That is not a limitation this
# file invented: `git ls-remote --tags origin` returns no tags at all, so no `s.source` tag exists for
# CocoaPods to download for ANY pod in this repo. The preflight below raises rather than letting a missing
# artifact become an empty pod and a module-not-found error at the consumer.

manifest_path = File.expand_path("../../../sdk/apple/Package.swift", __dir__)
version = File.read(manifest_path)[%r{/releases/download/v([0-9][^/\s"]*)/libhop\.xcframework\.zip}, 1]
raise "HopFFIBindings.podspec: no version in the release URL in #{manifest_path}" if version.nil?

xcframework = File.join(__dir__, "Frameworks/HopFFI.xcframework")
bindings = File.join(__dir__, "Sources/HopFFIBindings/hop.swift")
missing = [xcframework, bindings].reject { |path| File.exist?(path) }
unless missing.empty?
  raise <<~MESSAGE
    HopFFIBindings.podspec: missing build output(s):
    #{missing.map { |path| "  #{path}" }.join("\n")}
    Both are produced together by tools/build-xcframework.sh and are gitignored, so a fresh checkout has
    neither. Run it from anywhere in the repo, then re-run pod install:
      ./tools/build-xcframework.sh
    Keep HOP_SQLCIPHER at its default of 1. This pod is the ONLY core in the app's link line, so building
    with HOP_SQLCIPHER=0 turns off at-rest encryption for the whole app with no other symptom.
  MESSAGE
end

Pod::Spec.new do |s|
  s.name = "HopFFIBindings"
  s.version = version
  s.summary = "The UniFFI-generated Swift API for the Hop node, plus the one SQLCipher-enabled Hop core."
  s.description = <<~DESC
    hop.swift, the UniFFI-generated Swift face of the Hop node, together with HopFFI.xcframework, the
    Rust core compiled for ios-arm64, the iOS simulator and macOS. The xcframework carries the static
    library and a Headers directory whose module map names the module hopFFI, which is what the
    generated bindings import. This is the only pod in the graph that vendors the core, and its build
    has SQLCipher enabled so the driver's store is encrypted at rest.
  DESC
  s.homepage = "https://github.com/hopmesh/hop"
  s.license = { :type => "Apache-2.0" }
  s.authors = { "Hop Mesh, LLC" => "jason@waldrip.net" }

  # iOS 16 and macOS 13, matching drivers/apple/HopDriver/Package.swift and every pod in this graph.
  s.platforms = { :ios => "16.0", :osx => "13.0" }
  s.source = { :git => "https://github.com/hopmesh/hop.git", :tag => "v#{s.version}" }

  # hop.swift only. It is generated per release of the core, so a glob rather than a named file keeps
  # this from breaking if UniFFI starts emitting a second file.
  s.source_files = "Sources/HopFFIBindings/*.swift"
  s.swift_version = "5.9"
  s.frameworks = "Foundation"

  # No manual -L or -l flags, deliberately. CocoaPods' generated HopFFIBindings-xcframeworks.sh copies
  # the slice matching the current platform, puts its directory on LIBRARY_SEARCH_PATHS and adds
  # -l"hop" itself, and its slice selection is the part worth keeping. sdk/apple/CHop.podspec documents
  # what happened the last time something in this repo overrode those flags by hand.
  s.vendored_frameworks = "Frameworks/HopFFI.xcframework"
end
