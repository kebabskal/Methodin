package medit

import "core:os"
import "core:path/filepath"
import "core:testing"

@test
test_retarget_path :: proc(t: ^testing.T) {
	// Exact file rename.
	p, ok := retarget_path("src/a.odin", "src/a.odin", "src/b.odin")
	defer delete(p)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, p, "src/b.odin")

	// A path inside a renamed directory follows, either separator flavor.
	p2, ok2 := retarget_path(`src\deep\a.odin`, "src", "lib")
	defer delete(p2)
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, p2, `lib\deep\a.odin`)

	// A sibling that merely shares the name prefix does not.
	_, ok3 := retarget_path("src2/a.odin", "src", "lib")
	testing.expect_value(t, ok3, false)
	_, ok4 := retarget_path("other/a.odin", "src", "lib")
	testing.expect_value(t, ok4, false)
}

@test
test_fs_create_rename_delete :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_fsops_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	append(&app.cursors, cursor_at(Pos{0, 0}))
	append(&app.docs, Doc{}) // the active doc's (stale) slot, like the real app
	defer app_destroy(&app)

	// Create a folder, then a file inside it; the file opens in the tab.
	app.fs_create(tmp, "pkg", is_dir = true)
	sub, _ := filepath.join({tmp, "pkg"}, context.temp_allocator)
	testing.expect(t, os.is_directory(sub), "folder was not created")

	app.fs_create(sub, "a.odin", is_dir = false)
	fa, _ := filepath.join({sub, "a.odin"}, context.temp_allocator)
	testing.expect(t, os.exists(fa), "file was not created")
	testing.expect_value(t, app.buf.path, fa)

	// Creating over an existing path is refused.
	app.fs_create(sub, "a.odin", is_dir = false)
	testing.expect(t, os.exists(fa), "existing file was clobbered")

	// Renaming the folder drags the open tab's path along.
	app.fs_rename(sub, "lib")
	lib, _ := filepath.join({tmp, "lib"}, context.temp_allocator)
	fb, _ := filepath.join({lib, "a.odin"}, context.temp_allocator)
	testing.expect(t, os.is_directory(lib), "folder was not renamed")
	testing.expect(t, !os.exists(sub), "old folder still exists")
	testing.expect_value(t, app.buf.path, fb)

	// Renaming the file itself.
	app.fs_rename(fb, "b.odin")
	fc, _ := filepath.join({lib, "b.odin"}, context.temp_allocator)
	testing.expect(t, os.exists(fc), "file was not renamed")
	testing.expect_value(t, app.buf.path, fc)

	// Delete the file, then the folder tree.
	app.fs_delete(fc, is_dir = false)
	testing.expect(t, !os.exists(fc), "file was not deleted")
	app.fs_delete(lib, is_dir = true)
	testing.expect(t, !os.exists(lib), "folder was not deleted")
}
