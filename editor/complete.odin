// medit — completion popup and signature help (LSP).
//
// Completion: typing an identifier character (or '.') asks the server once,
// then filters client-side as the word grows — fuzzy, like the palette.
// Tab/enter inserts the selected item at every cursor, esc dismisses.
//
// Signature help: '(' and ',' ask the server for the enclosing call's
// signature, shown in a one-line panel above the cursor with the active
// parameter highlighted; it re-asks on every keystroke while open so the
// highlight tracks the argument you are on.
package medit

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

COMPLETION_MAX_ITEMS :: 500
COMPLETION_VISIBLE :: 10

Comp_Item :: struct {
	label:  string, // owned
	insert: string, // owned; "" = insert the label
	detail: string, // owned
	kind:   int,    // LSP CompletionItemKind
	score:  int,
	extra:  []Extra_Edit, // owned; additionalTextEdits (auto-import)
}

// One LSP additionalTextEdit, kept in UTF-16 coords until it is applied.
Extra_Edit :: struct {
	line, char:   int,
	eline, echar: int,
	text:         string, // owned
}

Completion :: struct {
	open:       bool,
	items:      [dynamic]Comp_Item, // full server result, owned
	visible:    [dynamic]int,       // indices into items after filtering
	sel:        int,
	scroll:     int,
	anchor:     Pos, // start of the word being completed (primary cursor)
	req_id:      int,
	requested:   bool, // a request is in flight
	incomplete:  bool, // server told us to re-ask as the word grows
	import_mode: bool, // items are import path segments (importcomp.odin)
}

Sig_Help :: struct {
	open:        bool,
	label:       string, // owned; active signature's label
	param_start: int,    // byte range in label to highlight (start == end: none)
	param_end:   int,
	req_id:      int,
}

// --- Shared helpers ------------------------------------------------------------

// Start of the identifier immediately before p (p itself if none).
@(private = "file")
word_start_before :: proc(b: ^Buffer, p: Pos) -> Pos {
	s := b.line_str(p.line)
	col := p.col
	for col > 0 {
		r, n := utf8.decode_last_rune(s[:col])
		if char_class(r) != 1 {
			break
		}
		col -= n
	}
	return Pos{p.line, col}
}

@(private = "file")
completion_items_clear :: proc(c: ^Completion) {
	for &it in c.items {
		delete(it.label)
		delete(it.insert)
		delete(it.detail)
		for e in it.extra {
			delete(e.text)
		}
		delete(it.extra)
	}
	clear(&c.items)
	clear(&c.visible)
}

completion_destroy :: proc(c: ^Completion) {
	completion_items_clear(c)
	delete(c.items)
	delete(c.visible)
}

// Kind → (gutter letter, face). LSP CompletionItemKind numbering.
@(private = "file")
comp_kind_face :: proc(kind: int) -> (rune, Face) {
	switch kind {
	case 2, 3, 4: // method, function, constructor
		return 'f', .Function
	case 5, 10: // field, property
		return '.', .Key
	case 7, 8, 22, 25: // class, interface, struct, type parameter
		return 't', .Type
	case 13, 20, 21, 12: // enum, enum member, constant, value
		return 'c', .Constant
	case 14: // keyword
		return 'k', .Keyword
	case 9, 17, 19: // module, file, folder
		return 'M', .Directive
	}
	return 'v', .Text
}

