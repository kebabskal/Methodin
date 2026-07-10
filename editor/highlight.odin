// medit — syntax highlighting.
//
// Layer 1 of the plan: fast synchronous lexing into per-line colored spans,
// recomputed whole-buffer whenever the buffer version changes. Odin/Methodin
// files go through core:odin/tokenizer (the compiler's own lexer); JSON and
// shader languages go through a small configurable lexer. LSP semantic
// tokens can later overlay these.
package medit

import "core:path/filepath"
import "core:strings"
import tok "core:odin/tokenizer"

Face :: enum u8 {
	Text,
	Keyword,
	Function,
	Type,
	Number,
	String,
	Comment,
	Operator,
	Constant, // true/false/nil/null
	Directive, // #directives, @attributes, @group(...) in wgsl
	Key, // JSON object keys
}

Span :: struct {
	start, end: int, // byte columns within the line
	face:       Face,
}

Lang :: enum {
	Plain,
	Odin,
	JSON,
	GLSL,
	HLSL,
	WGSL,
	C,
	CPP,
	Python,
	JS,
	TS,
	Rust,
	Go,
	Java,
	CSharp,
	Lua,
	Shell,
	PowerShell,
	Batch,
	YAML,
	TOML,
	INI,
	CSS,
	Markdown,
	HTML,
}

// Shown in the status bar.
LANG_NAMES := [Lang]string{
	.Plain      = "text",
	.Odin       = "methodin",
	.JSON       = "json",
	.GLSL       = "glsl",
	.HLSL       = "hlsl",
	.WGSL       = "wgsl",
	.C          = "c",
	.CPP        = "c++",
	.Python     = "python",
	.JS         = "javascript",
	.TS         = "typescript",
	.Rust       = "rust",
	.Go         = "go",
	.Java       = "java",
	.CSharp     = "c#",
	.Lua        = "lua",
	.Shell      = "shell",
	.PowerShell = "powershell",
	.Batch      = "batch",
	.YAML       = "yaml",
	.TOML       = "toml",
	.INI        = "ini",
	.CSS        = "css",
	.Markdown   = "markdown",
	.HTML       = "html",
}

Highlight :: struct {
	lang:    Lang,
	version: int, // buffer version these spans were computed from
	spans:   [dynamic][dynamic]Span,
}

lang_from_path :: proc(path: string) -> Lang {
	switch strings.to_lower(filepath.base(path), context.temp_allocator) {
	case "makefile", "gnumakefile", "dockerfile", "containerfile":
		return .Shell // close enough: # comments, strings
	}
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".odin":
		return .Odin
	case ".json", ".jsonc":
		return .JSON
	case ".vert", ".frag", ".geom", ".comp", ".tesc", ".tese", ".glsl":
		return .GLSL
	case ".hlsl", ".fx", ".fxh", ".shader":
		return .HLSL
	case ".wgsl":
		return .WGSL
	case ".c", ".h":
		return .C
	case ".cpp", ".cxx", ".cc", ".hpp", ".hxx", ".hh", ".inl":
		return .CPP
	case ".py", ".pyw":
		return .Python
	case ".js", ".mjs", ".cjs", ".jsx":
		return .JS
	case ".ts", ".tsx", ".mts", ".cts":
		return .TS
	case ".rs":
		return .Rust
	case ".go":
		return .Go
	case ".java":
		return .Java
	case ".cs":
		return .CSharp
	case ".lua":
		return .Lua
	case ".sh", ".bash", ".zsh", ".fish":
		return .Shell
	case ".ps1", ".psm1", ".psd1":
		return .PowerShell
	case ".bat", ".cmd":
		return .Batch
	case ".yml", ".yaml":
		return .YAML
	case ".toml":
		return .TOML
	case ".ini", ".cfg", ".conf", ".editorconfig", ".gitignore", ".gitattributes", ".gitmodules", ".properties":
		return .INI
	case ".css", ".scss", ".less":
		return .CSS
	case ".md", ".markdown":
		return .Markdown
	case ".html", ".htm", ".xml", ".xhtml", ".svg", ".vue", ".svelte":
		return .HTML
	}
	return .Plain
}

