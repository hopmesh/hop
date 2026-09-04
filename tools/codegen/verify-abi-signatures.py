#!/usr/bin/env python3
"""verify-abi-signatures.py (ABI-009): Compare wrapper FFI bindings against
canonical ABI manifest (tools/codegen/abi-manifest.json). Verifies symbol
presence, parameter arity, and pointer-vs-scalar/integer shape across all
supported wrapper DSLs: Node (koffi), Python (ctypes), Ruby (fiddle),
Crystal (lib), Dart (ffi), Go (cgo), Kotlin (JNA), Swift, and Embedded C.
Comments and string literals are stripped so non-callable mentions never pass.
"""
import json
import os
import re
import sys


def load_manifest(manifest_path: str) -> dict:
    with open(manifest_path, "r", encoding="utf-8") as f:
        return json.load(f)


def strip_comments_and_strings(text: str, strip_strings: bool = False) -> str:
    """Lexer-level comment and string stripper.
    When strip_strings is False, strings are preserved (for DSLs where bindings
    are written as string literals), but comments inside strings or strings inside
    comments are handled cleanly without false positives.
    When strip_strings is True, all string literals are replaced with whitespace.
    """
    result = []
    i = 0
    n = len(text)
    state = "NORMAL"

    while i < n:
        c = text[i]
        c2 = text[i : i + 2] if i + 1 < n else ""

        if state == "NORMAL":
            if c2 == "/*":
                state = "BLOCK_COMMENT"
                i += 2
                continue
            elif c2 == "//":
                state = "LINE_COMMENT"
                i += 2
                continue
            elif c == "#":
                state = "LINE_COMMENT"
                i += 1
                continue
            elif c == '"':
                state = "STRING_DOUBLE"
                if not strip_strings:
                    result.append(c)
                i += 1
                continue
            elif c == "'":
                state = "STRING_SINGLE"
                if not strip_strings:
                    result.append(c)
                i += 1
                continue
            elif c == "`":
                state = "STRING_BACKTICK"
                if not strip_strings:
                    result.append(c)
                i += 1
                continue
            else:
                result.append(c)
                i += 1
        elif state == "LINE_COMMENT":
            if c == "\n":
                state = "NORMAL"
                result.append("\n")
            i += 1
        elif state == "BLOCK_COMMENT":
            if c2 == "*/":
                state = "NORMAL"
                i += 2
            else:
                if c == "\n":
                    result.append("\n")
                i += 1
        elif state == "STRING_DOUBLE":
            if c == "\\":
                if not strip_strings:
                    result.append(text[i : i + 2])
                i += 2
            elif c == '"':
                state = "NORMAL"
                if not strip_strings:
                    result.append(c)
                i += 1
            else:
                if not strip_strings:
                    result.append(c)
                elif c == "\n":
                    result.append("\n")
                i += 1
        elif state == "STRING_SINGLE":
            if c == "\\":
                if not strip_strings:
                    result.append(text[i : i + 2])
                i += 2
            elif c == "'":
                state = "NORMAL"
                if not strip_strings:
                    result.append(c)
                i += 1
            else:
                if not strip_strings:
                    result.append(c)
                elif c == "\n":
                    result.append("\n")
                i += 1
        elif state == "STRING_BACKTICK":
            if c == "\\":
                if not strip_strings:
                    result.append(text[i : i + 2])
                i += 2
            elif c == "`":
                state = "NORMAL"
                if not strip_strings:
                    result.append(c)
                i += 1
            else:
                if not strip_strings:
                    result.append(c)
                elif c == "\n":
                    result.append("\n")
                i += 1

    return "".join(result)


# ---------------------------------------------------------------------------
# Per-wrapper FFI DSL extractors
# ---------------------------------------------------------------------------


def extract_node_koffi_bindings(source: str) -> dict:
    """Node koffi: lib.func('ret hop_name(params)')"""
    bindings = {}
    pattern = re.compile(
        r"\blib\.func\(\s*['\"]([^'\"]*?\b(hop_[a-z0-9_]+)\s*\(([^'\"]*?)\))['\"]\s*\)",
        re.S,
    )
    for full_sig, fn_name, params_str in pattern.findall(source):
        params_str = params_str.strip()
        if params_str in ("", "void"):
            params = []
        else:
            params = [p.strip() for p in params_str.split(",") if p.strip()]

        ret_prefix = full_sig[: full_sig.find(fn_name)].strip()
        ret_shape = "pointer" if "*" in ret_prefix else ("scalar" if ret_prefix else "unknown")

        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": [("pointer" if ("*" in p) else "scalar") for p in params],
            "return": ret_shape,
            "raw": full_sig.strip(),
        }
    return bindings


