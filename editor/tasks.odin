// medit — project tasks (run / debug / anything). `.medit/tasks.ini` in the
// workspace defines them; ctrl+r runs the default (first) one — restarting
// whatever is already running — and ctrl+shift+r (or "$" in the palette)
// picks by name. Output streams into a panel above the status bar, where
// file references like `main.odin(9:8)` click through to the source.
//
//   ; .medit/tasks.ini
//   [run]
//   cmd = odin run ${workspaceFolder}
//   [test this package]
//   cmd = odin test ${fileDir}
//   cwd = ${workspaceFolder}
//
// ${file}, ${fileName}, ${fileDir} and ${workspaceFolder} expand in cmd and
// cwd before the command is split into arguments (double quotes group one).
package medit

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

TASKS_PATH :: ".medit/tasks.ini"
output_rows := 12 // panel height in rows; drag the panel top edge to resize
OUTPUT_MAX_LINES :: 5000

// Panel header and row heights in line_h units. app.draw sizes the panel and
// main.odin's edge drag both use these same numbers, so tweaking them here
// can't make the content overflow into the status bar.
PANEL_HEAD_SCALE :: 2.0
PANEL_ROW_SCALE :: 1.1

TASKS_TEMPLATE :: `; medit tasks — ctrl+r runs the first task here (and restarts a running one);
; ctrl+shift+r (or "$" in the palette) picks one by name.
; ${file} ${fileName} ${fileDir} ${workspaceFolder} expand in cmd and cwd.
[run]
cmd = odin run ${workspaceFolder}

; [test]
; cmd = odin test ${fileDir}
; cwd = ${workspaceFolder}

; A debug task: cmd builds, then program launches under the debug adapter
; (lldb-dap on PATH; MEDIT_DAP overrides). F9 toggles breakpoints, F5
; continues, F10/F11 step.
; [debug]
; cmd = odin build ${workspaceFolder} -debug -out:dev.exe
; program = dev.exe
; debug = true
`

Task :: struct {
	name:    string, // owned; the section name
	cmd:     string, // owned
	cwd:     string, // owned; "" = the workspace directory
	program: string, // owned; executable a debug task launches under the adapter
	debug:   bool, // run program under the debugger after cmd succeeds
}

// One line into the output panel (tasks and the debugger share it).
task_append_line :: proc(ts: ^Task_State, line: string) {
	if len(ts.lines) < OUTPUT_MAX_LINES {
		append(&ts.lines, strings.clone(line))
	}
}

Task_State :: struct {
	tasks:                 [dynamic]Task,
	last:                  string, // owned; name of the last-started task (ctrl+r restarts it while it runs)

	// A debug task's build step ran; launch this under the adapter when it
	// succeeds (owned; "" = nothing pending).

	pending_debug_program: string,
	pending_debug_cwd:     string,

	// The live run.

	running:               bool,
	process:               os.Process,
	pipe:                  ^os.File, // read end; stdout+stderr merged

	// Output panel.

	open:                  bool,
	title:                 string, // owned; header line
	lines:                 [dynamic]string, // owned
	partial:               [dynamic]u8, // bytes of a not-yet-terminated last line
	scroll:                f32,
	follow:                bool, // pinned to the bottom while output arrives
	top, h:                f32, // layout of the last draw (hit testing)
	head_bot:              f32, // bottom edge of the header row
	row_h:                 f32,
	btns:                  [dynamic]Panel_Btn, // header buttons of the last draw

	// Debug columns (0 = not shown): call stack and locals, right of output.

	stack_x0:              f32,
	locals_x0:             f32,
	stack_scroll:          f32, // first visible frame row
	locals_scroll:         f32, // first visible local row
	filter:                [dynamic]u8, // fuzzy filter over locals/globals names
	filter_focus:          bool, // typing lands in the filter (click its header)

	// Row drag-selection in the output (terminal-style: release copies).

	drag_from:             int, // -1 = no drag
	drag_to:               int,

	// Hover feedback: the link span, header button or frame under the mouse.

	hover_row:             int, // -1 = none
	hover_lo, hover_hi:    int, // byte span within lines[hover_row]
	hover_btn:             int, // Panel_Btn id under the mouse (0 none)
	hover_frame:           int, // call-stack frame index (-1 none)
}

// A clickable word in the panel header (kill/close, debug stepping).
Panel_Btn :: struct {
	x0, x1: f32,
	id:     int,
}

PBTN_KILL :: 1
PBTN_CLOSE :: 2
PBTN_CONTINUE :: 3
PBTN_OVER :: 4
PBTN_IN :: 5
PBTN_OUT :: 6

