// medit — LSP client.
//
// JSON-RPC over stdio to one language server at a time, chosen by the current
// buffer's language (Methodin-ols for .odin; add more in lsp_server_exe).
// No threads: the server's stdout pipe is polled from the main loop with
// os.pipe_has_data, and complete Content-Length frames are peeled off an
// accumulation buffer. Document sync is whole-text didChange, driven by the
// buffer version — lsp_update is idempotent and runs every frame:
//
//   frame: lsp_update  (start server / didOpen / didChange as needed)
//          lsp_poll    (read stdout, dispatch responses)
//
// Requests carry an id → kind entry in `pending`; responses jump the cursor
// (definition), fill the palette's usages mode (references), or apply a
// WorkspaceEdit (rename — current buffer through the undo system, other
// files directly on disk).
package medit

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

Lsp_State :: enum {
	Off,
	Starting, // spawned, waiting for the initialize response
	Ready,
	Failed, // could not start or died; sticky for the session
}

Lsp_Req :: enum {
	Initialize,
	Definition,
	References,
	Rename,
	Hover,
	Completion,
	Sig_Help,
	Doc_Symbols,
	Workspace_Symbols,
	Format, // format-on-save; the pending write completes when this lands
}

Hover_State :: enum {
	Idle,      // nothing shown, nothing pending
	Requested, // dwell fired, waiting for the server
	Shown,     // tooltip visible (or empty answer, which blocks re-asking)
}

// A resolved source location, in LSP (UTF-16) column units; converted to
// buffer positions only once the file is actually open.
Lsp_Location :: struct {
	path:         string, // owned; relative to the working directory when inside it
	line, char:   int,
	eline, echar: int,
}

Lsp :: struct {
	state:    Lsp_State,
	process:  os.Process,
	to_srv:   ^os.File, // server stdin (we write)
	from_srv: ^os.File, // server stdout (we poll + read)

	inbuf:   [dynamic]u8,
	next_id: int,
	pending: map[int]Lsp_Req,

	open_uri:       string, // owned; document currently open on the server
	doc_version:    int,
	synced_version: int, // buffer version last pushed
}

when ODIN_OS == .Windows {
	@(private = "file")
	EXE_SUFFIX :: ".exe"
} else {
	@(private = "file")
	EXE_SUFFIX :: ""
}

// Which languages have a server at all — cheap, called every frame.
// Other languages: add a case here, in lsp_server_exe, and a languageId below.
@(private = "file")
lsp_has_server :: proc(lang: Lang) -> bool {
	#partial switch lang {
	case .Odin:
		return true
	}
	return false
}

@(private = "file")
SEP :: "\\" when ODIN_OS == .Windows else "/"

// Resolve the server executable (only when actually spawning). MEDIT_OLS
// overrides; otherwise a Methodin-ols checkout is searched for in the
// working directory and each of its ancestors (so running medit from the
// repo root or a subdirectory both find a sibling ../Methodin-ols), falling
// back to `ols` on PATH.
@(private = "file")
lsp_server_exe :: proc(lang: Lang) -> string {
	#partial switch lang {
	case .Odin:
		if env := os.get_env("MEDIT_OLS", context.temp_allocator); env != "" {
			return env
		}
		cwd, _ := os.get_working_directory(context.temp_allocator)
		dir := cwd
		for _ in 0 ..< 6 {
			candidates := [?]string{
				strings.concatenate({dir, SEP, "ols", EXE_SUFFIX}, context.temp_allocator),
				strings.concatenate({dir, SEP, "Methodin-ols", SEP, "ols", EXE_SUFFIX}, context.temp_allocator),
				strings.concatenate({dir, SEP, "ols", SEP, "ols", EXE_SUFFIX}, context.temp_allocator),
			}
			for c in candidates {
				if os.exists(c) {
					return c
				}
			}
			idx := strings.last_index_any(dir, "/\\")
			if idx <= 0 {
				break
			}
			dir = dir[:idx]
		}
		return "ols" // PATH
	}
	return ""
}

@(private = "file")
lsp_language_id :: proc(lang: Lang) -> string {
	#partial switch lang {
	case .Odin:
		return "odin"
	}
	return "plaintext"
}

// --- Encoding helpers ----------------------------------------------------------