highlight_destroy :: proc(h: ^Highlight) {
	for &line in h.spans {
		delete(line)
	}
	delete(h.spans)
}

// Splits [start_off, end_off) offsets in the joined buffer text into
// per-line spans. Offsets must be fed in increasing order.
Span_Emitter :: struct {
	h:           ^Highlight,
	line_starts: []int, // offset of each line's first byte
	line:        int,   // current line cursor

	emit :: proc(start_off, end_off: int, face: Face) {
		if end_off <= start_off {
			return
		}
		for line+1 < len(line_starts) && line_starts[line+1] <= start_off {
			line += 1
		}
		off := start_off
		for off < end_off {
			line_start := line_starts[line]
			line_end := line_starts[line+1] - 1 if line+1 < len(line_starts) else max(int)
			seg_end := min(end_off, line_end)
			if seg_end > off {
				append(&h.spans[line], Span{off - line_start, seg_end - line_start, face})
			}
			if end_off > line_end {
				line += 1
				off = line_starts[line]
			} else {
				break
			}
		}
	},
}

@(private)
highlight_reset :: proc(h: ^Highlight, b: ^Buffer) -> (text: string, em: Span_Emitter) {
	for &line in h.spans {
		delete(line)
	}
	clear(&h.spans)
	resize(&h.spans, b.line_count())

	text = b.text(context.temp_allocator)
	line_starts := make([dynamic]int, 0, b.line_count(), context.temp_allocator)
	append(&line_starts, 0)
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			append(&line_starts, i+1)
		}
	}
	em = Span_Emitter{h = h, line_starts = line_starts[:]}
	return
}

highlight_update :: proc(h: ^Highlight, b: ^Buffer) {
	if h.version == b.version && len(h.spans) > 0 {
		return
	}
	h.version = b.version
	#partial switch h.lang {
	case .Odin:
		highlight_odin(h, b)
	case .Markdown:
		highlight_markdown(h, b)
	case .HTML:
		highlight_markup(h, b)
	case .Plain:
		text, em := highlight_reset(h, b)
		_, _ = text, em
	case:
		highlight_generic(h, b)
	}
}

// --- Odin / Methodin ---------------------------------------------------------

@(private = "file")
odin_builtin_consts := []string{"true", "false", "nil", "context"}

@(private)
highlight_odin :: proc(h: ^Highlight, b: ^Buffer) {
	text, em := highlight_reset(h, b)

	t: tok.Tokenizer
	tok.init(&t, text, "", proc(pos: tok.Pos, fmt: string, args: ..any) {})

	tokens := make([dynamic]tok.Token, 0, 1024, context.temp_allocator)
	for {
		token := tok.scan(&t)
		if token.kind == .EOF {
			break
		}
		append(&tokens, token)
	}

	for token, i in tokens {
		start := token.pos.offset
		end := start + len(token.text)
		face := Face.Text

		switch {
		case tok.is_keyword(token.kind):
			face = .Keyword
		case token.kind == .Comment:
			face = .Comment
		case token.kind == .Integer || token.kind == .Float || token.kind == .Imag:
			face = .Number
		case token.kind == .Rune || token.kind == .String:
			face = .String
		case token.kind == .Ident:
			face = odin_ident_face(tokens[:], i)
		case token.kind == .Hash || token.kind == .At:
			// Color the directive sigil and its identifier together.
			face = .Directive
			if i+1 < len(tokens) && tokens[i+1].kind == .Ident && tokens[i+1].pos.offset == end {
				end = tokens[i+1].pos.offset + len(tokens[i+1].text)
			}
		case tok.is_operator(token.kind):
			face = .Operator
		}
		em.emit(start, end, face)
	}
}

