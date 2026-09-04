#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("crate_publish", root / "tools/crates-publish.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def rejected(call, label):
    try:
        call()
    except module.CrateError:
        return
    raise AssertionError(f"expected crate rejection: {label}")


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    readme = temporary / "README.md"
    readme.write_text("fixture\n")
    manifest = temporary / "Cargo.toml"
    manifest.write_text('[package]\nname = "fixture"\nversion = "1.2.3"\n')
    package = {
        "authors": ["Hop"],
        "categories": ["network-programming"],
        "dependencies": [{
            "features": [], "kind": None, "name": "serde", "optional": False,
            "registry": None, "rename": None, "req": "^1", "source": "registry+https://github.com/rust-lang/crates.io-index",
            "target": None, "uses_default_features": True,
        }],
        "description": "fixture crate",
        "documentation": None,
        "features": {},
        "homepage": None,
        "keywords": [],
        "license": "Apache-2.0",
        "license_file": None,
        "links": None,
        "manifest_path": str(manifest),
        "name": "fixture",
        "readme": str(readme),
        "repository": "https://github.com/hopmesh/monorepo",
        "rust_version": "1.85",
        "version": "1.2.3",
    }
    metadata = module.package_metadata(package)
    assert set(metadata) == module.PUBLISH_FIELDS
    assert metadata["deps"][0]["kind"] == "normal"
    assert metadata["readme"] == "fixture\n"
    rejected(
        lambda: module.package_metadata(dict(package, dependencies=[dict(package["dependencies"][0], source=None)])),
        "path dependency",
    )

    crate = temporary / "fixture.crate"
    cargo_toml = b'[package]\nname = "fixture"\nversion = "1.2.3"\n'
    with tarfile.open(crate, "w:gz") as archive:
        entry = tarfile.TarInfo("fixture-1.2.3/Cargo.toml")
        entry.size = len(cargo_toml)
        archive.addfile(entry, io.BytesIO(cargo_toml))
    payload = module.validate_crate(crate, metadata)

    class Response:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *_): return False
        def read(self): return b'{"warnings":{"other":[]}}'

    captured = {}
    def urlopen(request, timeout):
        captured["request"] = request
        captured["timeout"] = timeout
        return Response()

    metadata_path = temporary / "metadata.json"
    metadata_path.write_text(json.dumps(metadata))
    module.urllib.request.urlopen = urlopen
    os.environ["CARGO_REGISTRY_TOKEN"] = "secret"
    module.publish(type("Args", (), {"crate": str(crate), "metadata": str(metadata_path)})())
    request = captured["request"]
    assert request.full_url == "https://crates.io/api/v1/crates/new"
    assert request.get_method() == "PUT"
    assert request.get_header("Authorization") == "secret"
    metadata_size = struct.unpack("<I", request.data[:4])[0]
    offset = 4 + metadata_size
    crate_size = struct.unpack("<I", request.data[offset:offset + 4])[0]
    assert request.data[offset + 4:] == payload
    assert crate_size == len(payload)

    # ABI-012: dry-run packages all three monorepo crates and validates metadata
    dry_run_dir = temporary / "dry-run"
    produced = module.dry_run(type("Args", (), {"root": str(root), "output_dir": str(dry_run_dir)})())
    assert len(produced) == 3
    assert [p[0] for p in produced] == ["hop-mesh-core", "hop-mesh-store-sqlite", "hop-mesh-store-firestore"]
    for name, cpath, mpath, mdata in produced:
        assert Path(cpath).is_file()
        assert Path(mpath).is_file()
        assert mdata["name"] == name

    # Mutation with local name rejected
    orig_crates = module.PUBLISHED_CRATES
    try:
        module.PUBLISHED_CRATES = (
            ("core/hop-core", "hop-core", "hop-core"), # local name not renamed
            ("core/stores/hop-store-sqlite", "hop-store-sqlite", "hop-mesh-store-sqlite"),
            ("core/stores/hop-store-firestore", "hop-store-firestore", "hop-mesh-store-firestore"),
        )
        rejected(
            lambda: module.dry_run(type("Args", (), {"root": str(root), "output_dir": str(temporary / "mutated")})()),
            "local crate name rejected",
        )

        # Omission rejected
        module.PUBLISHED_CRATES = (
            ("core/hop-core", "hop-core", "hop-mesh-core"),
        )
        rejected(
            lambda: module.dry_run(type("Args", (), {"root": str(root), "output_dir": str(temporary / "omitted")})()),
            "omitted crate rejected",
        )
    finally:
        module.PUBLISHED_CRATES = orig_crates

print("crate publication tests passed")
PY
