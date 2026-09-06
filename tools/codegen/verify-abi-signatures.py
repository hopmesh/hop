#!/usr/bin/env python3
"""verify-abi-signatures.py (ABI-009, ABI-016): Compare wrapper FFI bindings
against canonical ABI manifest (tools/codegen/abi-manifest.json). Verifies
symbol presence, parameter arity, integer signedness (intptr_t vs uintptr_t/size_t),
bit widths, and callback trampoline types (return values, arity, and pointer-ness)
across all supported wrapper DSLs: Node (koffi), Python (ctypes), Ruby (fiddle),
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


def parse_type_descriptor(raw: str) -> dict:
    """Parse a language-specific type annotation into canonical shape, width, and signedness."""
    raw = raw.strip()
    is_ptr = False
    width = None
    signed = None
    is_cb = False
    cb_ret = None
    cb_name = None
    cb_params = None

    # Check for Crystal inline callback: (types... -> RetType) or (types... ->)
    if "->" in raw and "(" in raw:
        is_ptr = True
        is_cb = True
        width = 64
        signed = False
        parts = raw.split("->")
        ret_part = parts[1].strip().rstrip(")")
        cb_ret = "bool" if "Bool" in ret_part else "void"
        p_part = parts[0].strip().lstrip("(").rstrip(",").strip()
        cb_raw_params = [p.strip() for p in p_part.split(",") if p.strip()]
        cb_params = [parse_type_descriptor(p) for p in cb_raw_params]
        return {
            "shape": "pointer",
            "is_pointer": True,
            "width": 64,
            "signed": False,
            "is_callback": True,
            "callback_name": None,
            "callback_return": cb_ret,
            "callback_params": cb_params,
            "raw": raw,
        }

    # Check for Embedded C inline function pointer: ret (*name)(args)
    cb_c_m = re.search(r"\b(void|bool)\s*\(\s*\*\s*([a-zA-Z0-9_]+)\s*\)\s*\((.*?)\)", raw)
    if cb_c_m:
        cb_ret = cb_c_m.group(1)
        args_str = cb_c_m.group(3).strip()
        cb_raw_params = [p.strip() for p in args_str.split(",") if p.strip() and p.strip() != "void"]
        cb_params = [parse_type_descriptor(p) for p in cb_raw_params]
        return {
            "shape": "pointer",
            "is_pointer": True,
            "width": 64,
            "signed": False,
            "is_callback": True,
            "callback_name": cb_c_m.group(2),
            "callback_return": cb_ret,
            "callback_params": cb_params,
            "raw": raw,
        }

    # Ruby Fiddle single-letter constants
    if raw == "P":
        return {"shape": "pointer", "is_pointer": True, "width": 64, "signed": False, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "V":
        return {"shape": "scalar", "is_pointer": False, "width": 0, "signed": False, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "SZ":
        return {"shape": "scalar", "is_pointer": False, "width": 64, "signed": False, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "SSZ":
        return {"shape": "scalar", "is_pointer": False, "width": 64, "signed": True, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "I":
        return {"shape": "scalar", "is_pointer": False, "width": None, "signed": None, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "LL":
        return {"shape": "scalar", "is_pointer": False, "width": 64, "signed": None, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}
    elif raw == "CH":
        return {"shape": "scalar", "is_pointer": False, "width": 8, "signed": None, "is_callback": False, "callback_name": None, "callback_return": None, "callback_params": None, "raw": raw}

    # Explicit pointer types
    if "*" in raw:
        is_ptr = True
        width = 64
        signed = False
        for s in ("DrainSink", "InboxSink", "SvcReqSink", "SvcRespSink", "ReachSignSink", "ReachVerifySink", "HpsMsgSink", "HpsInviteSink", "HpsAddrSink", "HpsIdSink", "HpsTopicSink", "HpsBrowseSink"):
            if s in raw:
                is_cb = True
                cb_name = s
                break
    elif any(raw.startswith(p) for p in ("Pointer", "POINTER(", "c_void_p", "c_char_p", "ByteArray", "String")) or "Reference" in raw:
        is_ptr = True
        width = 64
        signed = False
        if "NativeFunction<" in raw:
            is_cb = True
            m = re.search(r"NativeFunction<\s*([A-Za-z0-9_]+)\s*>", raw)
            if m:
                cb_name = m.group(1)
        elif "Sink" in raw:
            is_cb = True
            m = re.search(r"([A-Za-z0-9_]+Sink[A-Za-z0-9_]*)", raw)
            if m:
                cb_name = m.group(1)

    # Sink / Callback references by name
    cb_match = re.search(r"\b([A-Za-z0-9_]+(?:Sink|SINK|Callback)[A-Za-z0-9_]*)\b", raw)
    if cb_match:
        is_ptr = True
        is_cb = True
        width = 64
        signed = False
        cb_name = cb_match.group(1)

    if not is_ptr:
        tokens = re.findall(r"[A-Za-z0-9_:]+", raw)
        t_lowers = [t.lower() for t in tokens]

        # Kotlin JNA types: JVM primitives have no unsigned representation, so signedness is None
        if "NativeLong" in tokens or any(t == "nativelong" for t in t_lowers):
            width = 64
            signed = None
        elif raw.rstrip("?") == "Long":
            width = 64
            signed = None
        elif raw.rstrip("?") == "Int":
            width = 32
            signed = None
        elif raw.rstrip("?") == "Short":
            width = 16
            signed = None
        elif raw.rstrip("?") == "Byte":
            width = 8
            signed = None
        # 64-bit unsigned (must be checked before 64-bit signed because size_t / uintptr)
        elif any(t in ("uint64", "uint64_t", "c_uint64", "c_ulonglong", "size_t", "c_size_t", "size", "uintptr_t", "uintptr", "sz") for t in t_lowers) or "LibC::SizeT" in raw or "UInt64" in tokens:
            width = 64
            signed = False
        # 64-bit signed
        elif any(t in ("int64", "int64_t", "c_int64", "c_longlong", "intptr", "intptr_t", "ssize_t", "c_ssize_t", "ssz", "long") for t in t_lowers) or "LibC::SSizeT" in raw or "LibC::IntPtrT" in raw or "Int64" in tokens or "IntPtr" in tokens or raw == "LL":
            width = 64
            signed = True
        # 32-bit unsigned
        elif any(t in ("uint32", "uint32_t", "c_uint32", "c_uint", "u32") for t in t_lowers) or "UInt32" in tokens:
            width = 32
            signed = False
        # 32-bit signed
        elif any(t in ("int32", "int32_t", "c_int32", "c_int", "i32", "int") for t in t_lowers) or "Int32" in tokens:
            width = 32
            signed = True
        # 16-bit unsigned
        elif any(t in ("uint16", "uint16_t", "c_uint16", "c_ushort", "u16") for t in t_lowers) or "UInt16" in tokens:
            width = 16
            signed = False
        # 16-bit signed
        elif any(t in ("int16", "int16_t", "c_int16", "c_short", "i16", "short") for t in t_lowers) or "Int16" in tokens:
            width = 16
            signed = True
        # 8-bit unsigned
        elif any(t in ("uint8", "uint8_t", "c_uint8", "c_ubyte", "u8") for t in t_lowers) or "UInt8" in tokens:
            width = 8
            signed = False
        # 8-bit signed
        elif any(t in ("int8", "int8_t", "c_int8", "c_byte", "i8") for t in t_lowers) or "Int8" in tokens:
            width = 8
            signed = True
        # Bool / Byte
        elif any(t in ("bool", "c_bool", "boolean") for t in t_lowers) or raw == "CH" or raw == "Byte" or "Bool" in tokens:
            width = 8
            signed = False
        # Void
        elif any(t in ("void", "unit", "none") for t in t_lowers) or raw == "V":
            width = 0
            signed = False

    return {
        "shape": "pointer" if is_ptr else "scalar",
        "is_pointer": is_ptr,
        "width": width,
        "signed": signed,
        "is_callback": is_cb,
        "callback_name": cb_name,
        "callback_return": cb_ret,
        "callback_params": cb_params,
        "raw": raw,
    }


# ---------------------------------------------------------------------------
# Per-wrapper FFI DSL extractors
# ---------------------------------------------------------------------------


def extract_node_koffi_bindings(source: str) -> dict:
    """Node koffi: lib.func('ret hop_name(params)') or multi-line declarations."""
    bindings = {}
    pattern = re.compile(r"\blib\.func\s*\(")
    for m in pattern.finditer(source):
        start = m.end()
        depth = 1
        i = start
        in_quote = None
        escape = False
        while i < len(source) and depth > 0:
            c = source[i]
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif in_quote:
                if c == in_quote:
                    in_quote = None
            elif c in ("'", '"', "`"):
                in_quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        inner = source[start : i - 1]

        str_pattern = re.compile(r"(['\"`])((?:\\.|(?!\1).)*?)\1", re.S)
        all_strs = [s for _, s in str_pattern.findall(inner)]
        if not any("hop_" in s for s in all_strs):
            continue

        full_sig = " ".join(" ".join(all_strs).split())
        fn_m = re.search(r"\b(hop_[a-z0-9_]+)\s*\((.*?)\)", full_sig, re.S)
        if not fn_m:
            continue

        fn_name = fn_m.group(1)
        params_str = fn_m.group(2).strip()

        if params_str in ("", "void"):
            params = []
        else:
            params = [p.strip() for p in params_str.split(",") if p.strip()]

        ret_prefix = full_sig[: full_sig.find(fn_name)].strip()
        param_types = [parse_type_descriptor(p) for p in params]
        ret_type = parse_type_descriptor(ret_prefix)

        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(params),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": ret_type["shape"],
            "return_type": ret_type,
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
        param_types = [parse_type_descriptor(a) for a in args]
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(args),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": "unknown",
            "return_type": parse_type_descriptor(""),
            "raw": f"_lib.{fn_name}.argtypes = [{args_str}]",
        }

    restype_pattern = re.compile(r"_lib\.(hop_[a-z0-9_]+)\.restype\s*=\s*([A-Za-z0-9_]+)")
    for fn_name, res in restype_pattern.findall(source):
        ret_type = parse_type_descriptor(res)
        if fn_name in bindings:
            bindings[fn_name]["return"] = ret_type["shape"]
            bindings[fn_name]["return_type"] = ret_type
        else:
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": 0,
                "params": [],
                "param_types": [],
                "return": ret_type["shape"],
                "return_type": ret_type,
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
        param_types = [parse_type_descriptor(a) for a in args]
        ret_desc = parse_type_descriptor(ret_type)
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(args),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": ret_desc["shape"],
            "return_type": ret_desc,
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

        param_types = [parse_type_descriptor(p) for p in raw_params]
        ret_type = parse_type_descriptor(ret_str)
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(param_types),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": ret_type["shape"],
            "return_type": ret_type,
            "raw": f"fun {fn_name}({params_str}) : {ret_str}",
        }
    return bindings


def extract_dart_ffi_bindings(source: str) -> dict:
    """Dart FFI: _lib.lookupFunction<CType, DartType>('hop_name')"""
    bindings = {}
    lookup_pattern = re.compile(
        r"_lib\s*\.\s*lookupFunction\s*<\s*([A-Za-z0-9_]+)\s*,\s*([A-Za-z0-9_]+)\s*>\s*\(\s*['\"](hop_[a-z0-9_]+)['\"]\s*,?\s*\)",
        re.S,
    )
    for c_type, dart_type, fn_name in lookup_pattern.findall(source):
        td_m = re.search(
            r"typedef\s+" + re.escape(c_type) + r"\s*=\s*([A-Za-z0-9_<>\s*]+)\s+Function\((.*?)\);",
            source,
            re.S,
        )
        if td_m:
            ret_type_str = td_m.group(1).strip()
            ret_type = parse_type_descriptor(ret_type_str)
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

            param_types = [parse_type_descriptor(p) for p in raw_params]
            bindings[fn_name] = {
                "name": fn_name,
                "param_count": len(param_types),
                "params": [pt["shape"] for pt in param_types],
                "param_types": param_types,
                "return": ret_type["shape"],
                "return_type": ret_type,
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
            param_types = [parse_type_descriptor(p.split(":")[-1].strip() if ":" in p else p) for p in raw_params]
        else:
            raw_params = []
            param_types = []

        ret_type = parse_type_descriptor(ret_str or "Unit")
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(param_types),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": ret_type["shape"],
            "return_type": ret_type,
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
            raw_params = []
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

        param_types = [parse_type_descriptor(p) for p in raw_params]
        ret_type = parse_type_descriptor(ret_str)
        bindings[fn_name] = {
            "name": fn_name,
            "param_count": len(param_types),
            "params": [pt["shape"] for pt in param_types],
            "param_types": param_types,
            "return": ret_type["shape"],
            "return_type": ret_type,
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


def extract_wrapper_callbacks(surface_dir: str) -> dict:
    """Extract callback definitions and trampolines from wrapper directory."""
    cbs = {}
    for root, dirs, files in os.walk(surface_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("target", "build", "node_modules")]
        for f in files:
            p = os.path.join(root, f)
            try:
                content = open(p, "r", encoding="utf-8", errors="ignore").read()
            except Exception:
                continue

            if f.endswith((".mjs", ".js")):
                node_cb_pattern = re.compile(
                    r"export\s+const\s+([A-Za-z0-9_]+)\s*=\s*koffi\.proto\(\s*[\x27\x22](void|bool)\s+([A-Za-z0-9_]+)\s*\((.*?)\)[\x27\x22]\s*,?\s*\)",
                    re.S,
                )
                for var_name, ret, fn_name, params_str in node_cb_pattern.findall(content):
                    raw_params = [param.strip() for param in params_str.split(",") if param.strip()]
                    cbs[var_name] = {
                        "return_type": ret,
                        "parameter_count": len(raw_params),
                        "parameters": [parse_type_descriptor(param) for param in raw_params],
                    }
                    cbs[fn_name] = cbs[var_name]
            elif f.endswith(".py"):
                for m in re.finditer(r"\b([A-Za-z0-9_]+)\s*=\s*CFUNCTYPE\(", content):
                    cb_name = m.group(1)
                    start = m.end()
                    depth = 1
                    i = start
                    while i < len(content) and depth > 0:
                        if content[i] == "(":
                            depth += 1
                        elif content[i] == ")":
                            depth -= 1
                        i += 1
                    args_str = content[start : i - 1].strip()

                    raw_params = []
                    p_depth = 0
                    cur = []
                    for c in args_str:
                        if c == "(":
                            p_depth += 1
                            cur.append(c)
                        elif c == ")":
                            p_depth -= 1
                            cur.append(c)
                        elif c == "," and p_depth == 0:
                            raw_params.append("".join(cur).strip())
                            cur = []
                        else:
                            cur.append(c)
                    if cur and "".join(cur).strip():
                        raw_params.append("".join(cur).strip())

                    if raw_params:
                        ret = "void" if raw_params[0] == "None" else "bool"
                        cb_params = raw_params[1:]
                        cbs[cb_name] = {
                            "return_type": ret,
                            "parameter_count": len(cb_params),
                            "parameters": [parse_type_descriptor(param) for param in cb_params],
                        }
            elif f.endswith(".dart"):
                dart_cb_pattern = re.compile(r"typedef\s+([A-Za-z0-9_]+)\s*=\s*(Void|Bool)\s+Function\s*\((.*?)\)\s*;", re.S)
                for name, ret, params_str in dart_cb_pattern.findall(content):
                    raw_params = [param.strip() for param in params_str.split(",") if param.strip()]
                    cbs[name] = {
                        "return_type": "void" if ret == "Void" else "bool",
                        "parameter_count": len(raw_params),
                        "parameters": [parse_type_descriptor(param) for param in raw_params],
                    }
            elif f.endswith(".kt"):
                kt_cb_pattern = re.compile(
                    r"internal\s+fun\s+interface\s+([A-Za-z0-9_]+)\s*:\s*Callback\s*\{\s*fun\s+invoke\s*\((.*?)\)(?:\s*:\s*([A-Za-z0-9_?]+))?",
                    re.S,
                )
                for name, params_str, ret_str in kt_cb_pattern.findall(content):
                    raw_params = [param.strip() for param in params_str.split(",") if param.strip()]
                    ret = "bool" if ret_str in ("Byte", "Boolean") else "void"
                    cbs[name] = {
                        "return_type": ret,
                        "parameter_count": len(raw_params),
                        "parameters": [parse_type_descriptor(param.split(":")[-1].strip()) for param in raw_params],
                    }
    return cbs


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
                combined.update(extract_embedded_c_bindings(content))
            elif f.endswith(".swift"):
                clean_text = strip_comments_and_strings(content, strip_strings=True)
                combined.update(extract_swift_bindings(clean_text))

    return combined


# ---------------------------------------------------------------------------
# Documented per-wrapper exclusions
# ---------------------------------------------------------------------------
# Functions exported in the canonical C ABI (sdk/hop.h) that are intentionally
# not bound in specific wrapper targets, grouped by architectural capability:
#
# 1. Server clustering (hop_cluster_*): only bound by server-side endpoints
#    (Node, Python, Ruby, Crystal, Go). Mobile (Apple, Android, Flutter) and
#    microcontroller (Embedded) SDKs do not host cluster nodes.
# 2. Reachability records (hop_sign_reach_record, hop_verify_reach_record): public
#    HTTPS endpoint discovery documents. Client SDKs do not sign reach records.
# 3. Wire bundle validation (hop_validate_wire_bundle): relay/router diagnostics.
# 4. Multi-hop status and routing (hop_send_to, hop_message_status, hop_is_secured):
#    specialized routing/inspection APIs not bound in server endpoint wrappers or
#    simplistic wrappers.
# 5. Persistent database handles (hop_node_open, hop_node_open_keyed, etc.):
#    microcontroller (Embedded) uses in-memory state only.
# 6. Go Cgo sink trampolines: cgo cannot pass Go funcs directly to C function
#    pointers without C trampolines in the cgo preamble; direct C.hop_* calls in Go
#    cover the remaining non-sink functions.
WRAPPER_EXCLUSIONS = {
    "apple": {
        "hop_cluster_join",
        "hop_cluster_join_passphrase",
        "hop_cluster_mark_done",
        "hop_cluster_members",
        "hop_cluster_set_quorum",
        "hop_cluster_would_drop",
        "hop_sign_reach_record",
        "hop_validate_wire_bundle",
        "hop_verify_reach_record",
    },
    "android": {
        "hop_cluster_join",
        "hop_cluster_join_passphrase",
        "hop_cluster_mark_done",
        "hop_cluster_members",
        "hop_cluster_set_quorum",
        "hop_cluster_would_drop",
        "hop_sign_reach_record",
        "hop_validate_wire_bundle",
        "hop_verify_reach_record",
    },
    "embedded": {
        "hop_accept_inbox",
        "hop_cluster_join",
        "hop_cluster_join_passphrase",
        "hop_cluster_mark_done",
        "hop_cluster_members",
        "hop_cluster_set_quorum",
        "hop_cluster_would_drop",
        "hop_message_status",
        "hop_node_is_persistent",
        "hop_node_open",
        "hop_node_open_keyed",
        "hop_node_rehydrate_dropped",
        "hop_send_to",
        "hop_sign_reach_record",
        "hop_validate_wire_bundle",
        "hop_verify_reach_record",
    },
    "go": {
        "hop_drain_outgoing",
        "hop_hps_browse",
        "hop_hps_members",
        "hop_hps_my_topics",
        "hop_hps_pending",
        "hop_hps_rekey",
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_node_secret",
        "hop_node_set_name",
        "hop_poll_hps_invites",
        "hop_poll_hps_messages",
        "hop_poll_inbox",
        "hop_poll_service_requests",
        "hop_poll_service_responses",
        "hop_send_message",
        "hop_send_to",
        "hop_sign_reach_record",
        "hop_validate_wire_bundle",
        "hop_verify_reach_record",
    },
    "node": {
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_send_to",
        "hop_validate_wire_bundle",
    },
    "python": {
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_node_secret",
        "hop_node_set_name",
        "hop_poll_inbox",
        "hop_send_message",
        "hop_send_to",
        "hop_validate_wire_bundle",
    },
    "ruby": {
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_node_secret",
        "hop_node_set_name",
        "hop_poll_inbox",
        "hop_send_message",
        "hop_send_to",
        "hop_validate_wire_bundle",
    },
    "crystal": {
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_node_secret",
        "hop_node_set_name",
        "hop_poll_inbox",
        "hop_send_message",
        "hop_send_to",
        "hop_validate_wire_bundle",
    },
    "flutter": {
        "hop_is_secured",
        "hop_message_status",
        "hop_node_rehydrate_dropped",
        "hop_node_secret",
        "hop_node_set_name",
        "hop_poll_inbox",
        "hop_relay_add",
        "hop_relay_next",
        "hop_relay_pool_size",
        "hop_relay_report",
        "hop_send_message",
        "hop_send_to",
        "hop_validate_wire_bundle",
    },
}


def get_wrapper_exclusions(surface_dir: str) -> set[str]:
    """Return documented exclusions for a wrapper directory."""
    norm = surface_dir.replace("\\", "/").rstrip("/")
    parts = norm.split("/")
    for key, exclusions in WRAPPER_EXCLUSIONS.items():
        if f"sdk/{key}" in norm or key in parts:
            return exclusions
    return set()


def verify_signatures(manifest: dict, surface_dir: str, required_symbol: str = None) -> list[str]:
    errors = []
    bindings = extract_wrapper_bindings(surface_dir)
    callbacks = extract_wrapper_callbacks(surface_dir) if os.path.isdir(surface_dir) else {}
    manifest_funcs = manifest.get("functions", {})

    if required_symbol:
        if required_symbol not in bindings:
            errors.append(f"required symbol {required_symbol} is not bound in FFI DSL under {surface_dir}")
            return errors
        to_check = [required_symbol]
    else:
        exclusions = get_wrapper_exclusions(surface_dir)
        expected_symbols = set(manifest_funcs.keys()) - exclusions
        bound_symbols = set(bindings.keys())

        missing = expected_symbols - bound_symbols
        if missing:
            for sym in sorted(missing):
                errors.append(f"missing required ABI function {sym} in {surface_dir}")

        unknown = bound_symbols - set(manifest_funcs.keys())
        if unknown:
            for sym in sorted(unknown):
                errors.append(f"wrapper under {surface_dir} binds unknown function {sym}")

        to_check = [s for s in sorted(bound_symbols) if s in manifest_funcs]
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
                raw_act = actual.get("raw", "")
                errors.append(
                    f"{sym} arity mismatch in {surface_dir}: wrapper declared {act_count} params, manifest expects {exp_count} (raw: {raw_act})"
                )
                continue

            # Check parameter types if known
            param_types = actual.get("param_types")
            if param_types and len(param_types) == exp_count:
                for idx, (act_type, exp_param) in enumerate(zip(param_types, expected["parameters"])):
                    act_shape = act_type.get("shape", "unknown")
                    if act_shape == "unknown":
                        continue
                    exp_shape = "pointer" if exp_param.get("is_pointer") else "scalar"
                    if act_shape != exp_shape:
                        raw_exp = exp_param.get("raw", "")
                        errors.append(
                            f"{sym} param #{idx+1} shape mismatch in {surface_dir}: wrapper declared {act_shape}, manifest expects {exp_shape} ({raw_exp})"
                        )

                    # Check width for non-pointers
                    if not act_type.get("is_pointer") and not exp_param.get("is_pointer"):
                        act_w = act_type.get("width")
                        exp_w = exp_param.get("width_bits")
                        if act_w is not None and exp_w is not None and act_w > 0 and exp_w > 0 and act_w != exp_w:
                            raw_a = act_type.get("raw", "")
                            raw_e = exp_param.get("raw", "")
                            errors.append(
                                f"{sym} param #{idx+1} width mismatch in {surface_dir}: wrapper declared {act_w}-bit ({raw_a}), manifest expects {exp_w}-bit ({raw_e})"
                            )

                        # Check signedness (ABI-016)
                        act_s = act_type.get("signed")
                        exp_s = exp_param.get("signed")
                        if act_s is not None and exp_s is not None and exp_w is not None and exp_w > 8:
                            if act_s != exp_s:
                                exp_sign = "signed" if exp_s else "unsigned"
                                act_sign = "signed" if act_s else "unsigned"
                                raw_a = act_type.get("raw", "")
                                raw_e = exp_param.get("raw", "")
                                errors.append(
                                    f"{sym} param #{idx+1} signedness mismatch in {surface_dir}: wrapper declared {act_sign} ({raw_a}), manifest expects {exp_sign} ({raw_e})"
                                )

                    # Check callback trampoline types and return values (ABI-016)
                    if exp_param.get("is_callback"):
                        cb_id = exp_param.get("callback_id")
                        exp_cb = manifest.get("callbacks", {}).get(cb_id, {})
                        exp_cb_ret = exp_cb.get("return_type", "void")
                        exp_cb_raw_args = exp_cb.get("arguments", "")
                        exp_cb_arg_list = [a.strip() for a in exp_cb_raw_args.split(",") if a.strip()] if exp_cb_raw_args and exp_cb_raw_args != "void" else []
                        exp_cb_params = [parse_type_descriptor(a) for a in exp_cb_arg_list]

                        act_cb_ret = act_type.get("callback_return")
                        act_cb_params = act_type.get("callback_params")
                        cb_name = act_type.get("callback_name")
                        if not act_cb_ret and cb_name:
                            cb_info = callbacks.get(cb_name)
                            if not cb_info:
                                for k, v in callbacks.items():
                                    if k.lower().replace("_", "") == cb_name.lower().replace("_", ""):
                                        cb_info = v
                                        break
                            if cb_info:
                                act_cb_ret = cb_info.get("return_type")
                                act_cb_params = cb_info.get("parameters")

                        if act_cb_ret:
                            exp_ret_norm = "bool" if exp_cb_ret == "bool" else "void"
                            act_ret_norm = "bool" if act_cb_ret in ("bool", "c_bool", "Bool", "Byte") else "void"
                            if act_ret_norm != exp_ret_norm:
                                errors.append(
                                    f"{sym} param #{idx+1} callback return mismatch in {surface_dir}: wrapper declared {act_ret_norm}, manifest expects {exp_ret_norm}"
                                )
                        if act_cb_params is not None:
                            if len(act_cb_params) != len(exp_cb_params):
                                errors.append(
                                    f"{sym} param #{idx+1} callback parameter count mismatch in {surface_dir}: wrapper declared {len(act_cb_params)} params, manifest expects {len(exp_cb_params)}"
                                )
                            else:
                                for p_idx, (act_p, exp_p) in enumerate(zip(act_cb_params, exp_cb_params)):
                                    act_ptr = act_p.get("is_pointer") if isinstance(act_p, dict) else (act_p == "pointer")
                                    exp_ptr = exp_p.get("is_pointer")
                                    if act_ptr != exp_ptr:
                                        act_s = "pointer" if act_ptr else "scalar"
                                        exp_s = "pointer" if exp_ptr else "scalar"
                                        errors.append(
                                            f"{sym} param #{idx+1} callback arg #{p_idx+1} shape mismatch in {surface_dir}: wrapper declared {act_s}, manifest expects {exp_s}"
                                        )

            elif actual["params"] and actual["params"] != ["unknown"] * act_count:
                for idx, (act_shape, exp_param) in enumerate(zip(actual["params"], expected["parameters"])):
                    if act_shape == "unknown":
                        continue
                    exp_shape = "pointer" if exp_param.get("is_pointer") else "scalar"
                    if act_shape != exp_shape:
                        raw_exp = exp_param.get("raw", "")
                        errors.append(
                            f"{sym} param #{idx+1} shape mismatch in {surface_dir}: wrapper declared {act_shape}, manifest expects {exp_shape} ({raw_exp})"
                        )

        # Check return type
        act_ret_type = actual.get("return_type")
        if act_ret_type and act_ret_type.get("shape") != "unknown":
            exp_ret = expected["return_type"]
            act_ret_shape = act_ret_type.get("shape", "unknown")
            exp_ret_shape = "pointer" if exp_ret.get("is_pointer") else "scalar"
            if act_ret_shape != exp_ret_shape:
                raw_exp = exp_ret.get("raw", "")
                errors.append(
                    f"{sym} return shape mismatch in {surface_dir}: wrapper declared {act_ret_shape}, manifest expects {exp_ret_shape} ({raw_exp})"
                )

            if not act_ret_type.get("is_pointer") and not exp_ret.get("is_pointer"):
                act_w = act_ret_type.get("width")
                exp_w = exp_ret.get("width_bits")
                if act_w is not None and exp_w is not None and act_w > 0 and exp_w > 0 and act_w != exp_w:
                    raw_a = act_ret_type.get("raw", "")
                    raw_e = exp_ret.get("raw", "")
                    errors.append(
                        f"{sym} return width mismatch in {surface_dir}: wrapper declared {act_w}-bit ({raw_a}), manifest expects {exp_w}-bit ({raw_e})"
                    )

                act_s = act_ret_type.get("signed")
                exp_s = exp_ret.get("signed")
                if act_s is not None and exp_s is not None and exp_w is not None and exp_w > 8:
                    if act_s != exp_s:
                        exp_sign = "signed" if exp_s else "unsigned"
                        act_sign = "signed" if act_s else "unsigned"
                        raw_a = act_ret_type.get("raw", "")
                        raw_e = exp_ret.get("raw", "")
                        errors.append(
                            f"{sym} return signedness mismatch in {surface_dir}: wrapper declared {act_sign} ({raw_a}), manifest expects {exp_sign} ({raw_e})"
                        )
                elif act_s is False and exp_s is True:
                    # Fail when a signed error-returning C function is bound to an unsigned type (ABI-016)
                    raw_a = act_ret_type.get("raw", "")
                    raw_e = exp_ret.get("raw", "")
                    errors.append(
                        f"{sym} return signedness mismatch in {surface_dir}: wrapper declared unsigned ({raw_a}), manifest expects signed ({raw_e})"
                    )
        else:
            act_ret = actual.get("return")
            if act_ret and act_ret != "unknown":
                exp_ret = "pointer" if expected["return_type"].get("is_pointer") else "scalar"
                if act_ret != exp_ret:
                    raw_exp = expected["return_type"].get("raw", "")
                    errors.append(
                        f"{sym} return shape mismatch in {surface_dir}: wrapper declared {act_ret}, manifest expects {exp_ret} ({raw_exp})"
                    )

    return errors


def run_self_tests(manifest_path: str = None) -> int:
    """Run internal self-tests for ABI-016 contract compliance."""
    if not manifest_path:
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        manifest_path = os.path.join(root, "tools", "codegen", "abi-manifest.json")

    manifest = load_manifest(manifest_path)

    # 1. Reject unsigned binding for hop_hps_rekey
    mock_unsigned_rekey = {
        "hop_hps_rekey": {
            "name": "hop_hps_rekey",
            "param_count": 7,
            "params": ["pointer", "pointer", "pointer", "pointer", "scalar", "pointer", "pointer"],
            "param_types": [
                parse_type_descriptor("void *node"),
                parse_type_descriptor("const char *path"),
                parse_type_descriptor("const char *new_path"),
                parse_type_descriptor("uint8_t *remove"),
                parse_type_descriptor("size_t remove_count"),
                parse_type_descriptor("HpsIdSink *sink"),
                parse_type_descriptor("void *ctx"),
            ],
            "return": "scalar",
            "return_type": parse_type_descriptor("size_t"),  # Unsigned binding for signed error return
            "raw": "size_t hop_hps_rekey(...)",
        }
    }
    orig_extract = globals()["extract_wrapper_bindings"]
    try:
        globals()["extract_wrapper_bindings"] = lambda d: mock_unsigned_rekey
        errs = verify_signatures(manifest, "mock_dir", required_symbol="hop_hps_rekey")
        assert any("signedness mismatch" in e for e in errs), f"Expected signedness mismatch, got: {errs}"

        # 2. Reject void-returning service request sink
        mock_void_sink = {
            "hop_poll_service_requests": {
                "name": "hop_poll_service_requests",
                "param_count": 3,
                "params": ["pointer", "pointer", "pointer"],
                "param_types": [
                    parse_type_descriptor("void *node"),
                    {
                        "shape": "pointer",
                        "is_pointer": True,
                        "width": 64,
                        "signed": False,
                        "is_callback": True,
                        "callback_name": None,
                        "callback_return": "void",  # Void instead of bool!
                        "callback_params": None,
                        "raw": "void (*sink)(void *ctx, ...)",
                    },
                    parse_type_descriptor("void *ctx"),
                ],
                "return": "scalar",
                "return_type": parse_type_descriptor("void"),
                "raw": "void hop_poll_service_requests(...)",
            }
        }
        globals()["extract_wrapper_bindings"] = lambda d: mock_void_sink
        errs = verify_signatures(manifest, "mock_dir", required_symbol="hop_poll_service_requests")
        assert any("callback return mismatch" in e for e in errs), f"Expected callback return mismatch, got: {errs}"

        # 3. Reject wrong-width integer
        mock_wrong_width = {
            "hop_node_tick": {
                "name": "hop_node_tick",
                "param_count": 2,
                "params": ["pointer", "scalar"],
                "param_types": [
                    parse_type_descriptor("void *node"),
                    parse_type_descriptor("uint32_t now_ms"),  # 32-bit instead of 64-bit!
                ],
                "return": "scalar",
                "return_type": parse_type_descriptor("void"),
                "raw": "void hop_node_tick(void *node, uint32_t now_ms)",
            }
        }
        globals()["extract_wrapper_bindings"] = lambda d: mock_wrong_width
        errs = verify_signatures(manifest, "mock_dir", required_symbol="hop_node_tick")
        assert any("width mismatch" in e for e in errs), f"Expected width mismatch, got: {errs}"

        # 4. Reject callback parameter count mismatch
        mock_cb_arity = {
            "hop_poll_service_requests": {
                "name": "hop_poll_service_requests",
                "param_count": 3,
                "params": ["pointer", "pointer", "pointer"],
                "param_types": [
                    parse_type_descriptor("void *node"),
                    {
                        "shape": "pointer",
                        "is_pointer": True,
                        "width": 64,
                        "signed": False,
                        "is_callback": True,
                        "callback_name": None,
                        "callback_return": "bool",
                        "callback_params": [parse_type_descriptor("void *ctx")],  # 1 param instead of 7!
                        "raw": "bool (*sink)(void *ctx)",
                    },
                    parse_type_descriptor("void *ctx"),
                ],
                "return": "scalar",
                "return_type": parse_type_descriptor("void"),
                "raw": "void hop_poll_service_requests(...)",
            }
        }
        globals()["extract_wrapper_bindings"] = lambda d: mock_cb_arity
        errs = verify_signatures(manifest, "mock_dir", required_symbol="hop_poll_service_requests")
        assert any("callback parameter count mismatch" in e for e in errs), f"Expected callback arity mismatch, got: {errs}"

        # 5. Reject callback argument pointer shape mismatch
        mock_cb_shape = {
            "hop_poll_service_requests": {
                "name": "hop_poll_service_requests",
                "param_count": 3,
                "params": ["pointer", "pointer", "pointer"],
                "param_types": [
                    parse_type_descriptor("void *node"),
                    {
                        "shape": "pointer",
                        "is_pointer": True,
                        "width": 64,
                        "signed": False,
                        "is_callback": True,
                        "callback_name": None,
                        "callback_return": "bool",
                        "callback_params": [
                            parse_type_descriptor("uint64_t ctx"),  # scalar instead of pointer!
                            parse_type_descriptor("uint8_t *from"),
                            parse_type_descriptor("uint8_t *request_id"),
                            parse_type_descriptor("const char *service"),
                            parse_type_descriptor("const char *method"),
                            parse_type_descriptor("uint8_t *args"),
                            parse_type_descriptor("size_t args_len"),
                        ],
                        "raw": "bool (*sink)(uint64_t ctx, ...)",
                    },
                    parse_type_descriptor("void *ctx"),
                ],
                "return": "scalar",
                "return_type": parse_type_descriptor("void"),
                "raw": "void hop_poll_service_requests(...)",
            }
        }
        globals()["extract_wrapper_bindings"] = lambda d: mock_cb_shape
        errs = verify_signatures(manifest, "mock_dir", required_symbol="hop_poll_service_requests")
        assert any("callback arg #1 shape mismatch" in e for e in errs), f"Expected callback arg shape mismatch, got: {errs}"

        # Restore original extract function for real file parsing tests
        globals()["extract_wrapper_bindings"] = orig_extract

        # 6. Multi-line declaration parsing and verification
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            multiline_source = """
const raw = {
  abi_version: lib.func('uint32_t hop_abi_version()'),
  node_open: lib.func(
    'void *hop_node_open(\\n' +
    '  const char *db_path, uint8_t *secret, size_t secret_len, uint8_t *app_secret, size_t app_secret_len\\n' +
    ')',
  ),
};
"""
            extracted_node = extract_node_koffi_bindings(multiline_source)
            assert "hop_node_open" in extracted_node, "Expected multi-line hop_node_open to be extracted"
            assert extracted_node["hop_node_open"]["param_count"] == 5

            dart_source = """
