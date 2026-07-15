// medit — buffer core.
//
// A Buffer is an array of lines (each a [dynamic]u8, no trailing '\n').
// Every mutation goes through commit() as a batch of (range, text)
// replacements — one per cursor — which is the single code path that
// multi-cursor editing, undo/redo, and (later) LSP didChange all share.
package medit

import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Position in a buffer. col is a byte offset into the line (always on a
// rune boundary). Both are 0-based.
Pos :: struct {
	line, col: int,
}

Range :: struct {
	start, end: Pos, // normalized: start <= end
}

// One replacement: delete range, insert text. text may contain '\n'.
Edit :: struct {
	range: Range,
	text:  string,
}

// A cursor is a head (where the caret is) and an anchor (other end of the
// selection). head == anchor means no selection.
Cursor :: struct {
	head, anchor: Pos,
	goal_col:     int, // visual column to aim for on vertical movement, -1 = unset
}

Undo_Group :: struct {
	// Edits that transform the post-group document back into the pre-group
	// document. Text is owned by the group.
	inverse:        []Edit,
	cursors_before: []Cursor,
}

Line_Ending :: enum {
	LF,
	CRLF,
}

Buffer :: struct {
	path:        string,
	lines:       [dynamic][dynamic]u8,
	version:     int, // bumped on every commit; consumed by highlighting & LSP
	line_ending: Line_Ending,

	undo_stack: [dynamic]Undo_Group,
	redo_stack: [dynamic]Undo_Group,
	// History is linear, so the undo depth identifies the document state;
	// remembering the depth at save time makes dirty-tracking exact even
	// through undo/redo. -1 = the saved state is no longer reachable.
	saved_depth: int,

	// External change detection (watch.odin): the file's mtime as of the
	// last load/save (0: never touched disk), and whether the file changed
	// under a dirty buffer — saving then needs confirmation.
	disk_mtime:  i64,
	conflict:    bool,

	// Longest line's visual width, cached for the horizontal scroll clamp
	// (see max_visual_cols). vis_cols_tab_w == 0 marks it never computed.
	vis_cols:         int,
	vis_cols_version: int,
	vis_cols_tab_w:   int,
}

pos_less :: proc(a, b: Pos) -> bool {
	if a.line != b.line {
		return a.line < b.line
	}
	return a.col < b.col
}

pos_eq :: proc(a, b: Pos) -> bool {
	return a.line == b.line && a.col == b.col
}

// Range spanning a and b regardless of their order.
range_make :: proc(a, b: Pos) -> Range {
	if pos_less(b, a) {
		return Range{b, a}
	}
	return Range{a, b}
}

range_empty :: proc(r: Range) -> bool {
	return pos_eq(r.start, r.end)
}

cursor_range :: proc(c: Cursor) -> Range {
	return range_make(c.head, c.anchor)
}

cursor_has_selection :: proc(c: Cursor) -> bool {
	return !pos_eq(c.head, c.anchor)
}

cursor_at :: proc(p: Pos) -> Cursor {
	return Cursor{head = p, anchor = p, goal_col = -1}
}

impl Buffer {
	is_dirty :: proc() -> bool {
		return len(undo_stack) != saved_depth
	}

	line_count :: proc() -> int {
		return len(lines)
	}

	// The line's bytes viewed as a string. Borrowed — invalidated by edits.
	line_str :: proc(i: int) -> string {
		return string(lines[i][:])
	}

	line_len :: proc(i: int) -> int {
		return len(lines[i])
	}

	end_pos :: proc() -> Pos {
		last := len(lines) - 1
		return Pos{last, len(lines[last])}
	}

	clamp_pos :: proc(p: Pos) -> Pos {
		p := p
		p.line = clamp(p.line, 0, len(lines)-1)
		p.col = clamp(p.col, 0, len(lines[p.line]))
		// Snap to a rune boundary (never split a UTF-8 sequence).
		line := lines[p.line]
		for p.col > 0 && p.col < len(line) && line[p.col] & 0xC0 == 0x80 {
			p.col -= 1
		}
		return p
	}

	// Full buffer contents joined with '\n'. Caller owns the result.
	text :: proc(allocator := context.allocator) -> string {
		sb := strings.builder_make(allocator)
		for line, i in lines {
			if i > 0 {
				strings.write_byte(&sb, '\n')
			}
			strings.write_bytes(&sb, line[:])
		}
		return strings.to_string(sb)
	}

	// Text inside r. Caller owns the result.
	range_text :: proc(r: Range, allocator := context.allocator) -> string {
		if r.start.line == r.end.line {
			return strings.clone(string(lines[r.start.line][r.start.col:r.end.col]), allocator)
		}
		sb := strings.builder_make(allocator)
		strings.write_bytes(&sb, lines[r.start.line][r.start.col:])
		for i in r.start.line + 1 ..< r.end.line {
			strings.write_byte(&sb, '\n')
			strings.write_bytes(&sb, lines[i][:])
		}
		strings.write_byte(&sb, '\n')
		strings.write_bytes(&sb, lines[r.end.line][:r.end.col])
		return strings.to_string(sb)
	}

	// Rune-aware single-step movement.
	next_pos :: proc(p: Pos) -> Pos {
		line := lines[p.line]
		if p.col >= len(line) {
			if p.line+1 < len(lines) {
				return Pos{p.line + 1, 0}
			}
			return p
		}
		_, n := utf8.decode_rune(line[p.col:])
		return Pos{p.line, p.col + n}
	}

	prev_pos :: proc(p: Pos) -> Pos {
		if p.col <= 0 {
			if p.line > 0 {
				return Pos{p.line - 1, len(lines[p.line-1])}
			}
			return p
		}
		line := lines[p.line]
		_, n := utf8.decode_last_rune(line[:p.col])
		return Pos{p.line, p.col - n}
	}

	rune_at :: proc(p: Pos) -> rune {
		line := lines[p.line]
		if p.col >= len(line) {
			return '\n'
		}
		r, _ := utf8.decode_rune(line[p.col:])
		return r
	}
}

char_class :: proc(r: rune) -> int {
	if r == ' ' || r == '\t' || r == '\n' {
		return 0 // whitespace
	}
	if r == '_' ||
	   ('a' <= r && r <= 'z') ||
	   ('A' <= r && r <= 'Z') ||
	   ('0' <= r && r <= '9') ||
	   r >= 0x80 {
		return 1 // word
	}
	return 2 // punctuation
}

// Subword helpers for smart word movement.
@(private = "file")
is_upper_r :: proc(r: rune) -> bool {
	return 'A' <= r && r <= 'Z'
}

@(private = "file")
is_lower_alpha :: proc(r: rune) -> bool {
	return 'a' <= r && r <= 'z'
}

// Continues a lowercase subword: lowercase, digits, and non-ASCII word runes.
@(private = "file")
is_sub_low :: proc(r: rune) -> bool {
	return ('a' <= r && r <= 'z') || ('0' <= r && r <= '9') || r >= 0x80
}

@(private = "file")
at_bof :: proc(p: Pos) -> bool {
	return p.line == 0 && p.col == 0
}

// Word movement mode; a setting, toggled from the command palette.
// Smart stops at subword boundaries (camelCase humps, underscores);
// whole-word hops entire identifiers like most editors.
smart_word := true

impl Buffer {
	word_right :: proc(p: Pos) -> Pos {
		return self.subword_right(p) if smart_word else self.full_word_right(p)
	}

	word_left :: proc(p: Pos) -> Pos {
		return self.subword_left(p) if smart_word else self.full_word_left(p)
	}

	// Whole-word movement: skip any run of same-class runes, plus leading
	// whitespace in the direction of travel.
	full_word_right :: proc(p: Pos) -> Pos {
		p := p
		if pos_eq(p, self.end_pos()) {
			return p
		}
		class := char_class(self.rune_at(p))
		for {
			np := self.next_pos(p)
			if pos_eq(np, p) {
				return p
			}
			p = np
			if pos_eq(p, self.end_pos()) {
				return p
			}
			c := char_class(self.rune_at(p))
			if class == 0 && c != 0 {
				class = c // consumed whitespace; now consume the word/punct run
			} else if c != class {
				return p
			}
		}
	}

	full_word_left :: proc(p: Pos) -> Pos {
		p := p
		if at_bof(p) {
			return p
		}
		p = self.prev_pos(p)
		class := char_class(self.rune_at(p))
		for class == 0 && !at_bof(p) {
			np := self.prev_pos(p)
			c := char_class(self.rune_at(np))
			p = np
			if c != 0 {
				class = c
				break
			}
		}
		for !at_bof(p) {
			np := self.prev_pos(p)
			if char_class(self.rune_at(np)) != class {
				return p
			}
			p = np
		}
		return p
	}

	// Smart word movement: stops at subword boundaries — camelCase humps,
	// underscores, punctuation runs — not just whitespace-separated words.
	// "fooBarHTTPBaz" hops foo|Bar|HTTP|Baz; "foo_bar" hops foo|_bar.
	subword_right :: proc(p: Pos) -> Pos {
		p := p
		end := self.end_pos()
		if pos_eq(p, end) {
			return p
		}
		// Whitespace (and newlines) first.
		for char_class(self.rune_at(p)) == 0 {
			p = self.next_pos(p)
			if pos_eq(p, end) {
				return p
			}
		}
		c := self.rune_at(p)
		if char_class(c) == 2 {
			for !pos_eq(p, end) && char_class(self.rune_at(p)) == 2 {
				p = self.next_pos(p)
			}
			return p
		}
		// Inside an identifier: consume exactly one subword.
		if c == '_' {
			for !pos_eq(p, end) && self.rune_at(p) == '_' {
				p = self.next_pos(p)
			}
			if pos_eq(p, end) {
				return p
			}
			c = self.rune_at(p)
			if !(is_upper_r(c) || is_sub_low(c)) {
				return p
			}
		}
		if is_upper_r(c) {
			p = self.next_pos(p)
			if pos_eq(p, end) {
				return p
			}
			if is_upper_r(self.rune_at(p)) {
				// Acronym run (HTTP): stop before an upper that begins the
				// next camel word (the P in HTMLParser).
				for {
					if pos_eq(p, end) || !is_upper_r(self.rune_at(p)) {
						return p
					}
					np := self.next_pos(p)
					if !pos_eq(np, end) && is_lower_alpha(self.rune_at(np)) {
						return p
					}
					p = np
				}
			}
			// Single upper starting a camel word: fall through to its tail.
		}
		for !pos_eq(p, end) && is_sub_low(self.rune_at(p)) {
			p = self.next_pos(p)
		}
		return p
	}

	subword_left :: proc(p: Pos) -> Pos {
		p := p
		if at_bof(p) {
			return p
		}
		for !at_bof(p) && char_class(self.rune_at(self.prev_pos(p))) == 0 {
			p = self.prev_pos(p)
		}
		if at_bof(p) {
			return p
		}
		c := self.rune_at(self.prev_pos(p))
		if char_class(c) == 2 {
			for !at_bof(p) && char_class(self.rune_at(self.prev_pos(p))) == 2 {
				p = self.prev_pos(p)
			}
			return p
		}
		if c == '_' {
			for !at_bof(p) && self.rune_at(self.prev_pos(p)) == '_' {
				p = self.prev_pos(p)
			}
			if at_bof(p) {
				return p
			}
			c = self.rune_at(self.prev_pos(p))
			if !(is_upper_r(c) || is_sub_low(c)) {
				return p
			}
		}
		if is_sub_low(c) {
			for !at_bof(p) && is_sub_low(self.rune_at(self.prev_pos(p))) {
				p = self.prev_pos(p)
			}
			// One leading upper completes a camel word (the B of Bar).
			if !at_bof(p) && is_upper_r(self.rune_at(self.prev_pos(p))) {
				p = self.prev_pos(p)
			}
			return p
		}
		// Acronym run backward.
		for !at_bof(p) && is_upper_r(self.rune_at(self.prev_pos(p))) {
			p = self.prev_pos(p)
		}
		return p
	}

	// Range of the word (or punctuation run) around p — for double-click
	// and ctrl+d.
	word_range_at :: proc(p: Pos) -> Range {
		start, end := p, p
		if p.col < self.line_len(p.line) && char_class(self.rune_at(p)) == 1 {
			end = self.next_pos(p)
			for end.col < self.line_len(end.line) && char_class(self.rune_at(end)) == 1 {
				end = self.next_pos(end)
			}
		}
		for start.col > 0 {
			prev := self.prev_pos(start)
			if prev.line != start.line || char_class(self.rune_at(prev)) != 1 {
				break
			}
			start = prev
		}
		return Range{start, end}
	}
}

buffer_make :: proc(path := "") -> Buffer {
	b: Buffer
	b.path = strings.clone(path)
	append(&b.lines, make([dynamic]u8))
	return b
}

buffer_destroy :: proc(b: ^Buffer) {
	for &line in b.lines {
		delete(line)
	}
	delete(b.lines)
	undo_groups_destroy(&b.undo_stack)
	undo_groups_destroy(&b.redo_stack)
	delete(b.path)
}

buffer_load :: proc(path: string) -> (b: Buffer, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	b.path = strings.clone(path)
	b.disk_mtime = file_mtime(path)
	text := string(data)
	if strings.contains(text, "\r\n") {
		b.line_ending = .CRLF
	}
	for {
		nl := strings.index_byte(text, '\n')
		line_text := text if nl < 0 else text[:nl]
		if len(line_text) > 0 && line_text[len(line_text)-1] == '\r' {
			line_text = line_text[:len(line_text)-1]
		}
		line := make([dynamic]u8, 0, len(line_text))
		append(&line, line_text)
		append(&b.lines, line)
		if nl < 0 {
			break
		}
		text = text[nl+1:]
	}
	return b, true
}

buffer_save :: proc(b: ^Buffer) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	for line, i in b.lines {
		if i > 0 {
			if b.line_ending == .CRLF {
				strings.write_byte(&sb, '\r')
			}
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, line[:])
	}
	if os.write_entire_file(b.path, sb.buf[:]) != nil {
		return false
	}
	b.saved_depth = len(b.undo_stack)
	b.disk_mtime = file_mtime(b.path)
	b.conflict = false
	return true
}

