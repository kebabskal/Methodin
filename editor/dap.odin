// medit — debugging via DAP (the Debug Adapter Protocol). The same shape as
// the LSP client: an adapter process (lldb-dap by default, MEDIT_DAP
// overrides) speaks Content-Length-framed JSON over stdio, polled from the
// main loop; the editor never blocks on it.
//
// A task with `debug = true` and a `program = path` drives it: ctrl+r builds
// (its cmd, if any) and then launches the program under the adapter. F9
// toggles a breakpoint (also click in the gutter), F5 continues (or starts
// the debug task), F10/F11/shift+F11 step over/in/out, shift+F5 stops.
// Program output and locals-at-stop stream into the task output panel;
// runtime errors (panics, bounds checks) trap and stop the debugger like a
// breakpoint would.
package medit

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Dap_State :: enum {
	Off,
	Initializing, // initialize sent
	Launching,    // launch sent, waiting for the initialized event
	Running,
	Stopped, // at a breakpoint / step / trap
}

Dap_Req :: enum {
	Initialize,
	Launch,
	Set_Breakpoints,
	Config_Done,
	Stack_Trace,
	Scopes,
	Variables,
	Evaluate,       // hover: runtime value of the expression under the mouse
	Hover_Children, // hover on an aggregate: its fields/elements
	Local_Children, // aggregate local: one level of fields, shown inline
	Local_Expand,   // clicked aggregate: children become indented rows
	Locations,      // a clicked local's declaration site
	Resume,         // continue / next / stepIn / stepOut
	Disconnect,
}

Dap :: struct {
	state:    Dap_State,
	process:  os.Process,
	to_adp:   ^os.File,
	from_adp: ^os.File,
	inbuf:    [dynamic]u8,
	next_seq: int,
	pending:  map[int]Dap_Req,

	program:    string, // owned; what was launched (titles)
	launch_cwd: string, // owned; working directory for the launch request
	thread_id:  int,    // from the last stopped event
	frame_id:   int,    // the stopped frame hover expressions evaluate in
	hover_expr: string, // owned; expression a hover evaluate is in flight for

	// Current stop location ("" / -1: none) — drawn as a line highlight.
	stop_path: string, // owned; buffer-style (workspace-relative) path
	stop_line: int,    // 0-based

	// The stopped state, shown as columns in the output panel: the call
	// stack (click a frame to jump + re-scope) and the locals of sel_frame.
	frames:    [dynamic]Dap_Frame,
	locals:    [dynamic]Dap_Var,
	sel_frame:   int,
	child_req:   map[int]int, // Local_Children/Local_Expand request seq → Dap_Var id
	next_var_id: int,         // ids keep in-flight replies aimed while rows shift
	globals_req: int,         // seq of the Globals scope's variables request
}

Dap_Frame :: struct {
	name: string, // owned
	path: string, // owned; buffer-style ("" = no source)
	line: int,    // 1-based (display)
	id:   int,
}

Dap_Var :: struct {
	name:     string, // owned
	value:    string, // owned
	decl_ref: int,    // declarationLocationReference (0 = none)
	ref:      int,    // variablesReference (>0: an aggregate, expandable)
	id:       int,    // stable identity for in-flight child requests
	depth:    int,    // tree indent (0 = top level)
	expanded: bool,   // children shown as the rows below
}

dap_clear_stopped :: proc(d: ^Dap) {
	for f in d.frames {
		delete(f.name)
		delete(f.path)
	}
	clear(&d.frames)
	for v in d.locals {
		delete(v.name)
		delete(v.value)
	}
	clear(&d.locals)
	clear(&d.child_req)
	d.sel_frame = 0
}

// Index of the local with a given id; -1 once it is gone (rows shift under
// in-flight child requests when an expansion inserts or a collapse removes).
dap_local_by_id :: proc(d: ^Dap, id: int) -> int {
	for &v, i in d.locals {
		if v.id == id {
			return i
		}
	}
	return -1
}

Breakpoint :: struct {
	path: string, // owned; buffer-style path
	line: int,    // 0-based
}

@(private = "file")
djesc :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(&sb, "\\\"")
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
			strings.write_string(&sb, "\\r")
		case '\t':
			strings.write_string(&sb, "\\t")
		case:
			if c < 0x20 {
				strings.write_string(&sb, fmt.tprintf("\\u%04x", int(c)))
			} else {
				strings.write_byte(&sb, c)
			}
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
dap_send :: proc(d: ^Dap, body: string) {
	if d.to_adp == nil {
		return
	}
	msg := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	_, _ = os.write(d.to_adp, transmute([]u8)msg)
}

