#!/usr/bin/env python3
"""identity-secret-guard.py (PROC-008): fail if a raw 32-byte identity secret
or private key is committable to this repository under an arbitrary filename.

Scans tracked files or explicit file paths for:
1. Raw 32-byte binary seeds with high Shannon entropy (> 4.5 bits/byte), including
   33-byte blobs with a trailing newline and inside files with safe extensions (PROC-008).
2. Private key markers and credential patterns.
3. Contributor local absolute paths (/Users/<name>/ and /home/<name>/) in tracked text files (CLAIM-016).
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

ABSOLUTE_PATH_PATTERN = re.compile(rb"/(?:Users|home)/[a-zA-Z0-9_.-]+/")
PATH_ALLOWLIST = {
    b"/home/web_user/",
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

def is_binary_seed(data: bytes) -> bool:
    if not data:
        return False
    return any((b < 32 and b not in (9, 10, 13)) or b > 126 for b in data)

def is_binary_file(data: bytes) -> bool:
    if not data:
        return False
    if b"\x00" in data:
        return True
    try:
        text = data.decode("utf-8")
        control_chars = sum(1 for c in text if ord(c) < 32 and c not in "\t\n\r")
        return control_chars > 0.05 * len(text)
    except UnicodeDecodeError:
        return True

def check_file(path: str) -> list[str]:
    violations = []
    # Skip excluded tool files
    rel_path = os.path.relpath(path, os.getcwd()).replace("\\", "/")
    if rel_path in EXCLUDED_PATHS or os.path.basename(rel_path).startswith(".git"):
        return violations

    try:
        with open(path, "rb") as f:
            data = f.read(1024 * 1024)
    except (OSError, IOError):
        return violations

    # 1. Exact 32-byte raw binary seed check (the relay/telemetryd identity format)
    # PROC-008: Check before SAFE_BINARY_EXTENSIONS so a 32-byte secret named .png or .wasm
    # is not exempted, and strip trailing newlines so a 33-byte file is caught.
    seed = data.rstrip(b"\r\n")
    if len(seed) == 32 and is_binary_seed(seed):
        entropy = shannon_entropy(seed)
        if entropy > 4.5:
            violations.append(
                f"raw 32-byte high-entropy identity seed detected (entropy {entropy:.2f} bits/byte)"
            )
            return violations

    _, ext = os.path.splitext(path.lower())
    if ext in SAFE_BINARY_EXTENSIONS:
        return violations

    # 2. Private key markers
    for pattern in PRIVATE_KEY_PATTERNS:
        if pattern.search(data):
            violations.append("private key or sensitive credential pattern detected")
            return violations

    # 3. Contributor local absolute paths in tracked text files (CLAIM-016)
    if not is_binary_file(data):
        for m in ABSOLUTE_PATH_PATTERN.finditer(data):
            matched_prefix = m.group(0)
            if matched_prefix not in PATH_ALLOWLIST:
                violations.append(
                    f"contributor local absolute path detected: {matched_prefix.decode('utf-8', errors='replace')}"
                )
                break

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