@(private = "file")
tasks_clear :: proc(ts: ^Task_State) {
	for t in ts.tasks {
		delete(t.name)
		delete(t.cmd)
		delete(t.cwd)
		delete(t.program)
	}
	clear(&ts.tasks)
}

tasks_destroy :: proc(ts: ^Task_State) {
	if ts.running {
		_ = os.process_kill(ts.process)
		if ts.pipe != nil {
			os.close(ts.pipe)
		}
	}
	tasks_clear(ts)
	delete(ts.tasks)
	delete(ts.last)
	delete(ts.title)
	for l in ts.lines {
		delete(l)
	}
	delete(ts.lines)
	delete(ts.partial)
	delete(ts.btns)
	delete(ts.filter)
	delete(ts.pending_debug_program)
	delete(ts.pending_debug_cwd)
}

// Parse tasks out of ini source (separate from the file read for testing).
tasks_parse :: proc(ts: ^Task_State, src: string) {
	tasks_clear(ts)
	it := ini.iterator_from_string(src)
	for key, value in ini.iterate(&it) {
		if it.section == "" {
			continue
		}
		ti := -1
		for t, i in ts.tasks {
			if t.name == it.section {
				ti = i
				break
			}
		}
		if ti < 0 {
			append(&ts.tasks, Task{name = strings.clone(it.section)})
			ti = len(ts.tasks) - 1
		}
		t := &ts.tasks[ti]
		switch key {
		case "cmd":
			delete(t.cmd)
			t.cmd = strings.clone(value)
		case "cwd":
			delete(t.cwd)
			t.cwd = strings.clone(value)
		case "program":
			delete(t.program)
			t.program = strings.clone(value)
		case "debug":
			t.debug = value == "true" || value == "1"
		}
	}
	// A section that neither runs nor debugs anything is dropped.
	for i := len(ts.tasks) - 1; i >= 0; i -= 1 {
		if ts.tasks[i].cmd == "" && !(ts.tasks[i].debug && ts.tasks[i].program != "") {
			delete(ts.tasks[i].name)
			delete(ts.tasks[i].cwd)
			delete(ts.tasks[i].program)
			ordered_remove(&ts.tasks, i)
		}
	}
}

tasks_load :: proc(ts: ^Task_State) {
	data, err := os.read_entire_file(TASKS_PATH, context.temp_allocator)
	if err != nil {
		tasks_clear(ts)
		return
	}
	tasks_parse(ts, string(data))
}

// ${var} substitution against the current file and workspace. Temp-allocated.
task_expand :: proc(s, file, workspace: string) -> string {
	dir, name := os.split_path(file)
	out := s
	pairs := [?]string {
		"${file}",
		file,
		"${fileDir}",
		dir,
		"${fileName}",
		name,
		"${workspaceFolder}",
		workspace,
	}
	for i := 0; i < len(pairs); i += 2 {
		out, _ = strings.replace_all(out, pairs[i], pairs[i + 1], context.temp_allocator)
	}
	return out
}

// Split a command line into arguments; double quotes group one. Temp-allocated.
task_split :: proc(cmd: string) -> []string {
	args := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(cmd) {
		for i < len(cmd) && cmd[i] == ' ' {
			i += 1
		}
		if i >= len(cmd) {
			break
		}
		sb := strings.builder_make(context.temp_allocator)
		for i < len(cmd) && cmd[i] != ' ' {
			if cmd[i] == '"' {
				i += 1
				for i < len(cmd) && cmd[i] != '"' {
					strings.write_byte(&sb, cmd[i])
					i += 1
				}
				if i < len(cmd) {
					i += 1
				}
			} else {
				strings.write_byte(&sb, cmd[i])
				i += 1
			}
		}
		append(&args, strings.to_string(sb))
	}
	return args[:]
}

// A file reference inside an output line — the shapes compilers print:
// `path(12:3)`, `path(12)`, `path:12:3`, `path:12`.
Task_Link :: struct {
	lo, hi:    int, // byte span within the line
	path:      string, // slice of the line
	line, col: int, // 1-based; col 0 = unknown
}

// Callers validate with all_digits first.
to_int :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}

all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// "12" or "12:3".
@(private = "file")
parse_line_col :: proc(s: string) -> (line, col: int, ok: bool) {
	num := s
	if c := strings.index_byte(s, ':'); c >= 0 {
		num = s[:c]
		if !all_digits(s[c + 1:]) {
			return
		}
		col = to_int(s[c + 1:])
	}
	if !all_digits(num) {
		return
	}
	return to_int(num), col, true
}