@(private = "file")
dap_request :: proc(d: ^Dap, kind: Dap_Req, command, arguments: string) -> int {
	seq := d.next_seq
	d.next_seq += 1
	d.pending[seq] = kind
	dap_send(d, fmt.tprintf(
		`{{"seq":%d,"type":"request","command":"%s","arguments":%s}}`,
		seq, command, arguments))
	return seq
}

@(private = "file")
dap_next_frame :: proc(d: ^Dap) -> (body: string, ok: bool) {
	data := string(d.inbuf[:])
	hdr_end := strings.index(data, "\r\n\r\n")
	if hdr_end < 0 {
		return
	}
	content_len := -1
	if idx := strings.index(data[:hdr_end], "Content-Length:"); idx >= 0 {
		v := strings.trim_space(data[idx+len("Content-Length:") : hdr_end])
		if nl := strings.index_byte(v, '\r'); nl >= 0 {
			v = v[:nl]
		}
		if all_digits(v) {
			content_len = to_int(v)
		}
	}
	if content_len < 0 {
		clear(&d.inbuf) // malformed header: drop the buffer
		return
	}
	start := hdr_end + 4
	if len(data) < start+content_len {
		return
	}
	body = strings.clone(data[start:start+content_len], context.temp_allocator)
	remove_range(&d.inbuf, 0, start+content_len)
	return body, true
}

dap_adapter_exe :: proc() -> string {
	if env := os.get_env("MEDIT_DAP", context.temp_allocator); env != "" {
		return env
	}
	when ODIN_OS == .Windows {
		// The LLVM installer's default home (it does not touch PATH).
		known :: `C:\Program Files\LLVM\bin\lldb-dap.exe`
		if os.exists(known) {
			return known
		}
	}
	return "lldb-dap" // PATH
}

// The adapter's environment. On Windows, LLVM's liblldb.dll hard-requires a
// version-matched Python (python311.dll for LLVM 22) and neither installer
// touches PATH — so the child gets a PATH extended with the adapter's own
// directory and a located Python, and works no matter how medit was
// launched. nil = inherit as-is (always, on other platforms).
dap_child_env :: proc(adapter: string) -> []string {
	when ODIN_OS != .Windows {
		return nil
	} else {
		extra := make([dynamic]string, context.temp_allocator)
		if dir, _ := os.split_path(adapter); dir != "" {
			append(&extra, dir)
		}
		local := os.get_env("LOCALAPPDATA", context.temp_allocator)
		candidates := [?]string{
			strings.concatenate({local, `\Programs\Python\Python311`}, context.temp_allocator),
			`C:\Python311`,
			`C:\Program Files\Python311`,
		}
		for cand in candidates {
			if os.exists(strings.concatenate({cand, `\python311.dll`}, context.temp_allocator)) {
				append(&extra, cand)
				break
			}
		}
		if len(extra) == 0 {
			return nil
		}
		envs, eerr := os.environ(context.temp_allocator)
		if eerr != nil {
			return nil
		}
		tail := strings.join(extra[:], ";", context.temp_allocator)
		out := make([dynamic]string, 0, len(envs)+1, context.temp_allocator)
		patched := false
		for e in envs {
			if len(e) >= 5 && strings.equal_fold(e[:5], "path=") {
				append(&out, fmt.tprintf("%s;%s", e, tail))
				patched = true
			} else {
				append(&out, e)
			}
		}
		if !patched {
			append(&out, fmt.tprintf("Path=%s", tail))
		}
		return out[:]
	}
}

impl App {
	dap_active :: proc() -> bool {
		return dap.state != .Off
	}