// Resolve LSP snippet syntax to plain text: "${1:placeholder}" keeps the
// placeholder, "$0"/"$1" vanish. Also reports where the caret should land —
// [sel_start, sel_end) selects the lowest-numbered placeholder (so the first
// argument of a method call ends up selected, ready to be typed over), or
// the $0 exit point. sel_start == -1: no snippet stops, caret goes to the end.
@(private = "file")
strip_snippet :: proc(s: string) -> (out: string, sel_start, sel_end: int) {
	sel_start = -1
	sel_end = -1
	if !strings.contains_rune(s, '$') {
		// Copy even the no-op case: the caller frees the completion item
		// (completion_close) before the returned text reaches the buffer.
		return strings.clone(s, context.temp_allocator), -1, -1
	}
	sb := strings.builder_make(context.temp_allocator)
	best_n := max(int)
	exit_pos := -1
	i := 0
	for i < len(s) {
		if s[i] != '$' {
			strings.write_byte(&sb, s[i])
			i += 1
			continue
		}
		i += 1
		if i < len(s) && s[i] == '{' {
			// ${n:placeholder} → placeholder
			i += 1
			n := 0
			for i < len(s) && (s[i] >= '0' && s[i] <= '9') {
				n = n*10 + int(s[i]-'0')
				i += 1
			}
			if i < len(s) && s[i] == ':' {
				i += 1
			}
			start := len(sb.buf)
			depth := 1
			for i < len(s) && depth > 0 {
				if s[i] == '{' {
					depth += 1
				} else if s[i] == '}' {
					depth -= 1
					if depth == 0 {
						i += 1
						break
					}
				}
				strings.write_byte(&sb, s[i])
				i += 1
			}
			if n < best_n {
				best_n = n
				sel_start = start
				sel_end = len(sb.buf)
			}
		} else if i < len(s) && s[i] >= '0' && s[i] <= '9' {
			n := 0
			for i < len(s) && s[i] >= '0' && s[i] <= '9' {
				n = n*10 + int(s[i]-'0')
				i += 1
			}
			pos := len(sb.buf)
			if n == 0 {
				exit_pos = pos
			} else if n < best_n {
				best_n = n
				sel_start = pos
				sel_end = pos
			}
		} else {
			strings.write_byte(&sb, '$') // literal dollar
		}
	}
	out = strings.to_string(sb)
	if sel_start < 0 && exit_pos >= 0 {
		sel_start = exit_pos
		sel_end = exit_pos
	}
	return
}

// --- Completion ------------------------------------------------------------------

impl App {
	completion_close :: proc() {
		completion.open = false
		completion.requested = false
		completion.import_mode = false
		completion_items_clear(&completion)
	}

	// The typed prefix being completed ("" if the anchor went stale).
	completion_prefix :: proc() -> string {
		p := self.primary_cursor().head
		a := completion.anchor
		if p.line != a.line || p.col < a.col {
			return ""
		}
		return strings.clone(buf.line_str(a.line)[a.col:p.col], context.temp_allocator)
	}

	// Ask the server for completions at the primary cursor.
	completion_trigger :: proc() {
		if !self.lsp_ready_quiet() {
			return
		}
		p := self.primary_cursor().head
		completion.anchor = word_start_before(&buf, p)
		completion.requested = true
		completion.req_id = lsp_request(&lsp, .Completion, "textDocument/completion", self.lsp_position_params(p))
	}

	// Re-rank items against the current prefix.
	completion_filter :: proc() {
		c := &completion
		prefix := self.completion_prefix()
		clear(&c.visible)
		ms := make([dynamic]int, context.temp_allocator)
		for &it, i in c.items {
			s, ok := fuzzy_match(prefix, it.label, 0, &ms)
			if !ok {
				continue
			}
			it.score = s
			append(&c.visible, i)
		}
		if len(prefix) > 0 {
			// Insertion sort by score, stable so server order breaks ties.
			for i in 1 ..< len(c.visible) {
				j := i
				for j > 0 && c.items[c.visible[j]].score > c.items[c.visible[j-1]].score {
					c.visible[j], c.visible[j-1] = c.visible[j-1], c.visible[j]
					j -= 1
				}
			}
		}
		c.sel = 0
		c.scroll = 0
		c.open = len(c.visible) > 0
	}

	// Runs after every text insertion (from main's TEXT_INPUT).
	completion_after_insert :: proc(text: string) {
		last, _ := utf8.decode_last_rune(text)
		// Inside an import string the popup offers path segments instead of
		// server symbols (importcomp.odin).
		if _, _, in_import := self.import_string_at(self.primary_cursor().head); in_import {
			switch {
			case last == '"' || last == ':' || last == '/':
				self.completion_trigger_import()
			case char_class(last) == 1:
				if completion.open && completion.import_mode {
					self.completion_filter()
				} else {
					self.completion_trigger_import()
				}
			case:
				self.completion_close()
			}
			return
		}
		switch {
		case last == '.':
			self.completion_close()
			self.completion_trigger()
		case char_class(last) == 1:
			if completion.open || completion.requested {
				if completion.incomplete {
					self.completion_trigger()
				} else {
					self.completion_filter()
				}
			} else if !('0' <= last && last <= '9') {
				// Fresh popup on identifier chars, but not bare numbers.
				self.completion_trigger()
			}
		case:
			self.completion_close()
		}
	}

	completion_after_backspace :: proc() {
		if !completion.open && !completion.requested {
			return
		}
		p := self.primary_cursor().head
		a := completion.anchor
		if p.line != a.line || p.col < a.col {
			self.completion_close()
			return
		}
		self.completion_filter()
	}

