// medit — one good theme, hardcoded.
package medit

Color :: [4]f32

@(private = "file")
rgb :: proc(hex: u32) -> Color {
	return Color{
		f32((hex >> 16) & 0xFF) / 255.0,
		f32((hex >> 8) & 0xFF) / 255.0,
		f32(hex & 0xFF) / 255.0,
		1.0,
	}
}

Theme :: struct {
	bg:            Color,
	fg:            Color,
	gutter_fg:     Color,
	gutter_cur:    Color,
	current_line:  Color,
	selection:     Color,
	cursor:        Color,
	status_bg:     Color,
	status_fg:     Color,
	status_dim:    Color,
	bracket_match: Color, // behind the bracket pair at the caret
	scope_guide:   Color, // vertical line marking the enclosing scope
	diag_err:      Color,
	diag_warn:     Color,
	diag_info:     Color,
	faces:         [Face]Color,
}

theme_default :: proc() -> Theme {
	t := Theme {
		bg           = rgb(0x1a1b26),
		fg           = rgb(0xc0caf5),
		gutter_fg    = rgb(0x3b4261),
		gutter_cur   = rgb(0x737aa2),
		current_line = rgb(0x1f2233),
		selection    = rgb(0x2d3f76),
		cursor       = rgb(0xc0caf5),
		status_bg    = rgb(0x16161e),
		status_fg    = rgb(0xa9b1d6),
		status_dim   = rgb(0x565f89),
		bracket_match = rgb(0x3d59a1),
		scope_guide   = rgb(0x3b4261),
		diag_err      = rgb(0xf7768e),
		diag_warn     = rgb(0xe0af68),
		diag_info     = rgb(0x7dcfff),
	}
	t.faces = [Face]Color {
		.Text      = t.fg,
		.Keyword   = rgb(0xbb9af7),
		.Function  = rgb(0x7aa2f7),
		.Type      = rgb(0x2ac3de),
		.Number    = rgb(0xff9e64),
		.String    = rgb(0x9ece6a),
		.Comment   = rgb(0x565f89),
		.Operator  = rgb(0x89ddff),
		.Constant  = rgb(0xff9e64),
		.Directive = rgb(0xe0af68),
		.Key       = rgb(0x73daca),
		.Bracket1  = rgb(0xffd700), // gold
		.Bracket2  = rgb(0xda70d6), // orchid
		.Bracket3  = rgb(0x87cefa), // sky blue
	}
	return t
}

color_alpha :: proc(c: Color, a: f32) -> Color {
	c := c
	c.a = a
	return c
}