@(private = "file")
looks_like_path :: proc(s: string) -> bool {
	return len(s) >= 3 && (strings.contains_any(s, "/\\") || strings.contains_rune(s, '.'))
}

@(private = "file")
link_from_token :: proc(tok: string) -> (l: Task_Link, ok: bool) {
	// Trailing punctuation from prose ("...in foo.odin:12:") is not part of it.
	t := tok
	for len(t) > 0 && (t[len(t) - 1] == ':' || t[len(t) - 1] == ',' || t[len(t) - 1] == ';') {
		t = t[:len(t) - 1]
	}
	// Odin style: path(line:col).
	if open := strings.index_byte(t, '('); open > 0 {
		if close := strings.index_byte(t[open:], ')'); close > 1 {
			line, col, pok := parse_line_col(t[open + 1:open + close])
			if pok && looks_like_path(t[:open]) {
				return Task_Link {
						lo   = 0,
						hi   = open + close + 1,
						path = t[:open],
						line = line,
						col  = col,
					}, true
			}
		}
	}
	// gcc/rust style: path:line[:col].
	last := strings.last_index_byte(t, ':')
	if last > 0 && all_digits(t[last + 1:]) {
		path := t[:last]
		line := to_int(t[last + 1:])
		col := 0
		if prev := strings.last_index_byte(path, ':'); prev > 0 && all_digits(path[prev + 1:]) {
			col = line
			line = to_int(path[prev + 1:])
			path = path[:prev]
		}
		if looks_like_path(path) {
			return Task_Link{lo = 0, hi = len(t), path = path, line = line, col = col}, true
		}
	}
	return
}

// Panel pixel x → byte offset in an output line, mirroring how it is drawn
// (one cell per rune, starting one cell in).
@(private = "file")
task_cell_to_offset :: proc(line: string, px, cell_w: f32) -> int {
	cell := int((px - cell_w) / cell_w)
	off := 0
	for _ in 0 ..< max(cell, 0) {
		if off >= len(line) {
			break
		}
		_, n := utf8.decode_rune(line[off:])
		off += n
	}
	return off
}

// Every file reference in an output line.
task_scan_links :: proc(s: string, out: ^[dynamic]Task_Link) {
	i := 0
	for i < len(s) {
		for i < len(s) && s[i] == ' ' {
			i += 1
		}
		start := i
		for i < len(s) && s[i] != ' ' {
			i += 1
		}
		if l, ok := link_from_token(s[start:i]); ok {
			l.lo += start
			l.hi += start
			append(out, l)
		}
	}
}

impl App {
	// Launch tasks[i]; a still-running previous task (or debug session) is
	// killed first. A debug task runs its cmd (the build) and hands program
	// to the debug adapter once it exits 0 — or straight away without a cmd.
	task_run :: proc(i: int) {
		ts := &task
		if i < 0 || i >= len(ts.tasks) {
			return
		}
		if ts.running {
			_ = os.process_kill(ts.process)
			_, _ = os.process_wait(ts.process)
			if ts.pipe != nil {
				os.close(ts.pipe)
				ts.pipe = nil
			}
			ts.running = false
		}
		self.dap_finish()
		delete(ts.pending_debug_program)
		ts.pending_debug_program = ""
		delete(ts.pending_debug_cwd)
		ts.pending_debug_cwd = ""

		t := &ts.tasks[i]
		ws, _ := os.get_working_directory(context.temp_allocator)
		file := abs_path(buf.path) if buf.path != "" else ""
		cwd := task_expand(t.cwd, file, ws) if t.cwd != "" else ""
		if t.debug {
			if t.program == "" {
				self.set_status("debug task needs a program = path")
				return
			}
			prog := task_expand(t.program, file, ws)
			delete(ts.last)
			ts.last = strings.clone(t.name)
			if t.cmd == "" {
				self.dap_launch(prog, cwd)
				return
			}
			ts.pending_debug_program = strings.clone(prog)
			ts.pending_debug_cwd = strings.clone(cwd)
			// The build runs below like any task; task_poll launches the
			// debugger when it exits 0.
		}
		args := task_split(task_expand(t.cmd, file, ws))
		if len(args) == 0 {
			return
		}

		out_r, out_w, perr := os.pipe()
		if perr != nil {
			self.set_status("task: could not create a pipe")
			return
		}
		process, err := os.process_start(
		{
			command     = args,
			working_dir = cwd,
			stdout      = out_w,
			stderr      = out_w, // merged; a run panel wants one stream
		},
		)
		os.close(out_w) // the child inherited its end
		if err != nil {
			os.close(out_r)
			self.set_status(fmt.tprintf("task: could not start \"%s\"", args[0]))
			return
		}

		ts.running = true
		ts.process = process
		ts.pipe = out_r
		for l in ts.lines {
			delete(l)
		}
		clear(&ts.lines)
		clear(&ts.partial)
		ts.scroll = 0
		ts.follow = true
		delete(ts.title)
		ts.title = strings.clone(
			fmt.tprintf(
				"%s — running: %s",
				t.name,
				strings.join(args, " ", context.temp_allocator),
			),
		)
		delete(ts.last)
		ts.last = strings.clone(t.name)
		self.task_open_panel()
	}

