package medit

import "core:testing"

// A minimal App for exercising editing actions without a window.
@(private = "file")
test_app :: proc(content: string) -> App {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	if len(content) > 0 {
		app.buf.commit([]Edit{{range = {}, text = content}}, nil)
	}
	append(&app.cursors, cursor_at(Pos{0, 0}))
	return app
}

@(private = "file")
expect_app_text :: proc(t: ^testing.T, app: ^App, want: string, loc := #caller_location) {
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}

@test
test_move_lines :: proc(t: ^testing.T) {
	app := test_app("aa\nbb\ncc")
	defer app_destroy(&app)

	app.move_lines(down = true) // aa below bb
	expect_app_text(t, &app, "bb\naa\ncc")
	testing.expect_value(t, app.cursors[0].head.line, 1)

	app.move_lines(down = true)
	expect_app_text(t, &app, "bb\ncc\naa")

	app.move_lines(down = true) // at the bottom: no-op
	expect_app_text(t, &app, "bb\ncc\naa")

	app.move_lines(down = false)
	app.move_lines(down = false)
	expect_app_text(t, &app, "aa\nbb\ncc")
	testing.expect_value(t, app.cursors[0].head.line, 0)

	app.move_lines(down = false) // at the top: no-op
	expect_app_text(t, &app, "aa\nbb\ncc")

	// A multi-line selection moves as a block.
	app.cursors[0] = Cursor{head = Pos{1, 1}, anchor = Pos{0, 0}, goal_col = -1}
	app.move_lines(down = true)
	expect_app_text(t, &app, "cc\naa\nbb")
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start.line, 1)
	testing.expect_value(t, r.end.line, 2)
}

@test
test_toggle_comment :: proc(t: ^testing.T) {
	app := test_app("x := 1\n\n\ty := 2")
	defer app_destroy(&app)
	app.hl.lang = .Odin

	// Select everything; blank line stays untouched.
	app.cursors[0] = Cursor{head = app.buf.end_pos(), anchor = Pos{0, 0}, goal_col = -1}
	app.toggle_comment()
	expect_app_text(t, &app, "// x := 1\n\n\t// y := 2")
	app.toggle_comment()
	expect_app_text(t, &app, "x := 1\n\n\ty := 2")

	// Mixed commented state: comment the uncommented rest.
	app2 := test_app("// a\nb")
	defer app_destroy(&app2)
	app2.hl.lang = .Odin
	app2.cursors[0] = Cursor{head = app2.buf.end_pos(), anchor = Pos{0, 0}, goal_col = -1}
	app2.toggle_comment()
	expect_app_text(t, &app2, "// a\n// b")

	// Plain text has no comment syntax: no-op.
	app3 := test_app("hello")
	defer app_destroy(&app3)
	app3.toggle_comment()
	expect_app_text(t, &app3, "hello")
}

@test
test_duplicate :: proc(t: ^testing.T) {
	// No selection: duplicate the line below, cursor stays.
	app := test_app("abc\ndef")
	defer app_destroy(&app)
	app.cursors[0] = cursor_at(Pos{0, 1})
	app.duplicate()
	expect_app_text(t, &app, "abc\nabc\ndef")
	testing.expect_value(t, app.cursors[0].head, Pos{0, 1})

	// With a selection: insert a copy after it, selection preserved.
	app2 := test_app("abc")
	defer app_destroy(&app2)
	app2.cursors[0] = Cursor{head = Pos{0, 2}, anchor = Pos{0, 1}, goal_col = -1}
	app2.duplicate()
	expect_app_text(t, &app2, "abbc")
	r := cursor_range(app2.cursors[0])
	testing.expect_value(t, r.start, Pos{0, 1})
	testing.expect_value(t, r.end, Pos{0, 2})
}

@test
test_escape_and_selection_undo :: proc(t: ^testing.T) {
	app := test_app("foo foo foo")
	defer app_destroy(&app)

	// ctrl+d three times: word + two more matches.
	app.select_next_match()
	app.select_next_match()
	app.select_next_match()
	testing.expect_value(t, len(app.cursors), 3)

	// esc: one caret, no selection, at the last (primary) cursor.
	last_head := app.primary_cursor().head
	app.escape()
	testing.expect_value(t, len(app.cursors), 1)
	testing.expect(t, !cursor_has_selection(app.cursors[0]))
	testing.expect_value(t, app.cursors[0].head, last_head)

	// ctrl+u: back to three cursors, then progressively fewer.
	app.undo_selection()
	testing.expect_value(t, len(app.cursors), 3)
	app.undo_selection()
	testing.expect_value(t, len(app.cursors), 2)
	app.undo_selection()
	testing.expect_value(t, len(app.cursors), 1)
}

@test
test_jump_centers_offscreen_target :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	sb: [dynamic]u8
	defer delete(sb)
	for _ in 0 ..< 200 {
		append(&sb, "x\n")
	}
	app.buf.commit([]Edit{{range = {}, text = string(sb[:])}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	line_h: f32 = 20
	app.view_h = 400
	app.view_w = 800

	// A jump far below the view lands ~40% down, not at the bottom edge.
	app.cursors[0] = cursor_at(Pos{100, 0})
	app.ensure_cursor_visible(8, line_h, center = true)
	testing.expect_value(t, app.scroll_y, 100*line_h-400*0.4)

	// Already visible: centering does not move the view.
	app.cursors[0] = cursor_at(Pos{105, 0})
	before := app.scroll_y
	app.ensure_cursor_visible(8, line_h, center = true)
	testing.expect_value(t, app.scroll_y, before)

	// Plain keystroke following still scrolls minimally (bottom edge).
	app.cursors[0] = cursor_at(Pos{150, 0})
	app.ensure_cursor_visible(8, line_h)
	testing.expect_value(t, app.scroll_y, 150*line_h+line_h-400)
}
