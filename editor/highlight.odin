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
}

Highlight :: struct {
	lang:    Lang,
	version: int, // buffer version these spans were computed from
	spans:   [dynamic][dynamic]Span,
}

lang_from_path :: proc(path: string) -> Lang {
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
	switch h.lang {
	case .Odin:
		highlight_odin(h, b)
	case .JSON, .GLSL, .HLSL, .WGSL:
		highlight_generic(h, b)
	case .Plain:
		text, em := highlight_reset(h, b)
		_, _ = text, em
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
	block_open:    string,
	block_close:   string,
	keywords:      []string,
	types:         []string,
	consts:        []string,
	directives:    bool, // '#'-prefixed lines (GLSL/HLSL preprocessor)
	at_attributes: bool, // '@ident' (WGSL)
	json_keys:     bool, // color "string": as a key
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
	case .Plain, .Odin:
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
		case match_at(text, i, cfg.line_comment):
			start := i
			for i < n && text[i] != '\n' {
				i += 1
			}
			em.emit(start, i, .Comment)

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

		case c == '"':
			start := i
			i += 1
			for i < n && text[i] != '"' && text[i] != '\n' {
				if text[i] == '\\' && i+1 < n {
					i += 1
				}
				i += 1
			}
			if i < n && text[i] == '"' {
				i += 1
			}
			face := Face.String
			if cfg.json_keys {
				// A string directly followed by ':' is an object key.
				j := i
				for j < n && (text[j] == ' ' || text[j] == '\t') {
					j += 1
				}
				if j < n && text[j] == ':' {
					face = .Key
				}
			}
			em.emit(start, i, face)

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
			}
			em.emit(start, i, face)

		case:
			i += 1
		}
	}
}
