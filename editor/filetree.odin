// medit — file tree sidebar.
//
// A lazily-loaded directory tree rooted at the working directory. Directories
// read their entries on first expand and drop them on collapse, so collapsing
// and re-expanding doubles as a refresh. Node paths are kept relative to the
// root (matching how files are usually passed on the command line), and the
// sidebar owns every string it hands out.
package medit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SIDEBAR_CELLS :: 26

// pending_open sentinel for ctrl+n's discard confirmation ('\x01' can never
// appear in a real path).
@(private)
PENDING_NEW :: "\x01new"

Tree_Node :: struct {
	name:     string, // owned
	path:     string, // owned; relative to the working directory ("" = the root itself)
	is_dir:   bool,
	expanded: bool,
	loaded:   bool,
	children: [dynamic]Tree_Node,
}

Sidebar :: struct {
	visible:      bool,
	root:         Tree_Node,
	scroll_y:     f32,
	pending_open: string, // owned; file awaiting a discard-changes confirmation click
}

// One row of the flattened tree, as drawn / hit-tested.
Tree_Row :: struct {
	node:  ^Tree_Node,
	depth: int,
}

sidebar_init :: proc(sb: ^Sidebar) {
	sb.visible = true
	cwd, _ := os.get_working_directory(context.temp_allocator)
	sb.root = Tree_Node{
		name     = strings.clone(filepath.base(cwd)),
		path     = "",
		is_dir   = true,
		expanded = true,
	}
	node_load(&sb.root)
}

sidebar_destroy :: proc(sb: ^Sidebar) {
	node_free_children(&sb.root)
	delete(sb.root.name)
	delete(sb.root.path)
	delete(sb.pending_open)
}

@(private = "file")
node_free_children :: proc(n: ^Tree_Node) {
	for &c in n.children {
		node_free_children(&c)
		delete(c.name)
		delete(c.path)
	}
	delete(n.children)
	n.children = nil
}

// Dirs before files, then case-insensitive by name.
@(private = "file")
node_less :: proc(a, b: Tree_Node) -> bool {
	if a.is_dir != b.is_dir {
		return a.is_dir
	}
	lower :: proc(c: u8) -> u8 {
		return c + 32 if 'A' <= c && c <= 'Z' else c
	}
	for i in 0 ..< min(len(a.name), len(b.name)) {
		ca, cb := lower(a.name[i]), lower(b.name[i])
		if ca != cb {
			return ca < cb
		}
	}
	return len(a.name) < len(b.name)
}

@(private = "file")
node_load :: proc(n: ^Tree_Node) {
	if n.loaded {
		return
	}
	n.loaded = true
	dir := n.path if n.path != "" else "."
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		if info.name == ".git" {
			continue
		}
		child := Tree_Node{
			name   = strings.clone(info.name),
			is_dir = info.type == .Directory,
		}
		if n.path == "" {
			child.path = strings.clone(info.name)
		} else {
			child.path, _ = filepath.join({n.path, info.name})
		}
		append(&n.children, child)
	}
	// Insertion sort; directory listings are small.
	for i in 1 ..< len(n.children) {
		j := i
		for j > 0 && node_less(n.children[j], n.children[j-1]) {
			n.children[j], n.children[j-1] = n.children[j-1], n.children[j]
			j -= 1
		}
	}
}

@(private = "file")
node_toggle :: proc(n: ^Tree_Node) {
	if n.expanded {
		// Collapse drops the children so the next expand re-reads the disk.
		n.expanded = false
		node_free_children(n)
		n.loaded = false
	} else {
		n.expanded = true
		node_load(n)
	}
}

// Flatten the expanded tree into drawable rows (root itself is the header,
// not a row).
@(private = "file")
sidebar_rows :: proc(sb: ^Sidebar, allocator := context.temp_allocator) -> []Tree_Row {
	rows := make([dynamic]Tree_Row, allocator)
	walk :: proc(n: ^Tree_Node, depth: int, rows: ^[dynamic]Tree_Row) {
		for &c in n.children {
			append(rows, Tree_Row{&c, depth})
			if c.is_dir && c.expanded {
				walk(&c, depth+1, rows)
			}
		}
	}
	walk(&sb.root, 0, &rows)
	return rows[:]
}

// Right- (collapsed) or down-pointing (expanded) triangle built from rects,
// so it needs nothing from the font atlas.
@(private = "file")
push_tri :: proc(r: ^Renderer, x, y_center, size: f32, expanded: bool, c: Color) {
	STEPS :: 4
	for i in 0 ..< STEPS {
		frac := f32(STEPS - i) / STEPS
		if expanded {
			w := size * frac
			push_rect(r, x+(size-w)*0.5, y_center-size*0.5+f32(i)*size*0.5/STEPS, w, size*0.5/STEPS+0.5, c)
		} else {
			h := size * frac
			push_rect(r, x+f32(i)*size*0.5/STEPS, y_center-h*0.5, size*0.5/STEPS+0.5, h, c)
		}
	}
}

impl App {
	// A click at sidebar pixel coordinates: toggle a directory, open a file.
	sidebar_click :: proc(py: f32, line_h: f32) {
		row := int((py + sidebar.scroll_y) / line_h) - 1 // row 0 is the header
		rows := sidebar_rows(&sidebar)
		if row < 0 || row >= len(rows) {
			return
		}
		n := rows[row].node
		if n.is_dir {
			node_toggle(n)
		} else {
			self.request_open(n.path)
		}
	}

