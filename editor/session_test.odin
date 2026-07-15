package medit

import "core:os"
import "core:path/filepath"
import "core:testing"

@test
test_session_roundtrip :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_session_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	fa, _ := filepath.join({tmp, "a.odin"}, context.temp_allocator)
	fb, _ := filepath.join({tmp, "b.txt"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fa, transmute([]u8)string("one\ntwo\nthree")), nil)
	testing.expect_value(t, os.write_entire_file(fb, transmute([]u8)string("x")), nil)

	// Two docs: fa active (stale slot: live fields win), fb in docs[1].
	app: App
	app.theme = theme_default()
	ok: bool
	app.buf, ok = buffer_load(fa)
	testing.expect(t, ok)
	append(&app.cursors, cursor_at(Pos{2, 1}))
	append(&app.docs, Doc{})
	bb, bok := buffer_load(fb)
	testing.expect(t, bok)
	d: Doc
	d.buf = bb
	append(&d.cursors, cursor_at(Pos{0, 1}))
	append(&app.docs, d)
	app.pending_close = -1
	app.pending_overwrite = -1
	defer app_destroy(&app)

	session, _ := filepath.join({tmp, "session"}, context.temp_allocator)
	session_write(&app, session)

	dir, entries, rok := session_read(session)
	testing.expect(t, rok)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	testing.expect_value(t, dir, cwd)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].path, fa)
	testing.expect_value(t, entries[0].active, true)
	testing.expect_value(t, entries[0].line, 2)
	testing.expect_value(t, entries[0].col, 1)
	testing.expect_value(t, entries[1].path, fb)
	testing.expect_value(t, entries[1].active, false)
}

@test
test_session_read_tolerates_junk :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_session_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	session, _ := filepath.join({tmp, "session"}, context.temp_allocator)
	junk := "/some/dir\n\nnot a doc line\n*3:0 real.odin\n9 missing-colon\n"
	testing.expect_value(t, os.write_entire_file(session, transmute([]u8)junk), nil)

	dir, entries, ok := session_read(session)
	testing.expect(t, ok)
	testing.expect_value(t, dir, "/some/dir")
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].path, "real.odin")
	testing.expect_value(t, entries[0].active, true)
	testing.expect_value(t, entries[0].line, 3)
}
