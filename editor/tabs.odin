// medit — multiple documents and the tab bar.
//
// Each open file is a Doc: a Buffer (with its own undo history) plus the
// view state that belongs to it — cursors, scroll, selection undo, syntax
// highlight. The active document's fields live directly on App, so the rest
// of the editor keeps addressing app.buf, app.cursors, ...; switching tabs
// stashes them into docs[active] and loads the new slot. docs[active] is
// therefore stale while that document is active — go through doc_buf.
package medit

import "core:path/filepath"
import "core:strings"

Doc :: struct {
	buf:         Buffer,
	hl:          Highlight,
	cursors:     [dynamic]Cursor,
	primary:     int,
	scroll_x:    f32,
	scroll_y:    f32,
	cursor_undo: [dynamic][]Cursor,
	preview:     bool, // transient palette-preview tab (see open_preview)
}

doc_destroy :: proc(d: ^Doc) {
	buffer_destroy(&d.buf)
	highlight_destroy(&d.hl)
	delete(d.cursors)
	for s in d.cursor_undo {
		delete(s)
	}
	delete(d.cursor_undo)
}

impl App {
	// The buffer of tab i (the live fields win over the stale active slot).
	doc_buf :: proc(i: int) -> ^Buffer {
		return &buf if i == active else &docs[i].buf
	}

	tab_label :: proc(i: int) -> string {
		path := self.doc_buf(i).path
		if path == "" {
			return "[untitled]"
		}
		return filepath.base(path)
	}

	// The live document fields as a Doc (for stashing or destroying).
	live_doc :: proc() -> Doc {
		return Doc{
			buf         = buf,
			hl          = hl,
			cursors     = cursors,
			primary     = primary,
			scroll_x    = scroll_x,
			scroll_y    = scroll_y,
			cursor_undo = cursor_undo,
			preview     = preview,
		}
	}

	doc_is_preview :: proc(i: int) -> bool {
		return preview if i == active else docs[i].preview
	}

	// Reset the transient UI state that never survives a document change.
	doc_reset_transients :: proc() {
		self.hover_hide()
		self.completion_close()
		self.sighelp_close()
		selecting = false
		select_word = false
		col_select = false
		pending_close = -1
		tab_follow = true
		retitle = true
		self.blink_reset()
	}

	stash_active :: proc() {
		docs[active] = self.live_doc()
	}

	// Load slot i into the live fields; the previous contents must have been
	// stashed or destroyed.
	doc_load :: proc(i: int) {
		active = i
		d := &docs[i]
		buf = d.buf
		hl = d.hl
		cursors = d.cursors
		primary = d.primary
		scroll_x = d.scroll_x
		scroll_y = d.scroll_y
		cursor_undo = d.cursor_undo
		preview = d.preview
	}

	doc_switch :: proc(i: int) {
		if i == active || i < 0 || i >= len(docs) {
			return
		}
		self.stash_active()
		self.doc_load(i)
		self.doc_reset_transients()
	}

	// Fill the live fields with a fresh document; the previous contents must
	// have been stashed or destroyed. Takes ownership of b.
	doc_install :: proc(b: Buffer, lang: Lang) {
		buf = b
		hl = {}
		hl.lang = lang
		cursors = {}
		append(&cursors, cursor_at(Pos{0, 0}))
		primary = 0
		scroll_x = 0
		scroll_y = 0
		cursor_undo = {}
		preview = false
		self.doc_reset_transients()
	}

	// Open b in a new tab and make it active.
	doc_append :: proc(b: Buffer, lang: Lang) {
		if len(docs) > 0 {
			self.stash_active()
		}
		append(&docs, Doc{})
		active = len(docs) - 1
		self.doc_install(b, lang)
	}

	// Open path: switch to its tab if it is already open, else load it into
	// a new tab. A pristine untitled tab is reused instead of left behind.
	open_file :: proc(path: string) {
		if path != "" && path == buf.path {
			return
		}
		if path != "" {
			for &d, i in docs {
				if i != active && d.buf.path == path {
					self.doc_switch(i)
					return
				}
			}
		}
		b, ok := buffer_load(path)
		if !ok {
			self.set_status("could not open file")
			return
		}
		if buf.path == "" && len(buf.undo_stack) == 0 && len(buf.redo_stack) == 0 {
			d := self.live_doc()
			doc_destroy(&d)
			self.doc_install(b, lang_from_path(path))
			return
		}
		self.doc_append(b, lang_from_path(path))
	}

