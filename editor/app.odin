// medit — editor state and actions.
//
// Every editing action builds a batch of edits (one per cursor) and pushes
// it through Buffer.commit. The app layer knows pixels only through the
// metrics the renderer exposes; SDL specifics (events, clipboard) stay in
// main.odin.
package medit

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

OVERSCROLL_LINES :: 4

// UI list rows (sidebar, palette) in line_h units — roomier than text lines.
UI_ROW_SCALE :: 1.55

// Tab display width; a setting, adjustable from the command palette.
// Indentation is always tab characters — this is only how wide they render.
tab_w: int = 2

App :: struct {
	// The active document's state; stashed into docs[active] on tab switch
	// (see tabs.odin).
	buf:                Buffer,
	hl:                 Highlight,
	cursors:            [dynamic]Cursor,
	primary:            int, // index of the most recently active cursor

	scroll_x, scroll_y: f32, // pixels

	// Selection history for ctrl+u (cursor undo).

	cursor_undo:        [dynamic][]Cursor,

	preview:            bool, // this document is the transient palette-preview tab

	docs:               [dynamic]Doc, // every open document; docs[active] is stale (see tabs.odin)
	active:             int,

	pending_close:      int, // tab awaiting a discard-changes confirmation; -1 = none
	pending_quit:       bool, // window close was refused once over unsaved changes

	tab_scroll:         f32, // tab bar horizontal scroll (pixels)
	tab_follow:         bool, // scroll the active tab into view on the next draw
	tab_rects:          [dynamic][2]f32, // per-tab [x0, x1] from the last draw (hit testing)

	// Window control buttons in the custom title bar: {cx, cy, radius} each,
	// and where the tab strip starts (from the last draw).

	win_close:          [4]f32, // the top-right window × (x0, y0, x1, y1)
	tabs_x0:            f32, // where the tab strip starts

	resizing:           int, // 0 none, 1 sidebar border drag, 2 panel top-edge drag
	edge_hover:         int, // same values; the edge currently under the mouse

	theme:              Theme,

	sidebar:            Sidebar,
	palette:            Palette,
	lsp:                Lsp,
	completion:         Completion,
	sighelp:            Sig_Help,
	retitle:            bool, // buffer path changed; main should refresh the window title
	want_follow:        bool, // something moved the cursor; main should scroll to it
	want_center:        bool, // ...and it was a jump: land it mid-view, not at an edge
	zoom_req:           Zoom_Req, // font-size change for main to apply (owns the renderer)

	// Hover tooltip (LSP), driven by mouse dwell.

	hover_state:        Hover_State,
	hover_pos:          Pos,
	hover_text:         string, // owned
	hover_req_id:       int,
	hover_armed:        bool, // mouse has moved since the last request/hide
	mouse_x, mouse_y:   f32, // last mouse position (framebuffer pixels)
	mouse_moved_ms:     u64,

	// View geometry, updated every draw (pixels).

	view_w, view_h:     f32, // text viewport (excludes sidebar, gutter, tab bar and status bar)
	sidebar_px:         f32,
	gutter_px:          f32, // left edge of the text area (includes sidebar_px)
	tabbar_h:           f32, // top edge of the text area
	status_h:           f32,

	now_ms:             u64,
	blink_start:        u64,
	focused:            bool, // window has keyboard focus (main tracks SDL focus events)

	recent_dirs:        [dynamic]string, // owned; most recent workspace first

	odin_root_dir:      string, // owned; resolved lazily for import completion
	odin_root_done:     bool,

	// Diagnostics (problems.odin): store + collapsible panel state.
	// Project tasks (ctrl+r) and their output panel (tasks.odin).

	task:               Task_State,

	// Debugging (dap.odin): the adapter session and the breakpoints, which
	// outlive sessions (set them first, debug later).

	dap:                Dap,
	breakpoints:        [dynamic]Breakpoint,

	problems:           [dynamic]Diagnostic,
	problems_open:      bool,
	problems_scroll:    f32, // first visible row (fractional while wheeling)
	problems_h:         f32, // panel height from the last draw (0: closed)
	problems_top:       f32, // panel top edge (hit testing)
	p_rows_y:           f32, // first row's top edge
	p_row_h:            f32,
	p_row0:             int, // first visible row index

	// Format-on-save (toggle: "File: Toggle Format on Save").

	format_on_save:     bool,
	// Show struct fields in the document outline ("Settings: Toggle Outline Fields").

	outline_fields:     bool,
	fmt_req:            int, // pending format request id (0: none)
	fmt_path:           string, // owned; document the pending format belongs to
	fmt_deadline:       u64, // save unformatted when the reply misses this

	// Mouse drag state.

	selecting:          bool,
	select_word:        bool,
	select_origin:      Range, // word the drag started on (word mode)

	// Column (alt+drag) selection state.

	col_select:         bool,
	col_origin_line:    int,
	col_origin_vis:     int,
	col_base:           [dynamic]Cursor, // cursors present when the gesture started

	status_msg:         string,
	status_msg_time:    u64,
}

Zoom_Req :: enum {
	None,
	In,
	Out,
	Reset,
}

Move :: enum {
	Left,
	Right,
	Up,
	Down,
	Word_Left,
	Word_Right,
	Line_Start, // smart home
	Line_End,
	Doc_Start,
	Doc_End,
}

app_init :: proc(app: ^App, path: string) {
	app.theme = theme_default()
	app.focused = true
	app.format_on_save = true
	b: Buffer
	lang := Lang.Plain
	if path != "" {
		ok: bool
		if b, ok = buffer_load(path); !ok {
			b = buffer_make(path) // new file at that path
		}
		lang = lang_from_path(path)
	} else {
		b = buffer_make()
	}
	app.doc_append(b, lang)
	app.task.drag_from = -1
	settings_load(app) // before the tree first loads: [files] hide filters it
	sidebar_init(&app.sidebar)
}

