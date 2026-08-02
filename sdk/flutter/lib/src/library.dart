/// Locate and open `libhop`, the Hop protocol core, as a [DynamicLibrary].
///
/// Resolution order (the same `HOP_LIBDIR` env the other SDKs honour, then the
/// in-repo cargo build):
///   1. `HOP_LIBDIR/libhop.<ext>` if `HOP_LIBDIR` is set
///   2. `<repo>/target/debug/libhop.<ext>`
///   3. `<repo>/target/release/libhop.<ext>`
///   4. the bare library name, so a system loader / Flutter bundle can find it
///
/// On Flutter the shared library is packaged with the app (see README), so the
/// bare-name lookup is the path that fires at runtime; the `target/` candidates
/// are for `dart test` and the examples against a local `cargo build -p hop`.
library;

import 'dart:ffi';
import 'dart:io';

String get _ext {
  if (Platform.isMacOS) return 'dylib';
  if (Platform.isWindows) return 'dll';
  return 'so';
}

String get _libFileName => Platform.isWindows ? 'hop.$_ext' : 'libhop.$_ext';

/// The candidate paths tried in order, exposed so a failing open can report them.
List<String> libraryCandidates() {
  final candidates = <String>[];
  final libdir = Platform.environment['HOP_LIBDIR'];
  if (libdir != null && libdir.isNotEmpty) {
    candidates.add('$libdir${Platform.pathSeparator}$_libFileName');
  }
  // Walk up from the working directory to a repo checkout's target/{debug,release}.
  for (final root in _repoRootGuesses()) {
    candidates.add('$root/target/debug/$_libFileName');
    candidates.add('$root/target/release/$_libFileName');
  }
  return candidates;
}

Iterable<String> _repoRootGuesses() sync* {
  // Walk up from the current working directory: works whether tests run from
  // sdk/flutter or the repo root.
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    yield dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
}

/// Open `libhop`. Throws an [ArgumentError] listing every path tried when the
/// library cannot be found or opened, so a missing `cargo build -p hop` is a
/// clear message rather than a raw loader abort.
DynamicLibrary openLibhop() {
  for (final path in libraryCandidates()) {
    if (File(path).existsSync()) {
      return DynamicLibrary.open(path);
    }
  }
  // Last resort: let the platform loader resolve the bare name (the Flutter and
  // system-install path). If that also fails, surface the candidate list.
  try {
    return DynamicLibrary.open(_libFileName);
  } on ArgumentError {
    final tried = libraryCandidates().join('\n  ');
    throw ArgumentError(
      '$_libFileName not found. Build it with `cargo build -p hop` or set '
      'HOP_LIBDIR.\nLooked in:\n  $tried\n  (and the system library path)',
    );
  }
}
