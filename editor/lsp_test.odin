package medit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Wire an App to a fake server: its "stdout" is a pipe we write frames into.
@(private = "file")
lsp_test_app :: proc(content: string) -> (app: App, srv_out: ^os.File) {
	app.theme = theme_default()
	app.buf = buffer_make("lsp_test_file.odin")
	if len(content) > 0 {
		app.buf.commit([]Edit{{range = {}, text = content}}, nil)
	}
	app.hl.lang = .Odin
	append(&app.cursors, cursor_at(Pos{0, 0}))

	r, w, err := os.pipe()
	assert(err == nil)
	app.lsp.from_srv = r
	// Give lsp_send somewhere to write; we never read it.
	_, w2, err2 := os.pipe()
	assert(err2 == nil)
	app.lsp.to_srv = w2
	app.lsp.state = .Ready
	return app, w
}

@(private = "file")
send_frame :: proc(w: ^os.File, body: string) {
	frame := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	_, _ = os.write(w, transmute([]u8)frame)
}

// The file URI that path_from_uri maps back to "lsp_test_file.odin".
@(private = "file")
test_uri :: proc() -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "file:///")
	for i in 0 ..< len(cwd) {
		strings.write_byte(&sb, '/' if cwd[i] == '\\' else cwd[i])
	}
	strings.write_string(&sb, "/lsp_test_file.odin")
	return strings.to_string(sb)
}

// JSON templates keep literal braces out of fmt (it treats {} as directives);
// @URI@ is substituted with the test document's URI.
@(private = "file")
with_uri :: proc(template: string) -> string {
	out, _ := strings.replace_all(template, "@URI@", test_uri(), context.temp_allocator)
	return out
}

@test
test_lsp_definition_response :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("first\nsecond\nthird target line\n")
	defer app_destroy(&app)

	app.lsp.pending[7] = Lsp_Req.Definition
	send_frame(srv, with_uri(`{"jsonrpc":"2.0","id":7,"result":[{"uri":"@URI@","range":{"start":{"line":2,"character":6},"end":{"line":2,"character":12}}}]}`))
	lsp_poll(&app)

	testing.expect_value(t, len(app.lsp.pending), 0)
	testing.expect_value(t, len(app.cursors), 1)
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start, Pos{2, 6})
	testing.expect_value(t, r.end, Pos{2, 12})
	testing.expect(t, app.want_follow, "should scroll to the jump target")
}

@test
test_lsp_references_response :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("aaa\nbbb\nccc\nddd\n")
	defer app_destroy(&app)

	app.lsp.pending[3] = Lsp_Req.References
	send_frame(srv, with_uri(`{"jsonrpc":"2.0","id":3,"result":[`+
		`{"uri":"@URI@","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}},`+
		`{"uri":"@URI@","range":{"start":{"line":3,"character":0},"end":{"line":3,"character":3}}}]}`))
	lsp_poll(&app)

	// Two usages: the palette opens in usages mode with both listed.
	testing.expect(t, app.palette.open, "palette should open for multiple usages")
	testing.expect_value(t, len(app.palette.usages), 2)
	testing.expect_value(t, len(app.palette.items), 2)
	testing.expect_value(t, app.palette.usages[1].line, 3)
	// Preview of the first usage selected it.
	testing.expect_value(t, cursor_range(app.cursors[0]).start, Pos{1, 0})
}

@test
test_lsp_rename_response :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("old_name := 1\nx := old_name\n")
	defer app_destroy(&app)

	app.lsp.pending[9] = Lsp_Req.Rename
	send_frame(srv, with_uri(`{"jsonrpc":"2.0","id":9,"result":{"changes":{"@URI@":[`+
		`{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}},"newText":"new_name"},`+
		`{"range":{"start":{"line":1,"character":5},"end":{"line":1,"character":13}},"newText":"new_name"}]}}}`))
	lsp_poll(&app)

	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "new_name := 1\nx := new_name\n")
	// The buffer edit is one undoable step.
	testing.expect_value(t, len(app.buf.undo_stack), 2) // initial content + rename
}