app_destroy :: proc(app: ^App) {
	for &d, i in app.docs {
		if i != app.active {
			doc_destroy(&d)
		}
	}
	delete(app.docs)
	delete(app.tab_rects)
	live := app.live_doc()
	doc_destroy(&live)
	sidebar_destroy(&app.sidebar)
	palette_destroy(&app.palette)
	lsp_stop(&app.lsp)
	completion_destroy(&app.completion)
	delete(app.sighelp.label)
	delete(app.hover_text)
	delete(app.col_base)
	delete(app.status_msg)
	delete(app.fmt_path)
	for d in app.recent_dirs {
		delete(d)
	}
	delete(app.recent_dirs)
	delete(app.odin_root_dir)
	problems_destroy(app)
	tasks_destroy(&app.task)
	dap_destroy(&app.dap)
	for b in app.breakpoints {
		delete(b.path)
	}
	delete(app.breakpoints)
}

impl App {
	blink_reset :: proc() {
		blink_start = now_ms
	}

	// A caret blinks only where keystrokes actually land; pass whether this
	// caret's widget has input. Carets elsewhere (unfocused window, editor
	// behind the palette) hold steady instead.
	caret_on :: proc(has_input: bool) -> bool {
		if !focused || !has_input {
			return true
		}
		return (now_ms - blink_start) / 530 % 2 == 0
	}

	set_status :: proc(msg: string) {
		delete(status_msg)
		status_msg = strings.clone(msg)
		status_msg_time = now_ms
	}

	primary_cursor :: proc() -> ^Cursor {
		if primary >= len(cursors) {
			primary = len(cursors) - 1
		}
		return &cursors[primary]
	}

	normalize_cursors :: proc() {
		head := self.primary_cursor().head
		cursors_normalize(&cursors)
		// Keep primary pointing at the cursor that owns the old head.
		primary = len(cursors) - 1
		for c, i in cursors {
			r := cursor_range(c)
			if !pos_less(head, r.start) && !pos_less(r.end, head) {
				primary = i
				break
			}
		}
	}
}

// --- Visual columns (tabs) ---------------------------------------------------

// Visual column of a byte offset within a line.
visual_col :: proc(b: ^Buffer, line: int, col: int) -> int {
	s := b.line_str(line)
	vis := 0
	for i := 0; i < min(col, len(s)); {
		if s[i] == '\t' {
			vis = (vis / tab_w + 1) * tab_w
			i += 1
		} else {
			_, n := utf8.decode_rune(s[i:])
			i += n
			vis += 1
		}
	}
	return vis
}

// Byte offset within a line for a target visual column (clamped to line end).
col_from_visual :: proc(b: ^Buffer, line: int, target_vis: int) -> int {
	s := b.line_str(line)
	vis := 0
	i := 0
	for i < len(s) && vis < target_vis {
		if s[i] == '\t' {
			vis = (vis / tab_w + 1) * tab_w
			i += 1
		} else {
			_, n := utf8.decode_rune(s[i:])
			i += n
			vis += 1
		}
	}
	return i
}

// --- Movement ----------------------------------------------------------------

impl App {
	move_cursors :: proc(m: Move, extend: bool) {
		b := &buf
		for &c in cursors {
			p := c.head
			keep_goal := false
			switch m {
			case .Left:
				if !extend && cursor_has_selection(c) {
					p = cursor_range(c).start
				} else {
					p = b.prev_pos(p)
				}
			case .Right:
				if !extend && cursor_has_selection(c) {
					p = cursor_range(c).end
				} else {
					p = b.next_pos(p)
				}
			case .Word_Left:
				p = b.word_left(p)
			case .Word_Right:
				p = b.word_right(p)
			case .Up, .Down:
				keep_goal = true
				if c.goal_col < 0 {
					c.goal_col = visual_col(b, p.line, p.col)
				}
				target := p.line - 1 if m == .Up else p.line + 1
				if target < 0 {
					p = Pos{0, 0}
				} else if target >= b.line_count() {
					p = b.end_pos()
				} else {
					p = Pos{target, col_from_visual(b, target, c.goal_col)}
				}
			case .Line_Start:
				// Smart home: first non-whitespace, or column 0 if already there.
				s := b.line_str(p.line)
				first := 0
				for first < len(s) && (s[first] == ' ' || s[first] == '\t') {
					first += 1
				}
				p.col = 0 if p.col == first else first
			case .Line_End:
				p.col = b.line_len(p.line)
			case .Doc_Start:
				p = Pos{0, 0}
			case .Doc_End:
				p = b.end_pos()
			}
			c.head = b.clamp_pos(p)
			if !extend {
				c.anchor = c.head
			}
			if !keep_goal {
				c.goal_col = -1
			}
		}
		self.normalize_cursors()
		self.blink_reset()
	}

	// Page movement needs the page size in lines, so it gets its own proc.
	move_page :: proc(up: bool, extend: bool, lines_per_page: int) {
		b := &buf
		for &c in cursors {
			if c.goal_col < 0 {
				c.goal_col = visual_col(b, c.head.line, c.head.col)
			}
			target := c.head.line - lines_per_page if up else c.head.line + lines_per_page
			target = clamp(target, 0, b.line_count() - 1)
			c.head = b.clamp_pos(Pos{target, col_from_visual(b, target, c.goal_col)})
			if !extend {
				c.anchor = c.head
			}
		}
		self.normalize_cursors()
		self.blink_reset()
	}

	// Snapshot the cursor set so ctrl+u can restore it.
	push_cursor_undo :: proc() {
		snap := make([]Cursor, len(cursors))
		copy(snap, cursors[:])
		append(&cursor_undo, snap)
		if len(cursor_undo) > 64 {
			delete(cursor_undo[0])
			ordered_remove(&cursor_undo, 0)
		}
	}

	clear_cursor_undo :: proc() {
		for s in cursor_undo {
			delete(s)
		}
		clear(&cursor_undo)
	}

	// ctrl+u: restore the cursor set from before the last selection change.
	undo_selection :: proc() {
		if len(cursor_undo) == 0 {
			return
		}
		snap := pop(&cursor_undo)
		clear(&cursors)
		for c in snap {
			append(
				&cursors,
				Cursor {
					head     = buf.clamp_pos(c.head),
					anchor   = buf.clamp_pos(c.anchor),
					goal_col = -1,
				},
			)
		}
		delete(snap)
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}