@(private = "file")
jesc :: proc(s: string) -> string {
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
				fmt.sbprintf(&sb, "\\u%04x", c)
			} else {
				strings.write_byte(&sb, c)
			}
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
uri_from_abs :: proc(abs: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "file://")
	if len(abs) > 0 && abs[0] != '/' {
		strings.write_byte(&sb, '/') // Windows drive paths: file:///C:/...
	}
	for i in 0 ..< len(abs) {
		c := abs[i]
		switch c {
		case '\\':
			strings.write_byte(&sb, '/')
		case ' ':
			strings.write_string(&sb, "%20")
		case '%':
			strings.write_string(&sb, "%25")
		case:
			strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

// URI for a buffer path (relative paths resolve against the cwd). "" if none.
@(private = "file")
lsp_uri_for :: proc(path: string) -> string {
	if path == "" {
		return ""
	}
	abs := path
	is_abs := strings.has_prefix(path, "/") || (len(path) > 1 && path[1] == ':')
	if !is_abs {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		abs, _ = filepath.join({cwd, path}, context.temp_allocator)
	}
	return uri_from_abs(abs)
}

@(private = "file")
hexval :: proc(c: u8) -> int {
	switch {
	case '0' <= c && c <= '9':
		return int(c - '0')
	case 'a' <= c && c <= 'f':
		return int(c-'a') + 10
	case 'A' <= c && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// Package-visible: problems.odin resolves diagnostics URIs with it.
path_from_uri :: proc(uri: string) -> string {
	s := uri
	if strings.has_prefix(s, "file://") {
		s = s[len("file://"):] // keeps the leading '/' of the absolute path
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i+2 < len(s) {
			hi, lo := hexval(s[i+1]), hexval(s[i+2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&sb, u8(hi*16 + lo))
				i += 3
				continue
			}
		}
		when ODIN_OS == .Windows {
			strings.write_byte(&sb, '\\' if c == '/' else c)
		} else {
			strings.write_byte(&sb, c)
		}
		i += 1
	}
	path := strings.to_string(sb)
	when ODIN_OS == .Windows {
		// file:///C:/x decodes to \C:\x — drop the leading separator.
		if len(path) > 2 && path[0] == '\\' && path[2] == ':' {
			path = path[1:]
		}
	}
	return shorten_path(path)
}

// LSP columns are UTF-16 code units; buffer columns are bytes.
@(private = "file")
utf16_col :: proc(b: ^Buffer, p: Pos) -> int {
	s := b.line_str(p.line)
	u := 0
	for i := 0; i < min(p.col, len(s)); {
		r, n := utf8.decode_rune(s[i:])
		u += 2 if r > 0xFFFF else 1
		i += n
	}
	return u
}

// Package-visible: completion applies additionalTextEdits (auto-import).
buf_pos_from_utf16 :: proc(b: ^Buffer, line, character: int) -> Pos {
	l := clamp(line, 0, b.line_count()-1)
	s := b.line_str(l)
	u := 0
	i := 0
	for i < len(s) && u < character {
		r, n := utf8.decode_rune(s[i:])
		u += 2 if r > 0xFFFF else 1
		i += n
	}
	return b.clamp_pos(Pos{l, i})
}

// --- Wire ----------------------------------------------------------------------

@(private = "file")
lsp_send :: proc(l: ^Lsp, body: string) {
	if l.to_srv == nil {
		return
	}
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	if _, err := os.write(l.to_srv, transmute([]u8)header); err != nil {
		return // poll notices the dead pipe and fails the session
	}
	_, _ = os.write(l.to_srv, transmute([]u8)body)
}

@(private)
lsp_request :: proc(l: ^Lsp, kind: Lsp_Req, method: string, params: string) -> int {
	id := l.next_id
	l.next_id += 1
	l.pending[id] = kind
	lsp_send(l, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}}`, id, method, params))
	return id
}

@(private = "file")
lsp_notify :: proc(l: ^Lsp, method: string, params: string) {
	lsp_send(l, fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params))
}

// --- Lifecycle -------------------------------------------------------------------

@(private = "file")
lsp_start :: proc(app: ^App, exe: string) {
	l := &app.lsp
	stdin_r, stdin_w, err1 := os.pipe()
	if err1 != nil {
		l.state = .Failed
		return
	}
	stdout_r, stdout_w, err2 := os.pipe()
	if err2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		l.state = .Failed
		return
	}

	process, err := os.process_start({
		command = []string{exe},
		stdin   = stdin_r,
		stdout  = stdout_w,
		stderr  = nil, // servers log freely there; discard
	})
	// The child inherited its ends; drop ours.
	os.close(stdin_r)
	os.close(stdout_w)
	if err != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		l.state = .Failed
		app.set_status(fmt.tprintf("language server \"%s\" not found (MEDIT_OLS overrides)", exe))
		return
	}

	l.process = process
	l.to_srv = stdin_w
	l.from_srv = stdout_r
	l.state = .Starting
	l.next_id = 1

	cwd, _ := os.get_working_directory(context.temp_allocator)
	root := jesc(uri_from_abs(cwd))
	params := fmt.tprintf(
		// snippetSupport matters: Methodin-ols only offers method completion
		// to snippet-capable clients (its method inserts are snippets, which
		// completion_accept resolves).
		// workspaceFolders matters too: ols indexes workspace symbols (and
		// walks references) from that list, not from rootUri.
		`{{"processId":null,"clientInfo":{{"name":"medit"}},"rootUri":"%s","workspaceFolders":[{{"uri":"%s","name":"%s"}}],"capabilities":{{"textDocument":{{"definition":{{}},"references":{{}},"rename":{{}},"hover":{{}},"completion":{{"completionItem":{{"snippetSupport":true}}}},"signatureHelp":{{}},"documentSymbol":{{"hierarchicalDocumentSymbolSupport":true}}}},"workspace":{{"symbol":{{}}}}}}}}`,
		root, root, jesc(filepath.base(cwd)))
	_ = lsp_request(l, .Initialize, "initialize", params)
}

lsp_stop :: proc(l: ^Lsp) {
	if l.state == .Starting || l.state == .Ready {
		lsp_notify(l, "exit", "null")
		os.close(l.to_srv)
		os.close(l.from_srv)
		_ = os.process_kill(l.process)
	}
	l.to_srv = nil
	l.from_srv = nil
	l.state = .Off
	delete(l.inbuf)
	l.inbuf = nil
	delete(l.pending)
	l.pending = nil
	delete(l.open_uri)
	l.open_uri = ""
}

@(private = "file")
lsp_fail :: proc(app: ^App, msg: string) {
	l := &app.lsp
	if l.to_srv != nil {
		os.close(l.to_srv)
		os.close(l.from_srv)
		_ = os.process_kill(l.process)
		l.to_srv = nil
		l.from_srv = nil
	}
	l.state = .Failed
	delete(l.open_uri)
	l.open_uri = ""
	app.set_status(msg)
}

// Runs every frame: keeps the server matched to the current document and
// pushes edits. Idempotent and cheap when nothing changed.
lsp_update :: proc(app: ^App) {
	l := &app.lsp
	if !lsp_has_server(app.hl.lang) || app.buf.path == "" {
		if l.state == .Ready && l.open_uri != "" {
			lsp_notify(l, "textDocument/didClose", fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, jesc(l.open_uri)))
			delete(l.open_uri)
			l.open_uri = ""
		}
		return
	}
	if l.state == .Off {
		lsp_start(app, lsp_server_exe(app.hl.lang))
	}
	if l.state != .Ready {
		return
	}

	uri := lsp_uri_for(app.buf.path)
	if uri != l.open_uri {
		if l.open_uri != "" {
			lsp_notify(l, "textDocument/didClose", fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, jesc(l.open_uri)))
		}
		l.doc_version += 1
		text := app.buf.text(context.temp_allocator)
		lsp_notify(l, "textDocument/didOpen", fmt.tprintf(
			`{{"textDocument":{{"uri":"%s","languageId":"%s","version":%d,"text":"%s"}}}}`,
			jesc(uri), lsp_language_id(app.hl.lang), l.doc_version, jesc(text)))
		delete(l.open_uri)
		l.open_uri = strings.clone(uri)
		l.synced_version = app.buf.version
	} else if app.buf.version != l.synced_version {
		l.doc_version += 1
		text := app.buf.text(context.temp_allocator)
		lsp_notify(l, "textDocument/didChange", fmt.tprintf(
			`{{"textDocument":{{"uri":"%s","version":%d}},"contentChanges":[{{"text":"%s"}}]}}`,
			jesc(uri), l.doc_version, jesc(text)))
		l.synced_version = app.buf.version
	}
}

// --- Reading ---------------------------------------------------------------------

lsp_poll :: proc(app: ^App) {
	l := &app.lsp
	if l.state != .Ready && l.state != .Starting {
		return
	}
	for {
		has, err := os.pipe_has_data(l.from_srv)
		if err != nil {
			lsp_fail(app, "language server exited")
			return
		}
		if !has {
			break
		}
		chunk: [8192]u8
		n, rerr := os.read(l.from_srv, chunk[:])
		if n > 0 {
			append(&l.inbuf, ..chunk[:n])
		}
		if rerr != nil {
			lsp_fail(app, "language server exited")
			return
		}
	}
	for {
		body, ok := lsp_next_frame(l)
		if !ok {
			break
		}
		lsp_handle(app, body)
	}
}

@(private = "file")
lsp_next_frame :: proc(l: ^Lsp) -> (body: string, ok: bool) {
	data := string(l.inbuf[:])
	hdr_end := strings.index(data, "\r\n\r\n")
	if hdr_end < 0 {
		return
	}
	content_len := -1
	if idx := strings.index(data[:hdr_end], "Content-Length:"); idx >= 0 {
		v := strings.trim_space(data[idx+len("Content-Length:") : hdr_end])
		// The value may be followed by another header line.
		if nl := strings.index_byte(v, '\r'); nl >= 0 {
			v = v[:nl]
		}
		n := 0
		for i in 0 ..< len(v) {
			if '0' <= v[i] && v[i] <= '9' {
				n = n*10 + int(v[i]-'0')
			}
		}
		content_len = n
	}
	if content_len < 0 {
		// Malformed header: drop it and try to resync.
		remove_range(&l.inbuf, 0, hdr_end+4)
		return "", false
	}
	total := hdr_end + 4 + content_len
	if len(data) < total {
		return
	}
	body = strings.clone(data[hdr_end+4:total], context.temp_allocator)
	remove_range(&l.inbuf, 0, total)
	return body, true
}

// --- JSON value helpers (shared with complete.odin) ---------------------------------

@(private)
jget :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

@(private)
jstr :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

@(private)
jint :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	}
	return 0
}

@(private)
jarr :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}

// --- Dispatch ---------------------------------------------------------------------

@(private = "file")
lsp_handle :: proc(app: ^App, body: string) {
	l := &app.lsp
	val, jerr := json.parse_string(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if jerr != nil {
		return
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return
	}

	if methodv, has_method := obj["method"]; has_method {
		if jstr(methodv) == "textDocument/publishDiagnostics" {
			lsp_on_diagnostics(app, obj["params"])
			return
		}
		if idv, has_id := obj["id"]; has_id {
			// Server→client request; a null result satisfies the ones
			// ols sends (configuration, registerCapability, ...).
			if ids, is_str := idv.(json.String); is_str {
				lsp_send(l, fmt.tprintf(`{{"jsonrpc":"2.0","id":"%s","result":null}}`, jesc(ids)))
			} else {
				lsp_send(l, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":null}}`, jint(idv)))
			}
		}
		return // notifications (diagnostics, logs) are ignored for now
	}

	idv, has_id := obj["id"]
	if !has_id {
		return
	}
	id := jint(idv)
	kind, was_pending := l.pending[id]
	if !was_pending {
		return
	}
	delete_key(&l.pending, id)

	if errv, has_err := obj["error"]; has_err {
		#partial switch kind {
		case .Definition, .References, .Rename, .Initialize:
			app.set_status(fmt.tprintf("lsp: %s", jstr(jget(errv, "message"))))
		case .Format:
			// The formatter failing must never swallow the save.
			lsp_on_format(app, nil, id)
		}
		return // hover/completion/signature errors are not worth a status line
	}
	result := obj["result"]
	switch kind {
	case .Initialize:
		l.state = .Ready
		lsp_notify(l, "initialized", "{}")
	case .Definition:
		lsp_on_definition(app, result)
	case .References:
		lsp_on_references(app, result)
	case .Rename:
		lsp_on_rename(app, result)
	case .Hover:
		lsp_on_hover(app, result, id)
	case .Completion:
		lsp_on_completion(app, result, id)
	case .Sig_Help:
		lsp_on_sighelp(app, result, id)
	case .Doc_Symbols:
		lsp_on_doc_symbols(app, result, id)
	case .Workspace_Symbols:
		lsp_on_workspace_symbols(app, result, id)
	case .Format:
		lsp_on_format(app, result, id)
	}
}