	// ctrl+n: a fresh untitled tab.
	new_file :: proc() {
		self.doc_append(buffer_make(), .Plain)
	}

	// Show path without committing to a tab: palette previews open files in
	// a single reusable preview tab, which palette_close promotes (if the
	// user landed on it) or removes. Explicit opens stay permanent.
	open_preview :: proc(path: string) -> bool {
		if path == "" {
			return false
		}
		if path == buf.path {
			return true
		}
		// Any tab already holding the file: just show it.
		for &d, i in docs {
			if i != active && d.buf.path == path {
				self.doc_switch(i)
				return true
			}
		}
		b, ok := buffer_load(path)
		if !ok {
			return false
		}
		// Reuse the existing preview tab if there is one, else open a new one.
		if !preview {
			for i in 0 ..< len(docs) {
				if i != active && docs[i].preview {
					self.doc_switch(i)
					break
				}
			}
		}
		if preview {
			d := self.live_doc()
			doc_destroy(&d)
			self.doc_install(b, lang_from_path(path))
		} else {
			self.doc_append(b, lang_from_path(path))
		}
		preview = true
		return true
	}

	// esc while previewing: drop the preview tab and return to the document
	// the palette was opened from.
	preview_abandon :: proc() {
		idx := -1
		for i in 0 ..< len(docs) {
			if self.doc_is_preview(i) {
				idx = i
				break
			}
		}
		if idx < 0 {
			return
		}
		home := palette.home_doc
		if active == idx && home != idx && home >= 0 && home < len(docs) {
			self.doc_switch(home)
		}
		self.tab_close(idx) // previews are never dirty; closes immediately
	}

	// Close tab i; losing unsaved changes takes a second attempt.
	tab_close :: proc(i: int) {
		if i < 0 || i >= len(docs) {
			return
		}
		if self.doc_buf(i).is_dirty() && pending_close != i {
			self.doc_switch(i) // show what would be lost
			pending_close = i
			self.set_status("unsaved changes — ctrl+s to save, close again to discard")
			return
		}
		pending_close = -1
		if i == active {
			d := self.live_doc()
			doc_destroy(&d)
			ordered_remove(&docs, i)
			if len(docs) == 0 {
				append(&docs, Doc{})
				active = 0
				self.doc_install(buffer_make(), .Plain)
				return
			}
			self.doc_load(min(i, len(docs)-1))
			self.doc_reset_transients()
		} else {
			doc_destroy(&docs[i])
			ordered_remove(&docs, i)
			if i < active {
				active -= 1
			}
			tab_follow = true
		}
	}

	// ctrl+tab / ctrl+pgup/pgdn: cyclic tab switch.
	tab_cycle :: proc(d: int) {
		if len(docs) > 1 {
			self.doc_switch((active + d + len(docs)) % len(docs))
		}
	}

	// ctrl+1..9: jump straight to a tab.
	tab_select :: proc(i: int) {
		if i >= 0 && i < len(docs) {
			self.doc_switch(i)
		}
	}
}

// --- Tab bar UI ----------------------------------------------------------------

TAB_MAX_NAME_CELLS :: 24

impl App {
	// A click on the tab bar, using the layout of the last draw.
	// button: 0 = left, 1 = middle, 2 = right.
	tabbar_click :: proc(px: f32, cell_w: f32, button: int) {
		for rect, i in tab_rects {
			// The layout can be one frame behind the docs list.
			if i >= len(docs) {
				return
			}
			if px < rect[0] || px >= rect[1] {
				continue
			}
			switch button {
			case 0:
				if px >= rect[1]-cell_w*2.4 {
					self.tab_close(i)
				} else {
					self.doc_switch(i)
				}
			case 1:
				self.tab_close(i)
			case 2:
				path := self.doc_buf(i).path
				if path != "" {
					self.open_context_file(path)
				}
			}
			return
		}
	}