	// Launch program (buffer-style or absolute path) under the adapter.
	dap_launch :: proc(program, cwd: string) {
		self.dap_finish() // one session at a time
		d := &dap

		stdin_r, stdin_w, err1 := os.pipe()
		if err1 != nil {
			return
		}
		stdout_r, stdout_w, err2 := os.pipe()
		if err2 != nil {
			os.close(stdin_r)
			os.close(stdin_w)
			return
		}
		exe := dap_adapter_exe()
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, exe)
		// The Odin data formatters (odin_lldb.py next to the medit binary)
		// would load here — but lldb-dap 22.1.8 on Windows crashes with
		// 0xC0000409 whenever a script import runs inside a DAP session
		// (via initCommands or --pre-init-command; plain lldb is fine).
		// Opt in once a fixed adapter ships: MEDIT_DAP_FORMATTERS=1.
		if os.get_env("MEDIT_DAP_FORMATTERS", context.temp_allocator) != "" {
			if exe_dir, xerr := os.get_executable_directory(context.temp_allocator); xerr == nil {
				py, jerr := filepath.join({exe_dir, "odin_lldb.py"}, context.temp_allocator)
				if jerr == nil && os.exists(py) {
					fwd, _ := strings.replace_all(py, "\\", "/", context.temp_allocator)
					append(&cmd, "--pre-init-command", fmt.tprintf(`command script import "%s"`, fwd))
				}
			}
		}
		process, err := os.process_start({
			command = cmd[:],
			env     = dap_child_env(exe),
			stdin   = stdin_r,
			stdout  = stdout_w,
			stderr  = nil,
		})
		os.close(stdin_r)
		os.close(stdout_w)
		if err != nil {
			os.close(stdin_w)
			os.close(stdout_r)
			self.set_status(fmt.tprintf("debug adapter \"%s\" not found (MEDIT_DAP overrides)", exe))
			return
		}
		d.process = process
		d.to_adp = stdin_w
		d.from_adp = stdout_r
		d.next_seq = 1
		d.state = .Initializing
		delete(d.program)
		d.program = strings.clone(abs_path(program))
		delete(task.title)
		task.title = strings.clone(fmt.tprintf("debug: %s — starting", program))
		self.task_open_panel()

