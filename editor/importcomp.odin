// medit — import path completion. Inside an Odin import string the popup
// lists collections (base:/core:/vendor:) and package directories instead of
// asking the language server:
//
//   import "|            → base: core: vendor: + dirs next to the file
//   import rl "vendor:|  → raylib sdl3 stb ...
//   import "core:odin/|  → ast parser tokenizer ...
package medit

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The Odin/Methodin root that owns base/core/vendor, resolved once:
// $ODIN_ROOT, else a cwd ancestor that has the three collections (the
// common case of hacking inside the compiler repo), else `odin root`.
@(private = "file")
find_odin_root :: proc() -> string {
	if env := os.get_env("ODIN_ROOT", context.temp_allocator); env != "" {
		return strings.clone(env)
	}
	has_collections :: proc(dir: string) -> bool {
		for coll in ([3]string{"base", "core", "vendor"}) {
			p, jerr := filepath.join({dir, coll}, context.temp_allocator)
			if jerr != nil || !os.is_directory(p) {
				return false
			}
		}
		return true
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	for dir := cwd; len(dir) > 1; dir, _ = os.split_path(dir) {
		if has_collections(dir) {
			return strings.clone(dir)
		}
	}
	state, out, _, err := os.process_exec(
		{command = []string{"odin", "root"}},
		context.temp_allocator,
	)
	if err == nil && state.exited && state.exit_code == 0 {
		if root := strings.trim_space(string(out)); root != "" {
			return strings.clone(root)
		}
	}
	return ""
}

impl App {
	odin_root :: proc() -> string {
		if !odin_root_done {
			odin_root_done = true
			odin_root_dir = find_odin_root()
		}
		return odin_root_dir
	}

	// If p sits inside the string of an `import [alias] "..."` line, return
	// the string content before the caret and the column where it starts.
	import_string_at :: proc(p: Pos) -> (content: string, content_col: int, ok: bool) {
		if hl.lang != .Odin {
			return
		}
		line := buf.line_str(p.line)
		q0 := strings.index_byte(line, '"')
		if q0 < 0 || p.col <= q0 {
			return
		}
		if strings.index_byte(line[q0+1:p.col], '"') >= 0 {
			return // caret is past the closing quote
		}
		// Everything before the quote must look like `import` + optional alias
		// (attributes like @(require) may precede it).
		pre := strings.fields(strings.trim_space(line[:q0]), context.temp_allocator)
		n := len(pre)
		looks := (n >= 1 && pre[n-1] == "import") || (n >= 2 && pre[n-2] == "import")
		if !looks {
			return
		}
		return line[q0+1 : p.col], q0 + 1, true
	}

	// Fill the completion popup with the entries for the current path
	// segment. Static listing — completion_filter fuzzy-narrows as usual.
	completion_trigger_import :: proc() {
		p := self.primary_cursor().head
		content, content_col, ok := self.import_string_at(p)
		if !ok || len(cursors) != 1 {
			return
		}
		c := &completion
		self.completion_close()

		// The segment being completed starts after the last ':' or '/'.
		seg := 0
		colon := -1
		for i in 0 ..< len(content) {
			if content[i] == ':' || content[i] == '/' {
				seg = i + 1
			}
			if content[i] == ':' {
				colon = i
			}
		}

		add :: proc(c: ^Completion, label, detail: string) {
			append(&c.items, Comp_Item{
				label  = strings.clone(label),
				insert = strings.clone(""),
				detail = strings.clone(detail),
				kind   = 9, // Module
			})
		}

		if colon < 0 {
			// No collection yet: offer the collections and, for relative
			// imports, the directories next to the current file.
			root := self.odin_root()
			if root != "" {
				add(c, "base:", "collection")
				add(c, "core:", "collection")
				add(c, "vendor:", "collection")
			}
			file_dir, _ := os.split_path(buf.path)
			self.import_list_dirs(file_dir if file_dir != "" else ".", content[:seg])
		} else {
			root := self.odin_root()
			coll := content[:colon]
			if root == "" {
				return
			}
			coll_dir, jerr := filepath.join({root, coll}, context.temp_allocator)
			if jerr != nil || !os.is_directory(coll_dir) {
				return
			}
			self.import_list_dirs(coll_dir, content[colon+1 : seg])
		}
		if len(c.items) == 0 {
			return
		}
		slice.sort_by(c.items[:], proc(a, b: Comp_Item) -> bool { return a.label < b.label })
		c.anchor = Pos{p.line, content_col + seg}
		c.import_mode = true
		c.requested = false
		c.incomplete = false
		self.completion_filter()
	}

	// Append every subdirectory of base/rel as a completion item.
	import_list_dirs :: proc(base, rel: string) {
		dir, jerr := filepath.join({base, rel}, context.temp_allocator)
		if jerr != nil {
			return
		}
		infos, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if rerr != nil {
			return
		}
		for fi in infos {
			if fi.type != .Directory || strings.has_prefix(fi.name, ".") {
				continue
			}
			append(&completion.items, Comp_Item{
				label  = strings.clone(fi.name),
				insert = strings.clone(""),
				detail = strings.clone("package"),
				kind   = 9, // Module
			})
		}
	}
}
