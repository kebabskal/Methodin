// medit — a few good themes, hardcoded. `[ui] theme = <name>` in
// settings.ini picks one at startup; ">Theme: …" in the palette switches
// live and persists the choice into the user settings.
package medit

import "core:fmt"

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

Theme_Def :: struct {
	name:  string, // the settings.ini spelling
	label: string, // the palette spelling
	make:  proc() -> Theme,
}

THEMES := []Theme_Def{
	{"tokyo-night", "Tokyo Night", theme_tokyo_night},
	{"tokyo-day", "Tokyo Day", theme_tokyo_day},
	{"paper", "Paper", theme_paper},
	{"gruvbox", "Gruvbox", theme_gruvbox},
}

theme_default :: proc() -> Theme {
	return theme_tokyo_night()
}

theme_by_name :: proc(name: string) -> (Theme, bool) {
	for d in THEMES {
		if d.name == name {
			return d.make(), true
		}
	}
	return {}, false
}

theme_tokyo_night :: proc() -> Theme {
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

// Tokyo Night's light companion.
theme_tokyo_day :: proc() -> Theme {
	t := Theme {
		bg           = rgb(0xe1e2e7),
		fg           = rgb(0x3760bf),
		gutter_fg    = rgb(0xa8aecb),
		gutter_cur   = rgb(0x3760bf),
		current_line = rgb(0xd5d6dc),
		selection    = rgb(0xb6bfe2),
		cursor       = rgb(0x3760bf),
		status_bg    = rgb(0xd0d1d9),
		status_fg    = rgb(0x3760bf),
		status_dim   = rgb(0x848cb5),
		bracket_match = rgb(0x99a7df),
		scope_guide   = rgb(0xa8aecb),
		diag_err      = rgb(0xf52a65),
		diag_warn     = rgb(0x8c6c3e),
		diag_info     = rgb(0x007197),
	}
	t.faces = [Face]Color {
		.Text      = t.fg,
		.Keyword   = rgb(0x7847bd),
		.Function  = rgb(0x2e7de9),
		.Type      = rgb(0x007197),
		.Number    = rgb(0xb15c00),
		.String    = rgb(0x587539),
		.Comment   = rgb(0x848cb5),
		.Operator  = rgb(0x188092),
		.Constant  = rgb(0xb15c00),
		.Directive = rgb(0x8c6c3e),
		.Key       = rgb(0x118c74),
		.Bracket1  = rgb(0xb08500), // dark gold
		.Bracket2  = rgb(0x9854f1), // orchid
		.Bracket3  = rgb(0x2e7de9), // blue
	}
	return t
}

// Near-white with saturated dark accents — the outdoor/high-glare theme.
theme_paper :: proc() -> Theme {
	t := Theme {
		bg           = rgb(0xffffff),
		fg           = rgb(0x1f2328),
		gutter_fg    = rgb(0xb0b6bf),
		gutter_cur   = rgb(0x1f2328),
		current_line = rgb(0xf3f4f6),
		selection    = rgb(0xb6d7ff),
		cursor       = rgb(0x1f2328),
		status_bg    = rgb(0xeaeef2),
		status_fg    = rgb(0x24292f),
		status_dim   = rgb(0x6e7781),
		bracket_match = rgb(0xc8e1ff),
		scope_guide   = rgb(0xd0d7de),
		diag_err      = rgb(0xcf222e),
		diag_warn     = rgb(0x9a6700),
		diag_info     = rgb(0x0969da),
	}
	t.faces = [Face]Color {
		.Text      = t.fg,
		.Keyword   = rgb(0xcf222e),
		.Function  = rgb(0x8250df),
		.Type      = rgb(0x0550ae),
		.Number    = rgb(0x953800),
		.String    = rgb(0x0a3069),
		.Comment   = rgb(0x6e7781),
		.Operator  = rgb(0x57606a),
		.Constant  = rgb(0x0550ae),
		.Directive = rgb(0x9a6700),
		.Key       = rgb(0x116329),
		.Bracket1  = rgb(0x9a6700), // dark gold
		.Bracket2  = rgb(0x8250df), // purple
		.Bracket3  = rgb(0x0969da), // blue
	}
	return t
}

// Warm retro dark.
theme_gruvbox :: proc() -> Theme {
	t := Theme {
		bg           = rgb(0x282828),
		fg           = rgb(0xebdbb2),
		gutter_fg    = rgb(0x504945),
		gutter_cur   = rgb(0xbdae93),
		current_line = rgb(0x32302f),
		selection    = rgb(0x504945),
		cursor       = rgb(0xebdbb2),
		status_bg    = rgb(0x1d2021),
		status_fg    = rgb(0xd5c4a1),
		status_dim   = rgb(0x928374),
		bracket_match = rgb(0x665c54),
		scope_guide   = rgb(0x504945),
		diag_err      = rgb(0xfb4934),
		diag_warn     = rgb(0xfabd2f),
		diag_info     = rgb(0x83a598),
	}
	t.faces = [Face]Color {
		.Text      = t.fg,
		.Keyword   = rgb(0xfb4934),
		.Function  = rgb(0x8ec07c),
		.Type      = rgb(0xfabd2f),
		.Number    = rgb(0xd3869b),
		.String    = rgb(0xb8bb26),
		.Comment   = rgb(0x928374),
		.Operator  = rgb(0xfe8019),
		.Constant  = rgb(0xd3869b),
		.Directive = rgb(0xfe8019),
		.Key       = rgb(0x83a598),
		.Bracket1  = rgb(0xfabd2f), // yellow
		.Bracket2  = rgb(0xd3869b), // purple
		.Bracket3  = rgb(0x83a598), // blue
	}
	return t
}

impl App {
	// Switch the theme live and remember it in the user settings.
	theme_apply :: proc(name: string) {
		t, ok := theme_by_name(name)
		if !ok {
			return
		}
		theme = t
		if settings_save_theme(name) {
			self.set_status(fmt.tprintf("theme: %s (saved to settings)", name))
		} else {
			self.set_status(fmt.tprintf("theme: %s (could not save settings)", name))
		}
	}
}

color_alpha :: proc(c: Color, a: f32) -> Color {
	c := c
	c.a = a
	return c
}