@test
test_lsp_hover_response :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("Foo :: struct {}\n")
	defer app_destroy(&app)

	app.hover_state = .Requested
	app.hover_pos = Pos{0, 0}
	app.hover_req_id = 4
	app.lsp.pending[4] = Lsp_Req.Hover
	send_frame(srv, `{"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"`+"```odin\\nFoo :: struct {}\\n```"+`"}}}`)
	lsp_poll(&app)

	testing.expect_value(t, app.hover_state, Hover_State.Shown)
	testing.expect_value(t, app.hover_text, "```odin\nFoo :: struct {}\n```")

	// A stale hover answer (id mismatch) must be ignored.
	app.hover_state = .Requested
	app.hover_req_id = 99
	app.lsp.pending[5] = Lsp_Req.Hover
	send_frame(srv, `{"jsonrpc":"2.0","id":5,"result":{"contents":"stale"}}`)
	lsp_poll(&app)
	testing.expect_value(t, app.hover_text, "```odin\nFoo :: struct {}\n```")
}

@test
test_lsp_hover_tick :: proc(t: ^testing.T) {
	app, _ := lsp_test_app("some_symbol := 1\nother_symbol := 2\n")
	defer app_destroy(&app)
	app.lsp.open_uri = strings.clone(test_uri())

	// Fake view geometry (normally set by draw): no sidebar, 100px gutter.
	app.gutter_px = 100
	app.view_h = 500

	cell_w, line_h: f32 = 8, 16
	app.now_ms = 1000
	app.hover_motion(140, 20, cell_w, line_h) // over "symbol" on line 1
	app.now_ms = 1500                         // rested past the dwell delay

	app.lsp_hover_tick(cell_w, line_h)
	testing.expect_value(t, app.hover_state, Hover_State.Requested)
	testing.expect_value(t, app.hover_pos.line, 1)
	found := false
	for _, kind in app.lsp.pending {
		if kind == .Hover {
			found = true
		}
	}
	testing.expect(t, found, "a hover request should be pending")

	// Not re-requested while pending, and gutter positions never fire.
	app.lsp_hover_tick(cell_w, line_h)
	testing.expect_value(t, len(app.lsp.pending), 1)
	app.hover_hide()
	app.hover_motion(50, 20, cell_w, line_h) // in the gutter
	app.now_ms = 2500
	app.lsp_hover_tick(cell_w, line_h)
	testing.expect_value(t, app.hover_state, Hover_State.Idle)
}

@test
test_lsp_completion :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("app.se")
	defer app_destroy(&app)
	app.cursors[0] = cursor_at(Pos{0, 6})
	app.completion.anchor = Pos{0, 4} // right after the dot
	app.completion.requested = true
	app.completion.req_id = 5
	app.lsp.pending[5] = Lsp_Req.Completion

	send_frame(srv, `{"jsonrpc":"2.0","id":5,"result":{"isIncomplete":false,"items":[`+
		`{"label":"set_status","kind":2,"detail":"proc(msg: string)"},`+
		`{"label":"select_all","kind":2},`+
		`{"label":"draw","kind":2}]}}`)
	lsp_poll(&app)

	testing.expect(t, app.completion.open, "popup should open")
	testing.expect_value(t, len(app.completion.items), 3)
	// Prefix "se" keeps set_status and select_all, drops draw.
	testing.expect_value(t, len(app.completion.visible), 2)

	// Accept "set_status" specifically.
	for vi, i in app.completion.visible {
		if app.completion.items[vi].label == "set_status" {
			app.completion.sel = i
		}
	}
	app.completion_accept()
	testing.expect_value(t, app.buf.text(context.temp_allocator), "app.set_status")
	testing.expect(t, !app.completion.open)

	// A stale response (wrong id) is dropped.
	app.completion.requested = true
	app.completion.req_id = 99
	app.lsp.pending[6] = Lsp_Req.Completion
	send_frame(srv, `{"jsonrpc":"2.0","id":6,"result":[{"label":"junk"}]}`)
	lsp_poll(&app)
	testing.expect(t, !app.completion.open)
}

