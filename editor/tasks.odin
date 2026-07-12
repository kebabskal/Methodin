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
OUTPUT_VISIBLE :: 12
OUTPUT_MAX_LINES :: 5000

TASKS_TEMPLATE :: `; medit tasks — ctrl+r runs the first task here (and restarts a running one);
; ctrl+shift+r (or "$" in the palette) picks one by name.
; ${file} ${fileName} ${fileDir} ${workspaceFolder} expand in cmd and cwd.
[run]
cmd = odin run ${workspaceFolder}

; [test]
; cmd = odin test ${fileDir}
; cwd = ${workspaceFolder}
`

Task :: struct {
	name: string, // owned; the section name
	cmd:  string, // owned
	cwd:  string, // owned; "" = the workspace directory
}

Task_State :: struct {
	tasks: [dynamic]Task,
	last:  string, // owned; name of the last-started task (ctrl+r restarts it while it runs)

	// The live run.
	running: bool,
	process: os.Process,
	pipe:    ^os.File, // read end; stdout+stderr merged

	// Output panel.
	open:    bool,
	title:   string, // owned; header line
	lines:   [dynamic]string, // owned
	partial: [dynamic]u8, // bytes of a not-yet-terminated last line
	scroll:  f32,
	follow:  bool, // pinned to the bottom while output arrives
	top, h:  f32,  // layout of the last draw (hit testing)
	head_bot:           f32, // bottom edge of the header row
	row_h:              f32,
	kill_x0, kill_x1:   f32, // header "kill" button (while running)
	close_x0, close_x1: f32, // header "close" button

	// Hover feedback: the link span or header button under the mouse.
	hover_row:          int, // -1 = none
	hover_lo, hover_hi: int, // byte span within lines[hover_row]
	hover_btn:          int, // 0 none, 1 kill, 2 close
}