	completion_move :: proc(d: int) {
		c := &completion
		n := len(c.visible)
		if n == 0 {
			return
		}
		if d == -1 || d == 1 {
			c.sel = (c.sel + d + n) % n
		} else {
			c.sel = clamp(c.sel+d, 0, n-1)
		}
	}

	// Insert the selected item at every cursor, replacing the typed prefix.
	// Snippet inserts (methods) resolve to plain text with the first argument
	// placeholder left selected, ready to be typed over.
	completion_accept :: proc() {
		c := &completion
		if c.sel >= len(c.visible) {
			self.completion_close()
			return
		}
		it := &c.items[c.visible[c.sel]]
		was_import := c.import_mode
		import_anchor := c.anchor
		text, ss, se := strip_snippet(it.insert if len(it.insert) > 0 else it.label)
		// Snapshot the companion edits (auto-import): the close below frees
		// the item they live in.
		extras := make([]Extra_Edit, len(it.extra), context.temp_allocator)
		for e, i in it.extra {
			extras[i] = e
			extras[i].text = strings.clone(e.text, context.temp_allocator)
		}
		edits := make([dynamic]Edit, context.temp_allocator)
		for cur in cursors {
			r := cursor_range(cur)
			start := word_start_before(&buf, r.start)
			// Import segments can contain '-' etc.; replace from the segment
			// start the import trigger recorded, not the word boundary.
			if was_import && r.start.line == import_anchor.line && import_anchor.col <= r.start.col {
				start = import_anchor
			}
			append(&edits, Edit{range = {start, r.end}, text = text})
		}
		self.completion_close()
		self.sighelp_close()
		self.apply_and_place(edits[:], false)
		if ss >= 0 && !strings.contains_rune(text, '\n') {
			// Carets sit at each insertion's end; walk them back onto the
			// placeholder (same line, so plain byte arithmetic).
			tail := len(text) - se
			for &cur in cursors {
				end_col := cur.head.col
				cur.head = buf.clamp_pos(Pos{cur.head.line, end_col - tail})
				cur.anchor = buf.clamp_pos(Pos{cur.head.line, end_col - tail - (se - ss)})
			}
			self.blink_reset()
			// The selected placeholder is usually a call argument.
			self.sighelp_trigger()
		}
		// additionalTextEdits last (typically an import line far above the
		// insertion); cursors ride across each edit so the caret stays put.
		for e in extras {
			r := Range{
				buf_pos_from_utf16(&buf, e.line, e.char),
				buf_pos_from_utf16(&buf, e.eline, e.echar),
			}
			nr := buf.commit([]Edit{{range = r, text = e.text}}, cursors[:])
			if len(nr) == 0 {
				continue
			}
			for &cur in cursors {
				if !pos_less(cur.head, r.end) {
					cur.head = transform_pos(cur.head, r, nr[0].end)
				}
				if !pos_less(cur.anchor, r.end) {
					cur.anchor = transform_pos(cur.anchor, r, nr[0].end)
				}
			}
		}
		// Accepting a collection ("core:") descends straight into it —
		// regardless of whether the item came from the import lister or the
		// server, so the follow-up list never needs a manual retype.
		if strings.has_suffix(text, ":") || strings.has_suffix(text, "/") {
			if _, _, in_import := self.import_string_at(self.primary_cursor().head); in_import {
				self.completion_trigger_import()
			}
		}
	}

