// medit — the command palette (ctrl+p).
//
// One input box, many modes, selected by the query's prefix:
//
//     (nothing)   fuzzy file finder over the working directory
//     >           app commands and settings
//     /           document search; up/down hops between matches live
//     :           go to line[:column]
//
// Adding a mode is one entry in PALETTE_MODES: a refresh proc that turns the
// query into items, an accept proc for enter/click, and an optional preview
// proc that runs whenever the selection changes (that is what makes search
// and goto feel live — esc restores the pre-palette view). Commands are just
// a table too; see PALETTE_COMMANDS.
package medit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

MAX_PALETTE_ITEMS :: 200
MAX_SEARCH_MATCHES :: 500
MAX_SCAN_FILES :: 30000
PALETTE_VISIBLE :: 14

Palette_Item :: struct {
	label:   string, // owned; main row text
	detail:  string, // owned; dim, right-aligned (keybinding, line:col)
	matches: []int,  // owned; byte offsets into label drawn in accent color
	dim_end: int,    // label[:dim_end] is drawn dim (directory prefix)
	score:   int,
	data:    int,    // mode-specific (command index, line, ...)
	data2:   int,    // mode-specific (column, ...)

	// Optional kind badge drawn before the label (symbol modes): a colored
	// letter, like the completion popup. 0 = none.
	kind_ch:   rune,
	kind_face: Face,
}

Palette_Mode :: struct {
	prefix:  string,
	hint:    string, // placeholder shown while the query is just the prefix
	refresh: proc(app: ^App, q: string), // q = query without prefix, trimmed
	accept:  proc(app: ^App, it: ^Palette_Item),
	preview: proc(app: ^App, it: ^Palette_Item), // live modes: runs on selection change
}

Palette_Command :: struct {
	name: string,
	key:  string, // shown dim on the right; "" if unbound
	run:  proc(app: ^App),
}

// One LSP symbol, backing the outline (!) and workspace symbol (#) modes.
Symbol_Item :: struct {
	name:   string, // owned
	detail: string, // owned; LSP detail or container name
	path:   string, // owned; "" = the current document (outline)
	kind:   int,    // LSP SymbolKind
	line, char, eline, echar: int, // LSP (UTF-16) coordinates
	depth:  int,    // outline nesting level
}

Sym_Mode :: enum {
	None, // nothing fetched yet
	Outline,
	Workspace,
}

Palette :: struct {
	open:       bool,
	query:      [dynamic]u8,
	caret:      int, // byte offset into query
	sel_anchor: int, // other end of the input selection (== caret: none)
	mode_i:     int,
	items:  [dynamic]Palette_Item,
	sel:    int,
	scroll: int, // first visible item index
	hover:  int, // item under the mouse (-1 none); drawn as a faint highlight

	forced_mode: int,    // ≥ 0: use this mode regardless of query prefix (context menu)
	ctx_path:    string, // owned; file the context menu is about ("" = editor context)
	ctx_is_dir:  bool,   // the context path is a directory ("." = the workspace root)
	ctx_local:   int,    // index into dap.locals for the locals context menu (-1 none)
	ctx_pos:     Pos,    // symbol position for the rename mode
	keep_open:   bool,   // an accept proc re-opened the palette; skip the close
	home_doc:    int,    // tab the palette was opened from (esc returns there)

	// File-op prompt mode (new file / new folder / rename on ctx_path).
	fileop:         File_Op,
	fileop_dir:     string, // owned; directory a New File/Folder creates in
	confirm_delete: string, // owned; path Delete was picked for once already

	usages: [dynamic]Lsp_Location, // owned; backing data for the usages mode

	// Symbol data fetched via LSP; cached across palette opens and refetched
	// when the stamps below no longer match what is being asked for.
	symbols:     [dynamic]Symbol_Item,
	sym_mode:    Sym_Mode,
	sym_req_id:  int,
	sym_path:    string, // owned; document the outline was fetched for
	sym_version: int,    // buffer version the outline was fetched at
	sym_query:   string, // owned; last workspace query sent

	files:   [dynamic]string, // owned; scanned lazily once per open
	scanned: bool,

	// Editor state to restore on cancel (live previews move the cursor).
	saved_cursors:  [dynamic]Cursor,
	saved_scroll_x: f32,
	saved_scroll_y: f32,

	// Layout of the last draw, for mouse hit testing (pixels).
	lx, ly, lw, lh: f32,
	l_row0:         f32,
	l_qx:           f32, // x where the query text starts (right of the search glyph)
	l_vis:          int,
}

// What the file-op prompt mode does with its query on enter.
File_Op :: enum {
	None,
	New_File,
	New_Folder,
	Rename,
}

@(private = "file")
PALETTE_MODE_FILES :: 0
// Prefix-less modes, entered via forced_mode (ctrl+., right-click, LSP results).
@(private = "file")
PALETTE_MODE_CONTEXT :: 4
PALETTE_MODE_USAGES :: 5
PALETTE_MODE_RENAME :: 6
@(private = "file")
PALETTE_MODE_FILEOP :: 10
// The tasks mode (index 11) is prefix-driven ("$"), never forced.

@(private = "file")
PALETTE_MODES := []Palette_Mode{
	{prefix = "", hint = ">commands  /search  :line  !outline  #symbols  ?problems  $tasks", refresh = files_refresh, accept = files_accept},
	{prefix = ">", hint = "run a command", refresh = commands_refresh, accept = commands_accept},
	{prefix = "/", hint = "search the document", refresh = search_refresh, accept = accept_nothing, preview = search_preview},
	{prefix = ":", hint = "go to line[:column]", refresh = goto_refresh, accept = accept_nothing, preview = goto_preview},
	{prefix = "", hint = "context actions — type to filter", refresh = context_refresh, accept = context_accept},
	{prefix = "", hint = "usages — enter jumps, esc restores", refresh = usages_refresh, accept = usages_accept, preview = usages_preview},
	{prefix = "", hint = "new name for the symbol", refresh = rename_refresh, accept = rename_accept},
	{prefix = "!", hint = "document outline — type to filter", refresh = outline_refresh, accept = accept_nothing, preview = outline_preview},
	{prefix = "#", hint = "workspace symbols — type to search", refresh = wsymbols_refresh, accept = wsymbols_accept, preview = wsymbols_preview},
	{prefix = "?", hint = "problems — type to filter", refresh = problems_refresh, accept = problems_pal_accept, preview = problems_pal_preview},
	{prefix = "", hint = "name — enter confirms, esc cancels", refresh = fileop_refresh, accept = fileop_accept},
	{prefix = "$", hint = "run a task — enter runs, esc cancels", refresh = tasks_refresh, accept = tasks_accept},
}