	// Right-click on a sidebar file: context menu for it.
	sidebar_context :: proc(py: f32, line_h: f32) {
		row := int((py + sidebar.scroll_y) / line_h) - 1 // row 0 is the header
		rows := sidebar_rows(&sidebar)
		if row < 0 || row >= len(rows) {
			return
		}
		n := rows[row].node
		if !n.is_dir {
			self.open_context_file(n.path)
		}
	}

	// Switch the workspace to dir: sidebar, file finder and language server
	// re-root there. The current buffer survives — its path is re-anchored
	// (absolute, or relative to the new root when inside it).
	open_workspace :: proc(dir: string) {
		if buf.path != "" {
			is_abs := strings.has_prefix(buf.path, "/") || (len(buf.path) > 1 && buf.path[1] == ':')
			if !is_abs {
				cwd, _ := os.get_working_directory(context.temp_allocator)
				abs, jerr := filepath.join({cwd, buf.path}, context.allocator)
				if jerr == nil {
					delete(buf.path)
					buf.path = abs
				}
			}
		}
		if os.set_working_directory(dir) != nil {
			self.set_status("could not open folder")
			return
		}
		if buf.path != "" {
			short := strings.clone(shorten_path(buf.path))
			delete(buf.path)
			buf.path = short
		}
		sidebar_destroy(&sidebar)
		sidebar = {}
		sidebar_init(&sidebar)
		lsp_stop(&lsp) // restarts lazily with the new rootUri
		self.clear_cursor_undo()
		retitle = true
		cwd, _ := os.get_working_directory(context.temp_allocator)
		self.set_status(fmt.tprintf("workspace: %s", cwd))
	}

	// Open path, but make losing unsaved changes take a second attempt.
	request_open :: proc(path: string) {
		if path == buf.path {
			return
		}
		if buf.is_dirty() && sidebar.pending_open != path {
			delete(sidebar.pending_open)
			sidebar.pending_open = strings.clone(path)
			self.set_status("unsaved changes — ctrl+s to save, open again to discard")
			return
		}
		self.open_file(path)
	}

	open_file :: proc(path: string) {
		b, ok := buffer_load(path)
		if !ok {
			self.set_status("could not open file")
			return
		}
		buffer_destroy(&buf)
		buf = b
		self.reset_view(lang_from_path(path))
	}

	// ctrl+n: replace the buffer with an empty untitled one (dirty-guarded).
	new_file :: proc() {
		if buf.is_dirty() && sidebar.pending_open != PENDING_NEW {
			delete(sidebar.pending_open)
			sidebar.pending_open = strings.clone(PENDING_NEW)
			self.set_status("unsaved changes — ctrl+s to save, ctrl+n again to discard")
			return
		}
		buffer_destroy(&buf)
		buf = buffer_make()
		self.reset_view(.Plain)
	}

	// Shared tail of open_file/new_file: fresh highlight, cursors, view.
	reset_view :: proc(lang: Lang) {
		delete(sidebar.pending_open)
		sidebar.pending_open = ""
		self.hover_hide()
		self.completion_close()
		self.sighelp_close()
		highlight_destroy(&hl)
		hl = {}
		hl.lang = lang
		clear(&cursors)
		append(&cursors, cursor_at(Pos{0, 0}))
		primary = 0
		scroll_x = 0
		scroll_y = 0
		selecting = false
		self.clear_cursor_undo()
		retitle = true
		self.blink_reset()
	}

	sidebar_draw :: proc(r: ^Renderer, height: f32) {
		if sidebar_px <= 0 {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w
		h := height - status_h

		// Panel over anything the text area let bleed left, plus a border.
		push_rect(r, 0, 0, sidebar_px, h, theme.status_bg)
		push_rect(r, sidebar_px-1, 0, 1, h, color_alpha(theme.gutter_fg, 0.6))

		rows := sidebar_rows(&sidebar)
		content_h := f32(len(rows)+1) * line_h
		sidebar.scroll_y = clamp(sidebar.scroll_y, 0, max(0, content_h-h))

		// Truncate with '…' before running into the border.
		draw_name :: proc(r: ^Renderer, x, baseline, limit: f32, s: string, c: Color) {
			x := x
			for ch in s {
				if x+r.cell_w*2 > limit {
					push_glyph(r, x, baseline, '…', c)
					return
				}
				push_glyph(r, x, baseline, ch, c)
				x += r.cell_w
			}
		}

		// Header: the root directory's name.
		baseline := r.ascent - sidebar.scroll_y
		draw_name(r, cell_w, baseline, sidebar_px, sidebar.root.name, theme.status_dim)

		for row, i in rows {
			y := f32(i+1)*line_h - sidebar.scroll_y
			if y+line_h < 0 {
				continue
			}
			if y > h {
				break
			}
			n := row.node
			if !n.is_dir && n.path == buf.path {
				push_rect(r, 0, y, sidebar_px-1, line_h, theme.selection)
			}
			x := cell_w * (1 + f32(row.depth)*1.5)
			if n.is_dir {
				push_tri(r, x, y+line_h*0.5, cell_w*0.6, n.expanded, theme.status_dim)
			}
			color := theme.faces[.Function] if n.is_dir else theme.status_fg
			if !n.is_dir && n.path == buf.path {
				color = theme.fg
			}
			draw_name(r, x+cell_w*1.4, y+r.ascent, sidebar_px, n.name, color)
		}
	}
}