		// The launch request goes out once the initialize response lands.
		delete(d.launch_cwd)
		d.launch_cwd = strings.clone(abs_path(cwd) if cwd != "" else "")
		_ = dap_request(d, .Initialize, "initialize",
			`{"clientID":"medit","adapterID":"medit","linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path"}`)
	}

	// Toggle a breakpoint; a live session is updated immediately.
	breakpoint_toggle :: proc(path: string, line: int) {
		if path == "" {
			return
		}
		for b, i in breakpoints {
			if b.path == path && b.line == line {
				delete(breakpoints[i].path)
				ordered_remove(&breakpoints, i)
				self.dap_sync_breakpoints(path)
				return
			}
		}
		append(&breakpoints, Breakpoint{path = strings.clone(path), line = line})
		self.dap_sync_breakpoints(path)
	}

	breakpoint_toggle_at_cursor :: proc() {
		self.breakpoint_toggle(buf.path, self.primary_cursor().head.line)
	}

	breakpoint_at :: proc(path: string, line: int) -> bool {
		for b in breakpoints {
			if b.path == path && b.line == line {
				return true
			}
		}
		return false
	}

	// Push one file's breakpoints to the adapter (1-based lines, abs path).
	dap_sync_breakpoints :: proc(path: string) {
		if dap.state == .Off {
			return
		}
		sb := strings.builder_make(context.temp_allocator)
		first := true
		for b in breakpoints {
			if b.path != path {
				continue
			}
			if !first {
				strings.write_byte(&sb, ',')
			}
			strings.write_string(&sb, fmt.tprintf(`{{"line":%d}}`, b.line+1))
			first = false
		}
		_ = dap_request(&dap, .Set_Breakpoints, "setBreakpoints", fmt.tprintf(
			`{{"source":{{"path":"%s"}},"breakpoints":[%s]}}`,
			djesc(abs_path(path)), strings.to_string(sb)))
	}

	dap_sync_all_breakpoints :: proc() {
		done := make([dynamic]string, context.temp_allocator)
		outer: for b in breakpoints {
			for p in done {
				if p == b.path {
					continue outer
				}
			}
			append(&done, b.path)
			self.dap_sync_breakpoints(b.path)
		}
	}

	// The dotted expression under p ("foo.bar" when hovering bar), for a
	// runtime-value hover while stopped.
	dap_expr_at :: proc(p: Pos) -> string {
		r := buf.word_range_at(p)
		if r.start.col >= r.end.col {
			return ""
		}
		line := buf.line_str(p.line)
		start := r.start.col
		for start >= 2 && line[start-1] == '.' {
			s := start - 1
			for s > 0 && char_class(rune(line[s-1])) == 1 {
				s -= 1
			}
			if s == start-1 {
				break
			}
			start = s
		}
		return line[start:r.end.col]
	}

	// lsp_hover_tick delegates here while the debugger is stopped: evaluate
	// the expression under the mouse in the stopped frame.
	dap_hover_request :: proc(p: Pos) -> bool {
		expr := self.dap_expr_at(p)
		if expr == "" {
			return false
		}
		delete(dap.hover_expr)
		dap.hover_expr = strings.clone(expr)
		hover_pos = p
		hover_state = .Requested
		hover_armed = false
		hover_req_id = dap_request(&dap, .Evaluate, "evaluate", fmt.tprintf(
			`{{"expression":"%s","frameId":%d,"context":"hover"}}`, djesc(expr), dap.frame_id))
		return true
	}

	// F5: continue when stopped; with no session, run the first debug task.
	dap_f5 :: proc() {
		switch dap.state {
		case .Stopped:
			self.dap_resume("continue")
		case .Running, .Initializing, .Launching:
			self.set_status("debuggee is running")
		case .Off:
			tasks_load(&task)
			for t, i in task.tasks {
				if t.debug {
					self.task_run(i)
					return
				}
			}
			self.set_status("no debug task — add debug = true in " + TASKS_PATH)
		}
	}

	// continue / next / stepIn / stepOut while stopped.
	dap_resume :: proc(command: string) {
		if dap.state != .Stopped {
			return
		}
		_ = dap_request(&dap, .Resume, command, fmt.tprintf(`{{"threadId":%d}}`, dap.thread_id))
		self.dap_mark_running()
	}

	dap_mark_running :: proc() {
		dap.state = .Running
		dap_clear_stopped(&dap)
		delete(dap.stop_path)
		dap.stop_path = ""
		dap.stop_line = -1
		delete(task.title)
		task.title = strings.clone(fmt.tprintf("debug: %s — running", dap.program))
	}

	// shift+F5 / the panel's kill button: end the session.
	dap_stop :: proc() {
		if dap.state == .Off {
			return
		}
		_ = dap_request(&dap, .Disconnect, "disconnect", `{"terminateDebuggee":true}`)
		// Blunt fallback so a wedged adapter cannot leave a zombie session:
		// the poll loop cleans up on pipe EOF, and the kill covers the rest.
		if dap.process.pid != 0 { // pid 0 = never spawned; kill(0) is our own process group
			_ = os.process_kill(dap.process)
		}
	}

	// Tear the session down (adapter gone or being replaced).
	dap_finish :: proc() {
		d := &dap
		if d.state == .Off {
			return
		}
		if d.process.pid != 0 {
			_ = os.process_kill(d.process)
			_, _ = os.process_wait(d.process)
		}
		if d.to_adp != nil {
			os.close(d.to_adp)
			os.close(d.from_adp)
			d.to_adp = nil
			d.from_adp = nil
		}
		d.state = .Off
		d.stop_line = -1
		delete(d.stop_path)
		d.stop_path = ""
		dap_clear_stopped(d)
		clear(&d.pending)
		clear(&d.inbuf)
	}

	// Click on a local: jump to its declaration — the adapter's declaration
	// location when it reports one, else the nearest whole-word occurrence
	// above the stop line in the stopped file.
	dap_local_goto :: proc(i: int) {
		d := &dap
		if d.state != .Stopped || i < 0 || i >= len(d.locals) {
			return
		}
		v := &d.locals[i]
		if v.value == "" {
			return // the globals divider row
		}
		if v.decl_ref > 0 {
			_ = dap_request(d, .Locations, "locations", fmt.tprintf(`{{"locationReference":%d}}`, v.decl_ref))
			return
		}
		if d.stop_path == "" || buf.path != d.stop_path {
			return
		}
		for line := min(d.stop_line, buf.line_count()-1); line >= 0; line -= 1 {
			s := buf.line_str(line)
			idx := strings.index(s, v.name)
			for idx >= 0 {
				before_ok := idx == 0 || char_class(rune(s[idx-1])) != 1
				after := idx + len(v.name)
				after_ok := after >= len(s) || char_class(rune(s[after])) != 1
				if before_ok && after_ok {
					self.push_cursor_undo()
					clear(&cursors)
					append(&cursors, cursor_at(buf.clamp_pos(Pos{line, idx})))
					primary = 0
					want_follow = true
					want_center = true
					return
				}
				next := strings.index(s[after:], v.name)
				idx = after + next if next >= 0 else -1
			}
		}
	}

	// Click on an aggregate local: its children become indented rows below
	// it (fetched on first expand), or fold back up.
	dap_local_toggle :: proc(i: int) {
		d := &dap
		if d.state != .Stopped || i < 0 || i >= len(d.locals) {
			return
		}
		v := &d.locals[i]
		if v.ref <= 0 || v.value == "" {
			return
		}
		if v.expanded {
			v.expanded = false
			n := 0
			for i+1+n < len(d.locals) && d.locals[i+1+n].depth > v.depth {
				delete(d.locals[i+1+n].name)
				delete(d.locals[i+1+n].value)
				n += 1
			}
			remove_range(&d.locals, i+1, i+1+n)
			return
		}
		s := dap_request(d, .Local_Expand, "variables", fmt.tprintf(`{{"variablesReference":%d}}`, v.ref))
		d.child_req[s] = v.id
	}

	// Click on a call-stack frame: jump there and re-scope the locals.
	dap_select_frame :: proc(i: int) {
		d := &dap
		if d.state != .Stopped || i < 0 || i >= len(d.frames) {
			return
		}
		d.sel_frame = i
		f := &d.frames[i]
		d.frame_id = f.id
		if f.path != "" {
			delete(d.stop_path)
			d.stop_path = strings.clone(f.path)
			d.stop_line = f.line - 1
			if os.exists(f.path) {
				self.open_file(f.path)
				if buf.path == f.path {
					clear(&cursors)
					append(&cursors, cursor_at(buf.clamp_pos(Pos{d.stop_line, 0})))
					primary = 0
					want_follow = true
					want_center = true
				}
			}
		}
		for v in d.locals {
			delete(v.name)
			delete(v.value)
		}
		clear(&d.locals)
		_ = dap_request(d, .Scopes, "scopes", fmt.tprintf(`{{"frameId":%d}}`, d.frame_id))
	}
}