@(private = "file")
PALETTE_COMMANDS := []Palette_Command{
	{"File: Save", "ctrl+s", proc(app: ^App) { app.save() }},
	{"File: Reload from Disk", "", proc(app: ^App) { app.doc_reload(app.active) }},
	{"File: New Untitled File", "ctrl+n", proc(app: ^App) { app.new_file() }},
	{"File: New File…", "", proc(app: ^App) { app.open_fileop_prompt(.New_File, ".") }},
	{"File: New Folder…", "", proc(app: ^App) { app.open_fileop_prompt(.New_Folder, ".") }},
	{"Tasks: Run Task…", "ctrl+shift+r", proc(app: ^App) {
		if app.task_picker() {
			app.palette.keep_open = true
		}
	}},
	{"Tasks: Run Default Task", "ctrl+r", proc(app: ^App) { app.task_run_default() }},
	{"Tasks: Stop Running Task", "", proc(app: ^App) { app.task_stop() }},
	{"Tasks: Toggle Output Panel", "", proc(app: ^App) {
		app.task.open = !app.task.open
		if app.task.open {
			app.problems_open = false
		}
	}},
	{"Tasks: Configure (.medit/tasks.ini)", "", proc(app: ^App) { app.task_edit_config() }},
	{"Tasks: Copy Output", "", proc(app: ^App) {
		sb := strings.builder_make(context.temp_allocator)
		for l in app.task.lines {
			strings.write_string(&sb, l)
			strings.write_byte(&sb, '\n')
		}
		clipboard_set(strings.to_string(sb))
		app.set_status(fmt.tprintf("copied %d lines", len(app.task.lines)))
	}},
	{"Debug: Copy Call Stack", "", proc(app: ^App) {
		sb := strings.builder_make(context.temp_allocator)
		for f, i in app.dap.frames {
			strings.write_string(&sb, fmt.tprintf("#%d %s — %s(%d)\n", i, f.name, f.path, f.line) if f.path != "" else fmt.tprintf("#%d %s\n", i, f.name))
		}
		clipboard_set(strings.to_string(sb))
		app.set_status(fmt.tprintf("copied %d frames", len(app.dap.frames)))
	}},
	{"Debug: Copy Locals", "", proc(app: ^App) {
		sb := strings.builder_make(context.temp_allocator)
		for v in app.dap.locals {
			strings.write_string(&sb, fmt.tprintf("%s = %s\n", v.name, v.value))
		}
		clipboard_set(strings.to_string(sb))
		app.set_status(fmt.tprintf("copied %d locals", len(app.dap.locals)))
	}},
	{"Problems: Copy All", "", proc(app: ^App) {
		sb := strings.builder_make(context.temp_allocator)
		for d in app.problems {
			strings.write_string(&sb, fmt.tprintf("%s %s:%d %s\n", severity_letter(d.severity), d.path, d.line+1, d.msg))
		}
		clipboard_set(strings.to_string(sb))
		app.set_status(fmt.tprintf("copied %d problems", len(app.problems)))
	}},
	{"File: Close Tab", "ctrl+w", proc(app: ^App) { app.tab_close(app.active) }},
	{"File: Open Folder…", "", proc(app: ^App) { open_folder_dialog() }},
	{"File: Toggle Format on Save", "", proc(app: ^App) {
		app.format_on_save = !app.format_on_save
		_ = settings_save_key("editor", "format-on-save", "true" if app.format_on_save else "false")
		app.set_status("format on save: on" if app.format_on_save else "format on save: off")
	}},
	{"File: Quit (Exit)", "ctrl+q", proc(app: ^App) { request_quit() }},
	{"File: Copy Path and Line", "", proc(app: ^App) {
		if app.buf.path == "" {
			app.set_status("no file path")
			return
		}
		loc := fmt.tprintf("%s:%d", app.buf.path, app.primary_cursor().head.line+1)
		clipboard_set(loc)
		app.set_status(fmt.tprintf("copied %s", loc))
	}},
	{"View: Next Tab", "ctrl+tab", proc(app: ^App) { app.tab_cycle(1) }},
	{"View: Previous Tab", "ctrl+shift+tab", proc(app: ^App) { app.tab_cycle(-1) }},
	{"View: Toggle File Tree Sidebar", "ctrl+b", proc(app: ^App) { app.sidebar.visible = !app.sidebar.visible }},
	{"View: Toggle Problems Panel", "ctrl+shift+m", proc(app: ^App) {
		app.problems_open = !app.problems_open
		if app.problems_open {
			app.task.open = false // the panels share the slot above the status bar
		}
	}},
	{"View: Increase Font Size", "ctrl+=", proc(app: ^App) { app.zoom_req = .In }},
	{"View: Decrease Font Size", "ctrl+-", proc(app: ^App) { app.zoom_req = .Out }},
	{"View: Reset Font Size", "ctrl+0", proc(app: ^App) { app.zoom_req = .Reset }},
	{"Search Document", "ctrl+f", proc(app: ^App) {
		app.open_search()
		app.palette.keep_open = true
	}},
	{"Edit: Undo", "ctrl+z", proc(app: ^App) { app.undo() }},
	{"Edit: Redo", "ctrl+shift+z", proc(app: ^App) { app.redo() }},
	{"Edit: Toggle Line Comment", "ctrl+'", proc(app: ^App) { app.toggle_comment() }},
	{"Edit: Duplicate Selection", "ctrl+shift+d", proc(app: ^App) { app.duplicate() }},
	{"Edit: Move Lines Up", "alt+up", proc(app: ^App) { app.move_lines(down = false) }},
	{"Edit: Move Lines Down", "alt+down", proc(app: ^App) { app.move_lines(down = true) }},
	{"Selection: Select All", "ctrl+a", proc(app: ^App) { app.select_all() }},
	{"Selection: Add Cursor Above", "ctrl+alt+up", proc(app: ^App) { app.add_cursor_line(below = false) }},
	{"Selection: Add Cursor Below", "ctrl+alt+down", proc(app: ^App) { app.add_cursor_line(below = true) }},
	{"Selection: Select Next Match", "ctrl+d", proc(app: ^App) { app.select_next_match() }},
	{"Selection: Select All Occurrences", "", proc(app: ^App) { app.select_all_matches() }},
	{"Selection: Undo Last Selection", "ctrl+u", proc(app: ^App) { app.undo_selection() }},
	{"Selection: Transform to Uppercase", "", proc(app: ^App) { app.transform_case(true) }},
	{"Selection: Transform to Lowercase", "", proc(app: ^App) { app.transform_case(false) }},
	{"Go to Definition", "ctrl+g", proc(app: ^App) { app.lsp_goto_definition() }},
	{"Go to Symbol in Document…", "ctrl+e", proc(app: ^App) {
		app.palette_open_with("!")
		app.palette.keep_open = true
	}},
	{"Go to Symbol in Workspace…", "ctrl+t", proc(app: ^App) {
		app.palette_open_with("#")
		app.palette.keep_open = true
	}},
	{"Go to Problem…", "ctrl+m", proc(app: ^App) {
		app.palette_open_with("?")
		app.palette.keep_open = true
	}},
	{"Find Usages", "ctrl+h", proc(app: ^App) { app.lsp_find_references() }},
	{"Rename Symbol", "F2", proc(app: ^App) { app.lsp_rename_prompt() }},
	{"LSP: Restart Language Server", "", proc(app: ^App) { app.lsp_restart() }},
	{"Language: Plain Text", "", proc(app: ^App) { app.set_language(.Plain) }},
	{"Language: Methodin / Odin", "", proc(app: ^App) { app.set_language(.Odin) }},
	{"Language: JSON", "", proc(app: ^App) { app.set_language(.JSON) }},
	{"Language: GLSL", "", proc(app: ^App) { app.set_language(.GLSL) }},
	{"Language: HLSL", "", proc(app: ^App) { app.set_language(.HLSL) }},
	{"Language: WGSL", "", proc(app: ^App) { app.set_language(.WGSL) }},
	{"Language: C", "", proc(app: ^App) { app.set_language(.C) }},
	{"Language: C++", "", proc(app: ^App) { app.set_language(.CPP) }},
	{"Language: Python", "", proc(app: ^App) { app.set_language(.Python) }},
	{"Language: JavaScript", "", proc(app: ^App) { app.set_language(.JS) }},
	{"Language: TypeScript", "", proc(app: ^App) { app.set_language(.TS) }},
	{"Language: Rust", "", proc(app: ^App) { app.set_language(.Rust) }},
	{"Language: Go", "", proc(app: ^App) { app.set_language(.Go) }},
	{"Language: Java", "", proc(app: ^App) { app.set_language(.Java) }},
	{"Language: C#", "", proc(app: ^App) { app.set_language(.CSharp) }},
	{"Language: Lua", "", proc(app: ^App) { app.set_language(.Lua) }},
	{"Language: Shell Script", "", proc(app: ^App) { app.set_language(.Shell) }},
	{"Language: PowerShell", "", proc(app: ^App) { app.set_language(.PowerShell) }},
	{"Language: Batch", "", proc(app: ^App) { app.set_language(.Batch) }},
	{"Language: YAML", "", proc(app: ^App) { app.set_language(.YAML) }},
	{"Language: TOML", "", proc(app: ^App) { app.set_language(.TOML) }},
	{"Language: INI / Config", "", proc(app: ^App) { app.set_language(.INI) }},
	{"Language: CSS", "", proc(app: ^App) { app.set_language(.CSS) }},
	{"Language: Markdown", "", proc(app: ^App) { app.set_language(.Markdown) }},
	{"Language: HTML / XML", "", proc(app: ^App) { app.set_language(.HTML) }},
	{"Settings: Cycle Tab Width (2/4/8)", "", proc(app: ^App) {
		tab_w = 2 if tab_w == 8 else tab_w * 2
		_ = settings_save_key("editor", "tab-width", fmt.tprintf("%d", tab_w))
		app.set_status(fmt.tprintf("tab width: %d", tab_w))
	}},
	{"Settings: Toggle Smart Word Movement", "", proc(app: ^App) {
		smart_word = !smart_word
		_ = settings_save_key("editor", "smart-word", "true" if smart_word else "false")
		app.set_status("word movement: smart (subwords)" if smart_word else "word movement: whole words")
	}},
	{"Settings: Open Settings", "", proc(app: ^App) { app.settings_open(project = false) }},
	{"Settings: Open Project Settings", "", proc(app: ^App) { app.settings_open(project = true) }},
	{"Settings: Toggle Outline Fields", "", proc(app: ^App) {
		app.outline_fields = !app.outline_fields
		_ = settings_save_key("editor", "outline-fields", "true" if app.outline_fields else "false")
		app.set_status("outline: fields shown" if app.outline_fields else "outline: fields hidden")
	}},
	{"Theme: Tokyo Night", "", proc(app: ^App) { app.theme_apply("tokyo-night") }},
	{"Theme: Tokyo Day (light)", "", proc(app: ^App) { app.theme_apply("tokyo-day") }},
	{"Theme: Paper (light, high contrast)", "", proc(app: ^App) { app.theme_apply("paper") }},
	{"Theme: Gruvbox", "", proc(app: ^App) { app.theme_apply("gruvbox") }},
}

