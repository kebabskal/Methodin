package medit

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@test
test_sidebar_refresh_sees_new_files :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "medit_tree_*", context.allocator)
	testing.expect_value(t, terr, nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	sub, _ := filepath.join({tmp, "pkg"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(sub), nil)

	// Node paths are normally relative to the workspace, but node_load treats
	// them as plain paths — an absolute root keeps the test out of the cwd.
	sb: Sidebar
	sb.root = Tree_Node{
		name     = strings.clone("tmp"),
		path     = strings.clone(tmp),
		is_dir   = true,
		expanded = true,
	}
	defer sidebar_destroy(&sb)

	sidebar_refresh(&sb) // expanded + unloaded → first load
	testing.expect_value(t, len(sb.root.children), 1)
	sb.root.children[0].expanded = true

	// Files appear behind the tree's back (what a save-as does).
	fa, _ := filepath.join({tmp, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fa, []byte{}), nil)
	fb, _ := filepath.join({sub, "b.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fb, []byte{}), nil)

	sidebar_refresh(&sb)
	testing.expect_value(t, len(sb.root.children), 2)
	testing.expect_value(t, sb.root.children[0].name, "pkg") // dirs sort first
	testing.expect_value(t, sb.root.children[0].expanded, true)
	testing.expect_value(t, len(sb.root.children[0].children), 1)
	testing.expect_value(t, sb.root.children[0].children[0].name, "b.odin")
	testing.expect_value(t, sb.root.children[1].name, "a.odin")
}
