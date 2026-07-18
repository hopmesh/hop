# link-libhop.py: verify and extract the one exact libhop archive for this board before linking.
import os
import shutil
import subprocess
import sys

Import("env")

lib_dir = env.Dir(".").srcnode().get_abspath()
mcu = env.BoardConfig().get("build.mcu", "esp32")
targets = {
    "esp32": "xtensa-esp32-espidf",
    "esp32s2": "xtensa-esp32s2-espidf",
    "esp32s3": "xtensa-esp32s3-espidf",
    "esp32c2": "riscv32imc-esp-espidf",
    "esp32c3": "riscv32imc-esp-espidf",
    "esp32c6": "riscv32imac-esp-espidf",
    "esp32h2": "riscv32imac-esp-espidf",
}
target = targets.get(mcu)
if target is None:
    raise RuntimeError("Hop: no signed libhop target is declared for MCU '%s'" % mcu)

native = os.path.join(lib_dir, "native")
helper = os.path.join(native, "native-artifacts.py")
manifest = os.path.join(native, "native-artifacts.json")
signature = os.path.join(native, "native-artifacts.json.sig")
public_key = os.path.join(native, "native-artifacts-public.pem")
artifacts = os.path.join(native, "artifacts")
for required in (helper, manifest, signature, public_key):
    if not os.path.isfile(required):
        raise RuntimeError("Hop: signed native release file is missing: %s" % required)

destination = os.path.join(lib_dir, ".native", target)
if os.path.isdir(destination):
    shutil.rmtree(destination)
subprocess.run(
    [
        sys.executable,
        helper,
        "extract",
        "--manifest",
        manifest,
        "--signature",
        signature,
        "--public-key",
        public_key,
        "--directory",
        artifacts,
        "--target",
        target,
        "--destination",
        destination,
    ],
    check=True,
)

archive = os.path.join(destination, "lib", "libhop.a")
header_dir = os.path.join(destination, "include")
if not os.path.isfile(archive) or not os.path.isfile(os.path.join(header_dir, "hop.h")):
    raise RuntimeError("Hop: verified target archive has an incomplete layout for %s" % target)
env.Append(LIBS=[env.File(archive)])
env.Append(CPPPATH=[header_dir])
