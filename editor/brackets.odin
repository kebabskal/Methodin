// medit — bracket-pair highlighting. Three layers on top of the rainbow
// faces from the highlighter: the bracket at the caret and its match get a
// background, the innermost enclosing pair a fainter one, and a thin
// vertical guide marks the extent of that enclosing scope. Brackets inside
// strings and comments are ignored (judged by the highlight spans).
package medit

// How far match/scope scans reach, in lines each way; beyond this we'd
// rather skip the highlight than hitch on a megabyte of minified JSON.
@(private = "file")
BRACKET_SCAN_LINES :: 5000

@(private = "file")
is_open_bracket :: proc(c: byte) -> bool {
	return c == '(' || c == '[' || c == '{'
}

@(private = "file")
is_close_bracket :: proc(c: byte) -> bool {
	return c == ')' || c == ']' || c == '}'
}

@(private = "file")
open_for :: proc(close: byte) -> byte {
	switch close {
	case ')':
		return '('
	case ']':
		return '['
	case '}':
		return '{'
	}
	return 0
}

// Visual indent of a line's leading whitespace; blank = nothing after it.
@(private = "file")
line_indent :: proc(b: ^Buffer, line: int) -> (ind: int, blank: bool) {
	s := b.line_str(line)
	for i in 0 ..< len(s) {
		switch s[i] {
		case ' ':
			ind += 1
		case '\t':
			ind = (ind/tab_w + 1) * tab_w
		case:
			return ind, false
		}
	}
	return ind, true
}

// Face covering a byte column, .Text where the highlighter left gaps.
@(private = "file")
face_at :: proc(h: ^Highlight, line, col: int) -> Face {
	if line < len(h.spans) {
		for sp in h.spans[line] {
			if sp.start <= col && col < sp.end {
				return sp.face
			}
		}
	}
	return .Text
}

// A bracket only counts when the highlighter didn't put it in a string or
// comment (Plain files have no spans, so everything counts there).
@(private = "file")
counts_as_code :: proc(h: ^Highlight, line, col: int) -> bool {
	f := face_at(h, line, col)
	return f != .String && f != .Comment
}

impl App {
	// Scan forward from an opener (inclusive) to its matching closer.
	bracket_match_forward :: proc(from: Pos, open: byte) -> (Pos, bool) {
		close := close_for(open)
		depth := 0
		last := min(buf.line_count()-1, from.line+BRACKET_SCAN_LINES)
		col := from.col
		for line in from.line ..= last {
			s := buf.line_str(line)
			for col < len(s) {
				c := s[col]
				if (c == open || c == close) && counts_as_code(&hl, line, col) {
					depth += 1 if c == open else -1
					if depth == 0 {
						return Pos{line, col}, true
					}
				}
				col += 1
			}
			col = 0
		}
		return {}, false
	}

	// Scan backward from a closer (inclusive) to its matching opener.
	bracket_match_backward :: proc(from: Pos, close: byte) -> (Pos, bool) {
		open := open_for(close)
		depth := 0
		first := max(0, from.line-BRACKET_SCAN_LINES)
		col := from.col
		for line := from.line; line >= first; line -= 1 {
			s := buf.line_str(line)
			if line != from.line {
				col = len(s) - 1
			}
			for ; col >= 0; col -= 1 {
				c := s[col]
				if (c == open || c == close) && counts_as_code(&hl, line, col) {
					depth += 1 if c == close else -1
					if depth == 0 {
						return Pos{line, col}, true
					}
				}
			}
		}
		return {}, false
	}

	// The innermost unmatched opener left of p — the scope the caret is in.
	enclosing_open :: proc(p: Pos) -> (Pos, bool) {
		kind :: proc(c: byte) -> int {
			switch c {
			case '(', ')':
				return 0
			case '[', ']':
				return 1
			}
			return 2
		}
		pending: [3]int // closers seen, per bracket kind
		first := max(0, p.line-BRACKET_SCAN_LINES)
		for line := p.line; line >= first; line -= 1 {
			s := buf.line_str(line)
			col := min(p.col, len(s)) - 1 if line == p.line else len(s)-1
			for ; col >= 0; col -= 1 {
				c := s[col]
				if !counts_as_code(&hl, line, col) {
					continue
				}
				if is_close_bracket(c) {
					pending[kind(c)] += 1
				} else if is_open_bracket(c) {
					if pending[kind(c)] > 0 {
						pending[kind(c)] -= 1
					} else {
						return Pos{line, col}, true
					}
				}
			}
		}
		return {}, false
	}

	// Ctrl+up/down: structural movement. Up walks to the enclosing scope's
	// opener (repeat presses climb outward), down to just past the scope's
	// closer; in between, both stop at "block starts" — definition headers,
	// paragraph starts after a blank line, and dedent points.
	semantic_move :: proc(dir: int, extend: bool) {
		moved := false
		for &c in cursors {
			if t, ok := self.semantic_target(c.head, dir); ok {
				c.head = t
				moved = true
			}
			if !extend {
				c.anchor = c.head
			}
			c.goal_col = -1
		}
		if moved {
			self.normalize_cursors()
			self.blink_reset()
		}
	}