// --- Item plumbing -------------------------------------------------------------

@(private = "file")
palette_items_clear :: proc(p: ^Palette) {
	for &it in p.items {
		delete(it.label)
		delete(it.detail)
		delete(it.matches)
	}
	clear(&p.items)
}

@(private = "file")
push_item :: proc(p: ^Palette, label, detail: string, matches: []int, dim_end := 0, score := 0, data := 0, data2 := 0, kind_ch := rune(0), kind_face := Face.Text) {
	m := make([]int, len(matches))
	copy(m, matches)
	append(&p.items, Palette_Item{
		label     = strings.clone(label),
		detail    = strings.clone(detail),
		matches   = m,
		dim_end   = dim_end,
		score     = score,
		data      = data,
		data2     = data2,
		kind_ch   = kind_ch,
		kind_face = kind_face,
	})
}

palette_destroy :: proc(p: ^Palette) {
	palette_items_clear(p)
	delete(p.items)
	usages_clear(p)
	delete(p.usages)
	symbols_clear(p)
	delete(p.symbols)
	delete(p.sym_path)
	delete(p.sym_query)
	for f in p.files {
		delete(f)
	}
	delete(p.files)
	delete(p.query)
	delete(p.ctx_path)
	delete(p.fileop_dir)
	delete(p.confirm_delete)
	delete(p.saved_cursors)
}

// --- Fuzzy matching ------------------------------------------------------------

@(private = "file")
ascii_lower :: proc(c: u8) -> u8 {
	return c + 32 if 'A' <= c && c <= 'Z' else c
}

// Case-insensitive and separator-agnostic ('/' finds '\' paths on Windows).
@(private = "file")
norm_byte :: proc(c: u8) -> u8 {
	return '/' if c == '\\' else ascii_lower(c)
}

@(private = "file")
is_word_boundary :: proc(c: u8) -> bool {
	switch c {
	case '/', '\\', '_', '-', '.', ' ', ':':
		return true
	}
	return false
}

// ctrl+arrow hops in the input: over one run of separators, then one run of
// word bytes. Any ASCII punctuation separates (so a hop never swallows a
// mode prefix like '>'); multi-byte runes always count as word bytes.
@(private = "file")
input_boundary :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return false
	}
	return c < 0x80
}

@(private = "file")
input_word_left :: proc(q: string, caret: int) -> int {
	i := caret
	for i > 0 && input_boundary(q[i-1]) {
		i -= 1
	}
	for i > 0 && !input_boundary(q[i-1]) {
		i -= 1
	}
	return i
}

@(private = "file")
input_word_right :: proc(q: string, caret: int) -> int {
	i := caret
	for i < len(q) && input_boundary(q[i]) {
		i += 1
	}
	for i < len(q) && !input_boundary(q[i]) {
		i += 1
	}
	return i
}

// Greedy fuzzy subsequence match, ASCII-case-insensitive. Fills matches with
// the byte offsets of matched bytes; higher score = better. Matches at or
// past bonus_from (the basename for paths) score extra.
@(private)
fuzzy_match :: proc(pattern, s: string, bonus_from: int, matches: ^[dynamic]int) -> (score: int, ok: bool) {
	clear(matches)
	if len(pattern) == 0 {
		return 0, true
	}
	pi := 0
	prev := -2
	for si in 0 ..< len(s) {
		if pi >= len(pattern) {
			break
		}
		if norm_byte(pattern[pi]) != norm_byte(s[si]) {
			continue
		}
		bonus := 1
		if si == 0 || is_word_boundary(s[si-1]) {
			bonus += 8
		} else if prev == si-1 {
			bonus += 5
		}
		if 'A' <= s[si] && s[si] <= 'Z' && si > 0 && 'a' <= s[si-1] && s[si-1] <= 'z' {
			bonus += 4 // camelCase hump
		}
		if si >= bonus_from {
			bonus += 6
		}
		score += bonus
		append(matches, si)
		prev = si
		pi += 1
	}
	if pi < len(pattern) {
		return 0, false
	}
	score -= (len(s) - len(pattern)) / 8 // mildly prefer shorter candidates
	return score, true
}

// --- Mode: files (no prefix) ---------------------------------------------------

// Byte offset where a path's basename starts.
@(private = "file")
base_start :: proc(path: string) -> int {
	return strings.last_index_any(path, "/\\") + 1
}

// Path-aware match. A pattern without separators fuzzy-matches the whole
// path. With separators ("editor/", "core/od/tok"), each segment before the
// last must fuzzy-match one directory component, in order — so "editor/"
// narrows to files under a dir matching "editor" — and the last segment
// fuzzy-matches the rest of the path (empty = everything under those dirs).
@(private)
path_match :: proc(pattern, path: string, matches: ^[dynamic]int) -> (score: int, ok: bool) {
	if strings.index_any(pattern, "/\\") < 0 {
		return fuzzy_match(pattern, path, base_start(path), matches)
	}
	clear(matches)

	segs := make([dynamic]string, context.temp_allocator)
	seg_start := 0
	for i in 0 ..< len(pattern) {
		if pattern[i] == '/' || pattern[i] == '\\' {
			append(&segs, pattern[seg_start:i])
			seg_start = i + 1
		}
	}
	append(&segs, pattern[seg_start:]) // last = file segment, may be ""

	// Byte offset of each path component (the last one is the basename).
	comp_off := make([dynamic]int, context.temp_allocator)
	append(&comp_off, 0)
	for i in 0 ..< len(path) {
		if path[i] == '/' || path[i] == '\\' {
			append(&comp_off, i+1)
		}
	}
	ncomp := len(comp_off)

	sub := make([dynamic]int, context.temp_allocator)
	ci := 0
	for seg in segs[:len(segs)-1] {
		if len(seg) == 0 {
			continue
		}
		found := false
		for ci < ncomp-1 { // directory components only
			comp := path[comp_off[ci] : comp_off[ci+1]-1]
			s, mok := fuzzy_match(seg, comp, len(comp)+1, &sub)
			ci += 1
			if mok {
				score += s
				for m in sub {
					append(matches, comp_off[ci-1]+m)
				}
				found = true
				break
			}
		}
		if !found {
			return 0, false
		}
	}

	// The file segment matches anywhere in the rest of the path, so
	// "editor/buf" still finds files in subdirectories of editor.
	rest_off := comp_off[ci]
	file_seg := segs[len(segs)-1]
	if len(file_seg) > 0 {
		s, mok := fuzzy_match(file_seg, path[rest_off:], base_start(path)-rest_off, &sub)
		if !mok {
			return 0, false
		}
		score += s
		for m in sub {
			append(matches, rest_off+m)
		}
	}
	return score, true
}

@(private = "file")
scan_files :: proc(files: ^[dynamic]string) {
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, "")
	for len(stack) > 0 && len(files) < MAX_SCAN_FILES {
		dir := pop(&stack)
		infos, err := os.read_all_directory_by_path(dir if dir != "" else ".", context.temp_allocator)
		if err != nil {
			continue
		}
		for info in infos {
			if info.name == ".git" {
				continue
			}
			path: string
			if dir == "" {
				path = strings.clone(info.name, context.temp_allocator)
			} else {
				path, _ = filepath.join({dir, info.name}, context.temp_allocator)
			}
			if info.type == .Directory {
				append(&stack, path)
			} else if len(files) < MAX_SCAN_FILES {
				append(files, strings.clone(path))
			}
		}
	}
	slice.sort(files[:])
}

@(private = "file")
Scored_File :: struct {
	file:    int,
	score:   int,
	matches: []int, // temp-allocated
}

@(private = "file")
files_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	if !p.scanned {
		p.scanned = true
		scan_files(&p.files)
	}

	// Spaces in the pattern are ignored, like vscode's quick open.
	pat_b := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< len(q) {
		if q[i] != ' ' {
			append(&pat_b, q[i])
		}
	}
	pat := string(pat_b[:])

	if len(pat) == 0 {
		for path in p.files {
			if len(p.items) >= MAX_PALETTE_ITEMS {
				break
			}
			push_item(p, path, "", nil, dim_end = base_start(path))
		}
		return
	}

	scored := make([dynamic]Scored_File, context.temp_allocator)
	ms := make([dynamic]int, context.temp_allocator)
	for path, fi in p.files {
		s, ok := path_match(pat, path, &ms)
		if !ok {
			continue
		}
		m := make([]int, len(ms), context.temp_allocator)
		copy(m, ms[:])
		append(&scored, Scored_File{fi, s, m})
	}
	// Tie-break on the file index so equal scores stay alphabetical
	// (matters for directory browsing, where every file scores the same).
	slice.sort_by(scored[:], proc(a, b: Scored_File) -> bool {
		return a.score > b.score || (a.score == b.score && a.file < b.file)
	})
	for sc in scored {
		if len(p.items) >= MAX_PALETTE_ITEMS {
			break
		}
		path := p.files[sc.file]
		push_item(p, path, "", sc.matches, dim_end = base_start(path), score = sc.score)
	}
}