	select_all :: proc() {
		self.push_cursor_undo()
		clear(&cursors)
		append(&cursors, Cursor{head = buf.end_pos(), anchor = Pos{0, 0}, goal_col = -1})
		primary = 0
	}

	// Esc: multiple cursors collapse to a single caret at the most recently
	// placed one; a lone selection collapses to its head.
	escape :: proc() {
		if len(cursors) > 1 {
			self.push_cursor_undo()
			p := self.primary_cursor().head
			clear(&cursors)
			append(&cursors, cursor_at(p))
			primary = 0
		} else if cursor_has_selection(cursors[0]) {
			self.push_cursor_undo()
			c := &cursors[0]
			c.anchor = c.head
		}
		self.blink_reset()
	}

	add_cursor_line :: proc(below: bool) {
		b := &buf
		// Clone from the topmost (above) or bottommost (below) cursor.
		src := 0
		for c, i in cursors {
			if below && pos_less(cursors[src].head, c.head) {
				src = i
			}
			if !below && pos_less(c.head, cursors[src].head) {
				src = i
			}
		}
		c := cursors[src]
		target := c.head.line + 1 if below else c.head.line - 1
		if target < 0 || target >= b.line_count() {
			return
		}
		self.push_cursor_undo()
		goal := c.goal_col >= 0 ? c.goal_col : visual_col(b, c.head.line, c.head.col)
		p := Pos{target, col_from_visual(b, target, goal)}
		append(&cursors, Cursor{head = p, anchor = p, goal_col = goal})
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}
}

// --- Offset mapping (for search / ctrl+d) ------------------------------------

impl Buffer {
	offset_from_pos :: proc(p: Pos) -> int {
		off := 0
		for i in 0 ..< p.line {
			off += len(lines[i]) + 1
		}
		return off + p.col
	}

	pos_from_offset :: proc(off: int) -> Pos {
		remaining := off
		for line, i in lines {
			if remaining <= len(line) {
				return Pos{i, remaining}
			}
			remaining -= len(line) + 1
		}
		return self.end_pos()
	}
}

impl App {
	// ctrl+d: select the word under the cursor, or add a cursor at the next
	// occurrence of the primary selection.
	select_next_match :: proc() {
		b := &buf
		pc := self.primary_cursor()
		if !cursor_has_selection(pc^) {
			r := b.word_range_at(pc.head)
			if range_empty(r) {
				return
			}
			self.push_cursor_undo()
			pc.anchor = r.start
			pc.head = r.end
			self.blink_reset()
			return
		}

		needle := b.range_text(cursor_range(pc^), context.temp_allocator)
		if len(needle) == 0 {
			return
		}
		text := b.text(context.temp_allocator)

		// Search after the last cursor, wrapping around once.
		start := 0
		for c in cursors {
			start = max(start, b.offset_from_pos(cursor_range(c).end))
		}
		idx := strings.index(text[start:], needle)
		found := -1
		if idx >= 0 {
			found = start + idx
		} else if idx = strings.index(text, needle); idx >= 0 {
			found = idx
		}
		if found < 0 {
			return
		}
		s := b.pos_from_offset(found)
		e := b.pos_from_offset(found + len(needle))
		// Already selected by some cursor? Then we're done (all occurrences taken).
		for c in cursors {
			r := cursor_range(c)
			if pos_eq(r.start, s) && pos_eq(r.end, e) {
				return
			}
		}
		self.push_cursor_undo()
		append(&cursors, Cursor{head = e, anchor = s, goal_col = -1})
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}
}

// --- Editing -----------------------------------------------------------------

impl App {
	// Replace every cursor's selection with text; carets end up after it.
	insert_text :: proc(text: string) {
		edits := make([]Edit, len(cursors), context.temp_allocator)
		for c, i in cursors {
			edits[i] = Edit {
				range = cursor_range(c),
				text  = text,
			}
		}
		self.apply_and_place(edits, false)
	}

	// Enter: newline + copy the current line's leading whitespace. Right
	// after an opening bracket the new line goes one level deeper, and a
	// matching closer sitting at the caret drops onto its own line at the
	// original level (the caret ends up on the indented middle line).
	insert_newline :: proc() {
		edits := make([]Edit, len(cursors), context.temp_allocator)
		mid := make([]bool, len(cursors), context.temp_allocator)
		for c, i in cursors {
			r := cursor_range(c)
			s := buf.line_str(r.start.line)
			ws_end := 0
			for ws_end < len(s) &&
			    ws_end < r.start.col &&
			    (s[ws_end] == ' ' || s[ws_end] == '\t') {
				ws_end += 1
			}
			ws := s[:ws_end]
			opener := byte(0)
			if r.start.col > 0 && r.start.col <= len(s) {
				switch s[r.start.col - 1] {
				case '{', '(', '[':
					opener = s[r.start.col - 1]
				}
			}
			text: string
			e := buf.line_str(r.end.line)
			if opener != 0 && r.end.col < len(e) && e[r.end.col] == close_for(opener) {
				text = strings.concatenate({"\n", ws, "\t", "\n", ws}, context.temp_allocator)
				mid[i] = true
			} else if opener != 0 {
				text = strings.concatenate({"\n", ws, "\t"}, context.temp_allocator)
			} else {
				text = strings.concatenate({"\n", ws}, context.temp_allocator)
			}
			edits[i] = Edit {
				range = r,
				text  = text,
			}
		}
		new_ranges := buf.commit(edits, cursors[:])
		clear(&cursors)
		for r, i in new_ranges {
			p := r.end
			if mid[i] {
				p = Pos{r.end.line - 1, buf.line_len(r.end.line - 1)}
			}
			append(&cursors, cursor_at(p))
		}
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}

	delete_backward :: proc() {
		b := &buf
		edits := make([]Edit, len(cursors), context.temp_allocator)
		for c, i in cursors {
			r := cursor_range(c)
			if range_empty(r) {
				r.start = b.prev_pos(r.start)
				// A caret between an empty pair removes both halves.
				if r.start.line == r.end.line && r.end.col - r.start.col == 1 {
					s := b.line_str(r.end.line)
					if close := close_for(s[r.start.col]);
					   close != 0 && r.end.col < len(s) && s[r.end.col] == close {
						r.end.col += 1
					}
				}
			}
			edits[i] = Edit {
				range = r,
				text  = "",
			}
		}
		self.apply_and_place(edits, false)
	}