	// The window close button (the top-right ×): 0 when hit, -1 otherwise.
	// (Minimize/maximize stay on the system shortcuts and window edges.)
	traffic_hit :: proc(px, py: f32) -> int {
		if px >= win_close[0] && px < win_close[2] && py >= win_close[1] && py < win_close[3] {
			return 0
		}
		return -1
	}

	// The tab bar doubles as the window title bar: the tab strip, then a
	// lone × in the top-right corner; empty space drags the window (hit
	// test in main.odin).
	tabbar_draw :: proc(r: ^Renderer, width: f32) {
		line_h := r.line_h
		cell_w := r.cell_w

		push_rect(r, 0, 0, width, tabbar_h, theme.status_bg)
		push_rect(r, 0, tabbar_h-1, width, 1, color_alpha(theme.gutter_fg, 0.6))

		close_w := tabbar_h * 1.4
		win_close = {width - close_w, 0, width, tabbar_h - 1}
		tabs_x0 = cell_w * 0.8

		resize(&tab_rects, len(docs))

		// Pass 1: widths (stored as {offset, width}, fixed up in pass 2).
		max_name := f32(TAB_MAX_NAME_CELLS) * cell_w
		total: f32 = 0
		for i in 0 ..< len(docs) {
			name_w := min(utext_width(r, self.tab_label(i)), max_name)
			w := name_w + cell_w*7.0
			tab_rects[i] = {total, w}
			total += w
		}
		avail := width - tabs_x0 - close_w
		if tab_follow {
			tab_follow = false
			x0 := tab_rects[active][0]
			x1 := x0 + tab_rects[active][1]
			if x1 > tab_scroll+avail {
				tab_scroll = x1 - avail
			}
			if x0 < tab_scroll {
				tab_scroll = x0
			}
		}
		tab_scroll = clamp(tab_scroll, 0, max(0, total-avail))

		baseline := (tabbar_h-line_h)*0.5 + r.ascent
		isz := line_h * 0.62
		for i in 0 ..< len(docs) {
			x := tabs_x0 + tab_rects[i][0] - tab_scroll
			w := tab_rects[i][1]
			tab_rects[i] = {x, x + w}
			if x+w <= tabs_x0 || x >= width-close_w {
				continue
			}
			if i == active {
				push_rect(r, x, 0, w, tabbar_h, theme.bg) // merge into the editor
				push_rect(r, x, 0, w, 2, theme.faces[.Function])
			} else {
				push_rect(r, x+w-1, tabbar_h*0.3, 1, tabbar_h*0.4, color_alpha(theme.gutter_fg, 0.6))
			}

			name := self.tab_label(i)
			color := theme.fg if i == active else theme.status_dim
			push_icon_file(r, x+cell_w*1.5, (tabbar_h-isz)*0.5, isz, color_alpha(color, 0.75))
			gx := x + cell_w*1.5 + isz + cell_w*0.8
			_ = utext_clip(r, gx, baseline, gx+max_name+cell_w, name, color)

			// Close box: a dirty dot that becomes × once the file is clean.
			cx := x + w - cell_w*2.4
			if self.doc_buf(i).is_dirty() {
				push_disc(r, cx+cell_w*0.5, tabbar_h*0.5, cell_w*0.32, theme.faces[.Number])
			} else {
				push_glyph(r, cx, baseline, '×', color_alpha(color, 0.8))
			}
		}

		// Cover tabs scrolled past either edge, then the window ×, hovered
		// like a native titlebar button.
		push_rect(r, 0, 0, tabs_x0, tabbar_h, theme.status_bg)
		push_rect(r, width-close_w, 0, close_w, tabbar_h, theme.status_bg)
		push_rect(r, 0, tabbar_h-1, width, 1, color_alpha(theme.gutter_fg, 0.6))
		hovered := mouse_x >= win_close[0] && mouse_x < win_close[2] &&
			mouse_y >= win_close[1] && mouse_y < win_close[3]
		if hovered {
			push_rect(r, win_close[0], 0, close_w, tabbar_h-1, Color{0.83, 0.18, 0.18, 1.0})
		}
		push_glyph(r, width-close_w*0.5-cell_w*0.5, baseline, '×',
			Color{1, 1, 1, 1} if hovered else theme.status_fg)
	}
}
