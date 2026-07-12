package medit

import "core:testing"

@(private = "file")
expect_match :: proc(t: ^testing.T, pattern, path: string, want: bool, loc := #caller_location) -> int {
	ms := make([dynamic]int, context.temp_allocator)
	score, ok := path_match(pattern, path, &ms)
	testing.expectf(t, ok == want, "path_match(%q, %q) = %v, want %v", pattern, path, ok, want, loc = loc)
	// Match positions must be ascending (the row renderer walks them once).
	for i in 1 ..< len(ms) {
		testing.expect(t, ms[i-1] < ms[i], "match positions not ascending", loc = loc)
	}
	return score
}

@test
test_palette_fuzzy_basics :: proc(t: ^testing.T) {
	expect_match(t, "", `editor\app.odin`, true)
	expect_match(t, "app", `editor\app.odin`, true)
	expect_match(t, "APP", `editor\app.odin`, true) // case-insensitive
	expect_match(t, "xyz", `editor\app.odin`, false)
	expect_match(t, "edapp", `editor\app.odin`, true) // subsequence across components

	// Filename hits should outrank directory hits.
	in_name := expect_match(t, "app", `editor\app.odin`, true)
	in_dir := expect_match(t, "app", `app\readme.md`, true)
	testing.expect(t, in_name > in_dir, "basename match should score higher")
}

@test
test_palette_dir_segments :: proc(t: ^testing.T) {
	// A trailing slash narrows to files under a matching directory.
	expect_match(t, "editor/", `editor\app.odin`, true)
	expect_match(t, "editor/", `editor\sub\deep.odin`, true)
	expect_match(t, "editor/", `core\os\dir.odin`, false)
	expect_match(t, "editor/", `editor.odin`, false) // basename is not a dir

	// Segments anchor to components, in order; '\' works like '/'.
	expect_match(t, "edi/buf", `editor\buffer.odin`, true)
	expect_match(t, `edi\buf`, `editor\buffer.odin`, true)
	expect_match(t, "core/od/tok", `core\odin\tokenizer\tokenizer.odin`, true)
	expect_match(t, "od/core/tok", `core\odin\tokenizer\tokenizer.odin`, false) // wrong order
	expect_match(t, "editor/zzz", `editor\app.odin`, false)

	// The file segment may match in subdirectories of the matched dir.
	expect_match(t, "editor/deep", `editor\sub\deep.odin`, true)

	// The dir segment must not consume the basename.
	expect_match(t, "buffer/", `editor\buffer.odin`, false)
}

@test
test_palette_input_selection :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	// A prefill past the mode prefix opens selected, ready to be typed over.
	app.palette_open_with(">abc")
	p := &app.palette
	testing.expect_value(t, p.caret, 4)
	testing.expect_value(t, p.sel_anchor, 1)

	app.palette_insert("x") // typing replaces the selection
	testing.expect_value(t, string(p.query[:]), ">x")

	app.palette_select_all()
	app.palette_backspace() // selection delete, not one rune
	testing.expect_value(t, string(p.query[:]), "")

	// shift+arrows extend; a plain arrow collapses onto the edge.
	app.palette_insert(">word")
	app.palette_caret_move(-1, extend = true)
	app.palette_caret_move(-1, extend = true)
	lo, hi := app.palette_sel()
	testing.expect_value(t, hi-lo, 2)
	app.palette_caret_move(-1)
	lo, hi = app.palette_sel()
	testing.expect_value(t, lo, hi)
	testing.expect_value(t, p.caret, 3)

	// ctrl+arrow hops a word, ctrl+shift selects it.
	app.palette_caret_move(2)
	app.palette_caret_move(-1, extend = true, word = true)
	lo, hi = app.palette_sel()
	testing.expect_value(t, string(p.query[lo:hi]), "word")
}