// --- Edit application -------------------------------------------------------

// Replace r with text. Returns the end position of the inserted text.
// Positions strictly after r remain meaningful only via transform_pos.
@(private)
replace_range :: proc(b: ^Buffer, r: Range, text: string) -> (new_end: Pos) {
	first := &b.lines[r.start.line]

	if r.start.line == r.end.line && !strings.contains_rune(text, '\n') {
		// Fast path: edit within a single line.
		line := first
		tail := make([]u8, len(line) - r.end.col, context.temp_allocator)
		copy(tail, line[r.end.col:])
		resize(line, r.start.col)
		append(line, text)
		append(line, string(tail))
		return Pos{r.start.line, r.start.col + len(text)}
	}

	// Save the suffix of the end line before any mutation.
	end_line := b.lines[r.end.line]
	suffix := make([]u8, len(end_line) - r.end.col, context.temp_allocator)
	copy(suffix, end_line[r.end.col:])

	// Split the inserted text into segments.
	segs := strings.split(text, "\n", context.temp_allocator)

	// First segment continues the start line.
	resize(first, r.start.col)
	append(first, segs[0])

	if len(segs) == 1 {
		new_end = Pos{r.start.line, len(first^)}
		append(first, string(suffix))
	} else {
		// Middle + last segments become fresh lines; last gets the suffix.
		last_i := len(segs) - 1
		new_lines := make([dynamic][dynamic]u8, 0, last_i, context.temp_allocator)
		for seg, i in segs[1:] {
			line := make([dynamic]u8, 0, len(seg) + (len(suffix) if i == last_i-1 else 0))
			append(&line, seg)
			if i == last_i-1 {
				new_end = Pos{r.start.line + 1 + i, len(line)}
				append(&line, string(suffix))
			}
			append(&new_lines, line)
		}
		// Replace old lines start+1..=end with new_lines.
		for i in r.start.line + 1 ..= r.end.line {
			delete(b.lines[i])
		}
		remove_range(&b.lines, r.start.line+1, r.end.line+1)
		#reverse for line in new_lines {
			inject_at(&b.lines, r.start.line+1, line)
		}
		return new_end
	}

	// len(segs) == 1 but the range spanned lines: drop the swallowed lines.
	for i in r.start.line + 1 ..= r.end.line {
		delete(b.lines[i])
	}
	remove_range(&b.lines, r.start.line+1, r.end.line+1)
	return new_end
}

