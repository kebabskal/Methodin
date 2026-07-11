package medit

import "core:strings"
import "core:testing"

@(private = "file")
prob :: proc(path: string, line, char, eline, echar, sev: int, msg: string) -> Diagnostic {
	return Diagnostic{
		path = strings.clone(path),
		line = line, char = char, eline = eline, echar = echar,
		severity = sev,
		msg = strings.clone(msg),
	}
}

@test
test_problems_cursor_and_sort :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make("cur.odin")
	app.buf.commit([]Edit{{range = {}, text = "aaa bbb ccc\nddd\n"}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	append(&app.problems, prob("other.odin", 0, 0, 0, 3, 2, "warn elsewhere"))
	append(&app.problems, prob("cur.odin", 0, 4, 0, 7, 1, "bad bbb"))
	app.problems_sort()

	// Current document sorts first.
	testing.expect_value(t, app.problems[0].path, "cur.odin")

	errs, warns := app.problems_count()
	testing.expect_value(t, errs, 1)
	testing.expect_value(t, warns, 1)

	// Cursor outside the range: no match; inside: index of the problem.
	testing.expect_value(t, app.problem_at_cursor(), -1)
	app.cursors[0] = cursor_at(Pos{0, 5})
	testing.expect_value(t, app.problem_at_cursor(), 0)
	app.cursors[0] = cursor_at(Pos{0, 7}) // inclusive end
	testing.expect_value(t, app.problem_at_cursor(), 0)
	app.cursors[0] = cursor_at(Pos{1, 0})
	testing.expect_value(t, app.problem_at_cursor(), -1)
}

@test
test_problems_palette_mode :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make("cur.odin")
	app.buf.commit([]Edit{{range = {}, text = "aaa bbb ccc\nddd\n"}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	append(&app.problems, prob("cur.odin", 0, 4, 0, 7, 1, "bad bbb"))
	append(&app.problems, prob("cur.odin", 1, 0, 1, 3, 2, "odd ddd"))

	app.palette_open_with("?")
	p := &app.palette
	testing.expect_value(t, len(p.items), 2)
	testing.expect_value(t, p.items[0].label, "E: bad bbb")
	testing.expect_value(t, p.items[0].detail, "cur.odin:1")

	// Accepting the first problem jumps to (and selects) its range.
	p.sel = 0
	app.palette_accept()
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start, Pos{0, 4})
	testing.expect_value(t, r.end, Pos{0, 7})

	// "E" filters by severity prefix.
	app.palette_open_with("?E:")
	testing.expect_value(t, len(app.palette.items), 1)
	app.palette_cancel()
}
