package medit

import "core:testing"

@(private = "file")
hl_setup :: proc(content: string, lang: Lang) -> (Buffer, Highlight) {
	b := buffer_make()
	if len(content) > 0 {
		b.commit([]Edit{{range = {}, text = content}}, nil)
	}
	h := Highlight{lang = lang}
	highlight_update(&h, &b)
	return b, h
}

// Face covering (line, col), or .Text if no span does.
@(private = "file")
face_at :: proc(h: ^Highlight, line, col: int) -> Face {
	for s in h.spans[line] {
		if s.start <= col && col < s.end {
			return s.face
		}
	}
	return .Text
}

@test
test_highlight_generic_langs :: proc(t: ^testing.T) {
	// C: keyword, type, directive, string, char.
	b, h := hl_setup("#include <stdio.h>\nstatic int x = 'a';\nchar *s = \"hi\"; // c\n", .C)
	defer buffer_destroy(&b)
	defer highlight_destroy(&h)
	testing.expect_value(t, face_at(&h, 0, 0), Face.Directive)
	testing.expect_value(t, face_at(&h, 1, 0), Face.Keyword)  // static
	testing.expect_value(t, face_at(&h, 1, 7), Face.Type)     // int
	testing.expect_value(t, face_at(&h, 1, 15), Face.String)  // 'a'
	testing.expect_value(t, face_at(&h, 2, 10), Face.String)  // "hi"
	testing.expect_value(t, face_at(&h, 2, 16), Face.Comment) // // c

	// Python: triple-quoted string spanning lines, # comment, def keyword.
	b2, h2 := hl_setup("def f():\n\t\"\"\"doc\nstring\"\"\"\n\treturn None # x\n", .Python)
	defer buffer_destroy(&b2)
	defer highlight_destroy(&h2)
	testing.expect_value(t, face_at(&h2, 0, 0), Face.Keyword)  // def
	testing.expect_value(t, face_at(&h2, 1, 3), Face.String)   // """doc
	testing.expect_value(t, face_at(&h2, 2, 0), Face.String)   // string"""
	testing.expect_value(t, face_at(&h2, 3, 8), Face.Constant) // None
	testing.expect_value(t, face_at(&h2, 3, 13), Face.Comment)

	// Lua: block comment wins over line comment prefix.
	b3, h3 := hl_setup("--[[ block\nstill ]] x = true\n-- line\n", .Lua)
	defer buffer_destroy(&b3)
	defer highlight_destroy(&h3)
	testing.expect_value(t, face_at(&h3, 0, 0), Face.Comment)
	testing.expect_value(t, face_at(&h3, 1, 0), Face.Comment)  // still ]]
	testing.expect_value(t, face_at(&h3, 1, 13), Face.Constant) // true
	testing.expect_value(t, face_at(&h3, 2, 0), Face.Comment)

	// INI: section, key, ; comment.
	b4, h4 := hl_setup("[core]\nname = medit ; note\n", .INI)
	defer buffer_destroy(&b4)
	defer highlight_destroy(&h4)
	testing.expect_value(t, face_at(&h4, 0, 0), Face.Directive)
	testing.expect_value(t, face_at(&h4, 1, 0), Face.Key)
	testing.expect_value(t, face_at(&h4, 1, 13), Face.Comment)

	// Go: raw string over lines.
	b5, h5 := hl_setup("s := `raw\nstill raw` // done\n", .Go)
	defer buffer_destroy(&b5)
	defer highlight_destroy(&h5)
	testing.expect_value(t, face_at(&h5, 0, 5), Face.String)
	testing.expect_value(t, face_at(&h5, 1, 0), Face.String)
	testing.expect_value(t, face_at(&h5, 1, 11), Face.Comment)
}

@test
test_highlight_markdown :: proc(t: ^testing.T) {
	b, h := hl_setup("# Title\n> quote\nuse `code` and [x](url)\n```\nfenced\n```\nafter\n", .Markdown)
	defer buffer_destroy(&b)
	defer highlight_destroy(&h)
	testing.expect_value(t, face_at(&h, 0, 0), Face.Keyword)  // heading
	testing.expect_value(t, face_at(&h, 1, 0), Face.Comment)  // quote
	testing.expect_value(t, face_at(&h, 2, 5), Face.String)   // `code`
	testing.expect_value(t, face_at(&h, 2, 15), Face.Function) // [x]
	testing.expect_value(t, face_at(&h, 2, 19), Face.Comment) // (url)
	testing.expect_value(t, face_at(&h, 4, 0), Face.String)   // fenced
	testing.expect_value(t, face_at(&h, 6, 0), Face.Text)     // after
}

