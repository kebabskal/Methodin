package medit

import "core:testing"

@(private = "file")
imp_app :: proc(content: string, caret: Pos) -> App {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	app.buf.commit([]Edit{{range = {}, text = content}}, nil)
	app.hl.lang = .Odin
	append(&app.cursors, cursor_at(caret))
	return app
}

@test
test_import_string_detection :: proc(t: ^testing.T) {
	app := imp_app("import \"\"", Pos{0, 8})
	defer app_destroy(&app)
	content, col, ok := app.import_string_at(Pos{0, 8})
	testing.expect_value(t, ok, true)
	testing.expect_value(t, content, "")
	testing.expect_value(t, col, 8)

	// Alias form.
	app2 := imp_app("import rl \"vendor:\"", Pos{0, 18})
	defer app_destroy(&app2)
	content2, _, ok2 := app2.import_string_at(Pos{0, 18})
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, content2, "vendor:")

	// Not an import line.
	app3 := imp_app("x := \"core:\"", Pos{0, 11})
	defer app_destroy(&app3)
	_, _, ok3 := app3.import_string_at(Pos{0, 11})
	testing.expect_value(t, ok3, false)
}

@test
test_parent_dir_walk_terminates :: proc(t: ^testing.T) {
	// os.split_path returns "/" and drive roots ("C:\") unchanged; the root
	// walk must notice the lack of progress or it spins forever (froze the
	// editor on import completion outside an Odin root).
	when ODIN_OS == .Windows {
		dir := `C:\Users\nobody\project`
	} else {
		dir := "/home/nobody/project"
	}
	steps := 0
	for dir != "" && steps < 64 {
		steps += 1
		parent, ok := parent_dir(dir)
		if !ok {
			break
		}
		dir = parent
	}
	testing.expect(t, steps < 64, "parent_dir walk did not terminate")
}

// Runs against the repo itself (cwd is an Odin root with base/core/vendor).
@test
test_import_completion_lists_and_accepts :: proc(t: ^testing.T) {
	app := imp_app("import \"\"", Pos{0, 8})
	defer app_destroy(&app)

	app.completion_trigger_import()
	testing.expect_value(t, app.completion.open, true)
	testing.expect_value(t, app.completion.import_mode, true)
	has :: proc(app: ^App, label: string) -> int {
		for vi, i in app.completion.visible {
			if app.completion.items[vi].label == label {
				return i
			}
		}
		return -1
	}
	testing.expect(t, has(&app, "core:") >= 0, "expected core: in collections")
	testing.expect(t, has(&app, "vendor:") >= 0, "expected vendor: in collections")

	// Accept "core:" → descends into the collection listing.
	app.completion.sel = has(&app, "core:")
	app.completion_accept()
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "import \"core:\"")
	testing.expect_value(t, app.completion.open, true)
	fmt_i := has(&app, "fmt")
	testing.expect(t, fmt_i >= 0, "expected fmt package inside core:")

	// Accept "fmt" → full import path, popup closed.
	app.completion.sel = fmt_i
	app.completion_accept()
	got = app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "import \"core:fmt\"")
	testing.expect_value(t, app.completion.open, false)
}
