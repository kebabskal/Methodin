package medit

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
buffer_from :: proc(s: string) -> Buffer {
	b := buffer_make()
	if len(s) > 0 {
		b.commit([]Edit{{range = {}, text = s}}, nil)
	}
	b.saved_depth = len(b.undo_stack) // treat as freshly saved
	return b
}

@(private = "file")
expect_text :: proc(t: ^testing.T, b: ^Buffer, want: string, loc := #caller_location) {
	got := b.text(context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}

@test
test_insert_and_text :: proc(t: ^testing.T) {
	b := buffer_from("hello\nworld")
	defer buffer_destroy(&b)
	testing.expect_value(t, b.line_count(), 2)
	expect_text(t, &b, "hello\nworld")
}

@test
test_single_line_replace :: proc(t: ^testing.T) {
	b := buffer_from("hello world")
	defer buffer_destroy(&b)
	// "world" -> "methodin"
	b.commit([]Edit{{range = {{0, 6}, {0, 11}}, text = "methodin"}}, nil)
	expect_text(t, &b, "hello methodin")
}

@test
test_multiline_insert_and_delete :: proc(t: ^testing.T) {
	b := buffer_from("ab")
	defer buffer_destroy(&b)
	b.commit([]Edit{{range = {{0, 1}, {0, 1}}, text = "1\n2\n3"}}, nil)
	expect_text(t, &b, "a1\n2\n3b")
	// Delete the span back out.
	b.commit([]Edit{{range = {{0, 1}, {2, 1}}, text = ""}}, nil)
	expect_text(t, &b, "ab")
}

@test
test_range_text :: proc(t: ^testing.T) {
	b := buffer_from("one\ntwo\nthree")
	defer buffer_destroy(&b)
	got := b.range_text(Range{{0, 1}, {2, 2}}, context.temp_allocator)
	testing.expect_value(t, got, "ne\ntwo\nth")
}

@test
test_batch_multicursor_insert :: proc(t: ^testing.T) {
	b := buffer_from("aa\nbb\ncc")
	defer buffer_destroy(&b)
	// Three cursors typing "X" at the start of each line.
	edits := []Edit{
		{range = {{0, 0}, {0, 0}}, text = "X"},
		{range = {{1, 0}, {1, 0}}, text = "X"},
		{range = {{2, 0}, {2, 0}}, text = "X"},
	}
	ranges := b.commit(edits, nil)
	expect_text(t, &b, "Xaa\nXbb\nXcc")
	testing.expect_value(t, len(ranges), 3)
	testing.expect_value(t, ranges[1].end, Pos{1, 1})
}

@test
test_batch_same_line :: proc(t: ^testing.T) {
	b := buffer_from("abcdef")
	defer buffer_destroy(&b)
	// Two cursors on one line: insert after 'b' and after 'd'.
	edits := []Edit{
		{range = {{0, 2}, {0, 2}}, text = "-"},
		{range = {{0, 4}, {0, 4}}, text = "-"},
	}
	ranges := b.commit(edits, nil)
	expect_text(t, &b, "ab-cd-ef")
	testing.expect_value(t, ranges[1].end, Pos{0, 6})
}

@test
test_batch_multiline_inserts_shift_lines :: proc(t: ^testing.T) {
	b := buffer_from("aa\nbb")
	defer buffer_destroy(&b)
	// Both cursors insert a newline: line indices of the second edit must
	// be transformed after the first splits line 0.
	edits := []Edit{
		{range = {{0, 1}, {0, 1}}, text = "\n"},
		{range = {{1, 1}, {1, 1}}, text = "\n"},
	}
	b.commit(edits, nil)
	expect_text(t, &b, "a\na\nb\nb")
}

@test
test_undo_redo :: proc(t: ^testing.T) {
	b := buffer_from("hello")
	defer buffer_destroy(&b)
	b.commit([]Edit{{range = {{0, 5}, {0, 5}}, text = " world"}}, nil)
	expect_text(t, &b, "hello world")

	restored, ok := b.undo(nil)
	testing.expect(t, ok)
	delete(restored)
	expect_text(t, &b, "hello")

	restored2, ok2 := b.redo(nil)
	testing.expect(t, ok2)
	delete(restored2)
	expect_text(t, &b, "hello world")
}

@test
test_undo_multicursor_batch :: proc(t: ^testing.T) {
	b := buffer_from("aa\nbb\ncc")
	defer buffer_destroy(&b)
	edits := []Edit{
		{range = {{0, 0}, {0, 2}}, text = "line one"},
		{range = {{1, 0}, {1, 2}}, text = "line\ntwo"},
		{range = {{2, 0}, {2, 2}}, text = ""},
	}
	b.commit(edits, nil)
	expect_text(t, &b, "line one\nline\ntwo\n")

	restored, ok := b.undo(nil)
	testing.expect(t, ok)
	delete(restored)
	expect_text(t, &b, "aa\nbb\ncc")
}

@test
test_undo_restores_cursors :: proc(t: ^testing.T) {
	b := buffer_from("abc")
	defer buffer_destroy(&b)
	before := []Cursor{cursor_at(Pos{0, 3})}
	b.commit([]Edit{{range = {{0, 3}, {0, 3}}, text = "def"}}, before)
	restored, ok := b.undo(nil)
	testing.expect(t, ok)
	defer delete(restored)
	testing.expect_value(t, len(restored), 1)
	testing.expect_value(t, restored[0].head, Pos{0, 3})
}

@test
test_word_motion :: proc(t: ^testing.T) {
	b := buffer_from("foo_bar baz(qux)")
	defer buffer_destroy(&b)
	p := b.word_right(Pos{0, 0})
	testing.expect_value(t, p, Pos{0, 3}) // end of foo (subword)
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 7}) // end of _bar
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 11}) // end of baz
	p = b.word_left(Pos{0, 11})
	testing.expect_value(t, p, Pos{0, 8}) // start of baz
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 4}) // start of bar (after underscore)
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 0})

	// Double-click still selects the whole identifier.
	w := b.word_range_at(Pos{0, 1})
	testing.expect_value(t, w, Range{{0, 0}, {0, 7}})
}