@(private = "file")
odin_ident_face :: proc(tokens: []tok.Token, i: int) -> Face {
	text := tokens[i].text
	// Methodin's `impl Type { ... }` blocks: `impl` lexes as an ident in the
	// stock tokenizer, so special-case it here.
	if text == "impl" {
		return .Keyword
	}
	for c in odin_builtin_consts {
		if text == c {
			return .Constant
		}
	}
	// Directive ident right after # / @ is colored by the sigil case.
	if i > 0 {
		prev := tokens[i-1]
		if (prev.kind == .Hash || prev.kind == .At) && prev.pos.offset + len(prev.text) == tokens[i].pos.offset {
			return .Directive
		}
	}
	if i+1 < len(tokens) && tokens[i+1].kind == .Open_Paren {
		return .Function
	}
	// Odin convention: Ada_Case names are types.
	c := text[0]
	if 'A' <= c && c <= 'Z' {
		return .Type
	}
	return .Text
}

// --- Generic lexer (JSON, GLSL, HLSL, WGSL) ----------------------------------

@(private = "file")
Lex_Config :: struct {
	line_comment:  string,
	line_comment2: string, // ini has both ';' and '#'
	block_open:    string,
	block_close:   string,
	keywords:      []string,
	types:         []string,
	consts:        []string,
	directives:    bool, // '#'-prefixed lines (C-family preprocessor)
	at_attributes: bool, // '@ident' (WGSL, CSS at-rules, Java annotations)
	json_keys:     bool, // color "string": as a key
	ident_keys:    bool, // bare word followed by ':' or '=' is a key (yaml/toml/ini/css)
	sq_strings:    bool, // '...' strings
	bt_strings:    bool, // `...` strings, may span lines (Go raw, JS template, shell)
	triple_quotes: bool, // """...""" / '''...''' (Python), may span lines
	sections:      bool, // [section] at line start → directive (ini/toml)
}

@(private = "file")
glsl_keywords := []string{
	"attribute", "break", "buffer", "case", "const", "continue", "default",
	"discard", "do", "else", "flat", "for", "if", "in", "inout", "invariant",
	"layout", "out", "precision", "return", "shared", "smooth", "struct",
	"switch", "uniform", "varying", "while", "highp", "mediump", "lowp",
	"centroid", "noperspective", "patch", "sample", "subroutine", "readonly",
	"writeonly", "coherent", "volatile", "restrict",
}
@(private = "file")
glsl_types := []string{
	"void", "bool", "int", "uint", "float", "double",
	"vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3",
	"uvec4", "bvec2", "bvec3", "bvec4", "dvec2", "dvec3", "dvec4",
	"mat2", "mat3", "mat4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3",
	"mat3x4", "mat4x2", "mat4x3", "mat4x4",
	"sampler1D", "sampler2D", "sampler3D", "samplerCube", "sampler2DArray",
	"sampler2DShadow", "samplerCubeShadow", "isampler2D", "usampler2D",
	"image2D", "image3D", "imageCube", "atomic_uint",
}
@(private = "file")
hlsl_keywords := []string{
	"break", "case", "cbuffer", "const", "continue", "default", "discard",
	"do", "else", "for", "if", "in", "inline", "inout", "out", "pass",
	"register", "return", "struct", "switch", "technique", "typedef",
	"uniform", "while", "static", "groupshared", "packoffset", "row_major",
	"column_major", "numthreads",
}
@(private = "file")
hlsl_types := []string{
	"void", "bool", "int", "uint", "dword", "half", "float", "double",
	"float2", "float3", "float4", "float2x2", "float3x3", "float4x4",
	"int2", "int3", "int4", "uint2", "uint3", "uint4", "half2", "half3",
	"half4", "matrix", "vector", "Texture1D", "Texture2D", "Texture3D",
	"TextureCube", "Texture2DArray", "SamplerState", "SamplerComparisonState",
	"RWTexture2D", "RWBuffer", "RWStructuredBuffer", "StructuredBuffer",
	"ByteAddressBuffer", "ConstantBuffer",
}
@(private = "file")
wgsl_keywords := []string{
	"alias", "break", "case", "const", "continue", "continuing", "default",
	"diagnostic", "discard", "else", "enable", "fn", "for", "if", "let",
	"loop", "override", "requires", "return", "struct", "switch", "var",
	"while",
}
@(private = "file")
wgsl_types := []string{
	"bool", "f16", "f32", "i32", "u32", "vec2", "vec3", "vec4", "mat2x2",
	"mat3x3", "mat4x4", "array", "atomic", "ptr", "sampler",
	"sampler_comparison", "texture_1d", "texture_2d", "texture_2d_array",
	"texture_3d", "texture_cube", "texture_storage_2d", "texture_depth_2d",
}
@(private = "file")
bool_consts := []string{"true", "false"}
@(private = "file")
json_consts := []string{"true", "false", "null"}