	delete_forward :: proc() {
		b := &buf
		edits := make([]Edit, len(cursors), context.temp_allocator)
		for c, i in cursors {
			r := cursor_range(c)
			if range_empty(r) {
				r.end = b.next_pos(r.end)
			}
			edits[i] = Edit {
				range = r,
				text  = "",
			}
		}
		self.apply_and_place(edits, false)
	}

	// Tab: indent selected lines, or insert a tab character.
	indent :: proc() {
		multiline := false
		for c in cursors {
			r := cursor_range(c)
			if r.start.line != r.end.line {
				multiline = true
			}
		}
		if !multiline {
			self.insert_text("\t")
			return
		}
		edits := make([dynamic]Edit, context.temp_allocator)
		seen_last := -1
		for c in cursors {
			r := cursor_range(c)
			for line in max(r.start.line, seen_last + 1) ..= r.end.line {
				if buf.line_len(line) > 0 {
					append(&edits, Edit{range = {{line, 0}, {line, 0}}, text = "\t"})
				}
			}
			seen_last = max(seen_last, r.end.line)
		}
		self.apply_keep_selections(edits[:])
	}

	dedent :: proc() {
		edits := make([dynamic]Edit, context.temp_allocator)
		seen_last := -1
		for c in cursors {
			r := cursor_range(c)
			for line in max(r.start.line, seen_last + 1) ..= r.end.line {
				s := buf.line_str(line)
				n := 0
				if len(s) > 0 && s[0] == '\t' {
					n = 1
				} else {
					for n < len(s) && n < tab_w && s[n] == ' ' {
						n += 1
					}
				}
				if n > 0 {
					append(&edits, Edit{range = {{line, 0}, {line, n}}, text = ""})
				}
			}
			seen_last = max(seen_last, r.end.line)
		}
		self.apply_keep_selections(edits[:])
	}

	// Apply one edit per cursor; place carets at each replacement's end
	// (select_inserted keeps the inserted text selected — used by paste-all).
	apply_and_place :: proc(edits: []Edit, select_inserted: bool) {
		if len(edits) == 0 {
			return
		}
		new_ranges := buf.commit(edits, cursors[:])
		clear(&cursors)
		for r in new_ranges {
			c := cursor_at(r.end)
			if select_inserted {
				c.anchor = r.start
			}
			append(&cursors, c)
		}
		primary = len(cursors) - 1
		self.normalize_cursors()
		self.blink_reset()
	}

	// Apply edits that don't correspond 1:1 to cursors (indent/dedent);
	// cursors are re-clamped afterwards but selections survive roughly.
	apply_keep_selections :: proc(edits: []Edit) {
		if len(edits) == 0 {
			return
		}
		saved := make([]Cursor, len(cursors), context.temp_allocator)
		copy(saved, cursors[:])
		buf.commit(edits, cursors[:])
		clear(&cursors)
		for c in saved {
			nc := c
			nc.head = buf.clamp_pos(nc.head)
			nc.anchor = buf.clamp_pos(nc.anchor)
			append(&cursors, nc)
		}
		self.normalize_cursors()
		self.blink_reset()
	}

	undo :: proc() {
		restored, ok := buf.undo(cursors[:])
		if !ok {
			return
		}
		if len(restored) > 0 {
			clear(&cursors)
			for c in restored {
				append(
					&cursors,
					Cursor {
						head     = buf.clamp_pos(c.head),
						anchor   = buf.clamp_pos(c.anchor),
						goal_col = -1,
					},
				)
			}
			primary = len(cursors) - 1
		} else {
			for &c in cursors {
				c.head = buf.clamp_pos(c.head)
				c.anchor = buf.clamp_pos(c.anchor)
			}
		}
		delete(restored)
		self.normalize_cursors()
		self.blink_reset()
	}

	redo :: proc() {
		restored, ok := buf.redo(cursors[:])
		if !ok {
			return
		}
		if len(restored) > 0 {
			clear(&cursors)
			for c in restored {
				append(
					&cursors,
					Cursor {
						head     = buf.clamp_pos(c.head),
						anchor   = buf.clamp_pos(c.anchor),
						goal_col = -1,
					},
				)
			}
			primary = len(cursors) - 1
		} else {
			for &c in cursors {
				c.head = buf.clamp_pos(c.head)
				c.anchor = buf.clamp_pos(c.anchor)
			}
		}
		delete(restored)
		self.normalize_cursors()
		self.blink_reset()
	}

	save :: proc() {
		if buf.path == "" {
			self.set_status("no file path — start medit with a filename")
			return
		}
		// With a live language server the write completes asynchronously,
		// after textDocument/formatting answers (lsp.odin).
		if format_on_save && self.format_request() {
			self.set_status("formatting…")
			return
		}
		self.save_now()
	}

	save_now :: proc() {
		if buffer_save(&buf) {
			self.set_status("saved")
			lsp_did_save(self)
			if strings.has_suffix(buf.path, "settings.ini") {
				settings_load(self) // hide globs may have changed
			}
			// The write may have created the file: let the sidebar see it.
			sidebar_refresh(&sidebar)
		} else {
			self.set_status("SAVE FAILED")
		}
	}

	// Copy: selections joined with '\n'; a cursor without a selection
	// contributes its whole line. Caller hands the result to the clipboard.
	copy_text :: proc() -> string {
		sb := strings.builder_make(context.temp_allocator)
		for c, i in cursors {
			if i > 0 {
				strings.write_byte(&sb, '\n')
			}
			r := cursor_range(c)
			if range_empty(r) {
				strings.write_string(&sb, buf.line_str(r.start.line))
			} else {
				t := buf.range_text(r, context.temp_allocator)
				strings.write_string(&sb, t)
			}
		}
		return strings.to_string(sb)
	}