// Map a position at or after edited.end (pre-edit coords) into post-edit coords.
transform_pos :: proc(p: Pos, edited: Range, new_end: Pos) -> Pos {
	if p.line == edited.end.line {
		return Pos{new_end.line, new_end.col + (p.col - edited.end.col)}
	}
	return Pos{p.line + (new_end.line - edited.end.line), p.col}
}

// Apply a sorted, non-overlapping batch. Returns the inverse batch (owned
// text, coordinates valid in the post-batch document) and the range each
// replacement occupies afterwards. Does not touch undo state.
@(private)
apply_edits :: proc(b: ^Buffer, edits: []Edit) -> (inverse: []Edit, new_ranges: []Range) {
	pending := make([]Edit, len(edits), context.temp_allocator)
	copy(pending, edits)

	inverse = make([]Edit, len(edits))
	new_ranges = make([]Range, len(edits), context.temp_allocator)

	for i in 0 ..< len(pending) {
		e := pending[i]
		old_text := b.range_text(e.range)
		new_end := replace_range(b, e.range, e.text)
		nr := Range{e.range.start, new_end}
		new_ranges[i] = nr
		inverse[i] = Edit{range = nr, text = old_text}
		// Later edits sit at or after e.range.end — pull them into the new coords.
		for j in i + 1 ..< len(pending) {
			pending[j].range.start = transform_pos(pending[j].range.start, e.range, new_end)
			pending[j].range.end = transform_pos(pending[j].range.end, e.range, new_end)
		}
	}
	return
}