@(private = "file")
c_keywords := []string{
	"auto", "break", "case", "const", "continue", "default", "do", "else",
	"enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
	"return", "sizeof", "static", "struct", "switch", "typedef", "union",
	"volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Static_assert",
	"_Thread_local",
}
@(private = "file")
c_types := []string{
	"void", "char", "short", "int", "long", "float", "double", "signed",
	"unsigned", "bool", "size_t", "ssize_t", "ptrdiff_t", "wchar_t",
	"int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
	"uint32_t", "uint64_t", "intptr_t", "uintptr_t", "FILE", "_Bool",
}
@(private = "file")
c_consts := []string{"true", "false", "NULL"}
@(private = "file")
cpp_keywords := []string{
	"alignas", "alignof", "auto", "break", "case", "catch", "class", "concept",
	"const", "consteval", "constexpr", "constinit", "const_cast", "continue",
	"co_await", "co_return", "co_yield", "decltype", "default", "delete", "do",
	"dynamic_cast", "else", "enum", "explicit", "export", "extern", "final",
	"for", "friend", "goto", "if", "inline", "mutable", "namespace", "new",
	"noexcept", "operator", "override", "private", "protected", "public",
	"register", "reinterpret_cast", "requires", "return", "sizeof", "static",
	"static_assert", "static_cast", "struct", "switch", "template", "throw",
	"try", "typedef", "typeid", "typename", "union", "using", "virtual",
	"volatile", "while",
}
@(private = "file")
cpp_types := []string{
	"void", "char", "char8_t", "char16_t", "char32_t", "short", "int", "long",
	"float", "double", "signed", "unsigned", "bool", "wchar_t", "size_t",
	"ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
	"uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "string",
	"vector", "map", "set", "pair", "unique_ptr", "shared_ptr", "weak_ptr",
	"optional", "variant", "array", "span", "string_view",
}
@(private = "file")
cpp_consts := []string{"true", "false", "nullptr", "NULL", "this"}
@(private = "file")
python_keywords := []string{
	"and", "as", "assert", "async", "await", "break", "case", "class",
	"continue", "def", "del", "elif", "else", "except", "finally", "for",
	"from", "global", "if", "import", "in", "is", "lambda", "match",
	"nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
	"with", "yield",
}
@(private = "file")
python_types := []string{
	"int", "float", "complex", "str", "bytes", "bytearray", "list", "dict",
	"set", "frozenset", "tuple", "bool", "object", "type",
}
@(private = "file")
python_consts := []string{"True", "False", "None", "self", "cls", "__name__"}
@(private = "file")
js_keywords := []string{
	"async", "await", "break", "case", "catch", "class", "const", "continue",
	"debugger", "default", "delete", "do", "else", "export", "extends",
	"finally", "for", "function", "get", "if", "import", "in", "instanceof",
	"let", "new", "of", "return", "set", "static", "super", "switch", "throw",
	"try", "typeof", "var", "void", "while", "with", "yield",
}
@(private = "file")
js_consts := []string{"true", "false", "null", "undefined", "NaN", "Infinity", "this", "globalThis"}
@(private = "file")
ts_keywords := []string{
	"abstract", "as", "asserts", "async", "await", "break", "case", "catch",
	"class", "const", "continue", "debugger", "declare", "default", "delete",
	"do", "else", "enum", "export", "extends", "finally", "for", "function",
	"get", "if", "implements", "import", "in", "infer", "instanceof",
	"interface", "is", "keyof", "let", "namespace", "new", "of", "override",
	"private", "protected", "public", "readonly", "return", "satisfies",
	"set", "static", "super", "switch", "throw", "try", "type", "typeof",
	"var", "void", "while", "with", "yield",
}
@(private = "file")
ts_types := []string{
	"any", "bigint", "boolean", "never", "number", "object", "string",
	"symbol", "unknown", "void",
}
@(private = "file")
rust_keywords := []string{
	"as", "async", "await", "break", "const", "continue", "crate", "dyn",
	"else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
	"match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct",
	"super", "trait", "type", "union", "unsafe", "use", "where", "while",
}
@(private = "file")
rust_types := []string{
	"bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize", "u8",
	"u16", "u32", "u64", "u128", "usize", "f32", "f64", "String", "Vec",
	"Option", "Result", "Box", "Rc", "Arc", "Cell", "RefCell", "HashMap",
	"HashSet", "BTreeMap", "Cow",
}
@(private = "file")
rust_consts := []string{"true", "false", "self", "Self", "None", "Some", "Ok", "Err"}
@(private = "file")
go_keywords := []string{
	"break", "case", "chan", "const", "continue", "default", "defer", "else",
	"fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
	"map", "package", "range", "return", "select", "struct", "switch", "type",
	"var",
}
@(private = "file")
go_types := []string{
	"any", "bool", "byte", "complex64", "complex128", "error", "float32",
	"float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
	"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
}
@(private = "file")
go_consts := []string{"true", "false", "nil", "iota"}
@(private = "file")
java_keywords := []string{
	"abstract", "assert", "break", "case", "catch", "class", "const",
	"continue", "default", "do", "else", "enum", "extends", "final",
	"finally", "for", "goto", "if", "implements", "import", "instanceof",
	"interface", "native", "new", "package", "permits", "private",
	"protected", "public", "record", "return", "sealed", "static",
	"strictfp", "super", "switch", "synchronized", "throw", "throws",
	"transient", "try", "var", "volatile", "while", "yield",
}
@(private = "file")
java_types := []string{
	"boolean", "byte", "char", "double", "float", "int", "long", "short",
	"void", "String", "Object", "Integer", "Long", "Double", "Boolean",
	"List", "Map", "Set", "Optional",
}
@(private = "file")
java_consts := []string{"true", "false", "null", "this"}
@(private = "file")
csharp_keywords := []string{
	"abstract", "as", "async", "await", "base", "break", "case", "catch",
	"checked", "class", "const", "continue", "default", "delegate", "do",
	"else", "enum", "event", "explicit", "extern", "finally", "fixed", "for",
	"foreach", "get", "goto", "if", "implicit", "in", "init", "interface",
	"internal", "is", "lock", "namespace", "new", "operator", "out",
	"override", "params", "partial", "private", "protected", "public",
	"readonly", "record", "ref", "required", "return", "sealed", "set",
	"sizeof", "stackalloc", "static", "struct", "switch", "throw", "try",
	"typeof", "unchecked", "unsafe", "using", "var", "virtual", "volatile",
	"when", "where", "while", "yield",
}
@(private = "file")
csharp_types := []string{
	"bool", "byte", "char", "decimal", "double", "dynamic", "float", "int",
	"long", "nint", "nuint", "object", "sbyte", "short", "string", "uint",
	"ulong", "ushort", "void",
}
@(private = "file")
csharp_consts := []string{"true", "false", "null", "this"}
@(private = "file")
lua_keywords := []string{
	"and", "break", "do", "else", "elseif", "end", "for", "function", "goto",
	"if", "in", "local", "not", "or", "repeat", "return", "then", "until",
	"while",
}
@(private = "file")
lua_consts := []string{"true", "false", "nil", "self"}
@(private = "file")
shell_keywords := []string{
	"alias", "break", "case", "continue", "declare", "do", "done", "elif",
	"else", "esac", "eval", "exec", "exit", "export", "fi", "for", "function",
	"if", "in", "local", "read", "readonly", "return", "select", "set",
	"shift", "source", "then", "time", "unset", "until", "while",
}
@(private = "file")
powershell_keywords := []string{
	"begin", "break", "catch", "class", "continue", "data", "do",
	"dynamicparam", "else", "elseif", "end", "enum", "exit", "filter",
	"finally", "for", "foreach", "from", "function", "hidden", "if", "in",
	"param", "process", "return", "static", "switch", "throw", "trap", "try",
	"until", "using", "while",
}
@(private = "file")
batch_keywords := []string{
	"call", "cd", "choice", "copy", "defined", "del", "do", "echo", "else",
	"endlocal", "errorlevel", "exist", "exit", "for", "goto", "if", "in",
	"mkdir", "move", "not", "pause", "popd", "pushd", "rem", "rmdir", "set",
	"setlocal", "shift", "start",
}
@(private = "file")
yaml_consts := []string{"true", "false", "null", "yes", "no", "on", "off"}