@(private = "file")
files_accept :: proc(app: ^App, it: ^Palette_Item) {
	app.open_file(it.label)
}

// --- Mode: commands (>) ----------------------------------------------------------

@(private = "file")
commands_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	ms := make([dynamic]int, context.temp_allocator)
	for cmd, ci in PALETTE_COMMANDS {
		s, ok := fuzzy_match(q, cmd.name, 0, &ms)
		if !ok {
			continue
		}
		push_item(p, cmd.name, cmd.key, ms[:], score = s, data = ci)
	}
	// Recent workspaces ride along as commands (data past the static list).
	for dir, di in app.recent_dirs {
		label := fmt.tprintf("Open Recent: %s", dir)
		s, ok := fuzzy_match(q, label, 0, &ms)
		if !ok {
			continue
		}
		push_item(p, label, "", ms[:], score = s, data = len(PALETTE_COMMANDS)+di)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
commands_accept :: proc(app: ^App, it: ^Palette_Item) {
	if it.data >= len(PALETTE_COMMANDS) {
		// recent_dirs_add reshuffles the list this string lives in; the
		// workspace switch needs its own copy.
		dir := strings.clone(app.recent_dirs[it.data-len(PALETTE_COMMANDS)], context.temp_allocator)
		app.open_workspace(dir)
		return
	}
	PALETTE_COMMANDS[it.data].run(app)
}

// --- Mode: document search (/) ---------------------------------------------------

// ASCII-case-insensitive substring search (byte offsets stay aligned, unlike
// a to_lower round trip on multi-byte runes).
@(private = "file")
index_nocase :: proc(hay, needle: string) -> int {
	if len(needle) == 0 || len(needle) > len(hay) {
		return -1
	}
	n0 := ascii_lower(needle[0])
	outer: for i in 0 ..= len(hay) - len(needle) {
		if ascii_lower(hay[i]) != n0 {
			continue
		}
		for j in 1 ..< len(needle) {
			if ascii_lower(hay[i+j]) != ascii_lower(needle[j]) {
				continue outer
			}
		}
		return i
	}
	return -1
}

@(private = "file")
search_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	if len(q) == 0 {
		return
	}
	// Smartcase: all-lowercase queries match case-insensitively.
	sensitive := false
	for i in 0 ..< len(q) {
		if 'A' <= q[i] && q[i] <= 'Z' {
			sensitive = true
			break
		}
	}

	ms := make([dynamic]int, context.temp_allocator)
	outer: for line in 0 ..< app.buf.line_count() {
		s := app.buf.line_str(line)
		off := 0
		for {
			idx := strings.index(s[off:], q) if sensitive else index_nocase(s[off:], q)
			if idx < 0 {
				break
			}
			col := off + idx

			// Window the label around the match so huge lines stay cheap;
			// snap the cut points to rune boundaries.
			start := 0
			for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
				start += 1
			}
			if col-start > 160 {
				start = col - 24
				for start > 0 && s[start]&0xC0 == 0x80 {
					start -= 1
				}
			}
			start = min(start, col)
			end := min(len(s), col + len(q) + 200)
			for end < len(s) && s[end]&0xC0 == 0x80 {
				end += 1
			}

			clear(&ms)
			for b in col - start ..< col - start + len(q) {
				append(&ms, b)
			}
			push_item(p, s[start:end], fmt.tprintf("%d:%d", line+1, col+1), ms[:], data = line, data2 = col)
			if len(p.items) >= MAX_SEARCH_MATCHES {
				break outer
			}
			off = col + max(len(q), 1)
		}
	}
}

@(private = "file")
search_preview :: proc(app: ^App, it: ^Palette_Item) {
	start := app.buf.clamp_pos(Pos{it.data, it.data2})
	end := app.buf.clamp_pos(Pos{it.data, it.data2 + len(it.matches)})
	clear(&app.cursors)
	append(&app.cursors, Cursor{head = end, anchor = start, goal_col = -1})
	app.primary = 0
	app.want_follow = true
	app.blink_reset()
}

// --- Mode: go to line (:) --------------------------------------------------------

@(private = "file")
goto_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	if len(q) == 0 {
		return
	}
	parts := strings.split(q, ":", context.temp_allocator)
	if len(parts) > 2 {
		return
	}
	line, lok := strconv.parse_int(parts[0], 10)
	if !lok {
		return
	}
	col := 1
	if len(parts) == 2 {
		c, cok := strconv.parse_int(parts[1], 10)
		if !cok {
			return
		}
		col = max(c, 1)
	}
	line = clamp(line, 1, app.buf.line_count())
	label: string
	if len(parts) == 2 {
		label = fmt.tprintf("Go to line %d, column %d", line, col)
	} else {
		label = fmt.tprintf("Go to line %d", line)
	}
	push_item(p, label, "", nil, data = line-1, data2 = col-1)
}

@(private = "file")
goto_preview :: proc(app: ^App, it: ^Palette_Item) {
	col := col_from_visual(&app.buf, it.data, it.data2)
	pos := app.buf.clamp_pos(Pos{it.data, col})
	clear(&app.cursors)
	append(&app.cursors, cursor_at(pos))
	app.primary = 0
	app.want_follow = true
	app.blink_reset()
}

@(private = "file")
accept_nothing :: proc(app: ^App, it: ^Palette_Item) {
	// Live modes already moved the cursor in preview; enter just keeps it.
}

// --- Mode: context menu (ctrl+. / right-click) -------------------------------------

@(private = "file")
Ctx_Action :: enum {
	Open_File,
	Local_Goto,
	Local_Copy_Value,
	Local_Copy_Pair,
	Locals_Copy_All,
	New_File,
	New_Folder,
	Rename_Path,
	Delete_Path,
	Reveal,
	Copy_Path,
	Copy_Rel_Path,
	Copy_Name,
	Copy_Path_Line,
	Copy_Abs_Path_Line,
	Copy,
	Cut,
	Paste,
	Select_Occurrences,
	Search_Selection,
	Toggle_Comment,
	Duplicate,
	Move_Up,
	Move_Down,
	Uppercase,
	Lowercase,
	Goto_Definition,
	Find_Usages,
	Rename_Symbol,
}

// What the editor context actions operate on: the primary selection if there
// is one (single line only, for display/search), else the word under the
// cursor. "" if neither.
@(private = "file")
context_needle :: proc(app: ^App) -> string {
	pc := app.primary_cursor()
	r := cursor_range(pc^)
	if range_empty(r) {
		r = app.buf.word_range_at(pc.head)
		if range_empty(r) {
			return ""
		}
	}
	if r.start.line != r.end.line {
		return ""
	}
	return app.buf.range_text(r, context.temp_allocator)
}