@test
test_word_motion_full :: proc(t: ^testing.T) {
	// The whole-word variant (smart_word = false) hops entire identifiers.
	b := buffer_from("foo_bar baz(qux)")
	defer buffer_destroy(&b)
	p := b.full_word_right(Pos{0, 0})
	testing.expect_value(t, p, Pos{0, 7}) // end of foo_bar
	p = b.full_word_right(p)
	testing.expect_value(t, p, Pos{0, 11}) // end of baz
	p = b.full_word_left(Pos{0, 11})
	testing.expect_value(t, p, Pos{0, 8}) // start of baz
	p = b.full_word_left(p)
	testing.expect_value(t, p, Pos{0, 0})
}

@test
test_word_movement_camel :: proc(t: ^testing.T) {
	b := buffer_from("fooBarHTTPBaz then")
	defer buffer_destroy(&b)
	p := b.word_right(Pos{0, 0})
	testing.expect_value(t, p, Pos{0, 3}) // foo|
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 6}) // Bar|
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 10}) // HTTP| (stops before Baz)
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 13}) // Baz|
	p = b.word_right(p)
	testing.expect_value(t, p, Pos{0, 18}) // then|

	p = b.word_left(Pos{0, 18})
	testing.expect_value(t, p, Pos{0, 14}) // |then
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 10}) // |Baz
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 6}) // |HTTP
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 3}) // |Bar
	p = b.word_left(p)
	testing.expect_value(t, p, Pos{0, 0}) // |foo
}

@test
test_rune_boundaries :: proc(t: ^testing.T) {
	b := buffer_from("aåb") // å is 2 bytes
	defer buffer_destroy(&b)
	p := b.next_pos(Pos{0, 1})
	testing.expect_value(t, p, Pos{0, 3})
	p = b.prev_pos(Pos{0, 3})
	testing.expect_value(t, p, Pos{0, 1})
	// clamp_pos must not land inside the å sequence.
	testing.expect_value(t, b.clamp_pos(Pos{0, 2}), Pos{0, 1})
}

@test
test_cursors_normalize_merges_overlap :: proc(t: ^testing.T) {
	cursors: [dynamic]Cursor
	defer delete(cursors)
	append(&cursors, Cursor{head = {0, 5}, anchor = {0, 2}, goal_col = -1})
	append(&cursors, Cursor{head = {0, 4}, anchor = {0, 8}, goal_col = -1})
	append(&cursors, Cursor{head = {2, 0}, anchor = {2, 0}, goal_col = -1})
	cursors_normalize(&cursors)
	testing.expect_value(t, len(cursors), 2)
	r := cursor_range(cursors[0])
	testing.expect_value(t, r, Range{{0, 2}, {0, 8}})
}

@test
test_load_save_roundtrip :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	testing.expect(t, terr == nil)
	path, _ := filepath.join({tmp, "medit_test_roundtrip.txt"}, context.temp_allocator)
	content := "line1\nline2\n\nline4\n"
	b := buffer_from(content)
	delete(b.path)
	b.path = strings.clone(path)
	testing.expect(t, buffer_save(&b))
	buffer_destroy(&b)

	b2, ok := buffer_load(path)
	testing.expect(t, ok)
	defer buffer_destroy(&b2)
	expect_text(t, &b2, content)
	testing.expect_value(t, b2.line_count(), 5) // trailing newline -> empty last line
}