dap_destroy :: proc(d: ^Dap) {
	dap_clear_stopped(d)
	delete(d.frames)
	delete(d.locals)
	delete(d.child_req)
	if d.state != .Off {
		if d.process.pid != 0 {
			_ = os.process_kill(d.process)
		}
		if d.to_adp != nil {
			os.close(d.to_adp)
			os.close(d.from_adp)
		}
	}
	delete(d.inbuf)
	delete(d.pending)
	delete(d.program)
	delete(d.stop_path)
	delete(d.launch_cwd)
	delete(d.hover_expr)
}

// The adapter's pipe died. Say why — an instant exit with STATUS_DLL_NOT_-
// FOUND is the classic "liblldb cannot find its Python" failure.
@(private = "file")
dap_session_lost :: proc(app: ^App) {
	state: os.Process_State
	if app.dap.process.pid != 0 {
		state, _ = os.process_wait(app.dap.process, 0)
	}
	app.dap_finish()
	if state.exited && state.exit_code == -1073741515 { // 0xC0000135
		app.set_status("debug adapter failed to start: a DLL is missing (liblldb needs python311.dll)")
		task_append_line(&app.task, "-- debug adapter exited: missing DLL (liblldb needs python311.dll on PATH)")
	} else if state.exited && state.exit_code != 0 {
		app.set_status(fmt.tprintf("debug adapter exited with code %d", state.exit_code))
		task_append_line(&app.task, fmt.tprintf("-- debug adapter exited with code %d", state.exit_code))
	} else {
		app.set_status("debug session ended")
		task_append_line(&app.task, "-- debug session ended")
	}
}

dap_poll :: proc(app: ^App) {
	d := &app.dap
	if d.state == .Off {
		return
	}
	for {
		has, err := os.pipe_has_data(d.from_adp)
		if err != nil {
			dap_session_lost(app) // adapter exited (or dap_stop killed it)
			return
		}
		if !has {
			break
		}
		chunk: [8192]u8
		n, rerr := os.read(d.from_adp, chunk[:])
		if n > 0 {
			append(&d.inbuf, ..chunk[:n])
		}
		if rerr != nil {
			dap_session_lost(app)
			return
		}
	}
	for {
		body, ok := dap_next_frame(d)
		if !ok {
			break
		}
		dap_handle(app, body)
	}
}