typedef _HpsSubscribeC = Bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Pointer<Uint8>);
late final _hpsSubscribe = _lib
    .lookupFunction<
        _HpsSubscribeC,
        _HpsSubscribeDart
    >(
      'hop_hps_subscribe',
    );
"""
            extracted_dart = extract_dart_ffi_bindings(dart_source)
            assert "hop_hps_subscribe" in extracted_dart, "Expected multi-line hop_hps_subscribe to be extracted"
            assert extracted_dart["hop_hps_subscribe"]["param_count"] == 4

            # Verify multi-line wrapper file in temp dir against mock manifest passes
            test_manifest = {
                "functions": {
                    "hop_abi_version": manifest["functions"]["hop_abi_version"],
                    "hop_node_open": manifest["functions"]["hop_node_open"],
                }
            }
            pass_dir = os.path.join(tmpdir, "pass_wrapper")
            os.makedirs(pass_dir)
            with open(os.path.join(pass_dir, "ffi.mjs"), "w") as f:
                f.write(multiline_source)

            errs_pass = verify_signatures(test_manifest, pass_dir)
            assert not errs_pass, f"Expected multi-line wrapper to pass, got: {errs_pass}"

            # 7. Fail closed on deleted declaration
            fail_dir = os.path.join(tmpdir, "fail_wrapper")
            os.makedirs(fail_dir)
            with open(os.path.join(fail_dir, "ffi.mjs"), "w") as f:
                f.write("""
const raw = {
  abi_version: lib.func('uint32_t hop_abi_version()'),
  // hop_node_open is deleted!
};
""")
            errs_fail = verify_signatures(test_manifest, fail_dir)
            assert any("missing required ABI function hop_node_open" in e for e in errs_fail), (
                f"Expected fail-closed missing symbol error, got: {errs_fail}"
            )

    finally:
        globals()["extract_wrapper_bindings"] = orig_extract

    print("verify-abi-signatures self-test: OK (unsigned rekey, void sink, wrong-width int, callback arity, callback shape, multi-line parsing, fail-closed missing declaration)")
    return 0


def main():
    if "--self-test" in sys.argv or "--test" in sys.argv:
        manifest_arg = None
        for a in sys.argv[1:]:
            if not a.startswith("--"):
                manifest_arg = a
                break
        sys.exit(run_self_tests(manifest_arg))

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