	semantic_target :: proc(p: Pos, dir: int) -> (Pos, bool) {
		first_nonws :: proc(b: ^Buffer, line: int) -> int {
			s := b.line_str(line)
			for i in 0 ..< len(s) {
				if s[i] != ' ' && s[i] != '\t' {
					return i
				}
			}
			return 0
		}
		// A line starts a block when it is non-blank, doesn't just close
		// one, and either follows a blank line or dedents from the line
		// above (so import groups and paragraphs count once, not per line).
		block_start :: proc(app: ^App, line: int) -> bool {
			ind, blank := line_indent(&app.buf, line)
			if blank {
				return false
			}
			s := app.buf.line_str(line)
			switch s[first_nonws(&app.buf, line)] {
			case '}', ')', ']':
				return false
			}
			if line == 0 {
				return true
			}
			prev_ind, prev_blank := line_indent(&app.buf, line-1)
			return prev_blank || ind < prev_ind
		}

		best := Pos{-1, -1}
		if dir < 0 {
			open, ok := self.enclosing_open(p)
			for ok && open.line == p.line {
				open, ok = self.enclosing_open(open) // climb out of same-line scopes
			}
			if ok {
				t := Pos{open.line, first_nonws(&buf, open.line)}
				if pos_less(t, p) {
					best = t
				}
			}
			low := max(0, p.line-BRACKET_SCAN_LINES)
			for line := p.line - 1; line >= low; line -= 1 {
				if line <= best.line {
					break // the scope opener is nearer
				}
				if block_start(self, line) {
					t := Pos{line, first_nonws(&buf, line)}
					if pos_less(t, p) && (best.line < 0 || pos_less(best, t)) {
						best = t
					}
					break
				}
			}
		} else {
			if open, ok := self.enclosing_open(p); ok {
				if close, cok := self.bracket_match_forward(open, buf.line_str(open.line)[open.col]); cok {
					t := Pos{close.line, close.col + 1}
					if pos_less(p, t) {
						best = t
					}
				}
			}
			high := min(buf.line_count()-1, p.line+BRACKET_SCAN_LINES)
			for line in p.line + 1 ..= high {
				if best.line >= 0 && line >= best.line {
					break // the scope closer is nearer
				}
				if block_start(self, line) {
					best = Pos{line, first_nonws(&buf, line)}
					break
				}
			}
		}
		return best, best.line >= 0
	}

	// Caret-adjacent bracket + match, enclosing pair, and the scope guide.
	// Called between the selection rects and the text glyphs.
	brackets_draw :: proc(r: ^Renderer, first_line, last_line: int, cell_w, line_h: f32) {
		if len(cursors) != 1 || cursor_has_selection(cursors[0]) {
			return
		}
		p := cursors[0].head

		cell_bg :: proc(app: ^App, r: ^Renderer, q: Pos, color: Color, first_line, last_line: int, cell_w, line_h: f32) {
			if q.line < first_line || q.line > last_line {
				return
			}
			x := app.gutter_px + f32(visual_col(&app.buf, q.line, q.col))*cell_w - app.scroll_x
			y := app.tabbar_h + f32(q.line)*line_h - app.scroll_y
			if x >= app.gutter_px-0.5 {
				push_rect(r, x, y, cell_w, line_h, color)
			}
		}

		// Enclosing scope: faint pair highlight + vertical guide.
		scope_open, scope_ok := self.enclosing_open(p)
		scope_close: Pos
		if scope_ok {
			scope_close, scope_ok = self.bracket_match_forward(scope_open, buf.line_str(scope_open.line)[scope_open.col])
		}
		if scope_ok {
			faint := color_alpha(theme.bracket_match, 0.45)
			cell_bg(self, r, scope_open, faint, first_line, last_line, cell_w, line_h)
			cell_bg(self, r, scope_close, faint, first_line, last_line, cell_w, line_h)
			if scope_close.line > scope_open.line+1 {
				s := buf.line_str(scope_open.line)
				ws := 0
				for ws < len(s) && (s[ws] == ' ' || s[ws] == '\t') {
					ws += 1
				}
				x := gutter_px + f32(visual_col(&buf, scope_open.line, ws))*cell_w - scroll_x
				y0 := max(tabbar_h+f32(scope_open.line+1)*line_h-scroll_y, tabbar_h)
				y1 := min(tabbar_h+f32(scope_close.line)*line_h-scroll_y, tabbar_h+view_h)
				if y1 > y0 && x >= gutter_px-0.5 {
					push_rect(r, x, y0, 1.5, y1-y0, theme.scope_guide)
				}
			}
		}

		// Bracket next to the caret and its match: strong highlight. The
		// character left of the caret wins (matches the typing flow).
		s := buf.line_str(p.line)
		q := Pos{-1, -1}
		if p.col > 0 && (is_open_bracket(s[p.col-1]) || is_close_bracket(s[p.col-1])) &&
		   counts_as_code(&hl, p.line, p.col-1) {
			q = Pos{p.line, p.col - 1}
		} else if p.col < len(s) && (is_open_bracket(s[p.col]) || is_close_bracket(s[p.col])) &&
		   counts_as_code(&hl, p.line, p.col) {
			q = Pos{p.line, p.col}
		}
		if q.line >= 0 {
			c := buf.line_str(q.line)[q.col]
			m: Pos
			ok: bool
			if is_open_bracket(c) {
				m, ok = self.bracket_match_forward(q, c)
			} else {
				m, ok = self.bracket_match_backward(q, c)
			}
			if ok {
				cell_bg(self, r, q, theme.bracket_match, first_line, last_line, cell_w, line_h)
				cell_bg(self, r, m, theme.bracket_match, first_line, last_line, cell_w, line_h)
			}
		}
	}
}
