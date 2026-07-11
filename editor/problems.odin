// medit — diagnostics. The language server's publishDiagnostics
// notifications feed a store of problems; they surface as colored underlines
// in the text and as a collapsible panel above the status bar (ctrl+m). The
// problem under the cursor is highlighted in the panel.
package medit

import "core:encoding/json"
import "core:fmt"
import "core:strings"

PROBLEMS_MAX :: 500
PROBLEMS_VISIBLE :: 8

Diagnostic :: struct {
	path:         string, // owned
	line, char:   int,    // LSP UTF-16 coords, converted lazily at use
	eline, echar: int,
	severity:     int,    // 1 error, 2 warning, 3 info, 4 hint
	msg:          string, // owned; first line only (panel rows are one line)
}

@(private = "file")
severity_color :: proc(t: ^Theme, severity: int) -> Color {
	switch severity {
	case 1:
		return t.diag_err
	case 2:
		return t.diag_warn
	}
	return t.diag_info
}

severity_letter :: proc(severity: int) -> string {
	switch severity {
	case 1:
		return "E"
	case 2:
		return "W"
	case 4:
		return "H"
	}
	return "I"
}

// The server owns the diagnostics per file: each publish replaces that
// file's set.
lsp_on_diagnostics :: proc(app: ^App, params: json.Value) {
	path := path_from_uri(jstr(jget(params, "uri")))
	for i := len(app.problems) - 1; i >= 0; i -= 1 {
		if app.problems[i].path == path {
			diag_free(app.problems[i])
			ordered_remove(&app.problems, i)
		}
	}
	for v in jarr(jget(params, "diagnostics")) {
		if len(app.problems) >= PROBLEMS_MAX {
			break
		}
		r := jget(v, "range")
		s := jget(r, "start")
		e := jget(r, "end")
		msg := jstr(jget(v, "message"))
		if nl := strings.index_byte(msg, '\n'); nl >= 0 {
			msg = msg[:nl]
		}
		append(&app.problems, Diagnostic{
			path     = strings.clone(path),
			line     = jint(jget(s, "line")),
			char     = jint(jget(s, "character")),
			eline    = jint(jget(e, "line")),
			echar    = jint(jget(e, "character")),
			severity = clamp(jint(jget(v, "severity")), 1, 4),
			msg      = strings.clone(msg),
		})
	}
	app.problems_sort()
}

@(private = "file")
diag_free :: proc(d: Diagnostic) {
	delete(d.path)
	delete(d.msg)
}

problems_destroy :: proc(app: ^App) {
	for d in app.problems {
		diag_free(d)
	}
	delete(app.problems)
}

impl App {
	// Current document first, then by path; by position within a file.
	problems_sort :: proc() {
		cur := buf.path
		for i in 1 ..< len(problems) {
			j := i
			for j > 0 && problems_before(problems[j], problems[j-1], cur) {
				problems[j], problems[j-1] = problems[j-1], problems[j]
				j -= 1
			}
		}
	}

	problems_count :: proc() -> (errs, warns: int) {
		for d in problems {
			switch d.severity {
			case 1:
				errs += 1
			case 2:
				warns += 1
			}
		}
		return
	}

	// The problem containing the primary cursor (-1: none).
	problem_at_cursor :: proc() -> int {
		if len(cursors) == 0 {
			return -1
		}
		p := self.primary_cursor().head
		for d, i in problems {
			if d.path != buf.path {
				continue
			}
			s := buf_pos_from_utf16(&buf, d.line, d.char)
			e := buf_pos_from_utf16(&buf, d.eline, d.echar)
			if !pos_less(p, s) && !pos_less(e, p) {
				return i
			}
		}
		return -1
	}