	// ctrl+r: restart whatever is running, else run the default (first) task.
	// No config yet → create it from the template and open it for editing.
	task_run_default :: proc() {
		tasks_load(&task)
		if len(task.tasks) == 0 {
			self.task_edit_config()
			self.set_status("no tasks yet — define some in " + TASKS_PATH)
			return
		}
		if task.running && task.last != "" {
			for t, i in task.tasks {
				if t.name == task.last {
					self.task_run(i) // kills the old run first
					return
				}
			}
		}
		self.task_run(0)
	}

	task_stop :: proc() {
		ts := &task
		if self.dap_active() {
			self.dap_stop()
			return
		}
		if !ts.running {
			return
		}
		delete(ts.pending_debug_program) // a killed build launches nothing
		ts.pending_debug_program = ""
		_ = os.process_kill(ts.process)
		self.set_status("task: killed")
		// task_poll reaps it and stamps the title.
	}

	task_open_panel :: proc() {
		task.open = true
		problems_open = false // the two panels share the slot above the status bar
	}

	// Create the config (with a template) if needed, then open it in a tab.
	task_edit_config :: proc() {
		if !os.exists(TASKS_PATH) {
			_ = os.make_directory_all(".medit")
			if os.write_entire_file(TASKS_PATH, TASKS_TEMPLATE) != nil {
				self.set_status("could not create " + TASKS_PATH)
				return
			}
			sidebar_refresh(&sidebar)
		}
		self.open_file(TASKS_PATH)
	}

	// Track what the mouse is over for hover feedback; true when it is
	// something clickable (main shows a pointing-hand cursor then).
	task_motion :: proc(px, py: f32, cell_w: f32) -> bool {
		ts := &task
		ts.hover_row = -1
		ts.hover_btn = 0
		ts.hover_frame = -1
		if !ts.open || py < ts.top || py >= ts.top + ts.h {
			return false
		}
		if py < ts.head_bot {
			for b in ts.btns {
				if px >= b.x0 && px < b.x1 {
					ts.hover_btn = b.id
					break
				}
			}
			return ts.hover_btn != 0
		}
		if ts.drag_from >= 0 {
			ts.drag_to = clamp(
				int(ts.scroll) + int((py - ts.head_bot) / ts.row_h),
				0,
				max(len(ts.lines) - 1, 0),
			)
			return false
		}
		if ts.stack_x0 > 0 && px >= ts.stack_x0 {
			if px < ts.locals_x0 {
				fi := int((py - ts.head_bot) / ts.row_h) - 1 // row 0 is the header
				if fi >= 0 && fi < output_rows - 1 {
					fi += int(ts.stack_scroll)
					if fi < len(dap.frames) && dap.frames[fi].path != "" {
						ts.hover_frame = fi
						return true
					}
				}
			}
			return false
		}
		row := int(ts.scroll) + int((py - ts.head_bot) / ts.row_h)
		if row < 0 || row >= len(ts.lines) {
			return false
		}
		line := ts.lines[row]
		off := task_cell_to_offset(line, px, cell_w)
		links := make([dynamic]Task_Link, context.temp_allocator)
		task_scan_links(line, &links)
		for l in links {
			if off >= l.lo && off < l.hi {
				ts.hover_row = row
				ts.hover_lo = l.lo
				ts.hover_hi = l.hi
				return true
			}
		}
		return false
	}