@test
test_highlight_markup :: proc(t: ^testing.T) {
	b, h := hl_setup("<!-- c -->\n<div class=\"x\">text</div>\n", .HTML)
	defer buffer_destroy(&b)
	defer highlight_destroy(&h)
	testing.expect_value(t, face_at(&h, 0, 2), Face.Comment)
	testing.expect_value(t, face_at(&h, 1, 1), Face.Keyword) // div
	testing.expect_value(t, face_at(&h, 1, 5), Face.Key)     // class
	testing.expect_value(t, face_at(&h, 1, 11), Face.String) // "x"
	testing.expect_value(t, face_at(&h, 1, 16), Face.Text)   // text
	testing.expect_value(t, face_at(&h, 1, 21), Face.Keyword) // /div

	// XML declarations don't trip it up.
	b2, h2 := hl_setup("<?xml version=\"1.0\"?>\n<a b='c'/>\n", .HTML)
	defer buffer_destroy(&b2)
	defer highlight_destroy(&h2)
	testing.expect_value(t, face_at(&h2, 0, 2), Face.Keyword) // xml
	testing.expect_value(t, face_at(&h2, 1, 6), Face.String)  // 'c'
}

@test
test_highlight_embedded_lang :: proc(t: ^testing.T) {
	// @(lang="wgsl") on a raw string: the interior lexes as WGSL.
	src := "@(lang=\"wgsl\")\nSHADER :: `\nfn vs_main() {\n\treturn true\n}\n`\nx := \"plain\"\n"
	b, h := hl_setup(src, .Odin)
	defer buffer_destroy(&b)
	defer highlight_destroy(&h)
	testing.expect_value(t, face_at(&h, 1, 10), Face.String)  // opening backtick keeps string face
	testing.expect_value(t, face_at(&h, 2, 0), Face.Keyword)  // fn
	testing.expect_value(t, face_at(&h, 2, 3), Face.Function) // vs_main
	testing.expect_value(t, face_at(&h, 3, 8), Face.Constant) // true
	testing.expect_value(t, face_at(&h, 6, 6), Face.String)   // later strings are ordinary

	// The attribute's own value string must not consume the tag, and
	// @(private, lang="json") works mid-group.
	src2 := "@(private, lang=\"json\")\nCFG :: `{\"key\": 12, \"b\": null}`\n"
	b2, h2 := hl_setup(src2, .Odin)
	defer buffer_destroy(&b2)
	defer highlight_destroy(&h2)
	testing.expect_value(t, face_at(&h2, 0, 11), Face.Text)   // lang ident inside attr
	testing.expect_value(t, face_at(&h2, 1, 9), Face.Key)     // "key"
	testing.expect_value(t, face_at(&h2, 1, 16), Face.Number) // 12
	testing.expect_value(t, face_at(&h2, 1, 25), Face.Constant) // null

	// Unknown language: whole literal stays a plain string.
	src3 := "@(lang=\"nope\")\nS :: `fn x`\n"
	b3, h3 := hl_setup(src3, .Odin)
	defer buffer_destroy(&b3)
	defer highlight_destroy(&h3)
	testing.expect_value(t, face_at(&h3, 1, 6), Face.String)
}

// Every language survives adversarial input (unterminated everything) and
// produces only in-bounds, ordered spans.
@test
test_highlight_no_crash_all_langs :: proc(t: ^testing.T) {
	nasty := "\"unterminated\n'x\n`y\n\"\"\"z\n--[[\n<!--\n<tag attr=\"\n[section\n#\n@\n/* \n// \n\\\n"
	for lang in Lang {
		b, h := hl_setup(nasty, lang)
		for spans, line in h.spans {
			for s in spans {
				testing.expectf(t, 0 <= s.start && s.start <= s.end && s.end <= b.line_len(line),
					"%v: bad span %v on line %d (len %d)", lang, s, line, b.line_len(line))
			}
		}
		buffer_destroy(&b)
		highlight_destroy(&h)
	}
}
