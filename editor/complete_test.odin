package medit

import "core:strings"
import "core:testing"

// Accepting a plain (non-snippet) completion must not read the item's
// strings after completion_close frees them — regression for word
// completions inserting garbage (use-after-free, caught under asan).
@test
test_completion_accept_plain_word :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	app.buf.commit([]Edit{{range = {}, text = "th"}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 2}))
	defer app_destroy(&app)

	c := &app.completion
	append(&c.items, Comp_Item{
		label  = strings.clone("thing"),
		insert = strings.clone("thing"),
		detail = strings.clone(""),
	})
	append(&c.visible, 0)
	c.sel = 0
	c.open = true
	c.anchor = Pos{0, 0}

	app.completion_accept()
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "thing")
	testing.expect_value(t, app.cursors[0].head, Pos{0, 5})
}

// additionalTextEdits (ols auto-import) land in the buffer too, and the
// caret shifts down past the inserted import line.
@test
test_completion_accept_auto_import :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	app.buf.commit([]Edit{{range = {}, text = "package main\n\nmain :: proc() {\n\tfm\n}"}}, nil)
	append(&app.cursors, cursor_at(Pos{3, 3}))
	defer app_destroy(&app)

	extra := make([dynamic]Extra_Edit)
	append(&extra, Extra_Edit{
		line = 1, char = 0, eline = 1, echar = 0,
		text = strings.clone("import \"core:fmt\"\n"),
	})
	c := &app.completion
	append(&c.items, Comp_Item{
		label  = strings.clone("fmt"),
		insert = strings.clone("fmt"),
		detail = strings.clone(""),
		extra  = extra[:],
	})
	append(&c.visible, 0)
	c.sel = 0
	c.open = true
	c.anchor = Pos{3, 1}

	app.completion_accept()
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "package main\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt\n}")
	// Caret sits after "fmt", one line further down than before the import.
	testing.expect_value(t, app.cursors[0].head, Pos{4, 4})
}

// Snippet completions resolve placeholders and leave the first one selected.
@test
test_completion_accept_snippet :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	app.buf.commit([]Edit{{range = {}, text = "th"}}, nil)
	append(&app.cursors, cursor_at(Pos{0, 2}))
	defer app_destroy(&app)

	c := &app.completion
	append(&c.items, Comp_Item{
		label  = strings.clone("thing"),
		insert = strings.clone("thing(${1:x})"),
		detail = strings.clone(""),
	})
	append(&c.visible, 0)
	c.sel = 0
	c.open = true
	c.anchor = Pos{0, 0}

	app.completion_accept()
	got := app.buf.text(context.temp_allocator)
	testing.expect_value(t, got, "thing(x)")
	r := cursor_range(app.cursors[0])
	testing.expect_value(t, r.start, Pos{0, 6})
	testing.expect_value(t, r.end, Pos{0, 7})
}
