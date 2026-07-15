# link-libhop.py: link the correct prebuilt libhop.a into the firmware.
#
# libhop is the Hop protocol core (Rust, the `hop-core` / `libhop` project) exposed as a flat C ABI.
# The wrapper in src/ calls that ABI; the actual code lives in a static archive that must be
# cross-compiled for the target chip. The release workflow (.github/workflows/release.yml) builds it
# with hop-core's `minimal` feature (no UniFFI, no SQLite) once per ESP32 architecture and commits the
# result, plus the C ABI header, under this library:
#
#   prebuilt/xtensa/libhop.a   for esp32, esp32-s2, esp32-s3   (esp-rs Xtensa toolchain, a Rust fork)
#   prebuilt/riscv/libhop.a    for esp32-c3, esp32-c6, esp32-h2 (stock Rust, the *-esp-espidf target)
#   include/hop.h              the generated C ABI header, shared by every arch
#
# Xtensa is a Rust fork, so that archive is the one to sanity check after any core change; see
# include/README.md. This script picks the archive by the board's MCU and adds it to the link.

import os

Import("env")

lib_dir = os.path.dirname(os.path.abspath(__file__))
mcu = env.BoardConfig().get("build.mcu", "esp32")

# RISC-V ESP32 parts use stock Rust; everything else on this platform is Xtensa.
riscv_mcus = ("esp32c2", "esp32c3", "esp32c6", "esp32h2")
arch = "riscv" if mcu in riscv_mcus else "xtensa"

archive = os.path.join(lib_dir, "prebuilt", arch, "libhop.a")
header_dir = os.path.join(lib_dir, "include")

if os.path.isfile(archive):
    # Pass the archive straight to the linker, and expose the C ABI header for anyone including it.
    env.Append(LINKFLAGS=[archive])
    env.Append(CPPPATH=[header_dir])
else:
    print("Hop: prebuilt libhop.a for arch '%s' (mcu '%s') not found at %s" % (arch, mcu, archive))
    print("Hop: it is produced by the release workflow; see include/README.md for how to stage it.")