@(private = "file")
lex_config_for :: proc(lang: Lang) -> Lex_Config {
	switch lang {
	case .JSON:
		return {
			block_open = "/*", block_close = "*/", line_comment = "//", // jsonc-friendly
			consts = json_consts,
			json_keys = true,
		}
	case .GLSL:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = glsl_keywords, types = glsl_types, consts = bool_consts,
			directives = true,
		}
	case .HLSL:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = hlsl_keywords, types = hlsl_types, consts = bool_consts,
			directives = true,
		}
	case .WGSL:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = wgsl_keywords, types = wgsl_types, consts = bool_consts,
			at_attributes = true,
		}
	case .C:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = c_keywords, types = c_types, consts = c_consts,
			directives = true, sq_strings = true,
		}
	case .CPP:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = cpp_keywords, types = cpp_types, consts = cpp_consts,
			directives = true, sq_strings = true,
		}
	case .Python:
		return {
			line_comment = "#",
			keywords = python_keywords, types = python_types, consts = python_consts,
			sq_strings = true, triple_quotes = true, at_attributes = true, // @decorator
		}
	case .JS:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = js_keywords, consts = js_consts,
			sq_strings = true, bt_strings = true,
		}
	case .TS:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = ts_keywords, types = ts_types, consts = js_consts,
			sq_strings = true, bt_strings = true, at_attributes = true, // @decorator
		}
	case .Rust:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = rust_keywords, types = rust_types, consts = rust_consts,
			// no sq_strings: 'a lifetimes would swallow the rest of the line
		}
	case .Go:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = go_keywords, types = go_types, consts = go_consts,
			sq_strings = true, bt_strings = true, // raw strings
		}
	case .Java:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = java_keywords, types = java_types, consts = java_consts,
			sq_strings = true, at_attributes = true, // @Override
		}
	case .CSharp:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/",
			keywords = csharp_keywords, types = csharp_types, consts = csharp_consts,
			sq_strings = true, directives = true, // #region etc
		}
	case .Lua:
		return {
			line_comment = "--", block_open = "--[[", block_close = "]]",
			keywords = lua_keywords, consts = lua_consts,
			sq_strings = true,
		}
	case .Shell:
		return {
			line_comment = "#",
			keywords = shell_keywords, consts = bool_consts,
			sq_strings = true, bt_strings = true, // `cmd` substitution
		}
	case .PowerShell:
		return {
			line_comment = "#", block_open = "<#", block_close = "#>",
			keywords = powershell_keywords,
			sq_strings = true,
		}
	case .Batch:
		return {
			line_comment = "::",
			keywords = batch_keywords,
		}
	case .YAML:
		return {
			line_comment = "#",
			consts = yaml_consts,
			sq_strings = true, json_keys = true, ident_keys = true,
		}
	case .TOML:
		return {
			line_comment = "#",
			consts = bool_consts,
			sq_strings = true, json_keys = true, ident_keys = true, sections = true,
		}
	case .INI:
		return {
			line_comment = ";", line_comment2 = "#",
			sq_strings = true, ident_keys = true, sections = true,
		}
	case .CSS:
		return {
			line_comment = "//", block_open = "/*", block_close = "*/", // scss-friendly
			sq_strings = true, ident_keys = true, at_attributes = true, // @media
		}
	case .Plain, .Odin, .Markdown, .HTML:
	}
	return {}
}