// After a successful write: ols runs its checker on didSave, which feeds the
// problems panel. The full text rides along (ols re-indexes from it).
lsp_did_save :: proc(app: ^App) {
	l := &app.lsp
	if l.state != .Ready || l.open_uri == "" {
		return
	}
	text := app.buf.text(context.temp_allocator)
	lsp_notify(l, "textDocument/didSave", fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"text":"%s"}}`, jesc(l.open_uri), jesc(text)))
}

// --- Format on save ----------------------------------------------------------------

impl App {
	// Ask the server to format the current document before saving; the save
	// itself completes in lsp_on_format (or in format_save_tick on timeout).
	// Returns false when the request could not be made — caller saves plain.
	format_request :: proc() -> bool {
		if !self.lsp_ready_quiet() {
			return false
		}
		lsp_update(self) // push pending edits so the server formats what we see
		if lsp.synced_version != buf.version || lsp.open_uri == "" {
			return false
		}
		fmt_req = lsp_request(&lsp, .Format, "textDocument/formatting", fmt.tprintf(
			`{{"textDocument":{{"uri":"%s"}},"options":{{"tabSize":%d,"insertSpaces":false}}}}`,
			jesc(lsp.open_uri), tab_w))
		delete(fmt_path)
		fmt_path = strings.clone(buf.path)
		fmt_deadline = now_ms + 1500
		return true
	}

	// Runs every frame: a formatter that never answers must not hold the
	// file hostage — save unformatted once the deadline passes.
	format_save_tick :: proc() {
		if fmt_req != 0 && now_ms > fmt_deadline {
			fmt_req = 0
			if buf.path == fmt_path {
				self.save_now()
				self.set_status("saved (formatter timed out)")
			}
		}
	}
}

@(private = "file")
lsp_on_format :: proc(app: ^App, result: json.Value, id: int) {
	if id != app.fmt_req {
		return // stale
	}
	app.fmt_req = 0
	if app.buf.path != app.fmt_path {
		return // tab switched mid-save; leave that buffer dirty rather than guess
	}
	if edits := jarr(result); len(edits) > 0 {
		lsp_apply_file_edits(app, app.buf.path, edits)
	}
	app.save_now()
}

// --- Symbols (palette ! outline and # workspace search) ---------------------------

// DocumentSymbol {name, kind, selectionRange, children} (hierarchical) or
// SymbolInformation {name, kind, location} (flat) — both are handled.
@(private = "file")
lsp_on_doc_symbols :: proc(app: ^App, result: json.Value, id: int) {
	p := &app.palette
	if id != p.sym_req_id {
		return // stale
	}
	symbols_clear(p)
	walk :: proc(p: ^Palette, v: json.Value, depth: int) {
		if len(p.symbols) >= 2000 {
			return
		}
		name := jstr(jget(v, "name"))
		if name == "" {
			return
		}
		rng := jget(v, "selectionRange")
		if rng == nil {
			rng = jget(jget(v, "location"), "range")
		}
		s := jget(rng, "start")
		e := jget(rng, "end")
		detail := jstr(jget(v, "detail"))
		if detail == "" {
			detail = jstr(jget(v, "containerName"))
		}
		append(&p.symbols, Symbol_Item{
			name   = strings.clone(name),
			detail = strings.clone(detail),
			path   = strings.clone(""),
			kind   = jint(jget(v, "kind")),
			line   = jint(jget(s, "line")),
			char   = jint(jget(s, "character")),
			eline  = jint(jget(e, "line")),
			echar  = jint(jget(e, "character")),
			depth  = depth,
		})
		for c in jarr(jget(v, "children")) {
			walk(p, c, depth+1)
		}
	}
	for v in jarr(result) {
		walk(p, v, 0)
	}
	if p.open {
		app.palette_refresh()
	}
}

@(private = "file")
lsp_on_workspace_symbols :: proc(app: ^App, result: json.Value, id: int) {
	p := &app.palette
	if id != p.sym_req_id {
		return // an answer for an older query
	}
	symbols_clear(p)
	for v in jarr(result) {
		if len(p.symbols) >= 500 {
			break
		}
		name := jstr(jget(v, "name"))
		if name == "" {
			continue
		}
		loc := jget(v, "location")
		rng := jget(loc, "range")
		s := jget(rng, "start")
		e := jget(rng, "end")
		append(&p.symbols, Symbol_Item{
			name   = strings.clone(name),
			detail = strings.clone(jstr(jget(v, "containerName"))),
			path   = strings.clone(path_from_uri(jstr(jget(loc, "uri")))),
			kind   = jint(jget(v, "kind")),
			line   = jint(jget(s, "line")),
			char   = jint(jget(s, "character")),
			eline  = jint(jget(e, "line")),
			echar  = jint(jget(e, "character")),
		})
	}
	if p.open {
		app.palette_refresh()
	}
}

// Location {uri, range} or LocationLink {targetUri, targetSelectionRange}.
@(private = "file")
lsp_loc_from_json :: proc(v: json.Value) -> (loc: Lsp_Location, ok: bool) {
	uri := jstr(jget(v, "uri"))
	rng := jget(v, "range")
	if uri == "" {
		uri = jstr(jget(v, "targetUri"))
		rng = jget(v, "targetSelectionRange")
	}
	if uri == "" {
		return
	}
	s := jget(rng, "start")
	e := jget(rng, "end")
	loc = Lsp_Location{
		path  = strings.clone(path_from_uri(uri)),
		line  = jint(jget(s, "line")),
		char  = jint(jget(s, "character")),
		eline = jint(jget(e, "line")),
		echar = jint(jget(e, "character")),
	}
	return loc, true
}

@(private = "file")
lsp_on_definition :: proc(app: ^App, result: json.Value) {
	v := result
	if arr, is_arr := v.(json.Array); is_arr {
		if len(arr) == 0 {
			app.set_status("no definition found")
			return
		}
		v = arr[0]
	}
	loc, ok := lsp_loc_from_json(v)
	if !ok {
		app.set_status("no definition found")
		return
	}
	defer delete(loc.path)
	app.lsp_jump(loc)
}

@(private = "file")
lsp_on_references :: proc(app: ^App, result: json.Value) {
	arr, is_arr := result.(json.Array)
	if !is_arr || len(arr) == 0 {
		app.set_status("no usages found")
		return
	}
	usages_clear(&app.palette)
	for v in arr {
		if loc, ok := lsp_loc_from_json(v); ok {
			append(&app.palette.usages, loc)
			if len(app.palette.usages) >= 500 {
				break
			}
		}
	}
	if len(app.palette.usages) == 1 {
		loc := app.palette.usages[0]
		app.lsp_jump(loc)
		usages_clear(&app.palette)
		return
	}
	app.palette_open_with("", forced = PALETTE_MODE_USAGES)
}

// Apply one file's TextEdits from a WorkspaceEdit. The current buffer goes
// through commit (undoable); other files are edited on disk.
@(private = "file")
lsp_apply_file_edits :: proc(app: ^App, path: string, edits: json.Array) -> bool {
	to_buf_edits :: proc(b: ^Buffer, edits: json.Array) -> []Edit {
		out := make([dynamic]Edit, context.temp_allocator)
		for ev in edits {
			r := jget(ev, "range")
			s := jget(r, "start")
			e := jget(r, "end")
			append(&out, Edit{
				range = {
					buf_pos_from_utf16(b, jint(jget(s, "line")), jint(jget(s, "character"))),
					buf_pos_from_utf16(b, jint(jget(e, "line")), jint(jget(e, "character"))),
				},
				text = jstr(jget(ev, "newText")),
			})
		}
		return out[:]
	}

	if path == app.buf.path {
		app.apply_keep_selections(to_buf_edits(&app.buf, edits))
		return true
	}
	// Open in another tab: edit that buffer (kept dirty, in its undo history)
	// instead of clobbering it on disk behind its back.
	for &d, i in app.docs {
		if i == app.active || d.buf.path != path {
			continue
		}
		d.buf.commit(to_buf_edits(&d.buf, edits), d.cursors[:])
		for &c in d.cursors {
			c.head = d.buf.clamp_pos(c.head)
			c.anchor = d.buf.clamp_pos(c.anchor)
		}
		return true
	}
	b, ok := buffer_load(path)
	if !ok {
		return false
	}
	defer buffer_destroy(&b)
	b.commit(to_buf_edits(&b, edits), nil)
	return buffer_save(&b)
}

@(private = "file")
lsp_on_rename :: proc(app: ^App, result: json.Value) {
	files := 0
	failed := 0
	if ch, ok := jget(result, "changes").(json.Object); ok {
		for uri, editsv in ch {
			if lsp_apply_file_edits(app, path_from_uri(uri), jarr(editsv)) {
				files += 1
			} else {
				failed += 1
			}
		}
	}
	if dc, ok := jget(result, "documentChanges").(json.Array); ok {
		for dv in dc {
			uri := jstr(jget(jget(dv, "textDocument"), "uri"))
			if uri == "" {
				continue // create/rename/delete file operations: unsupported
			}
			if lsp_apply_file_edits(app, path_from_uri(uri), jarr(jget(dv, "edits"))) {
				files += 1
			} else {
				failed += 1
			}
		}
	}
	switch {
	case files == 0 && failed == 0:
		app.set_status("rename: nothing to change")
	case failed > 0:
		app.set_status(fmt.tprintf("renamed in %d file(s), %d failed", files, failed))
	case:
		app.set_status(fmt.tprintf("renamed in %d file(s)", files))
	}
}

// --- Editor-facing actions ---------------------------------------------------------

impl App {
	// Like lsp_ready, but silent — for automatic triggers (completion, hover).
	lsp_ready_quiet :: proc() -> bool {
		lsp_update(self)
		return lsp.state == .Ready && lsp.open_uri != ""
	}

	// Flush pending edits and confirm there is a live server for this doc.
	lsp_ready :: proc() -> bool {
		lsp_update(self)
		if lsp.state == .Ready && lsp.open_uri != "" {
			return true
		}
		switch lsp.state {
		case .Failed:
			self.set_status("language server failed to start — set MEDIT_OLS or put ols on PATH (\">lsp\" to retry)")
		case .Starting:
			self.set_status("language server is starting…")
		case .Off, .Ready:
			self.set_status("no language server for this file type")
		}
		return false
	}

	// Palette: kill and relaunch the server (e.g. after installing ols).
	lsp_restart :: proc() {
		lsp_stop(&lsp)
		lsp_update(self)
		if !lsp_has_server(hl.lang) {
			self.set_status("no language server configured for this file type")
		} else {
			self.set_status(fmt.tprintf("language server: %s (%v)", lsp_server_exe(hl.lang), lsp.state))
		}
	}

	lsp_position_params :: proc(p: Pos) -> string {
		return fmt.tprintf(`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
			jesc(lsp.open_uri), p.line, utf16_col(&buf, p))
	}

	lsp_goto_definition :: proc() {
		if !self.lsp_ready() {
			return
		}
		lsp_request(&lsp, .Definition, "textDocument/definition",
			self.lsp_position_params(self.primary_cursor().head))
	}

	lsp_find_references :: proc() {
		if !self.lsp_ready() {
			return
		}
		p := self.primary_cursor().head
		params := fmt.tprintf(
			`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}},"context":{{"includeDeclaration":true}}}}`,
			jesc(lsp.open_uri), p.line, utf16_col(&buf, p))
		lsp_request(&lsp, .References, "textDocument/references", params)
	}

	// F2: prompt for the new name in the palette, then request the rename.
	lsp_rename_prompt :: proc() {
		r := buf.word_range_at(self.primary_cursor().head)
		if range_empty(r) {
			self.set_status("no symbol under the cursor")
			return
		}
		if !self.lsp_ready() {
			return
		}
		palette.ctx_pos = r.start
		self.palette_open_with(buf.range_text(r, context.temp_allocator), forced = PALETTE_MODE_RENAME)
	}

	lsp_rename :: proc(p: Pos, new_name: string) {
		if !self.lsp_ready() {
			return
		}
		params := fmt.tprintf(
			`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}},"newName":"%s"}}`,
			jesc(lsp.open_uri), p.line, utf16_col(&buf, p), jesc(new_name))
		lsp_request(&lsp, .Rename, "textDocument/rename", params)
	}

	// Fetch the document outline (palette ! mode). Stamps what it fetched so
	// the palette only refetches when the document actually changed.
	lsp_doc_symbols :: proc() {
		if !self.lsp_ready_quiet() {
			return
		}
		palette.sym_mode = .Outline
		delete(palette.sym_path)
		palette.sym_path = strings.clone(buf.path)
		palette.sym_version = buf.version
		palette.sym_req_id = lsp_request(&lsp, .Doc_Symbols, "textDocument/documentSymbol",
			fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, jesc(lsp.open_uri)))
	}

	// Search workspace symbols (palette # mode); the latest query wins.
	lsp_workspace_symbols :: proc(q: string) {
		if !self.lsp_ready_quiet() {
			return
		}
		palette.sym_mode = .Workspace
		delete(palette.sym_query)
		palette.sym_query = strings.clone(q)
		palette.sym_req_id = lsp_request(&lsp, .Workspace_Symbols, "workspace/symbol",
			fmt.tprintf(`{{"query":"%s"}}`, jesc(q)))
	}

	// Select loc's range in the current buffer (no file switch, no undo mark) —
	// live preview for the usages list.
	lsp_select_range :: proc(loc: Lsp_Location) {
		s := buf_pos_from_utf16(&buf, loc.line, loc.char)
		e := buf_pos_from_utf16(&buf, loc.eline, loc.echar)
		clear(&cursors)
		append(&cursors, Cursor{head = e, anchor = s, goal_col = -1})
		primary = 0
		want_follow = true
		self.blink_reset()
	}

	// Jump to a resolved location, opening its file (in a tab) if needed.
	lsp_jump :: proc(loc: Lsp_Location) {
		if loc.path != buf.path {
			self.open_file(loc.path)
			if buf.path != loc.path {
				return // could not be opened; the status bar explains
			}
		}
		self.push_cursor_undo()
		self.lsp_select_range(loc)
	}
}