	// Underlines in the text view, drawn over the glyphs' bottom edge.
	problems_draw_inline :: proc(r: ^Renderer, first_line, last_line: int, cell_w, line_h: f32) {
		for d in problems {
			if d.path != buf.path || d.line > last_line || d.eline < first_line {
				continue
			}
			s := buf_pos_from_utf16(&buf, d.line, d.char)
			e := buf_pos_from_utf16(&buf, d.eline, d.echar)
			color := severity_color(&theme, d.severity)
			for line in max(s.line, first_line) ..= min(e.line, last_line) {
				c0 := s.col if line == s.line else 0
				c1 := e.col if line == e.line else buf.line_len(line)
				x0 := gutter_px + f32(visual_col(&buf, line, c0))*cell_w - scroll_x
				x1 := gutter_px + f32(visual_col(&buf, line, c1))*cell_w - scroll_x
				if x1 <= x0 {
					x1 = x0 + cell_w // zero-width range: mark one cell
				}
				x0 = max(x0, gutter_px)
				y := tabbar_h + f32(line+1)*line_h - scroll_y - 2
				if x1 > x0 && y > tabbar_h && y < tabbar_h+view_h+line_h {
					push_rect(r, x0, y, x1-x0, 2, color)
				}
			}
		}
	}

	// The collapsible panel above the status bar. app.draw sized problems_h
	// already (the text view needs it before any drawing happens).
	problems_draw :: proc(r: ^Renderer, width, height: f32) {
		if !problems_open {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w
		row_h := line_h * 1.25
		head_h := line_h * 1.4
		top := height - status_h - problems_h
		problems_top = top
		p_rows_y = top + head_h
		p_row_h = row_h

		draw_str :: proc(r: ^Renderer, x, baseline: f32, s: string, color: Color) -> f32 {
			x := x
			for ch in s {
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
			return x
		}

		push_rect(r, 0, top, width, problems_h, theme.status_bg)
		push_rect(r, 0, top, width, 1, color_alpha(theme.gutter_fg, 0.6))

		errs, warns := self.problems_count()
		head := fmt.tprintf("problems — %d error(s), %d warning(s)", errs, warns)
		if len(problems) == 0 {
			head = "problems — none"
		}
		draw_str(r, cell_w, top+(head_h-line_h)*0.5+r.ascent, head, theme.status_dim)

		vis := clamp(len(problems), 1, PROBLEMS_VISIBLE)
		cur := self.problem_at_cursor()

		// Keep the scroll sane and the cursor's problem visible.
		max_row0 := max(len(problems)-vis, 0)
		row0 := clamp(int(problems_scroll), 0, max_row0)
		if cur >= 0 {
			if cur < row0 {
				row0 = cur
			}
			if cur >= row0+vis {
				row0 = cur - vis + 1
			}
		}
		problems_scroll = f32(row0)
		p_row0 = row0

		for vi in 0 ..< vis {
			i := row0 + vi
			if i >= len(problems) {
				break
			}
			d := problems[i]
			y := p_rows_y + f32(vi)*row_h
			if i == cur {
				push_rect(r, 0, y, width, row_h, theme.selection)
			}
			baseline := y + (row_h-line_h)*0.5 + r.ascent
			color := severity_color(&theme, d.severity)
			x := draw_str(r, cell_w, baseline, severity_letter(d.severity), color)
			x = draw_str(r, x+cell_w, baseline, d.msg, theme.fg)
			loc := fmt.tprintf("%s:%d", d.path, d.line+1)
			lw := f32(len(loc)) * cell_w
			if x+cell_w*2+lw < width {
				draw_str(r, width-cell_w-lw, baseline, loc, theme.status_dim)
			}
		}
	}

	// A click on a panel row jumps to the problem (opening its tab if needed).
	problems_click :: proc(px, py: f32) {
		_ = px
		if py < p_rows_y {
			return // header
		}
		i := p_row0 + int((py-p_rows_y)/p_row_h)
		if i < 0 || i >= len(problems) {
			return
		}
		self.problem_jump(i)
	}

	problem_jump :: proc(i: int) {
		d := problems[i]
		self.lsp_jump(Lsp_Location{
			path = strings.clone(d.path, context.temp_allocator),
			line = d.line, char = d.char, eline = d.eline, echar = d.echar,
		})
	}
}

@(private = "file")
problems_before :: proc(a, b: Diagnostic, cur_path: string) -> bool {
	if (a.path == cur_path) != (b.path == cur_path) {
		return a.path == cur_path
	}
	if a.path != b.path {
		return a.path < b.path
	}
	if a.line != b.line {
		return a.line < b.line
	}
	return a.char < b.char
}