@(private = "file")
match_at :: proc(text: string, off: int, what: string) -> bool {
	return len(what) > 0 && strings.has_prefix(text[off:], what)
}

@(private = "file")
in_list :: proc(word: string, list: []string) -> bool {
	for w in list {
		if w == word {
			return true
		}
	}
	return false
}

@(private)
highlight_generic :: proc(h: ^Highlight, b: ^Buffer) {
	cfg := lex_config_for(h.lang)
	text, em := highlight_reset(h, b)

	n := len(text)
	i := 0
	for i < n {
		c := text[i]
		switch {
		// Block before line comment: Lua's "--[[" starts with its "--".
		case match_at(text, i, cfg.block_open):
			start := i
			i += len(cfg.block_open)
			for i < n && !match_at(text, i, cfg.block_close) {
				i += 1
			}
			if i < n {
				i += len(cfg.block_close)
			}
			em.emit(start, i, .Comment)

		case match_at(text, i, cfg.line_comment) || match_at(text, i, cfg.line_comment2):
			start := i
			for i < n && text[i] != '\n' {
				i += 1
			}
			em.emit(start, i, .Comment)

		case c == '"' || (c == '\'' && cfg.sq_strings) || (c == '`' && cfg.bt_strings):
			start := i
			q := c
			if cfg.triple_quotes && q != '`' && i+2 < n && text[i+1] == q && text[i+2] == q {
				// """...""" spans lines.
				i += 3
				for i < n && !(text[i] == q && i+2 < n && text[i+1] == q && text[i+2] == q) {
					if text[i] == '\\' && i+1 < n {
						i += 1
					}
					i += 1
				}
				i = min(i+3, n)
				em.emit(start, i, .String)
				break
			}
			i += 1
			for i < n && text[i] != q && (q == '`' || text[i] != '\n') {
				// No escapes in backtick strings (Go raw strings).
				if q != '`' && text[i] == '\\' && i+1 < n {
					i += 1
				}
				i += 1
			}
			if i < n && text[i] == q {
				i += 1
			}
			face := Face.String
			if cfg.json_keys {
				// A string directly followed by ':' (or '=' in toml) is a key.
				j := i
				for j < n && (text[j] == ' ' || text[j] == '\t') {
					j += 1
				}
				if j < n && (text[j] == ':' || (cfg.ident_keys && text[j] == '=')) {
					face = .Key
				}
			}
			em.emit(start, i, face)

		case c == '[' && cfg.sections && (i == 0 || text[i-1] == '\n'):
			start := i
			for i < n && text[i] != '\n' && text[i] != ']' {
				i += 1
			}
			if i < n && text[i] == ']' {
				i += 1
			}
			em.emit(start, i, .Directive)

		case c == '#' && cfg.directives:
			start := i
			for i < n && text[i] != '\n' && !match_at(text, i, cfg.line_comment) {
				i += 1
			}
			em.emit(start, i, .Directive)

		case c == '@' && cfg.at_attributes:
			start := i
			i += 1
			for i < n && char_class(rune(text[i])) == 1 {
				i += 1
			}
			em.emit(start, i, .Directive)

		case '0' <= c && c <= '9',
		     c == '-' && i+1 < n && '0' <= text[i+1] && text[i+1] <= '9':
			start := i
			i += 1
			for i < n {
				d := text[i]
				is_num := ('0' <= d && d <= '9') || d == '.' || d == 'e' || d == 'E' ||
					d == 'x' || d == 'X' || d == '+' || d == '-' ||
					('a' <= d && d <= 'f') || ('A' <= d && d <= 'F') || d == 'u' || d == 'U'
				if !is_num {
					break
				}
				i += 1
			}
			em.emit(start, i, .Number)

		case char_class(rune(c)) == 1 && !('0' <= c && c <= '9'):
			start := i
			for i < n && char_class(rune(text[i])) == 1 {
				i += 1
			}
			word := text[start:i]
			face := Face.Text
			switch {
			case in_list(word, cfg.keywords):
				face = .Keyword
			case in_list(word, cfg.types):
				face = .Type
			case in_list(word, cfg.consts):
				face = .Constant
			case i < n && text[i] == '(':
				face = .Function
			case cfg.ident_keys:
				// A bare word followed by ':' or '=' is a key (yaml/css/ini).
				j := i
				for j < n && (text[j] == ' ' || text[j] == '\t') {
					j += 1
				}
				if j < n && (text[j] == ':' || text[j] == '=') {
					face = .Key
				}
			}
			em.emit(start, i, face)

		case:
			i += 1
		}
	}
}

