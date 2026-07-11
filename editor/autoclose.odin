// medit — bracket/quote auto-close. Typing an opener inserts the closer and
// leaves the caret between them (a selection gets wrapped instead); typing a
// closer that is already right of the caret steps over it. insert_newline
// (app.odin) and delete_backward complete the picture: enter after an opener
// indents one level deeper, backspace inside an empty pair removes both.
package medit

import "core:strings"

close_for :: proc(open: byte) -> byte {
	switch open {
	case '(':
		return ')'
	case '[':
		return ']'
	case '{':
		return '}'
	case '"', '\'', '`':
		return open
	}
	return 0
}

@(private = "file")
is_word_byte :: proc(b: byte) -> bool {
	switch b {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

impl App {
	// Keyboard typing lands here (paste and programmatic edits call
	// insert_text directly and are never auto-closed).
	type_text :: proc(text: string) {
		if len(text) == 1 {
			ch := text[0]
			switch ch {
			case '(', '[', '{':
				self.type_pair(ch, close_for(ch))
				return
			case ')', ']', '}':
				if self.type_over(ch) {
					return
				}
			case '"', '\'', '`':
				if self.type_over(ch) {
					return
				}
				if self.quotes_want_pair(ch) {
					self.type_pair(ch, ch)
					return
				}
			}
		}
		self.insert_text(text)
	}

	// Insert open+close at every cursor; carets land between them and a
	// wrapped selection stays selected (now sitting inside the pair).
	type_pair :: proc(open, close: byte) {
		edits := make([]Edit, len(cursors), context.temp_allocator)
		had_sel := make([]bool, len(cursors), context.temp_allocator)
		for c, i in cursors {
			r := cursor_range(c)
			sel := buf.range_text(r, context.temp_allocator)
			pair := [?]string{string([]byte{open}), sel, string([]byte{close})}
			edits[i] = Edit{range = r, text = strings.concatenate(pair[:], context.temp_allocator)}
			had_sel[i] = !range_empty(r)
		}
		new_ranges := buf.commit(edits, cursors[:])
		clear(&cursors)
		for r, i in new_ranges {
			c := cursor_at(Pos{r.end.line, r.end.col - 1}) // before the closer
			if had_sel[i] {
				c.anchor = Pos{r.start.line, r.start.col + 1} // after the opener
			}
			append(&cursors, c)
		}
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}

	// Typing a closer that is already the next character steps the caret
	// over it instead of doubling it. All-or-nothing across cursors so a
	// mixed multi-cursor edit stays uniform.
	type_over :: proc(ch: byte) -> bool {
		for c in cursors {
			if cursor_has_selection(c) {
				return false
			}
			s := buf.line_str(c.head.line)
			if c.head.col >= len(s) || s[c.head.col] != ch {
				return false
			}
		}
		for &c in cursors {
			c.head.col += 1
			c.anchor = c.head
			c.goal_col = -1
		}
		self.blink_reset()
		return true
	}

	// Quotes only pair against a neutral right-hand side and a non-word
	// left-hand side, so apostrophes and inch marks inside prose stay single.
	quotes_want_pair :: proc(q: byte) -> bool {
		for c in cursors {
			if cursor_has_selection(c) {
				continue // wrapping a selection is always wanted
			}
			s := buf.line_str(c.head.line)
			if c.head.col > 0 {
				prev := s[c.head.col-1]
				if is_word_byte(prev) || prev == q {
					return false
				}
			}
			if c.head.col < len(s) {
				next := s[c.head.col]
				switch next {
				case ' ', '\t', ')', ']', '}', ',', ';', ':', '.':
				case:
					return false
				}
			}
		}
		return true
	}
}