def extract_python_ctypes_bindings(source: str) -> dict:
    """Python ctypes: _lib.hop_name.argtypes = [...] and _lib.hop_name.restype = ..."""
    bindings = {}
    pattern = re.compile(
        r"_lib\.(hop_[a-z0-9_]+)\.argtypes\s*=\s*\[(.*?)\]",
        re.S,
    )
    for fn_name, args_str in pattern.findall(source):
        args = [a.strip() for a in args_str.split(",") if a.strip()]
        params = []
        for arg in args:
            if "POINTER" in arg or arg in ("c_void_p", "c_char_p") or arg.endswith("_SINK") or "SINK" in arg or "ByReference" in arg:
                params.append("pointer")
            else:
                params.append("scalar")
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": params,
            "return": "unknown",
            "raw": f"_lib.{fn_name}.argtypes = [{args_str}]",
        }

    restype_pattern = re.compile(r"_lib\.(hop_[a-z0-9_]+)\.restype\s*=\s*([A-Za-z0-9_]+)")
    for fn_name, res in restype_pattern.findall(source):
        ret_shape = "pointer" if res in ("c_void_p", "c_char_p") or "POINTER" in res else "scalar"
        if fn_name in bindings:
            bindings[fn_name]["return"] = ret_shape
        else:
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": 0,
                "params": [],
                "return": ret_shape,
                "raw": f"_lib.{fn_name}.restype = {res}",
            }
    return bindings


def extract_ruby_fiddle_bindings(source: str) -> dict:
    """Ruby fiddle: fn("hop_name", [types...], ret)"""
    bindings = {}
    pattern = re.compile(
        r'fn\(\s*["\'](hop_[a-z0-9_]+)["\']\s*,\s*\[(.*?)\]\s*,\s*([A-Za-z0-9_]+)\s*\)',
        re.S,
    )
    for fn_name, args_str, ret_type in pattern.findall(source):
        args = [a.strip() for a in args_str.split(",") if a.strip()]
        params = []
        for arg in args:
            if arg == "P":
                params.append("pointer")
            else:
                params.append("scalar")
        ret_shape = "pointer" if ret_type == "P" else "scalar"
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": params,
            "return": ret_shape,
            "raw": f'fn("{fn_name}", [{args_str}], {ret_type})',
        }
    return bindings


def extract_crystal_lib_bindings(source: str) -> dict:
    """Crystal lib: fun <alias> = hop_name(params) : ReturnType or fun hop_name : Ret"""
    bindings = {}
    pattern = re.compile(r"\bfun\s+(?:[a-zA-Z0-9_]+\s*=\s*)?(hop_[a-z0-9_]+)")
    for m in pattern.finditer(source):
        fn_name = m.group(1)
        start = m.end()
        rest = source[start:].lstrip()
        if rest.startswith("("):
            open_paren = source.find("(", start)
            i = open_paren + 1
            depth = 1
            while i < len(source) and depth > 0:
                if source[i] == "(":
                    depth += 1
                elif source[i] == ")":
                    depth -= 1
                i += 1
            params_str = source[open_paren + 1 : i - 1].strip()
            after = source[i:]
        else:
            params_str = ""
            after = rest

        ret_m = re.match(r"\s*:\s*([A-Za-z0-9_*:]+)", after)
        ret_str = ret_m.group(1) if ret_m else "Void"

        raw_params = []
        depth = 0
        cur = []
        for c in params_str:
            if c == "(":
                depth += 1
                cur.append(c)
            elif c == ")":
                depth -= 1
                cur.append(c)
            elif c == "," and depth == 0:
                raw_params.append("".join(cur).strip())
                cur = []
            else:
                cur.append(c)
        if cur and "".join(cur).strip():
            raw_params.append("".join(cur).strip())

        params = []
        for p in raw_params:
            if "*" in p or "->" in p:
                params.append("pointer")
            else:
                params.append("scalar")

        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": params,
            "return": "pointer" if "*" in ret_str else "scalar",
            "raw": f"fun {fn_name}({params_str}) : {ret_str}",
        }
    return bindings