// --- Markdown ------------------------------------------------------------------
//
// Line-oriented: headings, blockquotes and fenced code blocks per line, then
// inline `code` and [text](url) within ordinary lines.

@(private)
highlight_markdown :: proc(h: ^Highlight, b: ^Buffer) {
	text, em := highlight_reset(h, b)
	n := len(text)
	i := 0
	in_fence := false
	for i < n {
		le := i
		for le < n && text[le] != '\n' {
			le += 1
		}
		line := text[i:le]
		trimmed := strings.trim_left(line, " ")
		switch {
		case strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~"):
			em.emit(i, le, .Comment)
			in_fence = !in_fence
		case in_fence:
			em.emit(i, le, .String)
		case len(line) > 0 && line[0] == '#':
			em.emit(i, le, .Keyword)
		case len(trimmed) > 0 && trimmed[0] == '>':
			em.emit(i, le, .Comment)
		case:
			j := 0
			for j < len(line) {
				switch line[j] {
				case '`':
					k := j + 1
					for k < len(line) && line[k] != '`' {
						k += 1
					}
					if k < len(line) {
						k += 1
					}
					em.emit(i+j, i+k, .String)
					j = k
				case '[':
					// [text](url)
					k := j + 1
					for k < len(line) && line[k] != ']' {
						k += 1
					}
					if k+1 < len(line) && line[k+1] == '(' {
						m := k + 2
						for m < len(line) && line[m] != ')' {
							m += 1
						}
						if m < len(line) {
							em.emit(i+j, i+k+1, .Function)
							em.emit(i+k+1, i+m+1, .Comment)
							j = m + 1
							continue
						}
					}
					j += 1
				case:
					j += 1
				}
			}
		}
		i = le + 1
	}
}