@test
test_lsp_completion_method_snippet :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("buf.com")
	defer app_destroy(&app)
	app.cursors[0] = cursor_at(Pos{0, 7})
	app.completion.anchor = Pos{0, 4}
	app.completion.requested = true
	app.completion.req_id = 1
	app.lsp.pending[1] = Lsp_Req.Completion

	// Methodin-ols method item: snippet insert with per-arg placeholders.
	send_frame(srv, `{"jsonrpc":"2.0","id":1,"result":[`+
		`{"label":"commit","kind":2,"insertText":"commit(${1:edits}, ${2:cursors})$0",`+
		`"documentation":{"kind":"markdown","value":"`+"```odin\\nBuffer.commit :: proc(..)\\n```"+`"}}]}`)
	lsp_poll(&app)
	testing.expect(t, app.completion.open)
	// detail fell back to the documentation's code line
	testing.expect_value(t, app.completion.items[0].detail, "Buffer.commit :: proc(..)")

	app.completion_accept()
	testing.expect_value(t, app.buf.text(context.temp_allocator), "buf.commit(edits, cursors)")
	// The first placeholder is selected, ready to be typed over.
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, app.buf.range_text(r, context.temp_allocator), "edits")
}

@test
test_lsp_sighelp :: proc(t: ^testing.T) {
	app, srv := lsp_test_app("foo(1, ")
	defer app_destroy(&app)
	app.sighelp.req_id = 6
	app.lsp.pending[6] = Lsp_Req.Sig_Help

	send_frame(srv, `{"jsonrpc":"2.0","id":6,"result":{"activeSignature":0,"activeParameter":1,"signatures":[`+
		`{"label":"foo(a: int, b: string)","parameters":[{"label":"a: int"},{"label":"b: string"}]}]}}`)
	lsp_poll(&app)

	testing.expect(t, app.sighelp.open, "signature help should open")
	testing.expect_value(t, app.sighelp.label, "foo(a: int, b: string)")
	testing.expect_value(t, app.sighelp.label[app.sighelp.param_start:app.sighelp.param_end], "b: string")

	// Offsets-form parameter labels work too.
	app.sighelp.req_id = 7
	app.lsp.pending[7] = Lsp_Req.Sig_Help
	send_frame(srv, `{"jsonrpc":"2.0","id":7,"result":{"activeParameter":0,"signatures":[`+
		`{"label":"bar(x: f32)","parameters":[{"label":[4,10]}]}]}}`)
	lsp_poll(&app)
	testing.expect_value(t, app.sighelp.label[app.sighelp.param_start:app.sighelp.param_end], "x: f32")

	// Null result (cursor left the call) closes it.
	app.sighelp.req_id = 8
	app.lsp.pending[8] = Lsp_Req.Sig_Help
	send_frame(srv, `{"jsonrpc":"2.0","id":8,"result":null}`)
	lsp_poll(&app)
	testing.expect(t, !app.sighelp.open)
}

@test
test_lsp_frame_split_and_batch :: proc(t: ^testing.T) {
	// A frame delivered in two chunks, followed by a notification to ignore.
	app, srv := lsp_test_app("abc\ndef\n")
	defer app_destroy(&app)

	app.lsp.pending[1] = Lsp_Req.Definition
	body := with_uri(`{"jsonrpc":"2.0","id":1,"result":{"uri":"@URI@","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}}}}`)
	frame := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	half := len(frame) / 2
	_, _ = os.write(srv, transmute([]u8)frame[:half])
	lsp_poll(&app) // partial frame: nothing should happen yet
	testing.expect_value(t, cursor_range(app.cursors[0]).start, Pos{0, 0})
	_, _ = os.write(srv, transmute([]u8)frame[half:])

	send_frame(srv, `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{}}`)
	lsp_poll(&app)
	testing.expect_value(t, cursor_range(app.cursors[0]).start, Pos{1, 0})
	testing.expect_value(t, len(app.lsp.inbuf), 0)
}
