#!/usr/bin/env python3
# Generate Odin flat bindings for Box3D from its C headers via libclang.
#
# Emits, mirroring vendor:box2d, one .odin file per source header:
#   types.h -> types.odin, collision.h -> collision.odin,
#   math_functions.h -> math_functions.odin, id.h -> id.odin,
#   base.h + box3d.h -> box3d.odin, constants.h -> constants.odin
#
# The raw C API is bound flat (link_prefix="b3"); the hand-written method
# sugar lives in a separate, non-generated file (box3d_methods.odin).
#
#   usage: python3 generate.py <box3d_include_dir> <out_dir>

import sys, os, clang.cindex as cx

INCLUDE_DIR, OUT_DIR = sys.argv[1], sys.argv[2]
ROOT = os.path.join(INCLUDE_DIR, "box3d")

# Route decls to output files by the header they come from.
HEADER_TO_FILE = {
    "types.h": "types.odin",
    "collision.h": "collision.odin",
    "math_functions.h": "math_functions.odin",
    "id.h": "id.odin",
    "constants.h": "constants.odin",
    "base.h": "box3d.odin",
    "box3d.h": "box3d.odin",
}

# --- C type name -> Odin type, for named builtins/typedefs we want to preserve.
SCALAR = {
    "float": "f32", "double": "f64", "bool": "bool", "_Bool": "bool",
    "int8_t": "i8", "int16_t": "i16", "int32_t": "i32", "int64_t": "i64",
    "uint8_t": "u8", "uint16_t": "u16", "uint32_t": "u32", "uint64_t": "u64",
    "int": "c.int", "unsigned int": "c.uint", "unsigned": "c.uint",
    "short": "c.short", "unsigned short": "c.ushort",
    "long": "c.long", "unsigned long": "c.ulong",
    "long long": "c.longlong", "unsigned long long": "c.ulonglong",
    "char": "c.char", "signed char": "i8", "unsigned char": "u8",
    "size_t": "c.size_t", "uintptr_t": "uintptr", "intptr_t": "int",
    "void": "void",
}

ODIN_KEYWORDS = {
    "context", "in", "map", "matrix", "proc", "struct", "union", "enum", "using",
    "when", "where", "if", "else", "for", "switch", "case", "do", "return", "defer",
    "cast", "transmute", "distinct", "dynamic", "bit_set", "bit_field", "typeid",
    "foreign", "import", "package", "or_else", "or_return", "not_in", "auto_cast",
}
def safe(name: str) -> str:
    return name + "_" if name in ODIN_KEYWORDS else name

def strip_b3(name: str) -> str:
    return name[2:] if name.startswith("b3") or name.startswith("B3") else name

def enum_const(name: str) -> str:
    # b3_staticBody -> staticBody ; b3_shapeType -> shapeType
    if name.startswith("b3_"): return name[3:]
    if name.startswith("b3"):  return name[2:].lstrip("_")
    return name

def odin_ident(name: str) -> str:
    n = (name.replace("const ", "").replace("volatile ", "")
             .replace("struct ", "").replace("enum ", "").strip())
    return strip_b3(n)