	cut_text :: proc() -> string {
		text := self.copy_text()
		edits := make([]Edit, len(cursors), context.temp_allocator)
		for c, i in cursors {
			r := cursor_range(c)
			if range_empty(r) {
				// Cut the whole line including its newline.
				r = Range{{r.start.line, 0}, {r.start.line + 1, 0}}
				if r.end.line >= buf.line_count() {
					r.end = buf.end_pos()
				}
			}
			edits[i] = Edit {
				range = r,
				text  = "",
			}
		}
		self.apply_and_place(edits, false)
		return text
	}

	paste :: proc(text: string) {
		if len(text) == 0 {
			return
		}
		// Multi-cursor smart paste: N lines onto N cursors goes one line each.
		lines := strings.split(text, "\n", context.temp_allocator)
		if len(lines) == len(cursors) && len(cursors) > 1 {
			edits := make([]Edit, len(cursors), context.temp_allocator)
			for c, i in cursors {
				edits[i] = Edit {
					range = cursor_range(c),
					text  = lines[i],
				}
			}
			self.apply_and_place(edits, false)
			return
		}
		self.insert_text(text)
	}
}

// Per-language line comment prefix ("" = no line comments; toggle is a no-op).
@(private = "file")
COMMENT_PREFIX := [Lang]string {
	.Plain      = "",
	.Odin       = "//",
	.JSON       = "//", // jsonc
	.GLSL       = "//",
	.HLSL       = "//",
	.WGSL       = "//",
	.C          = "//",
	.CPP        = "//",
	.Python     = "#",
	.JS         = "//",
	.TS         = "//",
	.Rust       = "//",
	.Go         = "//",
	.Java       = "//",
	.CSharp     = "//",
	.Lua        = "--",
	.Shell      = "#",
	.PowerShell = "#",
	.Batch      = "::",
	.YAML       = "#",
	.TOML       = "#",
	.INI        = ";",
	.CSS        = "", // block comments only
	.Markdown   = "",
	.HTML       = "",
}

impl App {
	// alt+up/down: move each cursor's block of lines by one, swapping with
	// the neighbouring line. Selections ride along.
	move_lines :: proc(down: bool) {
		b := &buf

		// Disjoint line spans (cursors are sorted); adjacent spans merge so
		// they don't swap through each other.
		spans := make([dynamic][2]int, context.temp_allocator)
		for c in cursors {
			r := cursor_range(c)
			lo := r.start.line
			hi := r.end.line
			// A selection ending at column 0 doesn't claim that line.
			if hi > lo && r.end.col == 0 {
				hi -= 1
			}
			if len(spans) > 0 && lo <= spans[len(spans) - 1][1] + 1 {
				spans[len(spans) - 1][1] = max(spans[len(spans) - 1][1], hi)
			} else {
				append(&spans, [2]int{lo, hi})
			}
		}

		edits := make([dynamic]Edit, context.temp_allocator)
		moved := make([dynamic][2]int, context.temp_allocator) // spans that actually move
		for span in spans {
			lo, hi := span[0], span[1]
			if !down && lo == 0 {
				continue
			}
			if down && hi >= b.line_count() - 1 {
				continue
			}
			sb := strings.builder_make(context.temp_allocator)
			if down {
				strings.write_string(&sb, b.line_str(hi + 1))
				for line in lo ..= hi {
					strings.write_byte(&sb, '\n')
					strings.write_string(&sb, b.line_str(line))
				}
				append(
					&edits,
					Edit {
						range = {{lo, 0}, {hi + 1, b.line_len(hi + 1)}},
						text  = strings.to_string(sb),
					},
				)
			} else {
				for line in lo ..= hi {
					strings.write_string(&sb, b.line_str(line))
					strings.write_byte(&sb, '\n')
				}
				strings.write_string(&sb, b.line_str(lo - 1))
				append(
					&edits,
					Edit {
						range = {{lo - 1, 0}, {hi, b.line_len(hi)}},
						text  = strings.to_string(sb),
					},
				)
			}
			append(&moved, span)
		}
		if len(edits) == 0 {
			return
		}

		saved := make([]Cursor, len(cursors), context.temp_allocator)
		copy(saved, cursors[:])
		b.commit(edits[:], cursors[:])

		d := 1 if down else -1
		clear(&cursors)
		for c in saved {
			nc := c
			for span in moved {
				if c.head.line >= span[0] && cursor_range(c).start.line <= span[1] {
					nc.head.line += d
					nc.anchor.line += d
					break
				}
			}
			nc.head = b.clamp_pos(nc.head)
			nc.anchor = b.clamp_pos(nc.anchor)
			nc.goal_col = -1
			append(&cursors, nc)
		}
		self.normalize_cursors()
		self.blink_reset()
	}

	// ctrl+': comment the selected lines, or uncomment if they all are.
	toggle_comment :: proc() {
		prefix := COMMENT_PREFIX[hl.lang]
		if prefix == "" {
			return
		}
		b := &buf

		leading_ws :: proc(s: string) -> int {
			n := 0
			for n < len(s) && (s[n] == ' ' || s[n] == '\t') {
				n += 1
			}
			return n
		}

		// All non-blank target lines already commented?
		all_commented := true
		any_line := false
		seen_last := -1
		for c in cursors {
			r := cursor_range(c)
			for line in max(r.start.line, seen_last + 1) ..= r.end.line {
				s := b.line_str(line)
				ws := leading_ws(s)
				if ws == len(s) {
					continue // blank
				}
				any_line = true
				if !strings.has_prefix(s[ws:], prefix) {
					all_commented = false
				}
			}
			seen_last = max(seen_last, r.end.line)
		}
		if !any_line {
			return
		}

		edits := make([dynamic]Edit, context.temp_allocator)
		with_space := strings.concatenate({prefix, " "}, context.temp_allocator)
		seen_last = -1
		for c in cursors {
			r := cursor_range(c)
			for line in max(r.start.line, seen_last + 1) ..= r.end.line {
				s := b.line_str(line)
				ws := leading_ws(s)
				if ws == len(s) {
					continue
				}
				if all_commented {
					n := len(prefix)
					if ws + n < len(s) && s[ws + n] == ' ' {
						n += 1
					}
					append(&edits, Edit{range = {{line, ws}, {line, ws + n}}, text = ""})
				} else if !strings.has_prefix(s[ws:], prefix) {
					append(&edits, Edit{range = {{line, ws}, {line, ws}}, text = with_space})
				}
			}
			seen_last = max(seen_last, r.end.line)
		}
		self.apply_keep_selections(edits[:])
	}

