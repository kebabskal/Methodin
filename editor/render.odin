// medit — GL 3.3 renderer: one shader, one texture (font atlas + a white
// pixel), one dynamic vertex batch. Primitives are push_rect and push_glyph;
// everything on screen is built out of those two, which keeps the door open
// for an alternative (e.g. terminal) backend later.
package medit

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// 2048² fits the ~190 packed glyphs up to ~40pt at 2× display scale.
ATLAS_W :: 2048
ATLAS_H :: 2048
ASCII_FIRST :: 32
ASCII_COUNT :: 95 // 32..126
LATIN1_FIRST :: 0xA0
LATIN1_COUNT :: 96 // 0xA0..0xFF
PUNCT_FIRST :: 0x2010 // dashes, curly quotes, bullet, ellipsis...
PUNCT_COUNT :: 48 // 0x2010..0x203F

VERTEX_FLOATS :: 8 // x y u v r g b a

Renderer :: struct {
	program:   u32,
	vao, vbo:  u32,
	atlas_tex: u32,
	u_screen:  i32,

	batch: [dynamic]f32,

	ascii:  [ASCII_COUNT]stbtt.packedchar,
	latin1: [LATIN1_COUNT]stbtt.packedchar,
	punct:  [PUNCT_COUNT]stbtt.packedchar,
	// The proportional UI face (tabs, sidebar, status bar); falls back to
	// the monospace face when no system UI font is found.
	ui_ascii:  [ASCII_COUNT]stbtt.packedchar,
	ui_latin1: [LATIN1_COUNT]stbtt.packedchar,
	white_uv: [2]f32, // uv of a solid white pixel in the atlas

	// Font metrics (pixels).
	cell_w:  f32, // advance of one monospace cell
	line_h:  f32,
	ascent:  f32,
	font_px: f32,
}

