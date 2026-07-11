package medit

import "core:testing"

@(private = "file")
ac_app :: proc(content: string) -> App {
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
ac_expect :: proc(t: ^testing.T, app: ^App, want: string, loc := #caller_location) {
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}

@test
test_autoclose_pair_and_type_over :: proc(t: ^testing.T) {
	app := ac_app("")
	defer app_destroy(&app)

	app.type_text("(")
	ac_expect(t, &app, "()")
	testing.expect_value(t, app.cursors[0].head, Pos{0, 1})

	// Typing the closer steps over the auto-inserted one.
	app.type_text(")")
	ac_expect(t, &app, "()")
	testing.expect_value(t, app.cursors[0].head, Pos{0, 2})

	// A closer with nothing to step over inserts normally.
	app.type_text(")")
	ac_expect(t, &app, "())")
}

@test
test_autoclose_wraps_selection :: proc(t: ^testing.T) {
	app := ac_app("abc")
	defer app_destroy(&app)

	app.cursors[0] = Cursor{head = Pos{0, 3}, anchor = Pos{0, 0}, goal_col = -1}
	app.type_text("[")
	ac_expect(t, &app, "[abc]")
	// The wrapped text stays selected inside the pair.
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start, Pos{0, 1})
	testing.expect_value(t, r.end, Pos{0, 4})
}

@test
test_autoclose_quotes :: proc(t: ^testing.T) {
	app := ac_app("")
	defer app_destroy(&app)

	app.type_text("\"")
	ac_expect(t, &app, "\"\"")
	testing.expect_value(t, app.cursors[0].head, Pos{0, 1})
	app.type_text("\"") // step over, not a second pair
	ac_expect(t, &app, "\"\"")

	// An apostrophe right after a word stays single.
	app2 := ac_app("don")
	defer app_destroy(&app2)
	app2.cursors[0] = cursor_at(Pos{0, 3})
	app2.type_text("'")
	ac_expect(t, &app2, "don'")

	// A quote right before a word stays single too.
	app3 := ac_app("word")
	defer app_destroy(&app3)
	app3.type_text("\"")
	ac_expect(t, &app3, "\"word")
}

@test
test_autoclose_backspace_deletes_pair :: proc(t: ^testing.T) {
	app := ac_app("")
	defer app_destroy(&app)

	app.type_text("{")
	ac_expect(t, &app, "{}")
	app.delete_backward()
	ac_expect(t, &app, "")

	// Not a pair: only the char before the caret goes.
	app.type_text("x")
	app.type_text("y")
	app.delete_backward()
	ac_expect(t, &app, "x")
}

@test
test_newline_indents_after_brace :: proc(t: ^testing.T) {
	// Enter between {} puts the closer on its own line, caret indented.
	app := ac_app("\tmain :: proc() {}")
	defer app_destroy(&app)
	app.cursors[0] = cursor_at(Pos{0, 17})
	app.insert_newline()
	ac_expect(t, &app, "\tmain :: proc() {\n\t\t\n\t}")
	testing.expect_value(t, app.cursors[0].head, Pos{1, 2})

	// Enter after a brace with no closer just indents one level deeper.
	app2 := ac_app("if x {")
	defer app_destroy(&app2)
	app2.cursors[0] = cursor_at(Pos{0, 6})
	app2.insert_newline()
	ac_expect(t, &app2, "if x {\n\t")
	testing.expect_value(t, app2.cursors[0].head, Pos{1, 1})

	// Plain enter still just copies the leading whitespace.
	app3 := ac_app("\tabc")
	defer app_destroy(&app3)
	app3.cursors[0] = cursor_at(Pos{0, 4})
	app3.insert_newline()
	ac_expect(t, &app3, "\tabc\n\t")
}