@(private = "file")
dap_handle :: proc(app: ^App, body: string) {
	d := &app.dap
	v, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	switch jstr(jget(v, "type")) {
	case "response":
		seq := jint(jget(v, "request_seq"))
		kind, known := d.pending[seq]
		if !known {
			return
		}
		delete_key(&d.pending, seq)
		if ok, is_bool := jget(v, "success").(json.Boolean); is_bool && !ok {
			// A failed launch is fatal; anything else just reports.
			msg := jstr(jget(v, "message"))
			task_append_line(&app.task, fmt.tprintf("-- %s failed: %s", jstr(jget(v, "command")), msg))
			if kind == .Initialize || kind == .Launch {
				app.dap_finish()
				app.set_status("debug launch failed")
			}
			return
		}
		dap_on_response(app, kind, jget(v, "body"), seq)
	case "event":
		dap_on_event(app, jstr(jget(v, "event")), jget(v, "body"))
	}
}

// lldb spells globals in the global namespace, duplicates disambiguated
// by address: "::counter @ 0x7ff6…" → "counter".
@(private = "file")
dap_global_name :: proc(name: string) -> string {
	n := name
	if strings.has_prefix(n, "::") {
		n = n[2:]
	}
	if at := strings.index(n, " @ "); at >= 0 {
		n = n[:at]
	}
	return n
}

// CRT scalar statics whose names and types look exactly like user globals
// (plain ints and bools), so the shape rules below can't catch them.
@(private = "file")
DAP_GLOBAL_NOISE := []string{
	"errno_no_memory", "doserrno_no_memory", "fSystemSet",
	"is_initialized_as_dll", "c_termination_complete",
	"module_local_atexit_table_initialized", "function_pointers",
	"module_names", "module_handles", "thread_local_exit_callback_func",
}

// Does a Globals-scope variable look like the user's own code? Compiler
// and CRT statics carry _/$ name prefixes, C++ qualifiers, or C-only type
// shapes (const arrays, templates, function pointers); Odin's runtime
// internals carry runtime:: types or reserved __ name suffixes.
@(private = "file")
dap_global_user_space :: proc(name, type_name: string) -> bool {
	if name == "" || name[0] == '_' || name[0] == '$' {
		return false
	}
	if strings.contains(name, "::") || strings.contains_rune(name, '`') {
		return false
	}
	if strings.has_suffix(name, "__") { // args__ and friends
		return false
	}
	for noise in DAP_GLOBAL_NOISE {
		if name == noise {
			return false
		}
	}
	if strings.has_prefix(type_name, "_") || strings.has_prefix(type_name, "const ") {
		return false
	}
	if strings.contains(type_name, "(*") || strings.contains_rune(type_name, '<') {
		return false
	}
	if strings.contains(type_name, "runtime::") {
		return false
	}
	return true
}