	// A click on the panel: the header's kill/close buttons, or a file
	// reference in an output row (jumps there).
	task_click :: proc(px, py: f32, cell_w: f32) {
		ts := &task
		if py < ts.head_bot {
			for b in ts.btns {
				if px < b.x0 || px >= b.x1 {
					continue
				}
				switch b.id {
				case PBTN_KILL:
					self.task_stop()
				case PBTN_CLOSE:
					ts.open = false
				case PBTN_CONTINUE:
					self.dap_resume("continue")
				case PBTN_OVER:
					self.dap_resume("next")
				case PBTN_IN:
					self.dap_resume("stepIn")
				case PBTN_OUT:
					self.dap_resume("stepOut")
				}
				break
			}
			return
		}
		if ts.stack_x0 > 0 && px >= ts.stack_x0 {
			row := int((py - ts.head_bot) / ts.row_h) - 1
			if px >= ts.locals_x0 && row < 0 {
				ts.filter_focus = true // the header doubles as the filter box
			} else if row >= 0 && row < output_rows - 1 {
				if px < ts.locals_x0 {
					self.dap_select_frame(row + int(ts.stack_scroll))
				} else {
					vis := self.task_locals_filtered()
					if i := row + int(ts.locals_scroll); i < len(vis) {
						self.dap_local_goto(vis[i])
					}
				}
			}
			return
		}
		row := int(ts.scroll) + int((py - ts.head_bot) / ts.row_h)
		if row < 0 || row >= len(ts.lines) {
			return
		}
		// A drag starts here; mouse-up decides click (link) vs copy.
		ts.drag_from = row
		ts.drag_to = row
	}

	// Right-click on the panel: a context menu for the local under the
	// mouse (elsewhere it just swallows the click).
	task_context :: proc(px, py: f32) {
		ts := &task
		if ts.locals_x0 > 0 && px >= ts.locals_x0 && py >= ts.head_bot {
			i := int((py - ts.head_bot) / ts.row_h) - 1 // row 0 is the header
			if i >= 0 && i < output_rows - 1 {
				vis := self.task_locals_filtered()
				i += int(ts.locals_scroll)
				if i < len(vis) && dap.locals[vis[i]].value != "" {
					self.open_context_local(vis[i])
				}
			}
		}
	}

	// Mouse-up over the panel: a plain click opens a file link; a row drag
	// copies the selected lines to the clipboard.
	task_drag_end :: proc(px, py: f32, cell_w: f32) {
		ts := &task
		from := ts.drag_from
		ts.drag_from = -1
		if from < 0 {
			return
		}
		lo, hi := min(from, ts.drag_to), max(from, ts.drag_to)
		if lo != hi {
			sb := strings.builder_make(context.temp_allocator)
			for i in lo ..= min(hi, len(ts.lines) - 1) {
				strings.write_string(&sb, ts.lines[i])
				strings.write_byte(&sb, '\n')
			}
			clipboard_set(strings.to_string(sb))
			self.set_status(fmt.tprintf("copied %d lines", hi - lo + 1))
			return
		}
		if from >= len(ts.lines) {
			return
		}
		line := ts.lines[from]
		off := task_cell_to_offset(line, px, cell_w)
		links := make([dynamic]Task_Link, context.temp_allocator)
		task_scan_links(line, &links)
		for l in links {
			if off >= l.lo && off < l.hi {
				self.task_link_open(l)
				return
			}
		}
	}

	// Open a file reference from the output: workspace-relative or absolute.
	task_link_open :: proc(l: Task_Link) {
		path := shorten_path(l.path)
		if !os.exists(path) {
			self.set_status(fmt.tprintf("no such file: %s", l.path))
			return
		}
		self.open_file(path)
		if buf.path != path {
			return // could not be opened; the status bar explains
		}
		self.push_cursor_undo()
		pos := buf.clamp_pos(Pos{max(l.line - 1, 0), max(l.col - 1, 0)})
		clear(&cursors)
		append(&cursors, cursor_at(pos))
		primary = 0
		want_follow = true
		want_center = true
		self.blink_reset()
	}

	// Locals rows surviving the panel filter (indices into dap.locals).
	task_locals_filtered :: proc() -> []int {
		out := make([dynamic]int, context.temp_allocator)
		q := string(task.filter[:])
		ms := make([dynamic]int, context.temp_allocator)
		for v, i in dap.locals {
			if q == "" || v.value == "" {
				append(&out, i)
				continue
			}
			if _, ok := fuzzy_match(q, v.name, 0, &ms); ok {
				append(&out, i)
			}
		}
		return out[:]
	}

