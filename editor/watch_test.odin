package medit

import "core:os"
import "core:path/filepath"
import "core:testing"

// A minimal App around a buffer loaded from path (docs gets the active
// slot so files_tick has something to walk).
@(private = "file")
test_app_file :: proc(t: ^testing.T, path: string) -> App {
	app: App
	app.theme = theme_default()
	ok: bool
	app.buf, ok = buffer_load(path)
	testing.expect(t, ok)
	append(&app.cursors, cursor_at(Pos{0, 0}))
	append(&app.docs, Doc{})
	app.pending_close = -1
	app.pending_overwrite = -1
	return app
}

@test
test_external_change :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_watch_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	path, _ := filepath.join({tmp, "a.txt"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("one\ntwo")), nil)

	app := test_app_file(t, path)
	defer app_destroy(&app)
	testing.expect(t, app.buf.disk_mtime != 0)

	// A clean buffer picks up the external write on the next tick...
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("one\nTWO\nthree")), nil)
	app.buf.disk_mtime = 1 // pretend the load was long ago (mtime granularity)
	app.now_ms = 10_000
	app.files_tick()
	testing.expect_value(t, app.buf.text(context.temp_allocator), "one\nTWO\nthree")
	testing.expect_value(t, app.buf.is_dirty(), false)

	// ...and the reload is one undo step away.
	restored, uok := app.buf.undo(app.cursors[:])
	testing.expect(t, uok)
	delete(restored)
	testing.expect_value(t, app.buf.text(context.temp_allocator), "one\ntwo")
	testing.expect_value(t, app.buf.is_dirty(), true)
}

@test
test_external_change_conflict :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_watch_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	path, _ := filepath.join({tmp, "a.txt"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("one")), nil)

	app := test_app_file(t, path)
	defer app_destroy(&app)

	// Local edit, then an external write: the tick keeps the user's text
	// and arms the conflict instead of reloading.
	app.buf.commit([]Edit{{range = {}, text = "local "}}, app.cursors[:])
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("external")), nil)
	app.buf.disk_mtime = 1
	app.now_ms = 10_000
	app.files_tick()
	testing.expect_value(t, app.buf.text(context.temp_allocator), "local one")
	testing.expect_value(t, app.buf.conflict, true)

	// First save is refused; the second one is the confirmation.
	testing.expect_value(t, app.save_conflicted(), true)
	testing.expect_value(t, app.pending_overwrite, app.active)
	testing.expect_value(t, app.save_conflicted(), false)

	// Reloading instead takes the disk version and clears the conflict.
	app.buf.conflict = true
	app.doc_reload(app.active)
	testing.expect_value(t, app.buf.text(context.temp_allocator), "external")
	testing.expect_value(t, app.buf.conflict, false)
	testing.expect_value(t, app.buf.is_dirty(), false)
}