@(private)
edits_sort :: proc(edits: []Edit) {
	// Insertion sort by start position; batches are cursor-count sized.
	for i in 1 ..< len(edits) {
		j := i
		for j > 0 && pos_less(edits[j].range.start, edits[j-1].range.start) {
			edits[j], edits[j-1] = edits[j-1], edits[j]
			j -= 1
		}
	}
}

@(private)
undo_group_destroy :: proc(g: ^Undo_Group) {
	for e in g.inverse {
		delete(e.text)
	}
	delete(g.inverse)
	delete(g.cursors_before)
}

@(private)
undo_groups_destroy :: proc(groups: ^[dynamic]Undo_Group) {
	for &g in groups {
		undo_group_destroy(&g)
	}
	delete(groups^)
}

impl Buffer {
	// Apply a batch of edits as one undoable step. cursors is the cursor
	// set before the edit (restored on undo). Returns the post-edit range
	// of each replacement, ordered like the (sorted) batch, allocated with
	// context.temp_allocator.
	commit :: proc(edits: []Edit, cursors: []Cursor) -> []Range {
		if len(edits) == 0 {
			return nil
		}
		sorted := make([]Edit, len(edits), context.temp_allocator)
		copy(sorted, edits)
		edits_sort(sorted)
		for &e in sorted {
			e.range.start = self.clamp_pos(e.range.start)
			e.range.end = self.clamp_pos(e.range.end)
		}

		inverse, new_ranges := apply_edits(self, sorted)

		group := Undo_Group {
			inverse        = inverse,
			cursors_before = make([]Cursor, len(cursors)),
		}
		copy(group.cursors_before, cursors)
		if len(undo_stack) < saved_depth {
			saved_depth = -1 // committing from an undone state orphans the saved state
		}
		append(&undo_stack, group)
		undo_groups_destroy(&redo_stack)
		redo_stack = make([dynamic]Undo_Group)

		version += 1
		return new_ranges
	}