@(private = "file")
context_refresh :: proc(app: ^App, q: string) {
	p := &app.palette

	Entry :: struct {
		label:  string,
		action: Ctx_Action,
	}
	entries := make([dynamic]Entry, context.temp_allocator)

	if p.ctx_local >= 0 && p.ctx_local < len(app.dap.locals) {
		// A debugger local (right-click in the panel's locals column).
		v := &app.dap.locals[p.ctx_local]
		append(&entries, Entry{fmt.tprintf("Go to Declaration of %s", v.name), .Local_Goto})
		append(&entries, Entry{"Copy Value", .Local_Copy_Value})
		append(&entries, Entry{fmt.tprintf("Copy %s = …", v.name), .Local_Copy_Pair})
		append(&entries, Entry{"Copy All Locals", .Locals_Copy_All})
	} else if len(p.ctx_path) > 0 {
		// File or directory context (sidebar right-click, or ctrl+. on a
		// palette file item). "." is the workspace root row.
		is_root := p.ctx_path == "."
		name := p.ctx_path[base_start(p.ctx_path):]
		if !p.ctx_is_dir {
			append(&entries, Entry{fmt.tprintf("Open %s", name), .Open_File})
		}
		append(&entries, Entry{"New File…", .New_File})
		append(&entries, Entry{"New Folder…", .New_Folder})
		if !is_root {
			append(&entries, Entry{fmt.tprintf("Rename %s…", name), .Rename_Path})
			if p.confirm_delete == p.ctx_path {
				append(&entries, Entry{fmt.tprintf("Confirm Delete %s", name), .Delete_Path})
			} else {
				append(&entries, Entry{fmt.tprintf("Delete %s", name), .Delete_Path})
			}
		}
		append(&entries, Entry{REVEAL_LABEL, .Reveal})
		append(&entries, Entry{"Copy Path", .Copy_Path})
		if !is_root {
			append(&entries, Entry{"Copy Relative Path", .Copy_Rel_Path})
			append(&entries, Entry{"Copy File Name", .Copy_Name})
		}
	} else {
		// Editor context: selection or symbol under the cursor.
		needle := context_needle(app)
		if len(needle) > 0 {
			short := needle
			if len(short) > 24 {
				short = fmt.tprintf("%s…", short[:24])
			}
			if app.lsp.state == .Ready {
				append(&entries, Entry{fmt.tprintf("Go to Definition of \"%s\"", short), .Goto_Definition})
				append(&entries, Entry{fmt.tprintf("Find Usages of \"%s\"", short), .Find_Usages})
				append(&entries, Entry{fmt.tprintf("Rename \"%s\"…", short), .Rename_Symbol})
			}
			append(&entries, Entry{fmt.tprintf("Select All Occurrences of \"%s\"", short), .Select_Occurrences})
			append(&entries, Entry{fmt.tprintf("Search Document for \"%s\"", short), .Search_Selection})
		}
		has_sel := cursor_has_selection(app.primary_cursor()^)
		append(&entries, Entry{"Copy" if has_sel else "Copy Line", .Copy})
		append(&entries, Entry{"Cut" if has_sel else "Cut Line", .Cut})
		append(&entries, Entry{"Paste", .Paste})
		append(&entries, Entry{"Duplicate", .Duplicate})
		append(&entries, Entry{"Toggle Line Comment", .Toggle_Comment})
		append(&entries, Entry{"Move Lines Up", .Move_Up})
		append(&entries, Entry{"Move Lines Down", .Move_Down})
		if has_sel {
			append(&entries, Entry{"Transform to Uppercase", .Uppercase})
			append(&entries, Entry{"Transform to Lowercase", .Lowercase})
		}
		if app.buf.path != "" {
			append(&entries, Entry{"Copy Relative Path : Line", .Copy_Path_Line})
			append(&entries, Entry{"Copy Absolute Path : Line", .Copy_Abs_Path_Line})
		}
	}

	ms := make([dynamic]int, context.temp_allocator)
	for e in entries {
		s, ok := fuzzy_match(q, e.label, 0, &ms)
		if !ok {
			continue
		}
		push_item(p, e.label, "", ms[:], score = s, data = int(e.action))
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
context_accept :: proc(app: ^App, it: ^Palette_Item) {
	p := &app.palette
	action := Ctx_Action(it.data) // before any re-open below frees the item
	switch action {
	case .Open_File:
		app.open_file(p.ctx_path)
	case .Local_Goto:
		app.dap_local_goto(p.ctx_local)
	case .Local_Copy_Value:
		if p.ctx_local >= 0 && p.ctx_local < len(app.dap.locals) {
			clipboard_set(app.dap.locals[p.ctx_local].value)
			app.set_status("value copied")
		}
	case .Local_Copy_Pair:
		if p.ctx_local >= 0 && p.ctx_local < len(app.dap.locals) {
			v := &app.dap.locals[p.ctx_local]
			clipboard_set(fmt.tprintf("%s = %s", v.name, v.value))
			app.set_status("copied")
		}
	case .Locals_Copy_All:
		sb := strings.builder_make(context.temp_allocator)
		for v in app.dap.locals {
			strings.write_string(&sb, fmt.tprintf("%s = %s\n", v.name, v.value))
		}
		clipboard_set(strings.to_string(sb))
		app.set_status(fmt.tprintf("copied %d locals", len(app.dap.locals)))
	case .New_File, .New_Folder:
		// Create in the directory itself, or next to the file.
		dir := p.ctx_path if p.ctx_is_dir else p.ctx_path[:max(base_start(p.ctx_path)-1, 0)]
		app.open_fileop_prompt(.New_File if action == .New_File else .New_Folder, dir)
	case .Rename_Path:
		app.open_fileop_prompt(.Rename, "")
	case .Delete_Path:
		if p.confirm_delete == p.ctx_path {
			app.fs_delete(p.ctx_path, p.ctx_is_dir)
			delete(p.confirm_delete)
			p.confirm_delete = ""
		} else {
			delete(p.confirm_delete)
			p.confirm_delete = strings.clone(p.ctx_path)
			// Rebuild the menu so the entry reads "Confirm Delete" and is
			// already selected; enter again performs it, esc backs out.
			app.open_context_file(p.ctx_path, p.ctx_is_dir)
			for item, i in p.items {
				if Ctx_Action(item.data) == .Delete_Path {
					p.sel = i
					break
				}
			}
			app.set_status("enter again to delete")
			p.keep_open = true
		}
	case .Reveal:
		app.reveal_in_file_manager(p.ctx_path)
	case .Copy_Path:
		clipboard_set(abs_path(p.ctx_path))
		app.set_status("absolute path copied")
	case .Copy_Rel_Path:
		clipboard_set(shorten_path(abs_path(p.ctx_path)))
		app.set_status("relative path copied")
	case .Copy_Name:
		clipboard_set(p.ctx_path[base_start(p.ctx_path):])
		app.set_status("file name copied")
	case .Copy_Path_Line:
		loc := fmt.tprintf("%s:%d",
			shorten_path(abs_path(app.buf.path)), app.primary_cursor().head.line+1)
		clipboard_set(loc)
		app.set_status(fmt.tprintf("copied %s", loc))
	case .Copy_Abs_Path_Line:
		loc := fmt.tprintf("%s:%d", abs_path(app.buf.path), app.primary_cursor().head.line+1)
		clipboard_set(loc)
		app.set_status(fmt.tprintf("copied %s", loc))
	case .Copy:
		clipboard_set(app.copy_text())
	case .Cut:
		clipboard_set(app.cut_text())
	case .Paste:
		app.paste(clipboard_get())
	case .Select_Occurrences:
		app.select_all_matches()
	case .Search_Selection:
		needle := context_needle(app)
		app.palette_open_with(strings.concatenate({"/", needle}, context.temp_allocator))
		p.keep_open = true
	case .Toggle_Comment:
		app.toggle_comment()
	case .Duplicate:
		app.duplicate()
	case .Move_Up:
		app.move_lines(down = false)
	case .Move_Down:
		app.move_lines(down = true)
	case .Uppercase:
		app.transform_case(true)
	case .Lowercase:
		app.transform_case(false)
	case .Goto_Definition:
		app.lsp_goto_definition()
	case .Find_Usages:
		app.lsp_find_references()
	case .Rename_Symbol:
		app.lsp_rename_prompt()
		p.keep_open = true // the rename prompt replaced the menu
	}
}

// --- Mode: usages (LSP references) --------------------------------------------------

// Frees the location list backing the usages mode.
usages_clear :: proc(p: ^Palette) {
	for u in p.usages {
		delete(u.path)
	}
	clear(&p.usages)
}

@(private = "file")
usages_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	ms := make([dynamic]int, context.temp_allocator)
	for u, i in p.usages {
		label: string
		if u.path == app.buf.path && u.line < app.buf.line_count() {
			label = strings.trim_left(app.buf.line_str(u.line), " \t")
		} else {
			label = u.path
		}
		s, ok := fuzzy_match(q, label, 0, &ms)
		if !ok {
			continue
		}
		push_item(p, label, fmt.tprintf("%s:%d", u.path, u.line+1), ms[:], score = s, data = i)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
usages_preview :: proc(app: ^App, it: ^Palette_Item) {
	loc := app.palette.usages[it.data] // copy: open_preview switches documents
	if loc.path != app.buf.path {
		if !app.open_preview(loc.path) {
			return
		}
	}
	app.lsp_select_range(loc)
}

@(private = "file")
usages_accept :: proc(app: ^App, it: ^Palette_Item) {
	loc := app.palette.usages[it.data] // used before close frees the list
	app.lsp_jump(loc)
}

// --- Modes: document outline (!) and workspace symbols (#) ----------------------------

// Frees the symbol list backing the ! and # modes.
symbols_clear :: proc(p: ^Palette) {
	for s in p.symbols {
		delete(s.name)
		delete(s.detail)
		delete(s.path)
	}
	clear(&p.symbols)
}

// LSP SymbolKind → (badge letter, face), like the completion popup.
@(private = "file")
sym_kind_badge :: proc(kind: int) -> (rune, Face) {
	switch kind {
	case 5, 10, 11, 23, 26: // class, enum, interface, struct, type parameter
		return 't', .Type
	case 6, 9, 12, 25: // method, constructor, function, operator
		return 'f', .Function
	case 7, 8, 20: // property, field, key
		return '.', .Key
	case 14, 16, 17, 22: // constant, number, boolean, enum member
		return 'c', .Constant
	case 1, 2, 3, 4: // file, module, namespace, package
		return 'M', .Directive
	}
	return 'v', .Text
}

@(private = "file")
outline_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	// Refetch when the cached outline is for another document or version.
	if p.sym_mode != .Outline || p.sym_path != app.buf.path || p.sym_version != app.buf.version {
		app.lsp_doc_symbols()
	}
	ms := make([dynamic]int, context.temp_allocator)
	for &s, i in p.symbols {
		if len(p.items) >= MAX_PALETTE_ITEMS {
			break
		}
		// Struct fields/properties are noise in most outlines — hidden
		// unless ">Settings: Toggle Outline Fields" says otherwise.
		if !app.outline_fields && (s.kind == 7 || s.kind == 8 || s.kind == 20) {
			continue
		}
		indent := strings.repeat("  ", s.depth, context.temp_allocator)
		label := strings.concatenate({indent, s.name}, context.temp_allocator)
		score, ok := fuzzy_match(q, label, 0, &ms)
		if !ok {
			continue
		}
		detail := s.detail
		if detail == "" {
			detail = fmt.tprintf(":%d", s.line+1)
		}
		ch, face := sym_kind_badge(s.kind)
		push_item(p, label, detail, ms[:], score = score, data = i, kind_ch = ch, kind_face = face)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
outline_preview :: proc(app: ^App, it: ^Palette_Item) {
	s := &app.palette.symbols[it.data]
	app.lsp_select_range(Lsp_Location{path = app.buf.path, line = s.line, char = s.char, eline = s.eline, echar = s.echar})
}

@(private = "file")
wsymbols_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	// The server does the searching; re-ask when the query changes.
	if p.sym_mode != .Workspace || p.sym_query != q {
		app.lsp_workspace_symbols(q)
	}
	ms := make([dynamic]int, context.temp_allocator)
	for &s, i in p.symbols {
		if len(p.items) >= MAX_PALETTE_ITEMS {
			break
		}
		score, ok := fuzzy_match(q, s.name, 0, &ms)
		if !ok {
			continue
		}
		ch, face := sym_kind_badge(s.kind)
		push_item(p, s.name, fmt.tprintf("%s:%d", s.path, s.line+1), ms[:],
			score = score, data = i, kind_ch = ch, kind_face = face)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
wsymbols_preview :: proc(app: ^App, it: ^Palette_Item) {
	s := app.palette.symbols[it.data] // copy: open_preview switches documents
	loc := Lsp_Location{path = s.path, line = s.line, char = s.char, eline = s.eline, echar = s.echar}
	if loc.path != app.buf.path {
		if !app.open_preview(loc.path) {
			return
		}
	}
	app.lsp_select_range(loc)
}

@(private = "file")
wsymbols_accept :: proc(app: ^App, it: ^Palette_Item) {
	s := app.palette.symbols[it.data]
	app.lsp_jump(Lsp_Location{path = s.path, line = s.line, char = s.char, eline = s.eline, echar = s.echar})
}

// --- Mode: problems (?) --------------------------------------------------------------

// "E: msg" labels make severity part of the searchable text ("?E:" filters
// down to errors). The path matches too, so "?main" works.
@(private = "file")
problems_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	ms := make([dynamic]int, context.temp_allocator)
	for d, i in app.problems {
		if len(p.items) >= MAX_PALETTE_ITEMS {
			break
		}
		label := fmt.tprintf("%s: %s", severity_letter(d.severity), d.msg)
		loc := fmt.tprintf("%s:%d", d.path, d.line+1)
		score, ok := fuzzy_match(q, label, 0, &ms)
		if !ok {
			// Match against the location too, without highlight offsets
			// (they would index into the wrong string).
			if score, ok = fuzzy_match(q, loc, 0, &ms); ok {
				clear(&ms)
			}
		}
		if !ok {
			continue
		}
		push_item(p, label, loc, ms[:], score = score, data = i)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
problems_pal_accept :: proc(app: ^App, it: ^Palette_Item) {
	if it.data < len(app.problems) {
		app.problem_jump(it.data)
	}
}

@(private = "file")
problems_pal_preview :: proc(app: ^App, it: ^Palette_Item) {
	if it.data >= len(app.problems) {
		return
	}
	d := app.problems[it.data] // copy: open_preview switches documents
	loc := Lsp_Location{path = d.path, line = d.line, char = d.char, eline = d.eline, echar = d.echar}
	if loc.path != app.buf.path {
		if !app.open_preview(loc.path) {
			return
		}
	}
	app.lsp_select_range(loc)
}

// --- Mode: rename symbol (F2) --------------------------------------------------------

@(private = "file")
rename_refresh :: proc(app: ^App, q: string) {
	if len(q) == 0 {
		return
	}
	push_item(&app.palette, fmt.tprintf("Rename symbol to \"%s\"", q), "enter", nil)
}

@(private = "file")
rename_accept :: proc(app: ^App, it: ^Palette_Item) {
	name := strings.trim_space(string(app.palette.query[:]))
	if len(name) > 0 {
		app.lsp_rename(app.palette.ctx_pos, name)
	}
}

// --- Mode: file-op prompt (new file / new folder / rename on disk) --------------------

@(private = "file")
fileop_target :: proc(p: ^Palette, name: string) -> string {
	t, err := filepath.join({p.fileop_dir if p.fileop_dir != "" else ".", name}, context.temp_allocator)
	return name if err != nil else t
}

@(private = "file")
fileop_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	if len(q) == 0 {
		return
	}
	switch p.fileop {
	case .New_File:
		push_item(p, fmt.tprintf("Create file %s", fileop_target(p, q)), "enter", nil)
	case .New_Folder:
		push_item(p, fmt.tprintf("Create folder %s", fileop_target(p, q)), "enter", nil)
	case .Rename:
		push_item(p, fmt.tprintf("Rename %s to \"%s\"", p.ctx_path[base_start(p.ctx_path):], q), "enter", nil)
	case .None:
	}
}

@(private = "file")
fileop_accept :: proc(app: ^App, it: ^Palette_Item) {
	p := &app.palette
	name := strings.trim_space(string(p.query[:]))
	if len(name) == 0 {
		return
	}
	switch p.fileop {
	case .New_File:
		app.fs_create(p.fileop_dir, name, is_dir = false)
	case .New_Folder:
		app.fs_create(p.fileop_dir, name, is_dir = true)
	case .Rename:
		app.fs_rename(p.ctx_path, name)
	case .None:
	}
}

// --- Mode: tasks (ctrl+shift+r) --------------------------------------------------------

@(private = "file")
tasks_refresh :: proc(app: ^App, q: string) {
	p := &app.palette
	tasks_load(&app.task) // tiny file; reloading per keystroke keeps it live
	ms := make([dynamic]int, context.temp_allocator)
	for t, i in app.task.tasks {
		s, ok := fuzzy_match(q, t.name, 0, &ms)
		if !ok {
			continue
		}
		push_item(p, t.name, t.cmd, ms[:], score = s, data = i, kind_ch = '>', kind_face = .Function)
	}
	if len(q) > 0 {
		slice.sort_by(p.items[:], proc(a, b: Palette_Item) -> bool { return a.score > b.score })
	}
}

@(private = "file")
tasks_accept :: proc(app: ^App, it: ^Palette_Item) {
	app.task_run(it.data)
}

// --- Palette state machine -------------------------------------------------------

impl App {
	palette_open_with :: proc(prefill: string, forced := -1) {
		if !palette.open {
			palette.open = true
			palette.home_doc = active
			clear(&palette.saved_cursors)
			for c in cursors {
				append(&palette.saved_cursors, c)
			}
			palette.saved_scroll_x = scroll_x
			palette.saved_scroll_y = scroll_y
		}
		palette.forced_mode = forced
		clear(&palette.query)
		append(&palette.query, prefill)
		palette.caret = len(palette.query)
		self.palette_refresh()
		// A prefill past the mode prefix (search term, rename name) starts
		// selected, ready to be typed over.
		palette.sel_anchor = min(len(PALETTE_MODES[palette.mode_i].prefix), len(palette.query))
		self.blink_reset()
	}

	// ctrl+f: document search, prefilled with the primary selection when it
	// is a single-line one.
	open_search :: proc() {
		needle := ""
		pc := self.primary_cursor()
		if cursor_has_selection(pc^) {
			r := cursor_range(pc^)
			if r.start.line == r.end.line {
				needle = buf.range_text(r, context.temp_allocator)
			}
		}
		self.palette_open_with(strings.concatenate({"/", needle}, context.temp_allocator))
	}

	// The task picker (ctrl+shift+r, or typing "$" in the palette). With no
	// tasks yet it opens the config instead — created from a template on
	// first use. Returns whether the palette was (re)opened, so command
	// accepts can set keep_open.
	task_picker :: proc() -> bool {
		tasks_load(&task)
		if len(task.tasks) == 0 {
			self.task_edit_config()
			self.set_status("no tasks yet — define some in " + TASKS_PATH)
			return false
		}
		self.palette_open_with("$")
		return true
	}

	// ctrl+p while the palette is open: back to the file finder, or — when
	// already there — close it (so ctrl+p stays a toggle).
	palette_toggle_files :: proc() {
		if palette.mode_i == PALETTE_MODE_FILES && palette.forced_mode < 0 {
			self.palette_cancel()
		} else {
			self.palette_open_with("")
		}
	}

	// ctrl+. anywhere in the editor: context actions for the selection or
	// the word under the cursor.
	open_context_editor :: proc() {
		delete(palette.ctx_path)
		palette.ctx_path = ""
		palette.ctx_local = -1
		self.palette_open_with("", forced = PALETTE_MODE_CONTEXT)
	}

	// Context actions for a file or directory (sidebar right-click, palette
	// file item, tab right-click).
	open_context_file :: proc(path: string, is_dir := false) {
		np := strings.clone(path) // before open_with frees the item it may come from
		delete(palette.ctx_path)
		palette.ctx_path = np
		palette.ctx_is_dir = is_dir
		palette.ctx_local = -1
		self.palette_open_with("", forced = PALETTE_MODE_CONTEXT)
	}

	// Context actions for a debugger local (locals column right-click).
	open_context_local :: proc(i: int) {
		delete(palette.ctx_path)
		palette.ctx_path = ""
		palette.ctx_local = i
		self.palette_open_with("", forced = PALETTE_MODE_CONTEXT)
	}

	// Ask for a name, then run a file op on enter (the fileop palette mode).
	// dir is where New File / New Folder create; a rename targets ctx_path
	// and prefills its current name.
	open_fileop_prompt :: proc(op: File_Op, dir: string) {
		nd := strings.clone(dir)
		delete(palette.fileop_dir)
		palette.fileop_dir = nd
		palette.fileop = op
		prefill := palette.ctx_path[base_start(palette.ctx_path):] if op == .Rename else ""
		self.palette_open_with(prefill, forced = PALETTE_MODE_FILEOP)
		palette.keep_open = true
	}

	// ctrl+. while the palette is open: contextualize the selected file item.
	palette_context_here :: proc() {
		p := &palette
		if p.mode_i == PALETTE_MODE_FILES && p.sel < len(p.items) {
			self.open_context_file(p.items[p.sel].label)
		} else if p.mode_i != PALETTE_MODE_CONTEXT {
			self.open_context_editor()
		}
	}

	palette_refresh :: proc() {
		p := &palette
		q := string(p.query[:])
		rest: string
		if p.forced_mode >= 0 {
			p.mode_i = p.forced_mode
			rest = q
		} else {
			p.mode_i = 0
			for m, i in PALETTE_MODES {
				if len(m.prefix) > 0 && strings.has_prefix(q, m.prefix) {
					p.mode_i = i
					break
				}
			}
			rest = q[len(PALETTE_MODES[p.mode_i].prefix):]
		}
		mode := &PALETTE_MODES[p.mode_i]
		palette_items_clear(p)
		p.sel = 0
		p.scroll = 0
		p.hover = -1
		mode.refresh(self, strings.trim_left(rest, " "))
		if mode.preview != nil && len(p.items) > 0 {
			mode.preview(self, &p.items[0])
		}
	}

	// Selected byte range of the input ([lo, hi); lo == hi: no selection).
	palette_sel :: proc() -> (lo, hi: int) {
		return min(palette.caret, palette.sel_anchor), max(palette.caret, palette.sel_anchor)
	}

	palette_select_all :: proc() {
		palette.sel_anchor = 0
		palette.caret = len(palette.query)
		self.blink_reset()
	}

	// Remove the selected input text; false when nothing was selected.
	palette_sel_delete :: proc() -> bool {
		lo, hi := self.palette_sel()
		if lo == hi {
			return false
		}
		remove_range(&palette.query, lo, hi)
		palette.caret = lo
		palette.sel_anchor = lo
		return true
	}

	// ctrl+c / ctrl+x on the input selection.
	palette_copy :: proc(cut: bool) {
		lo, hi := self.palette_sel()
		if lo == hi {
			return
		}
		clipboard_set(string(palette.query[lo:hi]))
		if cut {
			_ = self.palette_sel_delete()
			self.palette_refresh()
			self.blink_reset()
		}
	}

	palette_insert :: proc(text: string) {
		p := &palette
		_ = self.palette_sel_delete() // typing replaces the selection
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, string(p.query[:p.caret]))
		ins := 0
		for ch in text {
			if ch == '\n' || ch == '\r' {
				continue
			}
			strings.write_rune(&sb, ch)
			ins += utf8.rune_size(ch)
		}
		strings.write_string(&sb, string(p.query[p.caret:]))
		clear(&p.query)
		append(&p.query, strings.to_string(sb))
		p.caret += ins
		p.sel_anchor = p.caret
		self.palette_refresh()
		self.blink_reset()
	}

	palette_backspace :: proc() {
		p := &palette
		if self.palette_sel_delete() {
			self.palette_refresh()
			self.blink_reset()
			return
		}
		if p.caret == 0 {
			return
		}
		_, n := utf8.decode_last_rune(p.query[:p.caret])
		remove_range(&p.query, p.caret-n, p.caret)
		p.caret -= n
		p.sel_anchor = p.caret
		self.palette_refresh()
		self.blink_reset()
	}

	palette_delete_forward :: proc() {
		p := &palette
		if self.palette_sel_delete() {
			self.palette_refresh()
			self.blink_reset()
			return
		}
		if p.caret >= len(p.query) {
			return
		}
		_, n := utf8.decode_rune(p.query[p.caret:])
		remove_range(&p.query, p.caret, p.caret+n)
		self.palette_refresh()
		self.blink_reset()
	}

	// d: ±1 = one rune (a word with word), ±2 and beyond = home/end. extend
	// (shift) keeps the selection anchor where it is.
	palette_caret_move :: proc(d: int, extend := false, word := false) {
		p := &palette
		lo, hi := self.palette_sel()
		switch {
		case d < -1:
			p.caret = 0
		case d > 1:
			p.caret = len(p.query)
		case !extend && lo != hi:
			// A plain arrow collapses the selection onto its edge.
			p.caret = lo if d < 0 else hi
		case d == -1 && p.caret > 0:
			if word {
				p.caret = input_word_left(string(p.query[:]), p.caret)
			} else {
				_, n := utf8.decode_last_rune(p.query[:p.caret])
				p.caret -= n
			}
		case d == 1 && p.caret < len(p.query):
			if word {
				p.caret = input_word_right(string(p.query[:]), p.caret)
			} else {
				_, n := utf8.decode_rune(p.query[p.caret:])
				p.caret += n
			}
		}
		if !extend {
			p.sel_anchor = p.caret
		}
		self.blink_reset()
	}

	// d: ±1 wraps around, larger steps (page) clamp.
	palette_move :: proc(d: int) {
		p := &palette
		n := len(p.items)
		if n == 0 {
			return
		}
		if d == -1 || d == 1 {
			p.sel = (p.sel + d + n) % n
		} else {
			p.sel = clamp(p.sel+d, 0, n-1)
		}
		// Keyboard movement drags the window along; wheel scrolling (which
		// leaves sel alone) is free to move away from it.
		vis := min(n, PALETTE_VISIBLE)
		if p.sel < p.scroll {
			p.scroll = p.sel
		}
		if vis > 0 && p.sel >= p.scroll+vis {
			p.scroll = p.sel - vis + 1
		}
		mode := &PALETTE_MODES[p.mode_i]
		if mode.preview != nil {
			mode.preview(self, &p.items[p.sel])
		}
		self.blink_reset()
	}

	palette_accept :: proc() {
		p := &palette
		if p.sel < len(p.items) {
			PALETTE_MODES[p.mode_i].accept(self, &p.items[p.sel])
		}
		if p.keep_open {
			p.keep_open = false // accept morphed into another mode
		} else {
			self.palette_close()
		}
	}

	palette_cancel :: proc() {
		p := &palette
		self.preview_abandon() // back to the home doc before restoring its view
		clear(&cursors)
		for c in p.saved_cursors {
			append(&cursors, Cursor{head = buf.clamp_pos(c.head), anchor = buf.clamp_pos(c.anchor), goal_col = c.goal_col})
		}
		if len(cursors) == 0 {
			append(&cursors, cursor_at(Pos{0, 0}))
		}
		primary = len(cursors) - 1
		scroll_x = p.saved_scroll_x
		scroll_y = p.saved_scroll_y
		self.palette_close()
		self.blink_reset()
	}

	palette_close :: proc() {
		p := &palette
		// The preview tab either becomes real (the user landed on it) or
		// goes away with the palette.
		preview = false
		i := 0
		for i < len(docs) {
			if i != active && docs[i].preview {
				doc_destroy(&docs[i])
				ordered_remove(&docs, i)
				if i < active {
					active -= 1
				}
				tab_follow = true
				continue
			}
			i += 1
		}
		p.open = false
		p.forced_mode = -1
		delete(p.ctx_path)
		p.ctx_path = ""
		p.ctx_local = -1
		p.fileop = .None
		delete(p.confirm_delete) // closing the menu resets the delete arm
		p.confirm_delete = ""
		palette_items_clear(p)
		usages_clear(p)
		for f in p.files {
			delete(f)
		}
		clear(&p.files)
		p.scanned = false
	}

	// --- Mouse ---

	// Item index under a pixel position; -1 for the input row, padding, or
	// anywhere outside the list.
	palette_row_at :: proc(px, py: f32, line_h: f32) -> int {
		p := &palette
		if px < p.lx || px > p.lx+p.lw || py < p.l_row0 || py > p.ly+p.lh {
			return -1
		}
		row := p.scroll + int((py-p.l_row0)/(line_h*UI_ROW_SCALE))
		if row < p.scroll || row >= min(p.scroll+p.l_vis, len(p.items)) {
			return -1
		}
		return row
	}

	palette_mouse :: proc(px, py: f32, cell_w, line_h: f32) {
		p := &palette
		if px < p.lx || px > p.lx+p.lw || py < p.ly || py > p.ly+p.lh {
			self.palette_cancel()
			return
		}
		if py < p.l_row0 {
			// Click in the input row: place the caret (collapses selection).
			q := string(p.query[:])
			ri := max(int((px-p.l_qx)/cell_w + 0.5), 0) // rune index
			off := 0
			for _ in 0 ..< ri {
				if off >= len(q) {
					break
				}
				_, n := utf8.decode_rune(q[off:])
				off += n
			}
			p.caret = off
			p.sel_anchor = off
			self.blink_reset()
			return
		}
		row := self.palette_row_at(px, py, line_h)
		if row >= 0 {
			p.sel = row
			self.palette_accept()
		}
	}

	// Track the row under the mouse for hover feedback.
	palette_motion :: proc(px, py: f32, line_h: f32) {
		palette.hover = self.palette_row_at(px, py, line_h)
	}

	palette_wheel :: proc(dy: f32, line_h: f32) {
		p := &palette
		p.scroll = clamp(p.scroll-int(dy*3), 0, max(0, len(p.items)-p.l_vis))
		// The rows moved under the pointer: re-aim the hover highlight.
		p.hover = self.palette_row_at(mouse_x, mouse_y, line_h)
	}
}

// --- Drawing -----------------------------------------------------------------

// Label with dim prefix, accent-colored match positions, and ellipses; the
// window shifts right if the first match would be off-screen.
@(private = "file")
palette_draw_label :: proc(r: ^Renderer, x, baseline, avail_px: f32, it: ^Palette_Item, t: ^Theme) {
	avail := int(avail_px / r.cell_w)
	if avail < 4 {
		return
	}
	label := it.label

	offs := make([dynamic]int, context.temp_allocator) // byte offset of each rune
	for i := 0; i < len(label); {
		append(&offs, i)
		_, n := utf8.decode_rune(label[i:])
		i += n
	}
	nrunes := len(offs)

	start := 0
	if len(it.matches) > 0 {
		first_rune := 0
		for o, i in offs {
			if o >= it.matches[0] {
				first_rune = i
				break
			}
		}
		if first_rune > avail-12 {
			start = first_rune - avail/3
		}
	}
	start = clamp(start, 0, max(0, nrunes-1))

	mi := 0
	xx := x
	drawn := 0
	if start > 0 {
		push_glyph(r, xx, baseline, '…', t.status_dim)
		xx += r.cell_w
		drawn += 1
	}
	for ri in start ..< nrunes {
		if drawn >= avail-1 && ri < nrunes-1 {
			push_glyph(r, xx, baseline, '…', t.status_dim)
			return
		}
		off := offs[ri]
		ch, _ := utf8.decode_rune(label[off:])
		if ch == '\t' {
			ch = ' '
		}
		for mi < len(it.matches) && it.matches[mi] < off {
			mi += 1
		}
		color := t.fg
		if off < it.dim_end {
			color = t.status_dim
		}
		if mi < len(it.matches) && it.matches[mi] == off {
			color = t.faces[.Function]
		}
		push_glyph(r, xx, baseline, ch, color)
		xx += r.cell_w
		drawn += 1
	}
}

impl App {
	palette_draw :: proc(r: ^Renderer, width, height: f32) {
		if !palette.open {
			return
		}
		p := &palette
		line_h := r.line_h
		cell_w := r.cell_w
		pad := cell_w * 1.5

		draw_str :: proc(r: ^Renderer, x, baseline: f32, s: string, color: Color) -> f32 {
			x := x
			for ch in s {
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
			return x
		}

		// Dim the editor underneath.
		push_rect(r, 0, 0, width, height, Color{0, 0, 0, 0.35})

		mode := &PALETTE_MODES[p.mode_i]
		vis := min(len(p.items), PALETTE_VISIBLE)
		row_h := line_h * UI_ROW_SCALE

		pw := min(cell_w*92, width*0.85)
		px := (width - pw) * 0.5
		py := tabbar_h + line_h*0.6
		input_h := line_h * 1.9
		ph := input_h + f32(max(vis, 1))*row_h + pad*0.8

		push_rect(r, px-1, py-1, pw+2, ph+2, color_alpha(theme.gutter_fg, 0.8))
		push_rect(r, px, py, pw, ph, theme.status_bg)
		push_rect(r, px+pad*0.5, py+(input_h-line_h)*0.5-3, pw-pad, line_h+6, theme.bg)

		// Input: a search glyph, then the prefix in accent, the rest normal,
		// a hint while empty.
		isz_q := line_h * 0.7
		push_icon(r, px+pad*0.6, py+(input_h-isz_q)*0.5, isz_q, .Search, theme.status_dim)
		q := string(p.query[:])
		qx := px + pad*0.6 + isz_q + cell_w*0.6
		p.l_qx = qx
		qbase := py + (input_h-line_h)*0.5 + r.ascent
		if lo, hi := self.palette_sel(); lo != hi {
			sx := qx + f32(strings.rune_count(q[:lo]))*cell_w
			sw := f32(strings.rune_count(q[lo:hi])) * cell_w
			push_rect(r, sx, py+(input_h-line_h)*0.5, sw, line_h, theme.selection)
		}
		x := qx
		for ch, i in q {
			color := theme.faces[.Keyword] if i < len(mode.prefix) else theme.fg
			push_glyph(r, x, qbase, ch, color)
			x += cell_w
		}
		// Match counter, right-aligned in the input row; its left edge also
		// clips the hint so a long one never runs underneath it.
		cnt_x := px + pw - pad
		if len(p.items) > 0 {
			cnt := fmt.tprintf("%d/%d", p.sel+1, len(p.items))
			cnt_x -= f32(len(cnt)) * cell_w
			draw_str(r, cnt_x, qbase, cnt, theme.status_dim)
		}

		if len(q) == len(mode.prefix) {
			hx := x + cell_w*0.5
			for ch in mode.hint {
				if hx+cell_w*2.5 > cnt_x {
					push_glyph(r, hx, qbase, '…', theme.status_dim)
					break
				}
				push_glyph(r, hx, qbase, ch, theme.status_dim)
				hx += cell_w
			}
		}

		// Caret.
		if self.caret_on(true) {
			cx := qx + f32(strings.rune_count(q[:p.caret]))*cell_w
			push_rect(r, cx-1, py+(input_h-line_h)*0.5, 2, line_h, theme.cursor)
		}

		// Rows.
		row0 := py + input_h + pad*0.4
		p.lx = px
		p.ly = py
		p.lw = pw
		p.lh = ph
		p.l_row0 = row0
		p.l_vis = vis

		p.scroll = clamp(p.scroll, 0, max(0, len(p.items)-vis))

		if len(p.items) == 0 {
			if len(q) > len(mode.prefix) {
				draw_str(r, px+pad, row0+(row_h-line_h)*0.5+r.ascent, "no results", theme.status_dim)
			}
			return
		}

		isz := line_h * 0.62
		for vi in 0 ..< vis {
			i := p.scroll + vi
			it := &p.items[i]
			y := row0 + f32(vi)*row_h
			if i == p.sel {
				push_rect(r, px, y, pw, row_h, theme.selection)
			} else if i == p.hover {
				push_rect(r, px, y, pw, row_h, color_alpha(theme.selection, 0.45))
			}
			baseline := y + (row_h-line_h)*0.5 + r.ascent

			right := px + pw - pad
			if len(it.detail) > 0 {
				right -= f32(len(it.detail)) * cell_w
				_ = draw_str(r, right, baseline, it.detail, theme.status_dim)
				right -= cell_w * 2
			}
			lx := px + pad
			if it.kind_ch != 0 {
				push_glyph(r, lx, baseline, it.kind_ch, theme.faces[it.kind_face])
				lx += cell_w * 2
			} else if p.mode_i == PALETTE_MODE_FILES || p.mode_i == PALETTE_MODE_USAGES {
				push_icon(r, lx, y+(row_h-isz)*0.5, isz, .File, color_alpha(theme.status_dim, 0.9))
				lx += isz + cell_w*0.9
			}
			palette_draw_label(r, lx, baseline, right-lx, it, &theme)
		}

		// A slim scrollbar when the list overflows, so wheel scrolling has
		// something to show for itself.
		draw_vscrollbar(r, px+pw, row0, f32(vis)*row_h, f32(len(p.items))*row_h, f32(p.scroll)*row_h, &theme)
	}
}