def map_type(t: cx.Type) -> str:
    t = t.get_canonical() if t.kind == cx.TypeKind.TYPEDEF else t
    # Named typedef we recognize (int32_t, b3Vec3, ...) — use spelling before canonicalizing away.
    spell = t.spelling.replace("const ", "").replace("volatile ", "").strip()
    if spell in SCALAR:
        return SCALAR[spell]
    if spell.startswith("b3") and t.kind in (cx.TypeKind.TYPEDEF, cx.TypeKind.ELABORATED, cx.TypeKind.RECORD, cx.TypeKind.ENUM):
        return odin_ident(spell)

    k = t.kind
    if k == cx.TypeKind.POINTER:
        pointee = t.get_pointee()
        pspell = pointee.spelling.replace("const ", "").strip()
        if pointee.kind in (cx.TypeKind.CHAR_S, cx.TypeKind.CHAR_U) or pspell == "char":
            return "cstring"
        if pointee.kind == cx.TypeKind.VOID:
            return "rawptr"
        # function pointer: raw proto, or a named callback typedef (b3FrictionCallback*).
        # In Odin a `proc "c"` type is already a pointer, so no extra ^.
        if pointee.get_canonical().kind == cx.TypeKind.FUNCTIONPROTO:
            if pspell.startswith("b3"):
                return odin_ident(pspell)
            return map_proc(pointee.get_canonical())
        return "^" + map_type(pointee)
    if k == cx.TypeKind.CONSTANTARRAY:
        return f"[{t.element_count}]{map_type(t.element_type)}"
    if k == cx.TypeKind.INCOMPLETEARRAY:
        return f"[^]{map_type(t.element_type)}"
    if k == cx.TypeKind.ELABORATED:
        return map_type(t.get_named_type())
    if k in (cx.TypeKind.RECORD, cx.TypeKind.ENUM):
        return odin_ident(t.spelling.replace("struct ", "").replace("enum ", "").strip())
    # fall back to canonical scalar kinds
    canon = {
        cx.TypeKind.VOID: "void", cx.TypeKind.BOOL: "bool",
        cx.TypeKind.FLOAT: "f32", cx.TypeKind.DOUBLE: "f64",
        cx.TypeKind.INT: "c.int", cx.TypeKind.UINT: "c.uint",
        cx.TypeKind.SHORT: "c.short", cx.TypeKind.USHORT: "c.ushort",
        cx.TypeKind.LONG: "c.long", cx.TypeKind.ULONG: "c.ulong",
        cx.TypeKind.LONGLONG: "c.longlong", cx.TypeKind.ULONGLONG: "c.ulonglong",
        cx.TypeKind.SCHAR: "i8", cx.TypeKind.UCHAR: "u8",
        cx.TypeKind.CHAR_S: "c.char", cx.TypeKind.CHAR_U: "c.char",
    }
    return canon.get(k, "rawptr  /* ? %s */" % t.spelling)

def map_proc(fp: cx.Type) -> str:
    args = [map_type(a) for a in fp.argument_types()]
    ret = fp.get_result()
    sig = "proc \"c\" (" + ", ".join(args) + ")"
    if ret.kind != cx.TypeKind.VOID:
        sig += " -> " + map_type(ret)
    return sig

def doc(cur) -> str:
    c = cur.raw_comment
    if not c:
        return ""
    lines = []
    for ln in c.splitlines():
        ln = ln.strip().lstrip("/*").lstrip("*").rstrip("*/").strip()
        if ln:
            lines.append("// " + ln)
    return "\n".join(lines) + ("\n" if lines else "")

# --- collectors, keyed by output file
buckets = {f: [] for f in set(HEADER_TO_FILE.values())}
seen = set()

def bucket_for(cur):
    f = cur.location.file
    if not f:
        return None
    base = os.path.basename(f.name)
    return HEADER_TO_FILE.get(base)

def emit_enum(cur, out):
    name = odin_ident(cur.spelling or cur.type.spelling)
    if not name or name in seen: return
    seen.add(name)
    s = doc(cur) + f"{name} :: enum c.int {{\n"
    for e in cur.get_children():
        if e.kind == cx.CursorKind.ENUM_CONSTANT_DECL:
            s += f"\t{enum_const(e.spelling)} = {e.enum_value},\n"
    s += "}\n"
    out.append(s)

def struct_is_hairy(cur) -> bool:
    # bitfields / anonymous nested unions have no clean Odin field form; bind opaque.
    for ch in cur.get_children():
        if ch.kind == cx.CursorKind.FIELD_DECL and ch.is_bitfield():
            return True
        if ch.kind in (cx.CursorKind.STRUCT_DECL, cx.CursorKind.UNION_DECL) and ch.is_anonymous():
            return True
        if ch.kind == cx.CursorKind.FIELD_DECL and "unnamed at" in ch.type.spelling:
            return True
    return False

def emit_struct(cur, out):
    name = odin_ident(cur.spelling or cur.type.spelling)
    if not name or name in seen: return
    seen.add(name)
    if name in TYPE_SKIP: return
    size, align = cur.type.get_size(), cur.type.get_align()
    if struct_is_hairy(cur) and size > 0:
        # opaque blob: exact ABI size/align preserved; internal type, passed by pointer
        out.append(doc(cur) + f"{name} :: struct #align({align}) {{ _: [{size}]u8 }} // opaque (bitfields/anon union)\n")
        return
    kw = "struct #raw_union" if cur.kind == cx.CursorKind.UNION_DECL else "struct"
    s = doc(cur) + f"{name} :: {kw} {{\n"
    for fld in cur.get_children():
        if fld.kind == cx.CursorKind.FIELD_DECL:
            s += f"\t{safe(fld.spelling)}: {map_type(fld.type)},\n"
    s += "}\n"
    out.append(s)