	// ctrl+shift+d: duplicate each selection after itself; a cursor without
	// a selection duplicates its line below.
	duplicate :: proc() {
		edits := make([dynamic]Edit, context.temp_allocator)
		for c in cursors {
			r := cursor_range(c)
			if range_empty(r) {
				line := r.start.line
				end := Pos{line, buf.line_len(line)}
				text := strings.concatenate({"\n", buf.line_str(line)}, context.temp_allocator)
				append(&edits, Edit{range = {end, end}, text = text})
			} else {
				text := buf.range_text(r, context.temp_allocator)
				append(&edits, Edit{range = {r.end, r.end}, text = text})
			}
		}
		self.apply_keep_selections(edits[:])
	}

	// Select every occurrence of the primary selection (or the word under
	// the cursor) in the whole document.
	select_all_matches :: proc() {
		b := &buf
		pc := self.primary_cursor()
		if !cursor_has_selection(pc^) {
			r := b.word_range_at(pc.head)
			if range_empty(r) {
				return
			}
			pc.anchor = r.start
			pc.head = r.end
		}
		prim := cursor_range(pc^)
		needle := b.range_text(prim, context.temp_allocator)
		if len(needle) == 0 {
			return
		}
		text := b.text(context.temp_allocator)

		self.push_cursor_undo()
		clear(&cursors)
		off := 0
		for len(cursors) < 1000 {
			idx := strings.index(text[off:], needle)
			if idx < 0 {
				break
			}
			s := b.pos_from_offset(off + idx)
			e := b.pos_from_offset(off + idx + len(needle))
			append(&cursors, Cursor{head = e, anchor = s, goal_col = -1})
			if pos_eq(s, prim.start) {
				primary = len(cursors) - 1
			}
			off += idx + max(len(needle), 1)
		}
		self.normalize_cursors()
		self.blink_reset()
	}

	// Upper/lowercase every selection; selections survive.
	transform_case :: proc(upper: bool) {
		edits := make([dynamic]Edit, context.temp_allocator)
		for c in cursors {
			r := cursor_range(c)
			if range_empty(r) {
				continue
			}
			text := buf.range_text(r, context.temp_allocator)
			out :=
				strings.to_upper(text, context.temp_allocator) if upper else strings.to_lower(text, context.temp_allocator)
			append(&edits, Edit{range = r, text = out})
		}
		self.apply_keep_selections(edits[:])
	}

	// Palette: force a language (overrides the path-based guess).
	set_language :: proc(l: Lang) {
		hl.lang = l
		hl.version = buf.version - 1 // force a relex
	}

	// Save under a new path (from the system save dialog).
	save_as :: proc(path: string) {
		delete(buf.path)
		buf.path = strings.clone(path)
		self.set_language(lang_from_path(path))
		retitle = true
		self.save()
	}
}

// --- Mouse -------------------------------------------------------------------

impl App {
	// Visual (cell) column under a pixel x, unclamped.
	vis_at_pixel :: proc(px: f32, cell_w: f32) -> int {
		return max(int((px - gutter_px + scroll_x) / cell_w + 0.5), 0)
	}

	// Convert a pixel position (already in framebuffer scale) to a buffer Pos.
	pos_at_pixel :: proc(px, py: f32, cell_w, line_h: f32) -> Pos {
		line := int((py - tabbar_h + scroll_y) / line_h)
		line = clamp(line, 0, buf.line_count() - 1)
		vis := self.vis_at_pixel(px, cell_w)
		return Pos{line, col_from_visual(&buf, line, vis)}
	}

	click :: proc(p: Pos, vis: int, clicks: int, shift, alt: bool) {
		if alt {
			// Start of a possible column-selection drag: remember the cursors
			// that were already there and the anchor cell.
			self.push_cursor_undo()
			clear(&col_base)
			for c in cursors {
				append(&col_base, c)
			}
			col_select = true
			col_origin_line = p.line
			col_origin_vis = vis
			append(&cursors, cursor_at(p))
			primary = len(cursors) - 1
			self.normalize_cursors()
			selecting = true
			select_word = false
		} else if shift {
			pc := self.primary_cursor()
			pc.head = p
			pc.goal_col = -1
			selecting = true
			select_word = false
		} else if clicks >= 2 {
			r := buf.word_range_at(p)
			clear(&cursors)
			append(&cursors, Cursor{head = r.end, anchor = r.start, goal_col = -1})
			primary = 0
			selecting = true
			select_word = true
			select_origin = r
		} else {
			clear(&cursors)
			append(&cursors, cursor_at(p))
			primary = 0
			selecting = true
			select_word = false
		}
		self.blink_reset()
	}

	drag :: proc(p: Pos, vis: int) {
		if !selecting {
			return
		}
		if col_select {
			// Rebuild: pre-gesture cursors + one per line in the dragged box.
			clear(&cursors)
			for c in col_base {
				append(&cursors, c)
			}
			lo := min(col_origin_line, p.line)
			hi := max(col_origin_line, p.line)
			for line in lo ..= hi {
				a := Pos{line, col_from_visual(&buf, line, col_origin_vis)}
				h := Pos{line, col_from_visual(&buf, line, vis)}
				append(&cursors, Cursor{head = h, anchor = a, goal_col = -1})
			}
			primary = len(cursors) - 1
			self.blink_reset()
			return
		}
		pc := self.primary_cursor()
		if select_word {
			r := buf.word_range_at(p)
			if pos_less(r.start, select_origin.start) {
				pc.anchor = select_origin.end
				pc.head = r.start
			} else {
				pc.anchor = select_origin.start
				pc.head = r.end
			}
		} else {
			pc.head = p
		}
		pc.goal_col = -1
		self.blink_reset()
	}

	mouse_up :: proc() {
		if selecting {
			selecting = false
			col_select = false
			self.normalize_cursors()
		}
	}

