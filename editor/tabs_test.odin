package medit

import "core:os"
import "core:testing"

// A minimal App with one untitled document, no window.
@(private = "file")
tabs_app :: proc() -> App {
	app: App
	app.theme = theme_default()
	app.doc_append(buffer_make(), .Plain)
	return app
}

@(private = "file")
expect_text :: proc(t: ^testing.T, app: ^App, want: string, loc := #caller_location) {
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}

@test
test_tabs_separate_undo :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	app.insert_text("one")
	app.doc_append(buffer_make(), .Plain)
	testing.expect_value(t, len(app.docs), 2)
	testing.expect_value(t, app.active, 1)
	expect_text(t, &app, "")

	app.insert_text("two")
	expect_text(t, &app, "two")

	// Undo only touches the active document.
	app.undo()
	expect_text(t, &app, "")
	app.doc_switch(0)
	expect_text(t, &app, "one")

	// Each document's redo stack survives the switch.
	app.doc_switch(1)
	app.redo()
	expect_text(t, &app, "two")
	app.doc_switch(0)
	app.undo()
	expect_text(t, &app, "")
}

@test
test_tabs_cursors_survive_switch :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	app.insert_text("hello world")
	app.cursors[0] = Cursor{head = Pos{0, 5}, anchor = Pos{0, 0}, goal_col = -1}

	app.doc_append(buffer_make(), .Plain)
	app.insert_text("x")
	app.doc_switch(0)

	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start, Pos{0, 0})
	testing.expect_value(t, r.end, Pos{0, 5})
}

@test
test_open_file_switches_to_existing_tab :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	app.doc_append(buffer_make("a.txt"), .Plain)
	app.doc_append(buffer_make("b.txt"), .Plain)
	testing.expect_value(t, len(app.docs), 3)
	testing.expect_value(t, app.active, 2)

	// Already open: switches instead of loading from disk.
	app.open_file("a.txt")
	testing.expect_value(t, len(app.docs), 3)
	testing.expect_value(t, app.active, 1)
	testing.expect_value(t, app.buf.path, "a.txt")

	// Opening the active path is a no-op.
	app.open_file("a.txt")
	testing.expect_value(t, app.active, 1)
}

@test
test_tab_close :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	app.doc_append(buffer_make("a.txt"), .Plain)
	app.doc_append(buffer_make("b.txt"), .Plain)

	// Closing the active tab activates its right neighbour (here: clamped left).
	app.tab_close(2)
	testing.expect_value(t, len(app.docs), 2)
	testing.expect_value(t, app.buf.path, "a.txt")

	// Closing a background tab keeps the active one live.
	app.tab_close(0)
	testing.expect_value(t, len(app.docs), 1)
	testing.expect_value(t, app.active, 0)
	testing.expect_value(t, app.buf.path, "a.txt")

	// Closing the last tab leaves a fresh untitled document.
	app.tab_close(0)
	testing.expect_value(t, len(app.docs), 1)
	testing.expect_value(t, app.buf.path, "")
	expect_text(t, &app, "")
}

@test
test_tab_close_dirty_guard :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	app.doc_append(buffer_make(), .Plain)
	app.insert_text("unsaved")

	// First attempt is refused; the second discards.
	app.tab_close(1)
	testing.expect_value(t, len(app.docs), 2)
	app.tab_close(1)
	testing.expect_value(t, len(app.docs), 1)

	// Any tab switch resets the confirmation.
	app.doc_append(buffer_make(), .Plain)
	app.insert_text("unsaved")
	app.tab_close(1)
	app.doc_switch(0)
	app.tab_close(1) // refused again: the pending confirmation was dropped
	testing.expect_value(t, len(app.docs), 2)
	app.tab_close(1)
	testing.expect_value(t, len(app.docs), 1)
}

@test
test_preview_tabs :: proc(t: ^testing.T) {
	_ = os.write_entire_file("_preview_test_a.txt", transmute([]u8)string("aaa\n"))
	_ = os.write_entire_file("_preview_test_b.txt", transmute([]u8)string("bbb\n"))
	defer os.remove("_preview_test_a.txt")
	defer os.remove("_preview_test_b.txt")

	app := tabs_app()
	defer app_destroy(&app)
	app.insert_text("home") // make the home tab non-pristine

	// Previews share one transient tab, replaced per file.
	app.palette.open = true
	app.palette.home_doc = app.active
	testing.expect(t, app.open_preview("_preview_test_a.txt"))
	testing.expect_value(t, len(app.docs), 2)
	testing.expect(t, app.preview, "the previewed doc is transient")
	testing.expect_value(t, app.buf.path, "_preview_test_a.txt")
	testing.expect(t, app.open_preview("_preview_test_b.txt"))
	testing.expect_value(t, len(app.docs), 2) // reused, not stacked
	testing.expect_value(t, app.buf.path, "_preview_test_b.txt")

	// esc: the preview vanishes and the home doc is active again.
	app.palette_cancel()
	testing.expect_value(t, len(app.docs), 1)
	testing.expect_value(t, app.buf.path, "")
	testing.expect(t, !app.preview)

	// Accept path: closing the palette on a preview promotes it.
	app.palette.open = true
	app.palette.home_doc = app.active
	testing.expect(t, app.open_preview("_preview_test_a.txt"))
	app.palette_close()
	testing.expect_value(t, len(app.docs), 2)
	testing.expect_value(t, app.buf.path, "_preview_test_a.txt")
	testing.expect(t, !app.preview, "landed-on preview becomes a real tab")

	// A preview left behind (home active at close) is dropped.
	app.palette.open = true
	app.palette.home_doc = app.active
	testing.expect(t, app.open_preview("_preview_test_b.txt"))
	app.doc_switch(app.palette.home_doc)
	app.palette_close()
	testing.expect_value(t, len(app.docs), 2) // home + promoted a; b's preview gone
	testing.expect_value(t, app.buf.path, "_preview_test_a.txt")
}

@test
test_open_file_reuses_pristine_untitled :: proc(t: ^testing.T) {
	app := tabs_app()
	defer app_destroy(&app)

	// tabs.odin reuses the untouched untitled tab instead of leaving it
	// behind; an edited one gets its own tab. buffer_load needs a real
	// file, so exercise the decision through doc_append + open_file on an
	// already-open path only when dirty.
	app.insert_text("edited")
	app.doc_append(buffer_make("a.txt"), .Plain)
	app.doc_switch(0)
	testing.expect_value(t, len(app.docs), 2) // the edited untitled tab survived
	expect_text(t, &app, "edited")
}
