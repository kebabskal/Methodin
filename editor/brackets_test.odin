package medit

import "core:testing"

// 0: package x
// 1:
// 2: foo :: proc() {
// 3: 	a := 1
// 4:
// 5: 	if a > 0 {
// 6: 		b()
// 7: 	}
// 8: }
// 9:
// 10: bar :: proc() {
// 11: }
@(private = "file")
SEM_SRC :: "package x\n\nfoo :: proc() {\n\ta := 1\n\n\tif a > 0 {\n\t\tb()\n\t}\n}\n\nbar :: proc() {\n}"

@(private = "file")
sem_app :: proc() -> App {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	app.buf.commit([]Edit{{range = {}, text = SEM_SRC}}, nil)
	app.hl.lang = .Odin
	append(&app.cursors, cursor_at(Pos{0, 0}))
	return app
}

@test
test_semantic_up_climbs_scopes :: proc(t: ^testing.T) {
	app := sem_app()
	defer app_destroy(&app)

	// From the call inside the if: up lands on the if header,
	// then the proc header, then the package line.
	app.cursors[0] = cursor_at(Pos{6, 2})
	app.semantic_move(-1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{5, 1})
	app.semantic_move(-1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{2, 0})
	app.semantic_move(-1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{0, 0})
}

@test
test_semantic_down_walks_scope_ends :: proc(t: ^testing.T) {
	app := sem_app()
	defer app_destroy(&app)

	// From inside the if: down exits the if, then the proc, then hops to
	// the next top-level definition.
	app.cursors[0] = cursor_at(Pos{6, 2})
	app.semantic_move(1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{7, 2})
	app.semantic_move(1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{8, 1})
	app.semantic_move(1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{10, 0})
}

@test
test_semantic_up_stops_at_paragraphs :: proc(t: ^testing.T) {
	app := sem_app()
	defer app_destroy(&app)

	// From bar: the previous block start is the if paragraph inside foo.
	app.cursors[0] = cursor_at(Pos{10, 0})
	app.semantic_move(-1, false)
	testing.expect_value(t, app.cursors[0].head, Pos{5, 1})

	// Shift extends a selection instead of collapsing.
	app.cursors[0] = cursor_at(Pos{10, 0})
	app.semantic_move(-1, true)
	testing.expect_value(t, app.cursors[0].anchor, Pos{10, 0})
	testing.expect_value(t, app.cursors[0].head, Pos{5, 1})
}