@(private = "file")
dap_on_response :: proc(app: ^App, kind: Dap_Req, body: json.Value, seq: int) {
	d := &app.dap
	switch kind {
	case .Initialize:
		_ = dap_request(d, .Launch, "launch", fmt.tprintf(
			`{{"program":"%s","cwd":"%s","stopOnEntry":false}}`,
			djesc(d.program), djesc(d.launch_cwd if d.launch_cwd != "" else abs_path("."))))
		d.state = .Launching
	case .Stack_Trace:
		frames := jarr(jget(body, "stackFrames"))
		if len(frames) == 0 {
			return
		}
		// The stack fills the panel's call-stack column (frames with a
		// source are clickable). The anchor is the first workspace frame
		// when there is one (a trap unwinds through runtime internals
		// first), else the first frame with any real source.
		dap_clear_stopped(d)
		anchor := -1
		ws_anchor := -1
		for f, i in frames {
			if i >= 32 {
				break
			}
			line := jint(jget(f, "line"))
			src := jget(f, "source")
			path := jstr(jget(src, "path"))
			// Frames without debug info get a synthetic disassembly
			// source (a sourceReference and a dll`symbol path) — not a file.
			if jint(jget(src, "sourceReference")) > 0 {
				path = ""
			}
			short := shorten_path(path) if path != "" && line > 0 else ""
			append(&d.frames, Dap_Frame{
				name = strings.clone(jstr(jget(f, "name"))),
				path = strings.clone(short),
				line = line,
				id   = jint(jget(f, "id")),
			})
			if short != "" {
				if anchor < 0 {
					anchor = i
				}
				if ws_anchor < 0 && len(short) < len(path) { // relative ⇒ inside the workspace
					ws_anchor = i
				}
			}
		}
		if ws_anchor >= 0 {
			anchor = ws_anchor
		}
		if anchor < 0 {
			return
		}
		d.sel_frame = anchor
		f := &d.frames[anchor]
		d.frame_id = f.id
		delete(d.stop_path)
		d.stop_path = strings.clone(f.path)
		d.stop_line = f.line - 1
		if os.exists(f.path) {
			app.open_file(f.path)
			if app.buf.path == f.path {
				clear(&app.cursors)
				append(&app.cursors, cursor_at(app.buf.clamp_pos(Pos{d.stop_line, 0})))
				app.primary = 0
				app.want_follow = true
				app.want_center = true
			}
		}
		// Locals of that frame follow.
		_ = dap_request(d, .Scopes, "scopes", fmt.tprintf(`{{"frameId":%d}}`, d.frame_id))
	case .Scopes:
		// Locals first, then a Globals/Statics scope when the adapter has
		// one — separated in the panel by a divider row (value == "").
		d.globals_req = 0
		for s, i in jarr(jget(body, "scopes")) {
			name := jstr(jget(s, "name"))
			ref := jint(jget(s, "variablesReference"))
			if ref <= 0 || name == "Registers" {
				continue
			}
			if i == 0 || name == "Locals" {
				_ = dap_request(d, .Variables, "variables", fmt.tprintf(`{{"variablesReference":%d}}`, ref))
			} else if name == "Globals" || name == "Statics" {
				d.globals_req = dap_request(d, .Variables, "variables", fmt.tprintf(`{{"variablesReference":%d}}`, ref))
			}
		}
	case .Variables:
		// The locals column of the panel. Aggregates ([3]f32, structs, …)
		// report their value in children — fetch one level and show it
		// inline, so locals read like hovers do.
		// The Globals scope arrives target-wide: user globals come
		// unqualified ("::time", duplicates as "::name @ 0xADDR") mixed
		// into hundreds of CRT and Odin-runtime statics, and DWARF gives
		// them no declaration references to filter by. Keep what looks
		// like user code by shape (dap_global_user_space).
		is_globals := seq == d.globals_req
		sep_done := false
		kept := 0
		for v, i in jarr(jget(body, "variables")) {
			if i >= (4096 if is_globals else 256) {
				break
			}
			name := jstr(jget(v, "name"))
			if is_globals {
				if kept >= 64 {
					break
				}
				name = dap_global_name(name)
				if !dap_global_user_space(name, jstr(jget(v, "type"))) {
					continue
				}
				if !sep_done {
					append(&d.locals, Dap_Var{name = strings.clone("— globals —"), value = strings.clone("")})
					sep_done = true
				}
				kept += 1
			}
			ref := jint(jget(v, "variablesReference"))
			append(&d.locals, Dap_Var{
				name     = strings.clone(name),
				value    = strings.clone(jstr(jget(v, "value"))),
				decl_ref = jint(jget(v, "declarationLocationReference")),
				ref      = ref,
				id       = d.next_var_id,
			})
			d.next_var_id += 1
			if ref > 0 && len(d.locals) <= 48 {
				s := dap_request(d, .Local_Children, "variables", fmt.tprintf(`{{"variablesReference":%d}}`, ref))
				d.child_req[s] = d.locals[len(d.locals)-1].id
			}
		}
	case .Local_Children:
		id, known := d.child_req[seq]
		delete_key(&d.child_req, seq)
		i := dap_local_by_id(d, id)
		if !known || i < 0 {
			return
		}
		sb := strings.builder_make(context.temp_allocator)
		strings.write_byte(&sb, '{')
		for v, j in jarr(jget(body, "variables")) {
			if j >= 8 {
				strings.write_string(&sb, ", …")
				break
			}
			if j > 0 {
				strings.write_string(&sb, ", ")
			}
			// Indexed children ({1, 2, 3}) skip their [i] names, Odin-style.
			name := jstr(jget(v, "name"))
			if len(name) > 0 && name[0] != '[' {
				strings.write_string(&sb, name)
				strings.write_string(&sb, " = ")
			}
			strings.write_string(&sb, jstr(jget(v, "value")))
		}
		strings.write_byte(&sb, '}')
		delete(d.locals[i].value)
		d.locals[i].value = strings.clone(strings.to_string(sb))
	case .Local_Expand:
		id, eknown := d.child_req[seq]
		delete_key(&d.child_req, seq)
		pi := dap_local_by_id(d, id)
		if !eknown || pi < 0 || d.locals[pi].expanded {
			return
		}
		d.locals[pi].expanded = true
		pdepth := d.locals[pi].depth
		at := pi + 1
		for v, j in jarr(jget(body, "variables")) {
			if j >= 128 {
				break
			}
			inject_at(&d.locals, at, Dap_Var{
				name     = strings.clone(jstr(jget(v, "name"))),
				value    = strings.clone(jstr(jget(v, "value"))),
				decl_ref = jint(jget(v, "declarationLocationReference")),
				ref      = jint(jget(v, "variablesReference")),
				id       = d.next_var_id,
				depth    = pdepth + 1,
			})
			d.next_var_id += 1
			at += 1
		}
	case .Locations:
		// A clicked local's declaration: jump there.
		line := jint(jget(body, "line"))
		path := shorten_path(jstr(jget(jget(body, "source"), "path")))
		if path != "" && line > 0 && os.exists(path) {
			app.open_file(path)
			if app.buf.path == path {
				app.push_cursor_undo()
				clear(&app.cursors)
				append(&app.cursors, cursor_at(app.buf.clamp_pos(Pos{line - 1, 0})))
				app.primary = 0
				app.want_follow = true
				app.want_center = true
			}
		}
	case .Evaluate:
		// A hover request: show "expr = value" in the regular hover tooltip.
		if app.hover_state != .Requested {
			return // the mouse moved on
		}
		res := jstr(jget(body, "result"))
		ref := jint(jget(body, "variablesReference"))
		if res == "" && ref <= 0 {
			app.hover_state = .Idle
			return
		}
		delete(app.hover_text)
		app.hover_text = strings.clone(fmt.tprintf("%s = %s", d.hover_expr, res))
		if ref > 0 {
			// An aggregate: lldb's "result" is just the type — the value
			// lives in the children. Fetch one level before showing.
			_ = dap_request(d, .Hover_Children, "variables", fmt.tprintf(
				`{{"variablesReference":%d}}`, ref))
			return
		}
		app.hover_state = .Shown
	case .Hover_Children:
		if app.hover_state != .Requested {
			return // the mouse moved on
		}
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, app.hover_text)
		vars := jarr(jget(body, "variables"))
		for v, i in vars {
			if i >= 16 {
				strings.write_string(&sb, fmt.tprintf("\n  … %d more", len(vars)-i))
				break
			}
			strings.write_string(&sb, fmt.tprintf("\n  %s = %s", jstr(jget(v, "name")), jstr(jget(v, "value"))))
		}
		delete(app.hover_text)
		app.hover_text = strings.clone(strings.to_string(sb))
		app.hover_state = .Shown
	case .Launch, .Set_Breakpoints, .Config_Done, .Resume, .Disconnect:
		// Nothing to do beyond the state changes made when sending.
	}
}

