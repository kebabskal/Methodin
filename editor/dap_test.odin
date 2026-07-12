package medit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Wire an App to a fake debug adapter: its "stdout" is a pipe we write
// frames into, mirroring how lsp_test.odin fakes a language server.
@(private = "file")
dap_test_app :: proc() -> (app: App, adp_out: ^os.File) {
	app.theme = theme_default()
	app.buf = buffer_make("dap_test_file.odin")
	app.buf.commit([]Edit{{range = {}, text = "a\nb\nc\nd\n"}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 0}))

	r, w, err := os.pipe()
	assert(err == nil)
	app.dap.from_adp = r
	_, w2, err2 := os.pipe()
	assert(err2 == nil)
	app.dap.to_adp = w2
	app.dap.state = .Initializing
	app.dap.pending[1] = Dap_Req.Initialize
	app.dap.next_seq = 2
	app.dap.program = strings.clone("dev.exe")
	app.dap.launch_cwd = strings.clone("")
	app.dap.stop_line = -1
	return app, w
}

@(private = "file")
dap_send_frame :: proc(w: ^os.File, body: string) {
	frame := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	_, _ = os.write(w, transmute([]u8)frame)
}

@(private = "file")
dap_pending_seq :: proc(d: ^Dap, kind: Dap_Req) -> int {
	for seq, k in d.pending {
		if k == kind {
			return seq
		}
	}
	return -1
}

// The test file's absolute path, forward slashes (JSON-safe; shorten_path
// folds separators when mapping it back).
@(private = "file")
dap_test_abs :: proc() -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	folded, _ := strings.replace_all(cwd, "\\", "/", context.temp_allocator)
	return strings.concatenate({folded, "/dap_test_file.odin"}, context.temp_allocator)
}

@(private = "file")
with_id :: proc(template: string, id: int) -> string {
	out, _ := strings.replace_all(template, "@ID@", fmt.tprintf("%d", id), context.temp_allocator)
	out, _ = strings.replace_all(out, "@PATH@", dap_test_abs(), context.temp_allocator)
	return out
}

@test
test_dap_session_flow :: proc(t: ^testing.T) {
	app, adp := dap_test_app()
	defer app_destroy(&app)
	d := &app.dap

	app.breakpoint_toggle("dap_test_file.odin", 2) // session live: syncs too
	testing.expect_value(t, len(app.breakpoints), 1)

	// initialize response → the launch request goes out.
	dap_send_frame(adp, `{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{}}`)
	dap_poll(&app)
	testing.expect_value(t, d.state, Dap_State.Launching)
	testing.expect(t, dap_pending_seq(d, .Launch) > 0, "expected a launch request in flight")

	// initialized event → breakpoints re-sync, configurationDone, running.
	dap_send_frame(adp, `{"seq":2,"type":"event","event":"initialized"}`)
	dap_poll(&app)
	testing.expect_value(t, d.state, Dap_State.Running)

	// stopped event → stackTrace is requested.
	dap_send_frame(adp, `{"seq":3,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":7}}`)
	dap_poll(&app)
	testing.expect_value(t, d.state, Dap_State.Stopped)
	testing.expect_value(t, d.thread_id, 7)
	st := dap_pending_seq(d, .Stack_Trace)
	testing.expect(t, st > 0, "expected a stackTrace request in flight")

	// stackTrace response → stop location lands, scopes requested.
	dap_send_frame(adp, with_id(`{"seq":4,"type":"response","request_seq":@ID@,"success":true,"command":"stackTrace","body":{"stackFrames":[{"id":100,"name":"main","line":3,"column":1,"source":{"path":"@PATH@"}}]}}`, st))
	dap_poll(&app)
	testing.expect_value(t, d.stop_path, "dap_test_file.odin")
	testing.expect_value(t, d.stop_line, 2)
	sc := dap_pending_seq(d, .Scopes)
	testing.expect(t, sc > 0, "expected a scopes request in flight")

	// scopes → variables → locals land in the output panel.
	dap_send_frame(adp, with_id(`{"seq":5,"type":"response","request_seq":@ID@,"success":true,"command":"scopes","body":{"scopes":[{"name":"Locals","variablesReference":11}]}}`, sc))
	dap_poll(&app)
	va := dap_pending_seq(d, .Variables)
	testing.expect(t, va > 0, "expected a variables request in flight")
	dap_send_frame(adp, with_id(`{"seq":6,"type":"response","request_seq":@ID@,"success":true,"command":"variables","body":{"variables":[{"name":"x","value":"42"},{"name":"s","value":"float[3]","variablesReference":21}]}}`, va))
	dap_poll(&app)
	// The aggregate local's children render inline, Odin-style.
	lc := dap_pending_seq(d, .Local_Children)
	testing.expect(t, lc > 0, "expected a local-children request in flight")
	dap_send_frame(adp, with_id(`{"seq":9,"type":"response","request_seq":@ID@,"success":true,"command":"variables","body":{"variables":[{"name":"[0]","value":"1"},{"name":"[1]","value":"2"},{"name":"[2]","value":"3"}]}}`, lc))
	dap_poll(&app)
	testing.expect_value(t, d.locals[1].value, "{1, 2, 3}")
	testing.expect_value(t, len(d.frames), 1) // the call-stack column
	if len(d.frames) == 1 {
		testing.expect_value(t, d.frames[0].name, "main")
		testing.expect_value(t, d.frames[0].line, 3)
	}
	testing.expect_value(t, len(d.locals), 2) // the locals column
	if len(d.locals) == 2 {
		testing.expect_value(t, d.locals[0].name, "x")
		testing.expect_value(t, d.locals[0].value, "42")
	}

	// Hovering while stopped evaluates the expression in the stopped frame.
	testing.expect_value(t, app.dap_hover_request(Pos{2, 0}), true) // the word "c"
	ev := dap_pending_seq(d, .Evaluate)
	testing.expect(t, ev > 0, "expected an evaluate request in flight")
	dap_send_frame(adp, with_id(`{"seq":10,"type":"response","request_seq":@ID@,"success":true,"command":"evaluate","body":{"result":"99"}}`, ev))
	dap_poll(&app)
	testing.expect_value(t, app.hover_state, Hover_State.Shown)
	testing.expect_value(t, app.hover_text, "c = 99")

	// An aggregate hover: the result is just the type, the value arrives
	// via one level of children.
	app.hover_hide()
	testing.expect_value(t, app.dap_hover_request(Pos{3, 0}), true) // the word "d"
	ev = dap_pending_seq(d, .Evaluate)
	dap_send_frame(adp, with_id(`{"seq":11,"type":"response","request_seq":@ID@,"success":true,"command":"evaluate","body":{"result":"float[2]","variablesReference":33}}`, ev))
	dap_poll(&app)
	testing.expect_value(t, app.hover_state, Hover_State.Requested) // waiting for children
	hc := dap_pending_seq(d, .Hover_Children)
	testing.expect(t, hc > 0, "expected a children request in flight")
	dap_send_frame(adp, with_id(`{"seq":12,"type":"response","request_seq":@ID@,"success":true,"command":"variables","body":{"variables":[{"name":"[0]","value":"1.5"},{"name":"[1]","value":"2"}]}}`, hc))
	dap_poll(&app)
	testing.expect_value(t, app.hover_state, Hover_State.Shown)
	testing.expect_value(t, app.hover_text, "d = float[2]\n  [0] = 1.5\n  [1] = 2")

	// continued event clears the stop.
	dap_send_frame(adp, `{"seq":7,"type":"event","event":"continued","body":{"threadId":7}}`)
	dap_poll(&app)
	testing.expect_value(t, d.state, Dap_State.Running)
	testing.expect_value(t, d.stop_line, -1)

	// terminated ends the session.
	dap_send_frame(adp, `{"seq":8,"type":"event","event":"terminated"}`)
	dap_poll(&app)
	testing.expect_value(t, d.state, Dap_State.Off)
}