@(private = "file")
tasks_clear :: proc(ts: ^Task_State) {
	for t in ts.tasks {
		delete(t.name)
		delete(t.cmd)
		delete(t.cwd)
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
		}
	}
	// A section without a cmd runs nothing; drop it.
	for i := len(ts.tasks) - 1; i >= 0; i -= 1 {
		if ts.tasks[i].cmd == "" {
			delete(ts.tasks[i].name)
			delete(ts.tasks[i].cwd)
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
	pairs := [?]string{
		"${file}", file,
		"${fileDir}", dir,
		"${fileName}", name,
		"${workspaceFolder}", workspace,
	}
	for i := 0; i < len(pairs); i += 2 {
		out, _ = strings.replace_all(out, pairs[i], pairs[i+1], context.temp_allocator)
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
	lo, hi:    int,    // byte span within the line
	path:      string, // slice of the line
	line, col: int,    // 1-based; col 0 = unknown
}

// Callers validate with all_digits first.
@(private = "file")
to_int :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}

@(private = "file")
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
		if !all_digits(s[c+1:]) {
			return
		}
		col = to_int(s[c+1:])
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
	for len(t) > 0 && (t[len(t)-1] == ':' || t[len(t)-1] == ',' || t[len(t)-1] == ';') {
		t = t[:len(t)-1]
	}
	// Odin style: path(line:col).
	if open := strings.index_byte(t, '('); open > 0 {
		if close := strings.index_byte(t[open:], ')'); close > 1 {
			line, col, pok := parse_line_col(t[open+1 : open+close])
			if pok && looks_like_path(t[:open]) {
				return Task_Link{lo = 0, hi = open + close + 1, path = t[:open], line = line, col = col}, true
			}
		}
	}
	// gcc/rust style: path:line[:col].
	last := strings.last_index_byte(t, ':')
	if last > 0 && all_digits(t[last+1:]) {
		path := t[:last]
		line := to_int(t[last+1:])
		col := 0
		if prev := strings.last_index_byte(path, ':'); prev > 0 && all_digits(path[prev+1:]) {
			col = line
			line = to_int(path[prev+1:])
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
	// Launch tasks[i]; a still-running previous task is killed first.
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
		t := &ts.tasks[i]
		ws, _ := os.get_working_directory(context.temp_allocator)
		file := abs_path(buf.path) if buf.path != "" else ""
		args := task_split(task_expand(t.cmd, file, ws))
		if len(args) == 0 {
			return
		}
		cwd := task_expand(t.cwd, file, ws) if t.cwd != "" else ""

		out_r, out_w, perr := os.pipe()
		if perr != nil {
			self.set_status("task: could not create a pipe")
			return
		}
		process, err := os.process_start({
			command     = args,
			working_dir = cwd,
			stdout      = out_w,
			stderr      = out_w, // merged; a run panel wants one stream
		})
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
		ts.title = strings.clone(fmt.tprintf("%s — running: %s", t.name, strings.join(args, " ", context.temp_allocator)))
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
		if !ts.running {
			return
		}
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
		if !ts.open || py < ts.top || py >= ts.top+ts.h {
			return false
		}
		if py < ts.head_bot {
			if ts.running && px >= ts.kill_x0 && px < ts.kill_x1 {
				ts.hover_btn = 1
			} else if px >= ts.close_x0 && px < ts.close_x1 {
				ts.hover_btn = 2
			}
			return ts.hover_btn != 0
		}
		row := int(ts.scroll) + int((py-ts.head_bot)/ts.row_h)
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
			if ts.running && px >= ts.kill_x0 && px < ts.kill_x1 {
				self.task_stop()
			} else if px >= ts.close_x0 && px < ts.close_x1 {
				ts.open = false
			}
			return
		}
		row := int(ts.scroll) + int((py-ts.head_bot)/ts.row_h)
		if row < 0 || row >= len(ts.lines) {
			return
		}
		line := ts.lines[row]
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
		pos := buf.clamp_pos(Pos{max(l.line-1, 0), max(l.col-1, 0)})
		clear(&cursors)
		append(&cursors, cursor_at(pos))
		primary = 0
		want_follow = true
		want_center = true
		self.blink_reset()
	}

	task_wheel :: proc(dy: f32, cell_w: f32) {
		ts := &task
		hi := f32(max(len(ts.lines)-OUTPUT_VISIBLE, 0))
		ts.scroll = clamp(ts.scroll-dy*3, 0, hi)
		ts.follow = ts.scroll >= hi // wheeling back down re-arms following
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
		row_h := line_h * 1.1
		head_h := line_h * 1.4
		top := height - status_h - ts.h
		ts.top = top

		push_rect(r, 0, top, width, ts.h, theme.status_bg)
		push_rect(r, 0, top, width, 1, color_alpha(theme.gutter_fg, 0.6))

		draw_str :: proc(r: ^Renderer, x, baseline: f32, s: string, color: Color) {
			x := x
			for ch in s {
				push_glyph(r, x, baseline, ch, color)
				x += r.cell_w
			}
		}
		head_base := top + (head_h-line_h)*0.5 + r.ascent
		draw_str(r, cell_w, head_base, ts.title, theme.status_dim)

		// Header buttons, right-aligned: kill (while running) and close.
		ts.head_bot = top + head_h
		bx := width - cell_w - f32(len("close"))*cell_w
		ts.close_x0 = bx
		ts.close_x1 = bx + f32(len("close"))*cell_w
		draw_str(r, bx, head_base, "close", theme.fg if ts.hover_btn == 2 else theme.status_dim)
		if ts.hover_btn == 2 {
			push_rect(r, bx, head_base+3, f32(len("close"))*cell_w, 1, theme.status_dim)
		}
		ts.kill_x0 = 0
		ts.kill_x1 = 0
		if ts.running {
			bx -= f32(len("kill")+3)*cell_w
			ts.kill_x0 = bx
			ts.kill_x1 = bx + f32(len("kill"))*cell_w
			draw_str(r, bx, head_base, "kill", theme.diag_err)
			if ts.hover_btn == 1 {
				push_rect(r, bx, head_base+3, f32(len("kill"))*cell_w, 1, theme.diag_err)
			}
		}

		hi := f32(max(len(ts.lines)-OUTPUT_VISIBLE, 0))
		if ts.follow {
			ts.scroll = hi
		}
		ts.scroll = clamp(ts.scroll, 0, hi)
		row0 := int(ts.scroll)
		ts.row_h = row_h

		links := make([dynamic]Task_Link, context.temp_allocator)
		for vi in 0 ..< OUTPUT_VISIBLE {
			i := row0 + vi
			if i >= len(ts.lines) {
				break
			}
			row_y := top + head_h + f32(vi)*row_h
			baseline := row_y + (row_h-line_h)*0.5 + r.ascent
			line := ts.lines[i]
			// File references draw accented and underlined — they're
			// clickable; the one under the mouse also gets a backdrop and a
			// solid underline.
			clear(&links)
			task_scan_links(line, &links)
			x := cell_w
			for ch, off in line {
				if x+cell_w > width {
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
					push_rect(r, x, baseline+2, cell_w, 1,
						theme.faces[.Function] if hovered else color_alpha(theme.faces[.Function], 0.6))
				} else {
					push_glyph(r, x, baseline, ch, theme.status_fg)
				}
				x += cell_w
			}
		}

		draw_vscrollbar(r, width, top+head_h, f32(OUTPUT_VISIBLE)*row_h,
			f32(len(ts.lines))*row_h, ts.scroll*row_h, &theme)
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
		remove_range(&ts.partial, 0, nl+1)
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
}