	completion_draw :: proc(r: ^Renderer, width, height: f32) {
		c := &completion
		if !c.open || len(c.visible) == 0 {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w

		if c.sel < c.scroll {
			c.scroll = c.sel
		}
		if c.sel >= c.scroll+COMPLETION_VISIBLE {
			c.scroll = c.sel - COMPLETION_VISIBLE + 1
		}
		vis := min(len(c.visible), COMPLETION_VISIBLE)

		prefix := self.completion_prefix()
		ms := make([dynamic]int, context.temp_allocator)

		label_cells := 8
		detail_cells := 0
		for vi in 0 ..< vis {
			it := &c.items[c.visible[c.scroll+vi]]
			label_cells = max(label_cells, min(strings.rune_count(it.label), 40))
			detail_cells = max(detail_cells, min(strings.rune_count(it.detail), 36))
		}
		pad := cell_w * 0.75
		w := f32(2+label_cells)*cell_w + (f32(detail_cells)*cell_w + cell_w*2 if detail_cells > 0 else 0) + pad*2
		h := f32(vis)*line_h + pad*0.5

		ax := gutter_px + f32(visual_col(&buf, c.anchor.line, c.anchor.col))*cell_w - scroll_x
		ay := text_top + f32(c.anchor.line+1)*line_h - scroll_y + 1
		ax = clamp(ax, sidebar_px, max(sidebar_px, width-w))
		if ay+h > height-status_h {
			ay = text_top + f32(c.anchor.line)*line_h - scroll_y - h - 1
		}
		ay = max(ay, 0)

		push_rect(r, ax-1, ay-1, w+2, h+2, color_alpha(theme.gutter_fg, 0.8))
		push_rect(r, ax, ay, w, h, theme.status_bg)

		for vi in 0 ..< vis {
			i := c.scroll + vi
			it := &c.items[c.visible[i]]
			y := ay + pad*0.25 + f32(vi)*line_h
			if i == c.sel {
				push_rect(r, ax, y, w, line_h, theme.selection)
			}
			baseline := y + r.ascent

			kch, kface := comp_kind_face(it.kind)
			push_glyph(r, ax+pad, baseline, kch, theme.faces[kface])

			// Label, matched chars in accent.
			clear(&ms)
			_, _ = fuzzy_match(prefix, it.label, 0, &ms)
			mi := 0
			x := ax + pad + cell_w*2
			n := 0
			for ch, off in it.label {
				if n >= label_cells {
					push_glyph(r, x, baseline, '…', theme.status_dim)
					break
				}
				for mi < len(ms) && ms[mi] < off {
					mi += 1
				}
				color := theme.fg
				if mi < len(ms) && ms[mi] == off {
					color = theme.faces[.Function]
				}
				push_glyph(r, x, baseline, ch, color)
				x += cell_w
				n += 1
			}

			if detail_cells > 0 && len(it.detail) > 0 {
				x = ax + w - pad - f32(min(strings.rune_count(it.detail), detail_cells))*cell_w
				n = 0
				for ch in it.detail {
					if n >= detail_cells {
						break
					}
					push_glyph(r, x, baseline, ch, theme.status_dim)
					x += cell_w
					n += 1
				}
			}
		}
	}
}

lsp_on_completion :: proc(app: ^App, result: json.Value, id: int) {
	c := &app.completion
	if !c.requested || id != c.req_id {
		return // stale
	}
	c.requested = false
	completion_items_clear(c)

	items := jarr(result)
	if items == nil {
		items = jarr(jget(result, "items"))
		inc, _ := jget(result, "isIncomplete").(json.Boolean)
		c.incomplete = inc
	} else {
		c.incomplete = false
	}
	for v in items {
		if len(c.items) >= COMPLETION_MAX_ITEMS {
			break
		}
		insert := jstr(jget(v, "insertText"))
		if te := jget(v, "textEdit"); te != nil {
			insert = jstr(jget(te, "newText"))
		}
		detail := jstr(jget(v, "detail"))
		if detail == "" {
			// ols puts the type in the documentation markdown; the first
			// non-fence line ("Foo.name: string") makes a fine detail.
			doc := jstr(jget(jget(v, "documentation"), "value"))
			for line in strings.split_lines_iterator(&doc) {
				if len(line) == 0 || strings.has_prefix(line, "```") {
					continue
				}
				detail = line
				break
			}
		}
		extra: []Extra_Edit
		if ae := jarr(jget(v, "additionalTextEdits")); len(ae) > 0 {
			ex := make([dynamic]Extra_Edit, 0, len(ae))
			for ev in ae {
				r := jget(ev, "range")
				s := jget(r, "start")
				e := jget(r, "end")
				append(&ex, Extra_Edit{
					line  = jint(jget(s, "line")),
					char  = jint(jget(s, "character")),
					eline = jint(jget(e, "line")),
					echar = jint(jget(e, "character")),
					text  = strings.clone(jstr(jget(ev, "newText"))),
				})
			}
			extra = ex[:]
		}
		append(&c.items, Comp_Item{
			label  = strings.clone(jstr(jget(v, "label"))),
			insert = strings.clone(insert),
			detail = strings.clone(detail),
			kind   = jint(jget(v, "kind")),
			extra  = extra,
		})
	}
	app.completion_filter()
}

// --- Signature help -----------------------------------------------------------------

impl App {
	sighelp_close :: proc() {
		sighelp.open = false
		delete(sighelp.label)
		sighelp.label = ""
	}

	sighelp_trigger :: proc() {
		if !self.lsp_ready_quiet() {
			return
		}
		sighelp.req_id = lsp_request(&lsp, .Sig_Help, "textDocument/signatureHelp",
			self.lsp_position_params(self.primary_cursor().head))
	}