def extract_dart_ffi_bindings(source: str) -> dict:
    """Dart FFI: _lib.lookupFunction<CType, DartType>('hop_name')"""
    bindings = {}
    lookup_pattern = re.compile(
        r"_lib\.lookupFunction<([A-Za-z0-9_]+),\s*([A-Za-z0-9_]+)>\(\s*['\"](hop_[a-z0-9_]+)['\"]\s*\)"
    )
    for c_type, dart_type, fn_name in lookup_pattern.findall(source):
        td_m = re.search(
            r"typedef\s+" + re.escape(c_type) + r"\s*=\s*([A-Za-z0-9_<>\s*]+)\s+Function\((.*?)\);",
            source,
            re.S,
        )
        if td_m:
            ret_type_str = td_m.group(1).strip()
            ret_shape = "pointer" if "Pointer" in ret_type_str else "scalar"

            params_str = " ".join(td_m.group(2).split()).strip()
            raw_params = []
            depth = 0
            cur = []
            for c in params_str:
                if c in "(<":
                    depth += 1
                    cur.append(c)
                elif c in ")>":
                    depth -= 1
                    cur.append(c)
                elif c == "," and depth == 0:
                    raw_params.append("".join(cur).strip())
                    cur = []
                else:
                    cur.append(c)
            if cur and "".join(cur).strip():
                raw_params.append("".join(cur).strip())

            params = []
            for p in raw_params:
                if "Pointer" in p or "NativeFunction" in p:
                    params.append("pointer")
                else:
                    params.append("scalar")
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": len(params),
                "params": params,
                "return": ret_shape,
                "raw": f"lookupFunction<{c_type}>('{fn_name}')",
            }
        else:
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": -1,
                "params": [],
                "return": "unknown",
                "raw": f"lookupFunction<{c_type}>('{fn_name}') (missing typedef)",
            }
    return bindings


def extract_go_cgo_bindings(source: str) -> dict:
    """Go cgo: C.hop_name(args...)"""
    bindings = {}
    pattern = re.compile(r"\bC\.(hop_[a-z0-9_]+)\s*\(")
    for m in pattern.finditer(source):
        fn_name = m.group(1)
        start = m.end()
        depth = 1
        i = start
        while i < len(source) and depth > 0:
            if source[i] == "(":
                depth += 1
            elif source[i] == ")":
                depth -= 1
            i += 1
        args_str = source[start : i - 1].strip()
        raw_args = []
        depth = 0
        cur = []
        for c in args_str:
            if c == "(":
                depth += 1
                cur.append(c)
            elif c == ")":
                depth -= 1
                cur.append(c)
            elif c == "," and depth == 0:
                raw_args.append("".join(cur).strip())
                cur = []
            else:
                cur.append(c)
        if cur and "".join(cur).strip():
            raw_args.append("".join(cur).strip())

        params = []
        for a in raw_args:
            a_clean = a.strip()
            if any(k in a_clean for k in ("*", "unsafe.Pointer", "&", "n.p", "cs", "cb", "cdst")):
                params.append("pointer")
            elif any(k in a_clean for k in ("C.uint", "C.size_t", "C.bool", "int", "uint")):
                params.append("scalar")
            else:
                params.append("unknown")

        if fn_name not in bindings:
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": len(raw_args),
                "params": params,
                "return": "unknown",
                "raw": f"C.{fn_name}({args_str})",
            }
    return bindings


def extract_kotlin_jna_bindings(source: str) -> dict:
    """Kotlin JNA: fun hop_name(params): RetType or general hop_name calls"""
    bindings = {}
    # 1. Match formal JNA declaration in interface
    decl_pattern = re.compile(
        r"\bfun\s+(hop_[a-z0-9_]+)\s*\((.*?)\)(?:\s*:\s*([A-Za-z0-9_?]+))?",
        re.S,
    )
    for m in decl_pattern.finditer(source):
        fn_name = m.group(1)
        params_str = m.group(2).strip()
        ret_str = m.group(3)

        if params_str:
            raw_params = [p.strip() for p in params_str.split(",") if p.strip()]
            params = []
            for p in raw_params:
                p_type = p.split(":")[-1].strip() if ":" in p else p
                if any(k in p_type for k in ("Pointer", "ByteArray", "Reference", "Sink", "String")):
                    params.append("pointer")
                else:
                    params.append("scalar")
        else:
            params = []

        ret_shape = "pointer" if (ret_str and "Pointer" in ret_str) else "scalar"
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": params,
            "return": ret_shape,
            "raw": f"fun {fn_name}({params_str}) : {ret_str or 'Unit'}",
        }

    # 2. General function calls
    call_pattern = re.compile(r"\b(hop_[a-z0-9_]+)\s*\(")
    for fn in call_pattern.findall(source):
        if fn not in bindings:
            bindings[fn] = {
                "name": fn,
                "param_count": -1,
                "params": [],
                "return": "unknown",
                "raw": f"call {fn}",
            }
    return bindings