@(private = "file")
dap_on_event :: proc(app: ^App, event: string, body: json.Value) {
	d := &app.dap
	switch event {
	case "initialized":
		app.dap_sync_all_breakpoints()
		_ = dap_request(d, .Config_Done, "configurationDone", "{}")
		app.dap_mark_running()
		app.set_status(fmt.tprintf("debugging %s", d.program))
	case "stopped":
		d.state = .Stopped
		d.thread_id = jint(jget(body, "threadId"))
		reason := jstr(jget(body, "reason"))
		delete(app.task.title)
		app.task.title = strings.clone(fmt.tprintf("debug: %s — stopped (%s)", d.program, reason))
		task_append_line(&app.task, fmt.tprintf("-- stopped (%s)", reason))
		app.task_open_panel()
		_ = dap_request(d, .Stack_Trace, "stackTrace", fmt.tprintf(
			`{{"threadId":%d,"startFrame":0,"levels":20}}`, d.thread_id))
	case "continued":
		app.dap_mark_running()
	case "output":
		out := jstr(jget(body, "output"))
		for line in strings.split_lines_iterator(&out) {
			if len(line) > 0 {
				task_append_line(&app.task, line)
			}
		}
	case "exited":
		task_append_line(&app.task, fmt.tprintf("-- exited with code %d", jint(jget(body, "exitCode"))))
		app.set_status(fmt.tprintf("debuggee exited with code %d", jint(jget(body, "exitCode"))))
	case "terminated":
		app.dap_finish()
		delete(app.task.title)
		app.task.title = strings.clone("debug — session ended")
	}
}