	// Right-click: keep the selection if clicked inside it, else move the
	// cursor there; then show the context menu.
	right_click :: proc(p: Pos) {
		inside := false
		for c in cursors {
			r := cursor_range(c)
			if !pos_less(p, r.start) && !pos_less(r.end, p) {
				inside = true
				break
			}
		}
		if !inside {
			clear(&cursors)
			append(&cursors, cursor_at(p))
			primary = 0
		}
		self.open_context_editor()
	}
}

// --- Drawing -----------------------------------------------------------------

// A discreet vertical scrollbar: a thin thumb hugging the right edge of a
// view, drawn only while the content actually overflows it. Shared by the
// editor, the sidebar and the palette so they all read the same.
draw_vscrollbar :: proc(r: ^Renderer, right, top, view_h, content_h, scroll: f32, t: ^Theme) {
	if view_h <= 0 || content_h <= view_h {
		return
	}
	th := max(view_h * view_h / content_h, 24)
	ty := top + (view_h - th) * clamp(scroll / (content_h - view_h), 0, 1)
	push_rect(r, right - 5, ty, 3, th, color_alpha(t.gutter_fg, 0.4))
}

@(private = "file")
count_digits :: proc(n: int) -> int {
	d := 1
	x := n
	for x >= 10 {
		x /= 10
		d += 1
	}
	return d
}

impl App {
	ensure_cursor_visible :: proc(cell_w, line_h: f32, center := false) {
		p := self.primary_cursor().head
		y := f32(p.line) * line_h
		if palette.open {
			// Palette previews: always anchor the target a few rows below the
			// floating palette — a fixed spot the eye can stay on, never at
			// the bottom of the screen or behind the palette. (The generous
			// margin also absorbs the stored layout lagging a frame when the
			// item list grows.)
			occ_top := clamp(
				palette.ly + palette.lh - tabbar_h + line_h * 3,
				0,
				max(view_h - line_h * 3, 0),
			)
			scroll_y = y - occ_top
		} else if center && (y < scroll_y || y + line_h > scroll_y + view_h) {
			// A jump landing off-screen sits ~40% down the view: low enough
			// to keep context above the symbol, high enough to show what
			// follows it — never pinned to the bottom edge.
			scroll_y = max(0, y - view_h * 0.4)
		} else {
			if y < scroll_y {
				scroll_y = y
			}
			if y + line_h > scroll_y + view_h {
				scroll_y = y + line_h - view_h
			}
		}
		x := f32(visual_col(&buf, p.line, p.col)) * cell_w
		if x < scroll_x {
			scroll_x = max(0, x - cell_w * 4)
		}
		if x + cell_w > scroll_x + view_w {
			scroll_x = x + cell_w * 4 - view_w
		}
	}

	clamp_scroll :: proc(line_h: f32) {
		content_h := f32(buf.line_count() + OVERSCROLL_LINES) * line_h
		scroll_y = clamp(scroll_y, 0, max(0, content_h - view_h))
		scroll_x = max(scroll_x, 0)
	}

	draw :: proc(r: ^Renderer, width, height: f32) {
		highlight_update(&hl, &buf)

		line_h := r.line_h
		cell_w := r.cell_w
		status_h = line_h * 1.8
		tabbar_h = line_h * 1.4
		sidebar_px = min(sidebar_cells * cell_w, width * 0.6) if sidebar.visible else 0
		gutter_digits := count_digits(buf.line_count())
		// Two extra cells on the left make room for the breakpoint disc and
		// the debugger's stop marker next to the line numbers.
		gutter_cells := f32(gutter_digits + 5)
		gutter_px = sidebar_px + gutter_cells * cell_w
		view_w = width - gutter_px
		problems_h = 0
		if problems_open {
			problems_h =
				line_h * 1.4 + f32(clamp(len(problems), 1, PROBLEMS_VISIBLE)) * line_h * 1.25
		}
		task.h = 0
		if task.open {
			task.h = line_h*PANEL_HEAD_SCALE + f32(output_rows)*line_h*PANEL_ROW_SCALE
		}
		view_h = height - status_h - tabbar_h - problems_h - task.h

		self.clamp_scroll(line_h)

		first_line := max(0, int(scroll_y / line_h))
		last_line := min(buf.line_count() - 1, int((scroll_y + view_h) / line_h) + 1)

		// Current-line highlight (single cursor, no selection).
		if len(cursors) == 1 && !cursor_has_selection(cursors[0]) {
			y := tabbar_h + f32(cursors[0].head.line) * line_h - scroll_y
			push_rect(r, sidebar_px, y, width - sidebar_px, line_h, theme.current_line)
		}

		// The debugger's stop line.
		if dap.stop_line >= 0 && dap.stop_path == buf.path {
			y := tabbar_h + f32(dap.stop_line) * line_h - scroll_y
			push_rect(
				r,
				sidebar_px,
				y,
				width - sidebar_px,
				line_h,
				color_alpha(theme.diag_warn, 0.16),
			)
		}

		// Selections.
		for c in cursors {
			sel := cursor_range(c)
			if range_empty(sel) {
				continue
			}
			for line in max(sel.start.line, first_line) ..= min(sel.end.line, last_line) {
				s_col := sel.start.col if line == sel.start.line else 0
				e_col := sel.end.col if line == sel.end.line else buf.line_len(line)
				x0 := gutter_px + f32(visual_col(&buf, line, s_col)) * cell_w - scroll_x
				x1 := gutter_px + f32(visual_col(&buf, line, e_col)) * cell_w - scroll_x
				if line != sel.end.line {
					x1 += cell_w * 0.5 // show the selected newline
				}
				y := tabbar_h + f32(line) * line_h - scroll_y
				push_rect(r, x0, y, max(x1 - x0, 2), line_h, theme.selection)
			}
		}

		self.brackets_draw(r, first_line, last_line, cell_w, line_h)

		// Text + gutter.
		cursor_lines := make(map[int]bool, 16, context.temp_allocator)
		for c in cursors {
			cursor_lines[c.head.line] = true
		}
		for line in first_line ..= last_line {
			y := tabbar_h + f32(line) * line_h - scroll_y
			baseline := y + r.ascent + (line_h - r.line_h) * 0.5

			// Breakpoint disc and the debugger's stop marker, in the marker
			// column the gutter reserves left of the line numbers.
			if self.breakpoint_at(buf.path, line) {
				push_disc(
					r,
					sidebar_px + cell_w * 1.0,
					y + line_h * 0.5,
					cell_w * 0.34,
					theme.diag_err,
				)
			}
			if dap.stop_line == line && dap.stop_path == buf.path {
				push_glyph(r, sidebar_px + cell_w * 1.8, baseline, '>', theme.diag_warn)
			}

			// Line number, right-aligned in the gutter.
			num := fmt.tprintf("%d", line + 1)
			num_color := theme.gutter_cur if cursor_lines[line] else theme.gutter_fg
			nx := gutter_px - cell_w * 1.5 - f32(len(num)) * cell_w
			for ch, ci in num {
				push_glyph(r, nx + f32(ci) * cell_w, baseline, ch, num_color)
			}

			// Line text with highlight spans.
			s := buf.line_str(line)
			spans: []Span
			if line < len(hl.spans) {
				spans = hl.spans[line][:]
			}
			span_i := 0
			vis := 0
			for i := 0; i < len(s); {
				ch, n := utf8.decode_rune(s[i:])
				if ch == '\t' {
					vis = (vis / tab_w + 1) * tab_w
					i += n
					continue
				}
				for span_i < len(spans) && spans[span_i].end <= i {
					span_i += 1
				}
				face := Face.Text
				if span_i < len(spans) && spans[span_i].start <= i {
					face = spans[span_i].face
				}
				x := gutter_px + f32(vis) * cell_w - scroll_x
				if x > width {
					break
				}
				if x + cell_w >= gutter_px {
					push_glyph(r, x, baseline, ch, theme.faces[face])
				}
				vis += 1
				i += n
			}
		}

		// Carets (blinking, ~1Hz cycle; steady while the palette has input).
		if self.caret_on(!palette.open) {
			for c in cursors {
				if c.head.line < first_line || c.head.line > last_line {
					continue
				}
				x := gutter_px + f32(visual_col(&buf, c.head.line, c.head.col)) * cell_w - scroll_x
				y := tabbar_h + f32(c.head.line) * line_h - scroll_y
				if x >= gutter_px - 1 {
					push_rect(r, x - 1, y + 1, 2, line_h - 2, theme.cursor)
				}
			}
		}

		self.problems_draw_inline(r, first_line, last_line, cell_w, line_h)

		// Document scrollbar (the content keeps its overscroll tail).
		draw_vscrollbar(
			r,
			width,
			tabbar_h,
			view_h,
			f32(buf.line_count() + OVERSCROLL_LINES) * line_h,
			scroll_y,
			&theme,
		)

		self.tabbar_draw(r, width)
		self.sidebar_draw(r, height)
		self.draw_status(r, width, height)
		self.problems_draw(r, width, height)
		self.task_draw(r, width, height)
		self.hover_draw(r, width, height)
		self.sighelp_draw(r, width, height)
		self.completion_draw(r, width, height)
		self.palette_draw(r, width, height)
	}