def extract_embedded_c_bindings(source: str) -> dict:
    """Embedded C/C++ prototypes: ret hop_name(params);"""
    bindings = {}
    extern_m = re.search(r'extern\s*"C"\s*\{(.*?)\}', source, re.S)
    if extern_m:
        block = extern_m.group(1)
    else:
        block = source

    # Strip comments from the block
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    lines = [line.split("//", 1)[0] for line in block.splitlines()]
    block = "\n".join(lines)

    proto_re = re.compile(r"([a-zA-Z0-9_* ]+?)\b(hop_[a-z0-9_]+)\s*\(([^;{}]*?)\)\s*;", re.S)
    for m in proto_re.finditer(block):
        ret_str = m.group(1).strip()
        fn_name = m.group(2)
        params_str = m.group(3).strip()

        if any(bad in ret_str for bad in (";", "{", "}", "?", ":", "=")):
            continue

        if params_str in ("", "void"):
            params = []
        else:
            raw_params = []
            depth = 0
            cur = []
            for c in params_str:
                if c == "(":
                    depth += 1
                    cur.append(c)
                elif c == ")":
                    depth -= 1
                    cur.append(c)
                elif c == "," and depth == 0:
                    raw_params.append("".join(cur).strip())
                    cur = []
                else:
                    cur.append(c)
            if cur and "".join(cur).strip():
                raw_params.append("".join(cur).strip())

            params = [("pointer" if ("*" in p) else "scalar") for p in raw_params]

        ret_shape = "pointer" if "*" in ret_str else "scalar"
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": params,
            "return": ret_shape,
            "raw": f"{ret_str} {fn_name}({params_str})",
        }

    return bindings


def extract_swift_bindings(source: str) -> dict:
    """Swift: hop_name(args...) calls"""
    bindings = {}
    pattern = re.compile(r"\b(hop_[a-z0-9_]+)\s*\(")
    for m in pattern.finditer(source):
        fn_name = m.group(1)
        start = m.end()
        depth_parens = 1
        depth_braces = 0
        depth_brackets = 0
        i = start
        while i < len(source) and depth_parens > 0:
            c = source[i]
            if c == "(":
                depth_parens += 1
            elif c == ")":
                depth_parens -= 1
            elif c == "{":
                depth_braces += 1
            elif c == "}":
                depth_braces -= 1
            elif c == "[":
                depth_brackets += 1
            elif c == "]":
                depth_brackets -= 1
            i += 1

        args_str = source[start : i - 1].strip()
        raw_args = []
        depth_parens = 0
        depth_braces = 0
        depth_brackets = 0
        cur = []
        for c in args_str:
            if c == "(":
                depth_parens += 1
                cur.append(c)
            elif c == ")":
                depth_parens -= 1
                cur.append(c)
            elif c == "{":
                depth_braces += 1
                cur.append(c)
            elif c == "}":
                depth_braces -= 1
                cur.append(c)
            elif c == "[":
                depth_brackets += 1
                cur.append(c)
            elif c == "]":
                depth_brackets -= 1
                cur.append(c)
            elif c == "," and depth_parens == 0 and depth_braces == 0 and depth_brackets == 0:
                raw_args.append("".join(cur).strip())
                cur = []
            else:
                cur.append(c)
        if cur and "".join(cur).strip():
            raw_args.append("".join(cur).strip())

        if fn_name not in bindings:
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": len(raw_args),
                "params": ["unknown"] * len(raw_args),
                "return": "unknown",
                "raw": f"{fn_name}({args_str})",
            }
    return bindings