	// Undo the last group. Returns the cursors to restore.
	undo :: proc(cursors: []Cursor) -> (restored: []Cursor, ok: bool) {
		if len(undo_stack) == 0 {
			return nil, false
		}
		group := pop(&undo_stack)
		redo_inverse, _ := apply_edits(self, group.inverse)

		redo_group := Undo_Group {
			inverse        = redo_inverse,
			cursors_before = make([]Cursor, len(cursors)),
		}
		copy(redo_group.cursors_before, cursors)
		append(&redo_stack, redo_group)

		version += 1
		restored = group.cursors_before // ownership moves to caller
		for e in group.inverse {
			delete(e.text)
		}
		delete(group.inverse)
		return restored, true
	}

	redo :: proc(cursors: []Cursor) -> (restored: []Cursor, ok: bool) {
		if len(redo_stack) == 0 {
			return nil, false
		}
		group := pop(&redo_stack)
		undo_inverse, _ := apply_edits(self, group.inverse)

		undo_group := Undo_Group {
			inverse        = undo_inverse,
			cursors_before = make([]Cursor, len(cursors)),
		}
		copy(undo_group.cursors_before, cursors)
		append(&undo_stack, undo_group)

		version += 1
		restored = group.cursors_before
		for e in group.inverse {
			delete(e.text)
		}
		delete(group.inverse)
		return restored, true
	}
}