@(private = "file")
VS_SRC :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_col;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_col;
void main() {
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0,
	                   1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
	v_uv = a_uv;
	v_col = a_col;
}
`

@(private = "file")
FS_SRC :: `#version 330 core
in vec2 v_uv;
in vec4 v_col;
uniform sampler2D u_tex;
out vec4 frag;
void main() {
	float a = texture(u_tex, v_uv).r;
	frag = vec4(v_col.rgb, v_col.a * a);
}
`

// Candidate monospace fonts per OS; first hit wins. MEDIT_FONT overrides.
when ODIN_OS == .Windows {
	@(private = "file")
	FONT_CANDIDATES := []string{
		"C:\\Windows\\Fonts\\CascadiaMono.ttf",
		"C:\\Windows\\Fonts\\consola.ttf",
		"C:\\Windows\\Fonts\\lucon.ttf",
	}
} else when ODIN_OS == .Darwin {
	@(private = "file")
	FONT_CANDIDATES := []string{
		"/System/Library/Fonts/Menlo.ttc",
		"/System/Library/Fonts/Monaco.ttf",
		"/System/Library/Fonts/SFNSMono.ttf",
	}
} else {
	// Fallbacks for when fc-match is unavailable: Debian/Ubuntu keep fonts
	// under truetype/<family>/, Arch under TTF/ and <family>/, Fedora under
	// <package-name>/.
	@(private = "file")
	FONT_CANDIDATES := []string{
		"/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
		"/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
		"/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
		"/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
		"/usr/share/fonts/google-noto/NotoSansMono-Regular.ttf",
	}

	// Distros disagree on font paths, so ask fontconfig where the user's
	// preferred monospace font lives; it prints its best match even when
	// nothing is explicitly configured.
	@(private = "file")
	fontconfig_monospace :: proc() -> (path: string, ok: bool) {
		state, stdout, _, err := os.process_exec(
			{command = []string{"fc-match", "--format=%{file}", "monospace"}},
			context.temp_allocator,
		)
		if err != nil || !state.exited || state.exit_code != 0 {
			return "", false
		}
		p := strings.trim_space(string(stdout))
		return p, p != ""
	}
}

// Candidate proportional UI fonts per OS (tabs, sidebar, ...).
when ODIN_OS == .Windows {
	@(private = "file")
	UI_FONT_CANDIDATES := []string{"C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\arial.ttf"}
} else when ODIN_OS == .Darwin {
	@(private = "file")
	UI_FONT_CANDIDATES := []string{"/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf"}
} else {
	@(private = "file")
	UI_FONT_CANDIDATES := []string{
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	}
}

@(private = "file")
load_ui_font_file :: proc() -> (data: []byte, ok: bool) {
	if env := os.get_env("MEDIT_UI_FONT", context.temp_allocator); env != "" {
		if d, err := os.read_entire_file(env, context.allocator); err == nil {
			return d, true
		}
	}
	when ODIN_OS != .Windows && ODIN_OS != .Darwin {
		state, stdout, _, perr := os.process_exec(
			{command = []string{"fc-match", "--format=%{file}", "sans-serif"}},
			context.temp_allocator,
		)
		if perr == nil && state.exited && state.exit_code == 0 {
			if p := strings.trim_space(string(stdout)); p != "" {
				if d, err := os.read_entire_file(p, context.allocator); err == nil {
					return d, true
				}
			}
		}
	}
	for path in UI_FONT_CANDIDATES {
		if d, err := os.read_entire_file(path, context.allocator); err == nil {
			return d, true
		}
	}
	return nil, false
}

@(private = "file")
load_font_file :: proc() -> (data: []byte, ok: bool) {
	if env := os.get_env("MEDIT_FONT", context.temp_allocator); env != "" {
		if d, err := os.read_entire_file(env, context.allocator); err == nil {
			return d, true
		}
		fmt.eprintfln("medit: MEDIT_FONT=%s could not be read, falling back", env)
	}
	when ODIN_OS != .Windows && ODIN_OS != .Darwin {
		if path, found := fontconfig_monospace(); found {
			if d, err := os.read_entire_file(path, context.allocator); err == nil {
				return d, true
			}
		}
	}
	for path in FONT_CANDIDATES {
		if d, err := os.read_entire_file(path, context.allocator); err == nil {
			return d, true
		}
	}
	return nil, false
}

renderer_init :: proc(r: ^Renderer, font_px: f32) -> bool {
	// GL objects.
	program, prog_ok := gl.load_shaders_source(VS_SRC, FS_SRC)
	if !prog_ok {
		msg, _ := gl.get_last_error_message()
		fmt.eprintfln("medit: shader compile failed: %s", msg)
		return false
	}
	r.program = program
	r.u_screen = gl.GetUniformLocation(program, "u_screen")

	gl.GenVertexArrays(1, &r.vao)
	gl.BindVertexArray(r.vao)
	gl.GenBuffers(1, &r.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	stride := i32(VERTEX_FLOATS * size_of(f32))
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, 2*size_of(f32))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(2, 4, gl.FLOAT, false, stride, 4*size_of(f32))
	gl.EnableVertexAttribArray(2)

	gl.GenTextures(1, &r.atlas_tex)
	gl.BindTexture(gl.TEXTURE_2D, r.atlas_tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	return renderer_build_atlas(r, font_px)
}

// (Re)pack the glyph atlas at font_px and refresh the metrics — also called
// at runtime for font-size changes. On failure the renderer keeps its
// previous atlas and metrics.
renderer_build_atlas :: proc(r: ^Renderer, font_px: f32) -> bool {
	ttf, ok := load_font_file()
	if !ok {
		fmt.eprintln("medit: no usable monospace font found (set MEDIT_FONT=/path/to/font.ttf)")
		return false
	}
	defer delete(ttf)

	font_offset := stbtt.GetFontOffsetForIndex(raw_data(ttf), 0)
	if font_offset < 0 {
		font_offset = 0
	}

	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(ttf), font_offset) {
		fmt.eprintln("medit: stbtt could not parse the font")
		return false
	}

	ascii:  [ASCII_COUNT]stbtt.packedchar
	latin1: [LATIN1_COUNT]stbtt.packedchar
	punct:  [PUNCT_COUNT]stbtt.packedchar

	bitmap := make([]byte, ATLAS_W*ATLAS_H, context.temp_allocator)

	spc: stbtt.pack_context
	if stbtt.PackBegin(&spc, raw_data(bitmap), ATLAS_W, ATLAS_H, 0, 1, nil) == 0 {
		return false
	}
	stbtt.PackSetOversampling(&spc, 2, 2)
	ok1 := stbtt.PackFontRange(&spc, raw_data(ttf), 0, font_px, ASCII_FIRST, ASCII_COUNT, &ascii[0])
	ok2 := stbtt.PackFontRange(&spc, raw_data(ttf), 0, font_px, LATIN1_FIRST, LATIN1_COUNT, &latin1[0])
	ok3 := stbtt.PackFontRange(&spc, raw_data(ttf), 0, font_px, PUNCT_FIRST, PUNCT_COUNT, &punct[0])

	// The proportional UI face rides in the same atlas.
	ui_ascii:  [ASCII_COUNT]stbtt.packedchar
	ui_latin1: [LATIN1_COUNT]stbtt.packedchar
	ui_ok := false
	if ui_ttf, uok := load_ui_font_file(); uok {
		defer delete(ui_ttf)
		u_off := stbtt.GetFontOffsetForIndex(raw_data(ui_ttf), 0)
		if u_off >= 0 {
			u1 := stbtt.PackFontRange(&spc, raw_data(ui_ttf), 0, font_px, ASCII_FIRST, ASCII_COUNT, &ui_ascii[0])
			u2 := stbtt.PackFontRange(&spc, raw_data(ui_ttf), 0, font_px, LATIN1_FIRST, LATIN1_COUNT, &ui_latin1[0])
			ui_ok = u1 != 0 && u2 != 0
		}
	}
	stbtt.PackEnd(&spc)
	if ok1 == 0 || ok2 == 0 || ok3 == 0 {
		return false // glyphs did not fit; keep the previous atlas
	}
	r.ascii = ascii
	r.latin1 = latin1
	r.punct = punct
	r.ui_ascii = ui_ascii if ui_ok else ascii
	r.ui_latin1 = ui_latin1 if ui_ok else latin1
	r.font_px = font_px

	// Stamp a solid white block in the bottom-right corner for rect fills.
	// Glyphs pack top-down, so with ~190 glyphs the bottom rows are free.
	for y in ATLAS_H - 4 ..< ATLAS_H {
		for x in ATLAS_W - 4 ..< ATLAS_W {
			bitmap[y*ATLAS_W+x] = 255
		}
	}
	r.white_uv = {f32(ATLAS_W) - 2.0, f32(ATLAS_H) - 2.0}
	r.white_uv.x /= f32(ATLAS_W)
	r.white_uv.y /= f32(ATLAS_H)

	// Metrics: the atlas is packed with a scale for font_px; cell width is
	// the advance of a representative glyph (monospace: all equal).
	scale := stbtt.ScaleForPixelHeight(&info, font_px)
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	adv, lsb: i32
	stbtt.GetCodepointHMetrics(&info, 'M', &adv, &lsb)
	r.cell_w = f32(adv) * scale
	r.ascent = f32(ascent) * scale
	r.line_h = f32(ascent-descent+line_gap) * scale
	if r.line_h < font_px {
		r.line_h = font_px * 1.2
	}

	gl.BindTexture(gl.TEXTURE_2D, r.atlas_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, ATLAS_W, ATLAS_H, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(bitmap))
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	delete(r.batch)
}

frame_begin :: proc(r: ^Renderer, width, height: i32, clear_color: Color) {
	gl.Viewport(0, 0, width, height)
	gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.UseProgram(r.program)
	gl.Uniform2f(r.u_screen, f32(width), f32(height))
	gl.BindVertexArray(r.vao)
	gl.BindTexture(gl.TEXTURE_2D, r.atlas_tex)
	clear(&r.batch)
}

@(private = "file")
push_vertex :: proc(r: ^Renderer, x, y, u, v: f32, c: Color) {
	append(&r.batch, x, y, u, v, c.r, c.g, c.b, c.a)
}

@(private = "file")
push_quad :: proc(r: ^Renderer, x0, y0, x1, y1, u0, v0, u1, v1: f32, c: Color) {
	push_vertex(r, x0, y0, u0, v0, c)
	push_vertex(r, x1, y0, u1, v0, c)
	push_vertex(r, x1, y1, u1, v1, c)
	push_vertex(r, x0, y0, u0, v0, c)
	push_vertex(r, x1, y1, u1, v1, c)
	push_vertex(r, x0, y1, u0, v1, c)
}

push_rect :: proc(r: ^Renderer, x, y, w, h: f32, c: Color) {
	push_quad(r, x, y, x+w, y+h, r.white_uv.x, r.white_uv.y, r.white_uv.x, r.white_uv.y, c)
}

// --- Icons: tiny vector shapes built from rects, so they scale with the
// font and need nothing from the atlas. ---------------------------------------

// Filled disc approximated with horizontal slices.
push_disc :: proc(r: ^Renderer, cx, cy, radius: f32, c: Color) {
	SLICES :: 10
	step := radius * 2 / SLICES
	for i in 0 ..< SLICES {
		y0 := -radius + f32(i)*step
		ymid := y0 + step*0.5
		half := math.sqrt(max(radius*radius - ymid*ymid, 0))
		push_rect(r, cx-half, cy+y0, half*2, step+0.4, c)
	}
}

// A document sheet with a folded top-right corner.
push_icon_file :: proc(r: ^Renderer, x, y, size: f32, c: Color) {
	w := size * 0.78
	fold := size * 0.32
	push_rect(r, x, y, w-fold, size, c)
	push_rect(r, x+w-fold, y+fold, fold, size-fold, c)
	push_rect(r, x+w-fold, y+fold*0.45, fold*0.55, fold*0.55, color_alpha(c, 0.55))
}

// A folder: tab on top of the body.
push_icon_folder :: proc(r: ^Renderer, x, y, size: f32, c: Color) {
	tab_h := size * 0.22
	push_rect(r, x, y+size*0.10, size*0.45, tab_h, c)
	push_rect(r, x, y+size*0.10+tab_h*0.6, size*0.92, size*0.62, c)
}

// Draw one glyph with its baseline at (x, baseline_y). Unknown runes render
// as a hollow box.
push_glyph :: proc(r: ^Renderer, x, baseline_y: f32, ch: rune, c: Color) {
	base: ^stbtt.packedchar
	index: i32
	switch {
	case ch >= ASCII_FIRST && ch < ASCII_FIRST+ASCII_COUNT:
		index = i32(ch) - ASCII_FIRST
		base = &r.ascii[0]
	case ch >= LATIN1_FIRST && ch < LATIN1_FIRST+LATIN1_COUNT:
		index = i32(ch) - LATIN1_FIRST
		base = &r.latin1[0]
	case ch >= PUNCT_FIRST && ch < PUNCT_FIRST+PUNCT_COUNT:
		index = i32(ch) - PUNCT_FIRST
		base = &r.punct[0]
	case:
		// Hollow box for anything outside the atlas.
		pad := r.cell_w * 0.12
		x0 := x + pad
		y0 := baseline_y - r.ascent + pad
		x1 := x + r.cell_w - pad
		y1 := baseline_y
		t: f32 = 1.0
		push_rect(r, x0, y0, x1-x0, t, c)
		push_rect(r, x0, y1-t, x1-x0, t, c)
		push_rect(r, x0, y0, t, y1-y0, c)
		push_rect(r, x1-t, y0, t, y1-y0, c)
		return
	}

	xpos := x
	ypos := baseline_y
	q: stbtt.aligned_quad
	stbtt.GetPackedQuad(base, ATLAS_W, ATLAS_H, index, &xpos, &ypos, &q, false)
	push_quad(r, q.x0, q.y0, q.x1, q.y1, q.s0, q.t0, q.s1, q.t1, c)
}

// --- UI text: the proportional face, for chrome (tabs, sidebar, status) ------------

// One UI-face glyph; returns its advance. Runes outside the UI ranges fall
// back to the monospace face.
push_uglyph :: proc(r: ^Renderer, x, baseline_y: f32, ch: rune, c: Color) -> f32 {
	base: ^stbtt.packedchar
	index: i32
	switch {
	case ch >= ASCII_FIRST && ch < ASCII_FIRST+ASCII_COUNT:
		index = i32(ch) - ASCII_FIRST
		base = &r.ui_ascii[0]
	case ch >= LATIN1_FIRST && ch < LATIN1_FIRST+LATIN1_COUNT:
		index = i32(ch) - LATIN1_FIRST
		base = &r.ui_latin1[0]
	case:
		push_glyph(r, x, baseline_y, ch, c)
		return r.cell_w
	}
	xpos := x
	ypos := baseline_y
	q: stbtt.aligned_quad
	stbtt.GetPackedQuad(base, ATLAS_W, ATLAS_H, index, &xpos, &ypos, &q, false)
	push_quad(r, q.x0, q.y0, q.x1, q.y1, q.s0, q.t0, q.s1, q.t1, c)
	return xpos - x
}

// Width of s in the UI face, without drawing.
utext_width :: proc(r: ^Renderer, s: string) -> f32 {
	w: f32 = 0
	for ch in s {
		switch {
		case ch >= ASCII_FIRST && ch < ASCII_FIRST+ASCII_COUNT:
			w += r.ui_ascii[i32(ch)-ASCII_FIRST].xadvance
		case ch >= LATIN1_FIRST && ch < LATIN1_FIRST+LATIN1_COUNT:
			w += r.ui_latin1[i32(ch)-LATIN1_FIRST].xadvance
		case:
			w += r.cell_w
		}
	}
	return w
}

// Draw s in the UI face; returns the end x.
utext :: proc(r: ^Renderer, x, baseline: f32, s: string, c: Color) -> f32 {
	x := x
	for ch in s {
		x += push_uglyph(r, x, baseline, ch, c)
	}
	return x
}

// Draw s in the UI face, truncating with an ellipsis before limit.
utext_clip :: proc(r: ^Renderer, x, baseline, limit: f32, s: string, c: Color) -> f32 {
	x := x
	for ch in s {
		if x+r.cell_w*1.5 > limit {
			push_uglyph(r, x, baseline, '…', c)
			return x + r.cell_w
		}
		x += push_uglyph(r, x, baseline, ch, c)
	}
	return x
}

flush :: proc(r: ^Renderer) {
	if len(r.batch) == 0 {
		return
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(r.batch)*size_of(f32), raw_data(r.batch), gl.DYNAMIC_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(r.batch)/VERTEX_FLOATS))
	clear(&r.batch)
}
