package medit

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@test
test_settings_hide_globs :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	settings_parse(&app, "; user\n[files]\nhide = *.exe *.pdb\n")
	settings_parse(&app, "[files]\nhide = bin\n") // the project file adds
	testing.expect_value(t, len(app.sidebar.hide), 3)

	hide := app.sidebar.hide[:]
	testing.expect_value(t, settings_hidden("medit.exe", hide), true)
	testing.expect_value(t, settings_hidden("odin.pdb", hide), true)
	testing.expect_value(t, settings_hidden("bin", hide), true)
	testing.expect_value(t, settings_hidden("main.odin", hide), false)
	testing.expect_value(t, settings_hidden("exe", hide), false)
}

@test
test_sidebar_hides_matching_files :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_hide_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	fa, _ := filepath.join({tmp, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fa, []byte{}), nil)
	fb, _ := filepath.join({tmp, "a.exe"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fb, []byte{}), nil)

	sb: Sidebar
	sb.root = Tree_Node{
		name     = strings.clone("tmp"),
		path     = strings.clone(tmp),
		is_dir   = true,
		expanded = true,
	}
	append(&sb.hide, strings.clone("*.exe"))
	defer sidebar_destroy(&sb)

	sidebar_refresh(&sb)
	testing.expect_value(t, len(sb.root.children), 1)
	if len(sb.root.children) == 1 {
		testing.expect_value(t, sb.root.children[0].name, "a.odin")
	}
}
