#!/usr/bin/env python3
"""generate-abi-manifest.py (ABI-009): Generate the canonical machine-readable
ABI manifest from sdk/hop.h, capturing function names, return types, parameter
counts, parameter types with widths/signedness/pointer-ness, callback typedefs,
and enums. Supports --check mode to fail when committed manifest drifts.
"""
import json
import os
import re
import sys


def parse_type(t_str: str) -> dict:
    t_str = " ".join(t_str.split()).strip()
    is_ptr = "*" in t_str
    is_const = "const" in t_str
    signed = None
    width = None
    if is_ptr:
        width = 64
        signed = False
    elif "bool" in t_str:
        width = 8
        signed = False
    elif "uint8_t" in t_str:
        width = 8
        signed = False
    elif "uint16_t" in t_str:
        width = 16
        signed = False
    elif "uint32_t" in t_str:
        width = 32
        signed = False
    elif "uint64_t" in t_str:
        width = 64
        signed = False
    elif "int8_t" in t_str:
        width = 8
        signed = True
    elif "int16_t" in t_str:
        width = 16
        signed = True
    elif "int32_t" in t_str:
        width = 32
        signed = True
    elif "int64_t" in t_str:
        width = 64
        signed = True
    elif "uintptr_t" in t_str or "size_t" in t_str:
        width = 64
        signed = False
    elif "intptr_t" in t_str:
        width = 64
        signed = True
    elif "char" in t_str:
        width = 8
        signed = True
    elif "Hop" in t_str or "enum" in t_str:
        width = 32
        signed = False
    elif t_str == "void":
        width = 0
        signed = False

    return {
        "raw": t_str,
        "is_pointer": is_ptr,
        "is_const": is_const,
        "width_bits": width,
        "signed": signed,
    }


