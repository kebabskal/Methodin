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

SIDEBAR_CELLS :: 32
sidebar_cells: f32 = SIDEBAR_CELLS // drag the sidebar border to resize

Tree_Node :: struct {
	name:     string, // owned
	path:     string, // owned; relative to the working directory ("" = the root itself)
	is_dir:   bool,
	expanded: bool,
	loaded:   bool,
	children: [dynamic]Tree_Node,
}

Sidebar :: struct {
	visible:  bool,
	root:     Tree_Node,
	scroll_y: f32,
	hide:     [dynamic]string, // owned; globs hidden from the tree ([files] hide)
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
	node_load(&sb.root, sb.hide[:])
}

sidebar_destroy :: proc(sb: ^Sidebar) {
	node_free_children(&sb.root)
	delete(sb.root.name)
	delete(sb.root.path)
	for g in sb.hide {
		delete(g)
	}
	delete(sb.hide)
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
node_load :: proc(n: ^Tree_Node, hide: []string) {
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
		if info.name == ".git" || settings_hidden(info.name, hide) {
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

// Re-read every loaded directory from disk, keeping expansion state — files
// created since the last read (a save-as, or another program) show up
// without collapsing and re-expanding their directory.
sidebar_refresh :: proc(sb: ^Sidebar) {
	node_refresh(&sb.root, sb.hide[:])
}

@(private = "file")
node_refresh :: proc(n: ^Tree_Node, hide: []string) {
	if !n.loaded {
		if n.expanded {
			node_load(n, hide)
		}
		return
	}
	old := n.children
	n.children = nil
	n.loaded = false
	node_load(n, hide)
	for &c in n.children {
		// A surviving directory adopts its old subtree so expansion is kept.
		for &o in old {
			if o.name == c.name && o.is_dir == c.is_dir {
				c.expanded = o.expanded
				c.loaded = o.loaded
				c.children = o.children
				o.children = nil
				o.loaded = false
				break
			}
		}
		if c.is_dir && (c.loaded || c.expanded) {
			node_refresh(&c, hide)
		}
	}
	for &o in old {
		node_free_children(&o)
		delete(o.name)
		delete(o.path)
	}
	delete(old)
}

// Expand (and load) every directory along the workspace-relative path so
// its last segment is visible in the tree.
sidebar_reveal :: proc(sb: ^Sidebar, path: string) {
	n := &sb.root
	rest := path
	for {
		i := strings.index_any(rest, "/\\")
		if i < 0 {
			return
		}
		seg := rest[:i]
		rest = rest[i+1:]
		found := false
		for &c in n.children {
			if c.is_dir && c.name == seg {
				c.expanded = true
				node_load(&c, sb.hide[:])
				n = &c
				found = true
				break
			}
		}
		if !found {
			return
		}
	}
}

@(private = "file")
node_toggle :: proc(n: ^Tree_Node, hide: []string) {
	if n.expanded {
		// Collapse drops the children so the next expand re-reads the disk.
		n.expanded = false
		node_free_children(n)
		n.loaded = false
	} else {
		n.expanded = true
		node_load(n, hide)
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

impl App {
	// Row index (into sidebar_rows) under a sidebar pixel y; -1 for none/header.
	sidebar_row_at :: proc(py: f32, line_h: f32) -> int {
		row_h := line_h * UI_ROW_SCALE
		return int((py - tabbar_h + sidebar.scroll_y - row_h*0.25) / row_h) - 1
	}

	// A click at sidebar pixel coordinates: toggle a directory, open a file.
	sidebar_click :: proc(py: f32, line_h: f32) {
		row := self.sidebar_row_at(py, line_h)
		rows := sidebar_rows(&sidebar)
		if row < 0 || row >= len(rows) {
			return
		}
		n := rows[row].node
		if n.is_dir {
			node_toggle(n, sidebar.hide[:])
		} else {
			self.open_file(n.path)
		}
	}

	// Right-click in the sidebar: context menu for the row's file or
	// directory; the header and empty space get the workspace root (".").
	sidebar_context :: proc(py: f32, line_h: f32) {
		row := self.sidebar_row_at(py, line_h)
		rows := sidebar_rows(&sidebar)
		if row >= 0 && row < len(rows) {
			n := rows[row].node
			self.open_context_file(n.path, n.is_dir)
		} else {
			self.open_context_file(".", true)
		}
	}

	// Switch the workspace to dir: sidebar, file finder and language server
	// re-root there. Open documents survive — their paths are re-anchored
	// (absolute, or relative to the new root when inside it).
	open_workspace :: proc(dir: string) {
		for i in 0 ..< len(docs) {
			b := self.doc_buf(i)
			if b.path == "" {
				continue
			}
			is_abs := strings.has_prefix(b.path, "/") || (len(b.path) > 1 && b.path[1] == ':')
			if !is_abs {
				cwd, _ := os.get_working_directory(context.temp_allocator)
				abs, jerr := filepath.join({cwd, b.path}, context.allocator)
				if jerr == nil {
					delete(b.path)
					b.path = abs
				}
			}
		}
		if os.set_working_directory(dir) != nil {
			self.set_status("could not open folder")
			return
		}
		for i in 0 ..< len(docs) {
			b := self.doc_buf(i)
			if b.path == "" {
				continue
			}
			short := strings.clone(shorten_path(b.path))
			delete(b.path)
			b.path = short
		}
		sidebar_destroy(&sidebar)
		sidebar = {}
		settings_load(self) // the new workspace brings its own .medit/settings.ini
		sidebar_init(&sidebar)
		lsp_stop(&lsp) // restarts lazily with the new rootUri
		self.clear_cursor_undo()
		retitle = true
		cwd, _ := os.get_working_directory(context.temp_allocator)
		if cwd != "" {
			self.recent_dirs_add(cwd)
		}
		self.set_status(fmt.tprintf("workspace: %s", cwd))
	}

	sidebar_draw :: proc(r: ^Renderer, height: f32) {
		if sidebar_px <= 0 {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w
		row_h := line_h * UI_ROW_SCALE
		top := tabbar_h
		h := height - status_h

		// Panel over anything the text area let bleed left, plus a border.
		push_rect(r, 0, top, sidebar_px, h-top, theme.status_bg)
		hot := edge_hover == 1 || resizing == 1
		push_rect(r, sidebar_px-2 if hot else sidebar_px-1, top, 3 if hot else 1, h-top,
			theme.faces[.Function] if hot else color_alpha(theme.gutter_fg, 0.6))

		rows := sidebar_rows(&sidebar)
		content_h := f32(len(rows)+1)*row_h + row_h*0.5
		sidebar.scroll_y = clamp(sidebar.scroll_y, 0, max(0, content_h-(h-top)))

		// The proportional UI face, truncated with '…' before the border.
		draw_name :: proc(r: ^Renderer, x, baseline, limit: f32, s: string, c: Color) {
			_ = utext_clip(r, x, baseline, limit, s, c)
		}

		isz := line_h * 0.62

		// Header: the workspace root, with a folder icon.
		hy := top + row_h*0.25 - sidebar.scroll_y
		if hy+row_h >= top {
			push_icon(r, cell_w*1.6, hy+(row_h-isz)*0.5, isz, .Folder_Open, theme.faces[.Function])
			draw_name(r, cell_w*1.6+isz+cell_w*0.8, hy+(row_h-line_h)*0.5+r.ascent, sidebar_px-cell_w,
				sidebar.root.name, theme.status_fg)
		}

		for row, i in rows {
			y := top + row_h*0.25 + f32(i+1)*row_h - sidebar.scroll_y
			if y+row_h < top {
				continue
			}
			if y > h {
				break
			}
			n := row.node
			selected := !n.is_dir && n.path == buf.path
			if selected {
				push_rect(r, 0, y, sidebar_px-1, row_h, theme.selection)
			}
			x := cell_w*1.6 + f32(row.depth)*cell_w*1.6
			mid := y + row_h*0.5
			if n.is_dir {
				push_icon(r, x+cell_w*0.28-isz*0.5, mid-isz*0.5, isz,
					.Chevron_Down if n.expanded else .Chevron_Right, theme.status_dim)
			}
			ix := x + cell_w*1.0
			if n.is_dir {
				push_icon(r, ix, mid-isz*0.5, isz, .Folder_Open if n.expanded else .Folder,
					color_alpha(theme.faces[.Function], 0.85))
			} else {
				push_icon(r, ix, mid-isz*0.5, isz, .File,
					color_alpha(theme.fg if selected else theme.status_dim, 0.85))
			}
			color := theme.fg if selected else theme.status_fg
			draw_name(r, ix+isz+cell_w*0.8, y+(row_h-line_h)*0.5+r.ascent, sidebar_px-cell_w*0.5, n.name, color)
		}

		draw_vscrollbar(r, sidebar_px-1, top, h-top, content_h, sidebar.scroll_y, &theme)
	}
}