// --- Hover -----------------------------------------------------------------------

HOVER_DELAY_MS :: 400

// Hover.contents is MarkedString | MarkedString[] | MarkupContent.
@(private = "file")
hover_extract :: proc(result: json.Value) -> string {
	write_one :: proc(sb: ^strings.Builder, v: json.Value) {
		#partial switch x in v {
		case json.String:
			strings.write_string(sb, x)
		case json.Object:
			strings.write_string(sb, jstr(jget(v, "value")))
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	c := jget(result, "contents")
	if arr, is_arr := c.(json.Array); is_arr {
		for e, i in arr {
			if i > 0 {
				strings.write_string(&sb, "\n")
			}
			write_one(&sb, e)
		}
	} else {
		write_one(&sb, c)
	}
	return strings.to_string(sb)
}

@(private = "file")
lsp_on_hover :: proc(app: ^App, result: json.Value, id: int) {
	if app.hover_state != .Requested || id != app.hover_req_id {
		return // stale answer for a hover we already left
	}
	delete(app.hover_text)
	app.hover_text = strings.clone(hover_extract(result))
	// Shown even when empty: it stops the tick from asking again until the
	// mouse moves away.
	app.hover_state = .Shown
}

impl App {
	hover_hide :: proc() {
		hover_state = .Idle
		hover_armed = false // require a mouse move before asking again
		delete(hover_text)
		hover_text = ""
	}

	// Every mouse move: remember where/when, and drop the tooltip once the
	// pointer leaves the hovered word.
	hover_motion :: proc(px, py: f32, cell_w, line_h: f32) {
		mouse_x = px
		mouse_y = py
		mouse_moved_ms = now_ms
		hover_armed = true
		if hover_state != .Idle {
			p := self.pos_at_pixel(px, py, cell_w, line_h)
			r := buf.word_range_at(hover_pos)
			if p.line != hover_pos.line || pos_less(p, r.start) || !pos_less(p, r.end) {
				self.hover_hide()
				hover_armed = true
			}
		}
	}

	// Every frame: fire a hover request once the mouse has rested on a word.
	lsp_hover_tick :: proc(cell_w, line_h: f32) {
		if hover_state != .Idle || !hover_armed || palette.open {
			return
		}
		if lsp.state != .Ready || lsp.open_uri == "" {
			return
		}
		if now_ms - mouse_moved_ms < HOVER_DELAY_MS {
			return
		}
		if mouse_x < gutter_px || mouse_y < tabbar_h || mouse_y >= tabbar_h+view_h {
			return
		}
		p := self.pos_at_pixel(mouse_x, mouse_y, cell_w, line_h)
		if char_class(buf.rune_at(p)) != 1 {
			return
		}
		hover_pos = p
		hover_state = .Requested
		hover_armed = false
		hover_req_id = lsp_request(&lsp, .Hover, "textDocument/hover", self.lsp_position_params(p))
	}

	hover_draw :: proc(r: ^Renderer, width, height: f32) {
		if hover_state != .Shown || len(hover_text) == 0 {
			return
		}
		line_h := r.line_h
		cell_w := r.cell_w

		// Markdown-lite: fenced blocks are code (normal color), prose is dim.
		Hover_Line :: struct {
			text: string,
			code: bool,
		}
		lines := make([dynamic]Hover_Line, context.temp_allocator)
		in_code := false
		it := hover_text
		for raw in strings.split_lines_iterator(&it) {
			line := strings.trim_right(raw, "\r ")
			if strings.has_prefix(strings.trim_left(line, " "), "```") {
				in_code = !in_code
				continue
			}
			if strings.contains_rune(line, '\t') {
				line, _ = strings.replace_all(line, "\t", "    ", context.temp_allocator)
			}
			append(&lines, Hover_Line{line, in_code})
		}
		// Trim blank edges, cap the height.
		lo := 0
		hi := len(lines)
		for lo < hi && len(strings.trim_space(lines[lo].text)) == 0 {
			lo += 1
		}
		for hi > lo && len(strings.trim_space(lines[hi-1].text)) == 0 {
			hi -= 1
		}
		if lo >= hi {
			return
		}
		shown := make([dynamic]Hover_Line, context.temp_allocator)
		for i in lo ..< hi {
			if len(shown) == 20 {
				append(&shown, Hover_Line{fmt.tprintf("… %d more lines", hi-i), false})
				break
			}
			append(&shown, lines[i])
		}

		max_cells := 0
		for l in shown {
			max_cells = max(max_cells, strings.rune_count(l.text))
		}
		max_cells = clamp(max_cells, 8, 100)

		pad := cell_w
		w := f32(max_cells)*cell_w + pad*2
		h := f32(len(shown))*line_h + pad

		// Anchor under the hovered word; flip above if it doesn't fit.
		ax := gutter_px + f32(visual_col(&buf, hover_pos.line, hover_pos.col))*cell_w - scroll_x
		ay := tabbar_h + f32(hover_pos.line+1)*line_h - scroll_y + 2
		ax = clamp(ax, sidebar_px, max(sidebar_px, width-w))
		if ay+h > height-status_h {
			ay = tabbar_h + f32(hover_pos.line)*line_h - scroll_y - h - 2
		}
		ay = max(ay, 0)

		push_rect(r, ax-1, ay-1, w+2, h+2, color_alpha(theme.gutter_fg, 0.8))
		push_rect(r, ax, ay, w, h, theme.status_bg)
		for l, i in shown {
			baseline := ay + pad*0.5 + f32(i)*line_h + r.ascent
			color := theme.fg if l.code else theme.status_dim
			x := ax + pad
			n := 0
			for ch in l.text {
				if n >= max_cells-1 && strings.rune_count(l.text) > max_cells {
					push_glyph(r, x, baseline, '…', theme.status_dim)
					break
				}
				push_glyph(r, x, baseline, ch, color)
				x += cell_w
				n += 1
			}
		}
	}
}