	task_wheel :: proc(dy: f32, cell_w: f32, px: f32) {
		ts := &task
		vis := output_rows - 1 // the columns' first row is their header
		if ts.locals_x0 > 0 && px >= ts.locals_x0 {
			ts.locals_scroll = clamp(
				ts.locals_scroll - dy * 3,
				0,
				f32(max(len(dap.locals) - vis, 0)),
			)
		} else if ts.stack_x0 > 0 && px >= ts.stack_x0 {
			ts.stack_scroll = clamp(
				ts.stack_scroll - dy * 3,
				0,
				f32(max(len(dap.frames) - vis, 0)),
			)
		} else {
			hi := f32(max(len(ts.lines) - output_rows, 0))
			ts.scroll = clamp(ts.scroll - dy * 3, 0, hi)
			ts.follow = ts.scroll >= hi // wheeling back down re-arms following
		}
		// The rows moved under a stationary pointer: re-aim the hover.
		_ = self.task_motion(mouse_x, mouse_y, cell_w)
	}

	task_draw :: proc(r: ^Renderer, width, height: f32) {
		ts := &task
		if !ts.open {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w
		row_h := line_h * PANEL_ROW_SCALE
		head_h := line_h * PANEL_HEAD_SCALE
		top := height - status_h - ts.h
		ts.top = top

		push_rect(r, 0, top, width, ts.h, theme.status_bg)
		hot := edge_hover == 2 || resizing == 2
		push_rect(
			r,
			0,
			top - 1 if hot else top,
			width,
			3 if hot else 1,
			theme.faces[.Function] if hot else color_alpha(theme.gutter_fg, 0.6),
		)

		draw_str :: proc(r: ^Renderer, x, baseline: f32, s: string, color: Color) {
			x := x
			for ch in s {
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
		}
		// A bug while a debug session is up, a play glyph otherwise; accent
		// while something is live.
		head_base := top + (head_h - line_h) * 0.5 + r.ascent
		hsz := line_h * 0.7
		live := ts.running || self.dap_active()
		push_icon(r, cell_w, top+(head_h-hsz)*0.5, hsz, .Bug if self.dap_active() else .Play,
			color_alpha(theme.faces[.Function], 0.95) if live else theme.status_dim)
		_ = utext_clip(r, cell_w+hsz+cell_w*0.7, head_base, width * 0.5, ts.title, theme.status_dim)

		// Header buttons, right-aligned (built right-to-left): close, kill,
		// and — while the debugger is stopped — the stepping controls.
		ts.head_bot = top + head_h
		clear(&ts.btns)
		bx := width - cell_w
		put_btn :: proc(
			ts: ^Task_State,
			r: ^Renderer,
			bx: ^f32,
			head_base: f32,
			label: string,
			id: int,
			color: Color,
			t: ^Theme,
		) {
			w := f32(len(label)) * r.cell_w
			bx^ -= w
			c := color
			if ts.hover_btn == id {
				push_rect(r, bx^, head_base + 3, w, 1, c)
			}
			x := bx^
			for ch in label {
				push_glyph(r, x, head_base, ch, c)
				x += r.cell_w
			}
			append(&ts.btns, Panel_Btn{x0 = bx^, x1 = bx^ + w, id = id})
			bx^ -= r.cell_w * 3
		}
		put_btn(
			ts,
			r,
			&bx,
			head_base,
			"close",
			PBTN_CLOSE,
			theme.fg if ts.hover_btn == PBTN_CLOSE else theme.status_dim,
			&theme,
		)
		if ts.running || self.dap_active() {
			put_btn(ts, r, &bx, head_base, "kill", PBTN_KILL, theme.diag_err, &theme)
		}
		if dap.state == .Stopped {
			put_btn(
				ts,
				r,
				&bx,
				head_base,
				"out",
				PBTN_OUT,
				theme.fg if ts.hover_btn == PBTN_OUT else theme.status_fg,
				&theme,
			)
			put_btn(
				ts,
				r,
				&bx,
				head_base,
				"in",
				PBTN_IN,
				theme.fg if ts.hover_btn == PBTN_IN else theme.status_fg,
				&theme,
			)
			put_btn(
				ts,
				r,
				&bx,
				head_base,
				"over",
				PBTN_OVER,
				theme.fg if ts.hover_btn == PBTN_OVER else theme.status_fg,
				&theme,
			)
			put_btn(
				ts,
				r,
				&bx,
				head_base,
				"continue",
				PBTN_CONTINUE,
				theme.faces[.Function],
				&theme,
			)
		}

		hi := f32(max(len(ts.lines) - output_rows, 0))
		if ts.follow {
			ts.scroll = hi
		}
		ts.scroll = clamp(ts.scroll, 0, hi)
		row0 := int(ts.scroll)
		ts.row_h = row_h

		draw_clip :: proc(r: ^Renderer, x, baseline, limit: f32, s: string, color: Color) {
			x := x
			for ch in s {
				if x + r.cell_w * 2 > limit {
					push_glyph(r, x, baseline, '…', color)
					return
				}
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
		}

		// While stopped in the debugger, the panel splits into columns:
		// output | call stack (clickable frames) | locals of the frame.
		ts.stack_x0 = 0
		ts.locals_x0 = 0
		out_w := width
		if len(dap.frames) > 0 && width > cell_w * 100 {
			stack_w := clamp(width * 0.24, cell_w * 24, cell_w * 46)
			locals_w := clamp(width * 0.28, cell_w * 24, cell_w * 54)
			out_w = width - stack_w - locals_w
			ts.stack_x0 = out_w
			ts.locals_x0 = out_w + stack_w
			push_rect(
				r,
				ts.stack_x0,
				ts.head_bot,
				1,
				ts.h - head_h,
				color_alpha(theme.gutter_fg, 0.4),
			)
			push_rect(
				r,
				ts.locals_x0,
				ts.head_bot,
				1,
				ts.h - head_h,
				color_alpha(theme.gutter_fg, 0.4),
			)

			hy := ts.head_bot + (row_h - line_h) * 0.5 + r.ascent
			col_vis := output_rows - 1 // row 0 is the column header
			ts.stack_scroll = clamp(ts.stack_scroll, 0, f32(max(len(dap.frames) - col_vis, 0)))
			ts.locals_scroll = clamp(ts.locals_scroll, 0, f32(max(len(dap.locals) - col_vis, 0)))

			draw_clip(r, ts.stack_x0 + cell_w, hy, ts.locals_x0, "call stack", theme.status_dim)
			s0 := int(ts.stack_scroll)
			for vi in 0 ..< col_vis {
				i := s0 + vi
				if i >= len(dap.frames) {
					break
				}
				f := &dap.frames[i]
				y := ts.head_bot + f32(vi + 1) * row_h
				if i == dap.sel_frame {
					push_rect(r, ts.stack_x0 + 1, y, stack_w - 1, row_h, theme.selection)
				} else if ts.hover_frame == i {
					push_rect(
						r,
						ts.stack_x0 + 1,
						y,
						stack_w - 1,
						row_h,
						color_alpha(theme.selection, 0.45),
					)
				}
				label :=
					f.name if f.path == "" else fmt.tprintf("%s — %s(%d)", f.name, f.path, f.line)
				draw_clip(
					r,
					ts.stack_x0 + cell_w,
					y + (row_h - line_h) * 0.5 + r.ascent,
					ts.locals_x0,
					label,
					theme.status_fg if f.path != "" else theme.status_dim,
				)
			}
			draw_vscrollbar(
				r,
				ts.locals_x0,
				ts.head_bot + row_h,
				f32(col_vis) * row_h,
				f32(len(dap.frames)) * row_h,
				ts.stack_scroll * row_h,
				&theme,
			)

			vis_locals := self.task_locals_filtered()
			head_label := "locals — click to filter"
			if ts.filter_focus || len(ts.filter) > 0 {
				head_label = fmt.tprintf(
					"locals ⌕ %s%s",
					string(ts.filter[:]),
					"_" if ts.filter_focus else "",
				)
			}
			draw_clip(
				r,
				ts.locals_x0 + cell_w,
				hy,
				width,
				head_label,
				theme.status_fg if ts.filter_focus else theme.status_dim,
			)
			ts.locals_scroll = clamp(ts.locals_scroll, 0, f32(max(len(vis_locals) - col_vis, 0)))
			l0 := int(ts.locals_scroll)
			for vi in 0 ..< col_vis {
				i := l0 + vi
				if i >= len(vis_locals) {
					break
				}
				v := &dap.locals[vis_locals[i]]
				y := ts.head_bot + f32(vi + 1) * row_h + (row_h - line_h) * 0.5 + r.ascent
				if v.value == "" { 	// section divider (globals)
					draw_clip(r, ts.locals_x0 + cell_w, y, width, v.name, theme.status_dim)
				} else {
					draw_clip(
						r,
						ts.locals_x0 + cell_w,
						y,
						width,
						fmt.tprintf("%s = %s", v.name, v.value),
						theme.status_fg,
					)
				}
			}
			draw_vscrollbar(
				r,
				width,
				ts.head_bot + row_h,
				f32(col_vis) * row_h,
				f32(len(vis_locals)) * row_h,
				ts.locals_scroll * row_h,
				&theme,
			)
		}

		links := make([dynamic]Task_Link, context.temp_allocator)
		for vi in 0 ..< output_rows {
			i := row0 + vi
			if i >= len(ts.lines) {
				break
			}
			row_y := top + head_h + f32(vi) * row_h
			baseline := row_y + (row_h - line_h) * 0.5 + r.ascent
			line := ts.lines[i]
			if ts.drag_from >= 0 &&
			   i >= min(ts.drag_from, ts.drag_to) &&
			   i <= max(ts.drag_from, ts.drag_to) {
				push_rect(r, 0, row_y, out_w, row_h, theme.selection)
			}
			// File references draw accented and underlined — they're
			// clickable; the one under the mouse also gets a backdrop and a
			// solid underline.
			clear(&links)
			task_scan_links(line, &links)
			x := cell_w
			for ch, off in line {
				if x + cell_w > out_w {
					break
				}
				in_link := false
				for l in links {
					if off >= l.lo && off < l.hi {
						in_link = true
						break
					}
				}
				hovered := i == ts.hover_row && off >= ts.hover_lo && off < ts.hover_hi
				if hovered {
					push_rect(r, x, row_y, cell_w, row_h, theme.selection)
				}
				if in_link {
					push_glyph(r, x, baseline, ch, theme.faces[.Function])
					push_rect(
						r,
						x,
						baseline + 2,
						cell_w,
						1,
						theme.faces[.Function] if hovered else color_alpha(theme.faces[.Function], 0.6),
					)
				} else {
					push_glyph(r, x, baseline, ch, theme.status_fg)
				}
				x += cell_w
			}
		}

		draw_vscrollbar(
			r,
			out_w,
			top + head_h,
			f32(output_rows) * row_h,
			f32(len(ts.lines)) * row_h,
			ts.scroll * row_h,
			&theme,
		)
	}
}

// Runs every frame: drain the pipe into lines; reap the process on exit.
// Never blocks — a task that closes its output but keeps running must not
// hang the editor, so the process is polled with a zero timeout.
task_poll :: proc(app: ^App) {
	ts := &app.task
	if !ts.running {
		return
	}
	for ts.pipe != nil {
		has, err := os.pipe_has_data(ts.pipe)
		if err != nil {
			os.close(ts.pipe) // EOF: the child closed its end
			ts.pipe = nil
			break
		}
		if !has {
			break
		}
		chunk: [8192]u8
		n, rerr := os.read(ts.pipe, chunk[:])
		if n > 0 {
			append(&ts.partial, ..chunk[:n])
		}
		if rerr != nil {
			os.close(ts.pipe)
			ts.pipe = nil
			break
		}
	}
	// Completed lines move from partial into the panel.
	for {
		nl := -1
		for b, i in ts.partial {
			if b == '\n' {
				nl = i
				break
			}
		}
		if nl < 0 {
			break
		}
		line := strings.trim_suffix(string(ts.partial[:nl]), "\r")
		if len(ts.lines) < OUTPUT_MAX_LINES {
			clean, _ := strings.replace_all(line, "\t", "    ", context.temp_allocator)
			append(&ts.lines, strings.clone(clean))
		}
		remove_range(&ts.partial, 0, nl + 1)
	}

	state, werr := os.process_wait(ts.process, 0)
	if werr != nil || !state.exited {
		return // still running (or unknowable); keep polling
	}
	if len(ts.partial) > 0 && len(ts.lines) < OUTPUT_MAX_LINES {
		append(&ts.lines, strings.clone(string(ts.partial[:])))
	}
	clear(&ts.partial)
	if ts.pipe != nil {
		os.close(ts.pipe)
		ts.pipe = nil
	}
	ts.running = false
	name := strings.clone(ts.last, context.temp_allocator)
	delete(ts.title)
	ts.title = strings.clone(fmt.tprintf("%s — exited with code %d", name, state.exit_code))
	app.set_status(fmt.tprintf("task %s: exit code %d", name, state.exit_code))

	// A debug task's build step finished: hand the program to the adapter.
	if ts.pending_debug_program != "" {
		prog := strings.clone(ts.pending_debug_program, context.temp_allocator)
		cwd := strings.clone(ts.pending_debug_cwd, context.temp_allocator)
		delete(ts.pending_debug_program)
		ts.pending_debug_program = ""
		delete(ts.pending_debug_cwd)
		ts.pending_debug_cwd = ""
		if state.exit_code == 0 {
			app.dap_launch(prog, cwd)
		} else {
			app.set_status("build failed — debug canceled")
		}
	}
}