	draw_status :: proc(r: ^Renderer, width, height: f32) {
		line_h := r.line_h
		cell_w := r.cell_w
		y := height - status_h
		push_rect(r, 0, y, width, status_h, theme.status_bg)
		push_rect(r, 0, y, width, 1, color_alpha(theme.gutter_fg, 0.6))
		baseline := y + (status_h - line_h) * 0.5 + r.ascent

		draw_str :: proc(r: ^Renderer, x, baseline: f32, s: string, color: Color) -> f32 {
			x := x
			for ch in s {
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
			return x
		}

		// Left: dirty dot + file icon + path (+ transient message).
		x := cell_w * 2
		if buf.is_dirty() {
			push_disc(r, x + cell_w * 0.3, y + status_h * 0.5, cell_w * 0.3, theme.faces[.Number])
			x += cell_w * 1.7
		}
		isz := line_h * 0.62
		push_icon_file(r, x, y + (status_h - isz) * 0.5, isz, color_alpha(theme.status_dim, 0.9))
		x += isz + cell_w * 0.8
		name := buf.path if buf.path != "" else "[untitled]"
		x = utext(r, x, baseline, name, theme.status_fg)
		if len(status_msg) > 0 && now_ms - status_msg_time < 3000 {
			x = utext(r, x + cell_w * 2, baseline, status_msg, theme.faces[.String])
		}

		// Right: problem counts, language, cursor count, position.
		pc := self.primary_cursor()
		right: string
		if len(cursors) > 1 {
			right = fmt.tprintf(
				"%d cursors  %s  %d:%d",
				len(cursors),
				LANG_NAMES[hl.lang],
				pc.head.line + 1,
				visual_col(&buf, pc.head.line, pc.head.col) + 1,
			)
		} else {
			right = fmt.tprintf(
				"%s  %d:%d",
				LANG_NAMES[hl.lang],
				pc.head.line + 1,
				visual_col(&buf, pc.head.line, pc.head.col) + 1,
			)
		}
		rx := width - f32(len(right) + 2) * cell_w
		draw_str(r, rx, baseline, right, theme.status_dim)
		if errs, warns := self.problems_count(); errs > 0 || warns > 0 {
			counts := fmt.tprintf("%dE %dW", errs, warns)
			rx -= f32(len(counts) + 2) * cell_w
			draw_str(r, rx, baseline, counts, theme.diag_err if errs > 0 else theme.diag_warn)
		}
		if task.running || self.dap_active() {
			// A live task (or debug session) shows here even with the output
			// panel closed: a spinner while running, "||" while stopped.
			spinner := [4]string{"|", "/", "-", "\\"}
			ind := spinner[now_ms / 120 % 4]
			if dap.state == .Stopped {
				ind = "||"
			}
			run := fmt.tprintf("%s %s", ind, task.last)
			rx -= f32(len(run) + 2) * cell_w
			draw_str(
				r,
				rx,
				baseline,
				run,
				theme.diag_warn if dap.state == .Stopped else theme.faces[.Function],
			)
		}
	}
}
