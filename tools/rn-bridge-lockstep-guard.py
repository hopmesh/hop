#!/usr/bin/env python3
"""Keep the React Native bridge identical on all three sides it is written on.

sdk/react-native/CLAUDE.md states the rule in prose: "Change one, change all three, or a call
silently no-ops on one platform." Nothing enforced it. This does.

The JS layer is unit-tested against a FAKE native module, so a method that exists in the TypeScript
contract and is missing from a real platform still passes every test in the package. The failure only
appears in a consuming app, on one platform, as a call that resolves undefined.

Three surfaces have to agree:

  src/native.ts                 HopNativeModule, the declared contract and the source of truth
  ios/HopMesh.swift             the @objc implementations
  ios/HopMesh.m                 the RCT_EXTERN_METHOD declarations that expose them to JS
  android/.../HopMeshModule.kt  the @ReactMethod implementations

iOS needs both files because they fail differently. A Swift @objc func with no matching
RCT_EXTERN_METHOD is invisible to JS; an RCT_EXTERN_METHOD with no Swift func is an unrecognized
selector at call time. Worse, both can exist while their SELECTORS disagree, which compiles cleanly
and throws only when the method is actually called, so the selector is compared, not just the name.
"""

import re
from pathlib import Path

PKG = "sdk/react-native"
NATIVE_TS = f"{PKG}/src/native.ts"
SWIFT = f"{PKG}/ios/HopMesh.swift"
OBJC = f"{PKG}/ios/HopMesh.m"
KOTLIN = f"{PKG}/android/src/main/java/sh/hop/reactnative/HopMeshModule.kt"

# addListener/removeListeners are the RCTEventEmitter event-subscription pair. On iOS they are
# INHERITED from RCTEventEmitter, so declaring them in Swift or ObjC would override the base class;
# on Android there is no such base class and React Native requires the module to define them itself.
# So their asymmetry is correct, and exempting them is not a hole: they are still required in the
# contract and on Android, and still forbidden on iOS, which is asserted below.
EVENT_EMITTER_PAIR = ("addListener", "removeListeners")


class BridgeLockstepError(RuntimeError):
    pass


def read(root, relative):
    path = root / relative
    if not path.is_file():
        raise BridgeLockstepError(f"missing bridge file: {relative}")
    return path.read_text(encoding="utf-8")


def contract_methods(text):
    """Method names declared on the HopNativeModule interface."""
    match = re.search(r"HopNativeModule\s*\{(.*?)\n\}", text, re.S)
    if not match:
        raise BridgeLockstepError(f"{NATIVE_TS}: HopNativeModule interface not found")
    names = []
    for name in re.findall(r"^\s{2}([A-Za-z][A-Za-z0-9_]*)\s*[(:<]", match.group(1), re.M):
        if name not in names:
            names.append(name)
    if not names:
        raise BridgeLockstepError(f"{NATIVE_TS}: HopNativeModule declares no methods")
    return names


def swift_selectors(text):
    """{func name: objc selector} for every @objc func."""
    found = {}
    for selector, name in re.findall(
        r"@objc(?:\(([^)]*)\))?\s+func\s+([A-Za-z][A-Za-z0-9_]*)", text
    ):
        found[name] = selector.strip() if selector.strip() else name
    return found


def objc_selectors(text):
    """{base name: selector} reconstructed from each RCT_EXTERN_METHOD declaration.

    RCT_EXTERN_METHOD(createEphemeral:(RCTPromiseResolveBlock)resolve
                      rejecter:(RCTPromiseRejectBlock)reject)
    declares the selector createEphemeral:rejecter:. Every argument label is a `label:(Type)` pair,
    so the labels in order, colon-joined, are the selector.
    """
    found = {}
    for body in re.findall(r"RCT_EXTERN_METHOD\((.*?)\)\s*(?:$|\n)", text, re.S):
        labels = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\(", body)
        if not labels:
            bare = body.strip().split(":")[0].strip()
            if bare:
                found[bare] = bare
            continue
        found[labels[0]] = ":".join(labels) + ":"
    return found


def kotlin_methods(text):
    return sorted(
        set(
            re.findall(
                r"@ReactMethod[^\n]*\n(?:\s*@[^\n]*\n)*\s*fun\s+([A-Za-z][A-Za-z0-9_]*)", text
            )
        )
    )


def check(root):
    root = Path(root)
    contract = contract_methods(read(root, NATIVE_TS))
    swift = swift_selectors(read(root, SWIFT))
    objc = objc_selectors(read(root, OBJC))
    kotlin = kotlin_methods(read(root, KOTLIN))

    problems = []

    for name in contract:
        if name in EVENT_EMITTER_PAIR:
            # Required on Android, and must NOT be redeclared on iOS.
            if name not in kotlin:
                problems.append(f"{name}: declared in the contract but missing from the Android module")
            if name in swift:
                problems.append(
                    f"{name}: declared in ios/HopMesh.swift, but it is inherited from RCTEventEmitter "
                    f"and redeclaring it overrides the base class"
                )
            continue
        if name not in swift:
            problems.append(f"{name}: in the contract, missing from ios/HopMesh.swift")
        if name not in objc:
            problems.append(f"{name}: in the contract, missing from ios/HopMesh.m (invisible to JS)")
        if name not in kotlin:
            problems.append(f"{name}: in the contract, missing from the Android module")

    # Drift the other way: a platform method nobody declared is dead weight at best, and at worst a
    # surface the contract does not describe.
    for name in sorted(swift):
        if name not in contract:
            problems.append(f"{name}: implemented in ios/HopMesh.swift but absent from the contract")
    for name in sorted(objc):
        if name not in contract:
            problems.append(f"{name}: declared in ios/HopMesh.m but absent from the contract")
    for name in kotlin:
        if name not in contract:
            problems.append(f"{name}: implemented in the Android module but absent from the contract")

    # Selector equality. Both sides can exist and still disagree, which compiles and then throws
    # "unrecognized selector" the first time JS calls it.
    for name in sorted(set(swift) & set(objc)):
        if swift[name] != objc[name]:
            problems.append(
                f"{name}: selector mismatch, ios/HopMesh.swift declares @objc({swift[name]}) "
                f"but ios/HopMesh.m declares {objc[name]}"
            )

    if problems:
        raise BridgeLockstepError("\n  - " + "\n  - ".join(problems))

    bridged = [n for n in contract if n not in EVENT_EMITTER_PAIR]
    print(
        f"rn bridge lockstep OK: {len(bridged)} bridged methods agree across the contract, "
        f"Swift, ObjC and Kotlin, selectors included"
    )


if __name__ == "__main__":
    import sys

    # An explicit root lets the self-test point the guard at a sandbox holding a deliberately broken
    # copy of the bridge. Without it the guard could only ever be run against the real tree, and a
    # guard you cannot aim at a known-bad input is a guard you cannot prove.
    default_root = Path(__file__).resolve().parent.parent
    try:
        check(Path(sys.argv[1]) if len(sys.argv) > 1 else default_root)
    except (BridgeLockstepError, OSError) as error:
        raise SystemExit(f"::error::rn bridge lockstep failed: {error}") from error