// --- HTML / XML ------------------------------------------------------------------

@(private = "file")
is_tag_char :: proc(c: u8) -> bool {
	return char_class(rune(c)) == 1 || c == '-' || c == ':'
}

@(private)
highlight_markup :: proc(h: ^Highlight, b: ^Buffer) {
	text, em := highlight_reset(h, b)
	n := len(text)
	i := 0
	for i < n {
		if text[i] != '<' {
			i += 1
			continue
		}
		if match_at(text, i, "<!--") {
			start := i
			i += 4
			for i < n && !match_at(text, i, "-->") {
				i += 1
			}
			i = min(i+3, n)
			em.emit(start, i, .Comment)
			continue
		}
		// <tag attr="value" ...> (also </tag>, <!doctype>, <?xml?>)
		start := i
		i += 1
		if i < n && (text[i] == '/' || text[i] == '!' || text[i] == '?') {
			i += 1
		}
		ts := i
		for i < n && is_tag_char(text[i]) {
			i += 1
		}
		em.emit(start, ts, .Operator)
		em.emit(ts, i, .Keyword)
		for i < n && text[i] != '>' {
			c := text[i]
			switch {
			case c == '"' || c == '\'':
				qs := i
				i += 1
				for i < n && text[i] != c {
					i += 1
				}
				if i < n {
					i += 1
				}
				em.emit(qs, i, .String)
			case is_tag_char(c):
				as := i
				for i < n && is_tag_char(text[i]) {
					i += 1
				}
				em.emit(as, i, .Key)
			case:
				i += 1
			}
		}
		if i < n {
			i += 1
			em.emit(i-1, i, .Operator)
		}
	}
}