def parse_header(header_path: str) -> dict:
    with open(header_path, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. ABI version
    abi_ver_m = re.search(r"#define\s+HOP_ABI_VERSION\s+([0-9]+)", content)
    abi_ver = int(abi_ver_m.group(1)) if abi_ver_m else None

    # 2. Enums
    enums = {}
    enum_re = re.compile(
        r"typedef\s+enum\s+([A-Za-z0-9_]+)\s*\{([^}]+)\}\s*([A-Za-z0-9_]+);",
        re.S,
    )
    for m in enum_re.finditer(content):
        enum_name = m.group(1)
        body = m.group(2)
        variants = {}
        for line in body.splitlines():
            line = re.sub(r"//.*", "", line).strip()
            if not line:
                continue
            var_m = re.match(r"([A-Za-z0-9_]+)\s*=\s*([0-9]+)", line)
            if var_m:
                variants[var_m.group(1)] = int(var_m.group(2))
        enums[enum_name] = variants

    # 3. Functions
    m = re.search(r'extern "C" \{(.*?)\}\s*// extern "C"', content, re.S)
    extern_block = m.group(1) if m else content

    cleaned_lines = []
    for line in extern_block.splitlines():
        cleaned = re.sub(r"//.*", "", line)
        cleaned_lines.append(cleaned)
    cleaned_extern = "\n".join(cleaned_lines)

    fn_re = re.compile(r"([a-zA-Z0-9_* ]+?)\b(hop_[a-z0-9_]+)\s*\((.*?)\);", re.S)
    functions = {}
    callbacks = {}

    for m in fn_re.finditer(cleaned_extern):
        ret_str = m.group(1).strip()
        fn_name = m.group(2).strip()
        params_str = m.group(3).strip()

        ret_info = parse_type(ret_str)

        params = []
        if params_str != "void" and params_str != "":
            raw_params = []
            depth = 0
            current = []
            for char in params_str:
                if char == "(":
                    depth += 1
                    current.append(char)
                elif char == ")":
                    depth -= 1
                    current.append(char)
                elif char == "," and depth == 0:
                    raw_params.append("".join(current).strip())
                    current = []
                else:
                    current.append(char)
            if current:
                raw_params.append("".join(current).strip())

            for p in raw_params:
                p_clean = " ".join(p.split())
                cb_m = re.match(
                    r"([a-zA-Z0-9_* ]+?)\s*\(\s*\*\s*([a-zA-Z0-9_]+)\s*\)\s*\((.*?)\)",
                    p_clean,
                )
                if cb_m:
                    cb_ret = cb_m.group(1).strip()
                    cb_name = cb_m.group(2).strip()
                    cb_args = cb_m.group(3).strip()
                    cb_key = f"{fn_name}_{cb_name}"
                    callbacks[cb_key] = {
                        "return_type": cb_ret,
                        "arguments": cb_args,
                    }
                    params.append({
                        "name": cb_name,
                        "raw": p_clean,
                        "is_callback": True,
                        "is_pointer": True,
                        "is_const": False,
                        "width_bits": 64,
                        "signed": False,
                        "callback_id": cb_key,
                    })
                else:
                    parts = p_clean.split()
                    if parts[-1].startswith("*"):
                        p_name = parts[-1].lstrip("*")
                        p_type = " ".join(parts[:-1]) + " *"
                    elif len(parts) > 1 and not parts[-1].endswith("*"):
                        p_name = parts[-1]
                        p_type = " ".join(parts[:-1])
                    else:
                        p_name = ""
                        p_type = p_clean
                    p_info = parse_type(p_type)
                    p_info["name"] = p_name
                    p_info["is_callback"] = False
                    params.append(p_info)

        functions[fn_name] = {
            "name": fn_name,
            "return_type": ret_info,
            "parameter_count": len(params),
            "parameters": params,
        }

    return {
        "version": abi_ver,
        "source": "sdk/hop.h",
        "enums": enums,
        "callbacks": callbacks,
        "functions": functions,
    }


def check_manifest(header_path: str, manifest_path: str) -> list[str]:
    """Compare generated manifest from header_path against existing manifest_path."""
    if not os.path.exists(manifest_path):
        return [f"manifest file does not exist: {manifest_path}"]

    if not os.path.exists(header_path):
        return [f"header file does not exist: {header_path}"]

    generated = parse_header(header_path)
    with open(manifest_path, "r", encoding="utf-8") as f:
        try:
            committed = json.load(f)
        except Exception as e:
            return [f"failed to parse manifest JSON {manifest_path}: {e}"]

    errors = []
    # 1. Version check
    if generated.get("version") != committed.get("version"):
        errors.append(
            f"ABI version mismatch: header has {generated.get('version')}, manifest has {committed.get('version')}"
        )

    # 2. Enum check
    gen_enums = generated.get("enums", {})
    com_enums = committed.get("enums", {})
    if gen_enums != com_enums:
        for e_name, e_vars in gen_enums.items():
            if e_name not in com_enums:
                errors.append(f"enum {e_name} present in header but missing in manifest")
            elif e_vars != com_enums[e_name]:
                errors.append(f"enum {e_name} variants mismatch between header and manifest")
        for e_name in com_enums:
            if e_name not in gen_enums:
                errors.append(f"enum {e_name} present in manifest but missing in header")

    # 3. Callback check
    gen_cbs = generated.get("callbacks", {})
    com_cbs = committed.get("callbacks", {})
    if gen_cbs != com_cbs:
        for cb_name, cb_info in gen_cbs.items():
            if cb_name not in com_cbs:
                errors.append(f"callback {cb_name} present in header but missing in manifest")
            elif cb_info != com_cbs[cb_name]:
                errors.append(f"callback {cb_name} signature mismatch between header and manifest")
        for cb_name in com_cbs:
            if cb_name not in gen_cbs:
                errors.append(f"callback {cb_name} present in manifest but missing in header")

    # 4. Function check
    gen_funcs = generated.get("functions", {})
    com_funcs = committed.get("functions", {})
    for fn_name, gen_fn in gen_funcs.items():
        if fn_name not in com_funcs:
            errors.append(f"function {fn_name} present in header but missing in manifest")
            continue
        com_fn = com_funcs[fn_name]
        # Check return type
        if gen_fn.get("return_type") != com_fn.get("return_type"):
            errors.append(
                f"function {fn_name} return type mismatch: header has {gen_fn.get('return_type')}, manifest has {com_fn.get('return_type')}"
            )
        # Check parameter count
        if gen_fn.get("parameter_count") != com_fn.get("parameter_count"):
            errors.append(
                f"function {fn_name} parameter count mismatch: header has {gen_fn.get('parameter_count')}, manifest has {com_fn.get('parameter_count')}"
            )
        else:
            # Check parameters
            for idx, (p_gen, p_com) in enumerate(zip(gen_fn.get("parameters", []), com_fn.get("parameters", []))):
                if p_gen != p_com:
                    errors.append(
                        f"function {fn_name} param #{idx+1} mismatch: header has {p_gen.get('raw')}, manifest has {p_com.get('raw')}"
                    )
    for fn_name in com_funcs:
        if fn_name not in gen_funcs:
            errors.append(f"function {fn_name} present in manifest but missing in header")

    return errors

def run_self_test() -> int:
    """Self-test for generate-abi-manifest.py (ABI-016)."""
    t_uintptr = parse_type("uintptr_t")
    t_intptr = parse_type("intptr_t")
    t_size = parse_type("size_t")
    assert t_uintptr["signed"] is False, f"uintptr_t signed must be False, got {t_uintptr['signed']}"
    assert t_uintptr["width_bits"] == 64, f"uintptr_t width must be 64, got {t_uintptr['width_bits']}"
    assert t_intptr["signed"] is True, f"intptr_t signed must be True, got {t_intptr['signed']}"
    assert t_intptr["width_bits"] == 64, f"intptr_t width must be 64, got {t_intptr['width_bits']}"
    assert t_size["signed"] is False, f"size_t signed must be False, got {t_size['signed']}"
    assert t_size["width_bits"] == 64, f"size_t width must be 64, got {t_size['width_bits']}"
    print("generate-abi-manifest self-test: OK (uintptr_t signed:false, intptr_t signed:true)")
    return 0


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    header_path = os.path.join(root, "sdk", "hop.h")
    out_path = os.path.join(root, "tools", "codegen", "abi-manifest.json")
    check_mode = False

    if "--self-test" in sys.argv or "--test" in sys.argv:
        sys.exit(run_self_test())

    args = []
    for arg in sys.argv[1:]:
        if arg == "--check":
            check_mode = True
        else:
            args.append(arg)
    if len(args) > 0:
        header_path = args[0]
    if len(args) > 1:
        out_path = args[1]

    if check_mode:
        errors = check_manifest(header_path, out_path)
        if errors:
            print(f"::error:: ABI manifest drift between {header_path} and {out_path}:", file=sys.stderr)
            for err in errors:
                print(f"  - {err}", file=sys.stderr)
            sys.exit(1)
        print(f"OK: ABI manifest {out_path} is in sync with {header_path}")
        sys.exit(0)

    manifest = parse_header(header_path)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(
        f"Wrote canonical ABI manifest to {out_path} ({len(manifest['functions'])} functions, {len(manifest['enums'])} enums, {len(manifest['callbacks'])} callbacks)"
    )


if __name__ == "__main__":
    main()