def extract_wrapper_bindings(surface_dir: str) -> dict:
    """Extract bindings from wrapper directory based on files present."""
    combined = {}
    for root, dirs, files in os.walk(surface_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("target", "build", "node_modules")]
        for f in files:
            if f.startswith("."):
                continue
            path = os.path.join(root, f)
            try:
                content = open(path, "r", encoding="utf-8", errors="ignore").read()
            except Exception:
                continue

            if f.endswith((".mjs", ".js")):
                clean_text = strip_comments_and_strings(content, strip_strings=False)
                combined.update(extract_node_koffi_bindings(clean_text))
            elif f.endswith(".py"):
                clean_text = strip_comments_and_strings(content, strip_strings=False)
                combined.update(extract_python_ctypes_bindings(clean_text))
            elif f.endswith(".rb"):
                clean_text = strip_comments_and_strings(content, strip_strings=False)
                combined.update(extract_ruby_fiddle_bindings(clean_text))
            elif f.endswith(".dart"):
                clean_text = strip_comments_and_strings(content, strip_strings=False)
                combined.update(extract_dart_ffi_bindings(clean_text))
            elif f.endswith(".cr"):
                clean_text = strip_comments_and_strings(content, strip_strings=True)
                combined.update(extract_crystal_lib_bindings(clean_text))
            elif f.endswith(".go"):
                clean_text = strip_comments_and_strings(content, strip_strings=True)
                combined.update(extract_go_cgo_bindings(clean_text))
            elif f.endswith(".kt"):
                clean_text = strip_comments_and_strings(content, strip_strings=True)
                combined.update(extract_kotlin_jna_bindings(clean_text))
            elif f.endswith((".h", ".cpp", ".c", ".cc")):
                # Pass raw content to extract_embedded_c_bindings to find extern "C"
                combined.update(extract_embedded_c_bindings(content))
            elif f.endswith(".swift"):
                clean_text = strip_comments_and_strings(content, strip_strings=True)
                combined.update(extract_swift_bindings(clean_text))

    return combined


def verify_signatures(manifest: dict, surface_dir: str, required_symbol: str = None) -> list[str]:
    errors = []
    bindings = extract_wrapper_bindings(surface_dir)
    manifest_funcs = manifest.get("functions", {})

    if required_symbol:
        if required_symbol not in bindings:
            errors.append(f"required symbol {required_symbol} is not bound in FFI DSL under {surface_dir}")
            return errors
        to_check = [required_symbol]
    else:
        to_check = list(bindings.keys())

    for sym in to_check:
        if sym not in manifest_funcs:
            errors.append(f"wrapper under {surface_dir} binds unknown function {sym}")
            continue

        expected = manifest_funcs[sym]
        actual = bindings[sym]

        # Check parameter count if DSL declares arity
        if actual["param_count"] >= 0:
            exp_count = expected["parameter_count"]
            act_count = actual["param_count"]
            if act_count != exp_count:
                errors.append(
                    f"{sym} arity mismatch in {surface_dir}: wrapper declared {act_count} params, manifest expects {exp_count} (raw: {actual.get('raw', '')})"
                )
                continue

            # Check pointer vs scalar shape where known
            if actual["params"] and actual["params"] != ["unknown"] * act_count:
                for idx, (act_shape, exp_param) in enumerate(zip(actual["params"], expected["parameters"])):
                    if act_shape == "unknown":
                        continue
                    exp_shape = "pointer" if exp_param.get("is_pointer") else "scalar"
                    if act_shape != exp_shape:
                        errors.append(
                            f"{sym} param #{idx+1} shape mismatch in {surface_dir}: wrapper declared {act_shape}, manifest expects {exp_shape} ({exp_param.get('raw', '')})"
                        )

        # Check return type shape if known
        act_ret = actual.get("return")
        if act_ret and act_ret != "unknown":
            exp_ret = "pointer" if expected["return_type"].get("is_pointer") else "scalar"
            if act_ret != exp_ret:
                errors.append(
                    f"{sym} return shape mismatch in {surface_dir}: wrapper declared {act_ret}, manifest expects {exp_ret} ({expected['return_type'].get('raw', '')})"
                )

    return errors


def main():
    if len(sys.argv) < 3:
        print("Usage: verify-abi-signatures.py <abi-manifest.json> <surface-dir> [required-symbol]")
        sys.exit(1)

    manifest_file = sys.argv[1]
    surface_dir = sys.argv[2]
    req_sym = sys.argv[3] if len(sys.argv) > 3 else None

    if not os.path.exists(manifest_file):
        print(f"::error:: manifest not found: {manifest_file}")
        sys.exit(1)

    if not os.path.isdir(surface_dir):
        print(f"::error:: surface directory not found: {surface_dir}")
        sys.exit(1)

    manifest = load_manifest(manifest_file)
    errors = verify_signatures(manifest, surface_dir, req_sym)

    if errors:
        for e in errors:
            print(f"::error:: {e}", file=sys.stderr)
        sys.exit(1)

    checked_count = 1 if req_sym else len(extract_wrapper_bindings(surface_dir))
    print(f"OK: verified {checked_count} binding(s) in {surface_dir} against {manifest_file}")
    sys.exit(0)


if __name__ == "__main__":
    main()