// --- Multi-cursor maintenance ----------------------------------------------

// Sort cursors by head and merge any whose selections overlap (or heads
// coincide). Returns the new count; the slice is mutated in place.
cursors_normalize :: proc(cursors: ^[dynamic]Cursor) {
	if len(cursors) <= 1 {
		return
	}
	// Insertion sort by selection start.
	for i in 1 ..< len(cursors) {
		j := i
		for j > 0 && pos_less(cursor_range(cursors[j]).start, cursor_range(cursors[j-1]).start) {
			cursors[j], cursors[j-1] = cursors[j-1], cursors[j]
			j -= 1
		}
	}
	// Merge overlaps.
	w := 0
	for i in 1 ..< len(cursors) {
		prev := cursor_range(cursors[w])
		cur := cursor_range(cursors[i])
		overlap := pos_less(cur.start, prev.end) ||
			(pos_eq(cur.start, prev.end) && (range_empty(cur) || range_empty(prev)))
		if overlap {
			// Keep the union; head orientation follows the later cursor.
			merged := range_make(prev.start, cur.end)
			if pos_less(cursors[i].anchor, cursors[i].head) {
				cursors[w] = Cursor{head = merged.end, anchor = merged.start, goal_col = -1}
			} else {
				cursors[w] = Cursor{head = merged.start, anchor = merged.end, goal_col = -1}
			}
		} else {
			w += 1
			cursors[w] = cursors[i]
		}
	}
	resize(cursors, w+1)
}