// End-to-end against the real adapter, when one is installed: a program
// that trips a bounds check must stop the debugger like a breakpoint.
// Silently passes when lldb-dap (or its Python) is unavailable.
@test
test_dap_real_adapter_trap :: proc(t: ^testing.T) {
	// Probe with the same environment medit hands the adapter, so a PATH
	// without LLVM/Python (the common launch situation) still counts.
	adapter := dap_adapter_exe()
	probe, _, _, perr := os.process_exec(
		{command = []string{adapter, "--version"}, env = dap_child_env(adapter)},
		context.temp_allocator,
	)
	if perr != nil || !probe.exited || probe.exit_code != 0 {
		return // no usable adapter here
	}

	tmp, terr := os.make_directory_temp("", "medit_dap_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	src, _ := strings.concatenate({tmp, "/crash.odin"}, context.temp_allocator)
	werr := os.write_entire_file(src,
		"package main\nmain :: proc() {\n\tx := []int{1, 2, 3}\n\ti := 9\n\t_ = x[i]\n}\n")
	testing.expect_value(t, werr, nil)
	exe, _ := strings.concatenate({tmp, "/crash.exe"}, context.temp_allocator)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	when ODIN_OS == .Windows {
		odin_name :: "odin.exe"
	} else {
		odin_name :: "odin"
	}
	odin_exe, _ := strings.concatenate({cwd, "/", odin_name}, context.temp_allocator)
	bstate, bout, berr_out, berr := os.process_exec(
		{command = []string{odin_exe, "build", src, "-file", "-debug", fmt.tprintf("-out:%s", exe)}},
		context.temp_allocator,
	)
	if berr != nil || !bstate.exited || bstate.exit_code != 0 {
		testing.expectf(t, false, "build failed: %s %s", string(bout), string(berr_out))
		return
	}

	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	append(&app.cursors, cursor_at(Pos{0, 0}))
	app.dap.stop_line = -1
	defer app_destroy(&app)

	app.dap_launch(exe, tmp)
	testing.expect(t, app.dap.state != Dap_State.Off, "adapter failed to start")

	for _ in 0 ..< 1200 { // up to ~60s; first-launch symbol loading is slow
		dap_poll(&app)
		if app.dap.state == .Stopped || app.dap.state == .Off {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect_value(t, app.dap.state, Dap_State.Stopped)

	app.dap_stop()
	for _ in 0 ..< 100 {
		dap_poll(&app)
		if app.dap.state == .Off {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect_value(t, app.dap.state, Dap_State.Off)
}