	// Runs after every text insertion.
	sighelp_after_insert :: proc(text: string) {
		last, _ := utf8.decode_last_rune(text)
		switch {
		case last == '(' || last == ',':
			self.sighelp_trigger()
		case last == ')':
			if sighelp.open {
				self.sighelp_trigger() // server says null when we left the call
			}
		case sighelp.open:
			self.sighelp_trigger() // keep the active parameter tracking
		}
	}

	sighelp_draw :: proc(r: ^Renderer, width, height: f32) {
		if !sighelp.open || len(sighelp.label) == 0 {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w
		label := sighelp.label

		max_cells := min(strings.rune_count(label), int((width-sidebar_px)/cell_w)-6)
		max_cells = max(max_cells, 8)
		pad := cell_w
		w := f32(max_cells)*cell_w + pad*2
		h := line_h + pad*0.5

		p := self.primary_cursor().head
		ax := gutter_px + f32(visual_col(&buf, p.line, p.col))*cell_w - scroll_x - pad
		ay := text_top + f32(p.line)*line_h - scroll_y - h - 2
		ax = clamp(ax, sidebar_px, max(sidebar_px, width-w))
		if ay < tabbar_h {
			ay = text_top + f32(p.line+1)*line_h - scroll_y + 2
		}

		push_rect(r, ax-1, ay-1, w+2, h+2, color_alpha(theme.gutter_fg, 0.8))
		push_rect(r, ax, ay, w, h, theme.status_bg)

		// Window the text so the active parameter stays on screen.
		offs := make([dynamic]int, context.temp_allocator)
		for i := 0; i < len(label); {
			append(&offs, i)
			_, n := utf8.decode_rune(label[i:])
			i += n
		}
		start := 0
		if sighelp.param_end > sighelp.param_start {
			pr := 0
			for o, i in offs {
				if o >= sighelp.param_end {
					break
				}
				pr = i
			}
			if pr >= max_cells-2 {
				start = pr - max_cells + 8
			}
		}
		start = clamp(start, 0, max(0, len(offs)-1))

		baseline := ay + pad*0.25 + r.ascent
		x := ax + pad
		n := 0
		if start > 0 {
			push_glyph(r, x, baseline, '…', theme.status_dim)
			x += cell_w
			n += 1
		}
		for ri in start ..< len(offs) {
			if n >= max_cells {
				push_glyph(r, x, baseline, '…', theme.status_dim)
				break
			}
			off := offs[ri]
			ch, _ := utf8.decode_rune(label[off:])
			in_param := off >= sighelp.param_start && off < sighelp.param_end
			if in_param {
				push_rect(r, x, ay+pad*0.25, cell_w, line_h, theme.selection)
			}
			push_glyph(r, x, baseline, ch, theme.fg if in_param else theme.status_fg)
			x += cell_w
			n += 1
		}
	}
}

lsp_on_sighelp :: proc(app: ^App, result: json.Value, id: int) {
	s := &app.sighelp
	if id != s.req_id {
		return
	}
	sigs := jarr(jget(result, "signatures"))
	if len(sigs) == 0 {
		app.sighelp_close()
		return
	}
	asig := clamp(jint(jget(result, "activeSignature")), 0, len(sigs)-1)
	sig := sigs[asig]
	label := jstr(jget(sig, "label"))
	if len(label) == 0 {
		app.sighelp_close()
		return
	}

	// Active parameter → byte range in the label.
	ps, pe := 0, 0
	params := jarr(jget(sig, "parameters"))
	if len(params) > 0 {
		ap := jget(sig, "activeParameter")
		if ap == nil {
			ap = jget(result, "activeParameter")
		}
		pi := clamp(jint(ap), 0, len(params)-1)
		pl := jget(params[pi], "label")
		if plr, is_arr := pl.(json.Array); is_arr && len(plr) == 2 {
			ps = clamp(jint(plr[0]), 0, len(label))
			pe = clamp(jint(plr[1]), ps, len(label))
		} else if pls, is_str := pl.(json.String); is_str && len(pls) > 0 {
			// Search after the opening paren so a param named like the proc
			// doesn't match the name.
			from := max(strings.index_byte(label, '('), 0)
			if idx := strings.index(label[from:], pls); idx >= 0 {
				ps = from + idx
				pe = ps + len(pls)
			}
		}
	}

	delete(s.label)
	s.label = strings.clone(label)
	s.param_start = ps
	s.param_end = pe
	s.open = true
}
