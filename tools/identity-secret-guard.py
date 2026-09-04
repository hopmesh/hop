#!/usr/bin/env python3
"""identity-secret-guard.py (PROC-008): fail if a raw 32-byte identity secret
or private key is committable to this repository under an arbitrary filename.

Scans tracked files or explicit file paths for:
1. Raw 32-byte binary seeds with high Shannon entropy (> 4.5 bits/byte).
2. Private key markers and credential patterns.
"""
import math
import os
import re
import subprocess
import sys

PRIVATE_KEY_PATTERNS = [
    re.compile(rb"BEGIN (?:RSA|EC|OPENSSH|DSA|PGP) PRIVATE"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"ghp_[A-Za-z0-9]{36}"),
    re.compile(rb"xox[baprs]-[0-9A-Za-z]{10,48}"),
]

SAFE_BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".wasm", ".a", ".so",
    ".dylib", ".tar", ".gz", ".xz", ".zip", ".xcframework",
}

EXCLUDED_PATHS = {
    "tools/identity-secret-guard.py",
    "tools/identity-secret-guard.test.sh",
}

def shannon_entropy(data: bytes) -> float:
    if not data:
        return 0.0
    freq = {}
    for byte in data:
        freq[byte] = freq.get(byte, 0) + 1
    entropy = 0.0
    length = len(data)
    for count in freq.values():
        p = count / length
        entropy -= p * math.log2(p)
    return entropy

def is_binary(data: bytes) -> bool:
    if not data:
        return False
    return any((b < 32 and b not in (9, 10, 13)) or b > 126 for b in data)

def check_file(path: str) -> list[str]:
    violations = []
    # Skip excluded tool files
    rel_path = os.path.relpath(path, os.getcwd()).replace("\\", "/")
    if rel_path in EXCLUDED_PATHS or os.path.basename(rel_path).startswith(".git"):
        return violations

    _, ext = os.path.splitext(path.lower())
    if ext in SAFE_BINARY_EXTENSIONS:
        return violations

    try:
        with open(path, "rb") as f:
            data = f.read(1024 * 1024)
    except (OSError, IOError):
        return violations

    # 1. Exact 32-byte raw binary seed check (the relay/telemetryd identity format)
    if len(data) == 32 and is_binary(data):
        entropy = shannon_entropy(data)
        if entropy > 4.5:
            violations.append(
                f"raw 32-byte high-entropy identity seed detected (entropy {entropy:.2f} bits/byte)"
            )
            return violations
    # 2. Private key markers
    for pattern in PRIVATE_KEY_PATTERNS:
        if pattern.search(data):
            violations.append("private key or sensitive credential pattern detected")
            return violations

    return violations

def main() -> int:
    files_to_check = []
    if len(sys.argv) > 1:
        files_to_check = sys.argv[1:]
    else:
        # Scan git tracked files
        try:
            out = subprocess.check_output(["git", "ls-files"], text=True)
            files_to_check = [f.strip() for f in out.splitlines() if f.strip()]
        except Exception as e:
            sys.stderr.write(f"error: failed to list git files: {e}\n")
            return 2

    violations_found = 0
    for file_path in files_to_check:
        if not os.path.isfile(file_path):
            continue
        reasons = check_file(file_path)
        for reason in reasons:
            sys.stderr.write(f"error: {file_path}: {reason}\n")
            violations_found += 1

    if violations_found > 0:
        sys.stderr.write(
            f"identity-secret-guard: FAILED ({violations_found} potential secret(s) found)\n"
        )
        return 1

    print("identity-secret-guard: OK (clean)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