def emit_typedef(cur, out):
    name = odin_ident(cur.spelling)
    if not name or name in seen or name in TYPE_SKIP: return
    under = cur.underlying_typedef_type
    # function-pointer callback typedef
    if under.kind == cx.TypeKind.POINTER and under.get_pointee().kind == cx.TypeKind.FUNCTIONPROTO:
        seen.add(name)
        out.append(doc(cur) + f"{name} :: #type {map_proc(under.get_pointee())}\n")
        return
    # typedef to a record with the same name (typedef struct X {} X) — struct already emitted
    canon = under.get_canonical()
    if canon.kind == cx.TypeKind.RECORD:
        return
    # plain scalar/pointer alias
    if under.spelling.replace("b3","") == name:
        return
    seen.add(name)
    out.append(f"{name} :: {map_type(under)}\n")

# Math primitives are hand-written as Odin array/matrix types (math_types.odin) so
# they get native arithmetic — mirrors vendor:box2d's Vec2 :: [2]f32. Skip generating them.
TYPE_SKIP = {"Vec3", "Vec2", "Quat", "Matrix3", "Transform", "Plane", "Pos"}

emitted_funcs = set()
def emit_func(cur, out):
    # skip B3_INLINE helpers defined in headers — they aren't exported by the lib
    if cur.is_definition():
        return
    name = odin_ident(cur.spelling)
    if name in emitted_funcs:
        return
    emitted_funcs.add(name)
    params = []
    for i, p in enumerate(cur.get_arguments()):
        pname = safe(p.spelling) if p.spelling else f"_arg{i}"
        params.append(f"{pname}: {map_type(p.type)}")
    ret = cur.result_type
    sig = f"\t{name} :: proc(" + ", ".join(params) + ")"
    if ret.kind != cx.TypeKind.VOID:
        sig += " -> " + map_type(ret)
    sig += " ---"
    out.append((doc(cur), sig))

def main():
    index = cx.Index.create()
    import subprocess
    res = subprocess.run(["clang", "-print-resource-dir"], capture_output=True, text=True)
    clang_inc = os.path.join(res.stdout.strip(), "include")
    args = ["-x", "c", f"-I{INCLUDE_DIR}", f"-isystem{clang_inc}", "-DBOX3D_EXPORT="]
    tu = index.parse(os.path.join(ROOT, "box3d.h"), args=args,
                     options=cx.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD)
    errs = [d for d in tu.diagnostics if d.severity >= cx.Diagnostic.Error]
    for d in errs[:10]:
        print("  parse:", d.spelling, file=sys.stderr)

    funcs = {f: [] for f in buckets}
    for cur in tu.cursor.get_children():
        b = bucket_for(cur)
        if b is None:
            continue
        out = buckets[b]
        k = cur.kind
        if k == cx.CursorKind.ENUM_DECL and cur.spelling:
            emit_enum(cur, out)
        elif k in (cx.CursorKind.STRUCT_DECL, cx.CursorKind.UNION_DECL) and cur.spelling:
            emit_struct(cur, out)
        elif k == cx.CursorKind.TYPEDEF_DECL:
            emit_typedef(cur, out)
        elif k == cx.CursorKind.FUNCTION_DECL:
            emit_func(cur, funcs[b])

    os.makedirs(OUT_DIR, exist_ok=True)
    counts = {}
    for fname, decls in buckets.items():
        fns = funcs[fname]
        body = ""
        for d in decls:
            body += d + "\n"
        if fns:
            body += 'foreign import lib { LIB_PATH }\n\n'
            body += '@(link_prefix="b3", default_calling_convention="c")\n'
            body += "foreign lib {\n"
            for docstr, sig in fns:
                if docstr:
                    body += "".join("\t"+l+"\n" for l in docstr.splitlines())
                body += sig + "\n"
            body += "}\n"
        head = "package vendor_box3d\n\n"
        if "c." in body:
            head += 'import "core:c"\n\n'
        with open(os.path.join(OUT_DIR, fname), "w") as fh:
            fh.write(head + body)
        counts[fname] = (len(decls), len(fns))
    for f, (d, n) in sorted(counts.items()):
        print(f"  {f}: {d} types, {n} funcs")

if __name__ == "__main__":
    main()
