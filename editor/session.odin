// medit — session restore.
//
// On quit the workspace directory and the open documents (with cursor
// position and the active tab) are written to <user config>/medit/session.
// Launched with no file/dir argument, medit changes into that workspace and
// reopens those documents; an explicit argument wins, and the session is
// simply overwritten on the next quit. With no session file the most recent
// workspace (recent-dirs) is used, with nothing reopened.
package medit

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// One document line of the session file: "line:col path", '*' prefix marks
// the active tab.
Session_Entry :: struct {
	line, col: int,
	active:    bool,
	path:      string, // borrows the read buffer
}

@(private = "file")
dir_exists :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.type == .Directory
}

// Serialize the workspace and open documents to path.
session_write :: proc(app: ^App, path: string) {
	cwd, cerr := os.get_working_directory(context.temp_allocator)
	if cerr != nil || cwd == "" {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, cwd)
	strings.write_byte(&sb, '\n')
	for i in 0 ..< len(app.docs) {
		b := app.doc_buf(i)
		if b.path == "" || app.doc_is_preview(i) {
			continue
		}
		c := cursor_at(Pos{0, 0})
		if i == app.active {
			c = app.primary_cursor()^
		} else if d := &app.docs[i]; len(d.cursors) > 0 {
			c = d.cursors[clamp(d.primary, 0, len(d.cursors)-1)]
		}
		if i == app.active {
			strings.write_byte(&sb, '*')
		}
		fmt.sbprintf(&sb, "%d:%d %s\n", c.head.line, c.head.col, b.path)
	}
	dir, _ := os.split_path(path)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(sb))
}

// Read a session file. dir and entry paths borrow temp-allocated data.
session_read :: proc(path: string) -> (dir: string, entries: []Session_Entry, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	list := make([dynamic]Session_Entry, context.temp_allocator)
	rest := string(data)
	first := true
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if first {
			dir = strings.trim_space(l)
			first = false
			continue
		}
		if l == "" {
			continue
		}
		e: Session_Entry
		if l[0] == '*' {
			e.active = true
			l = l[1:]
		}
		num, sep, doc_path := strings.partition(l, " ")
		ls, _, cs := strings.partition(num, ":")
		li, lok := strconv.parse_int(ls)
		ci, cok := strconv.parse_int(cs)
		if sep == "" || doc_path == "" || !lok || !cok {
			continue
		}
		e.line = li
		e.col = ci
		e.path = doc_path
		append(&list, e)
	}
	return dir, list[:], dir != ""
}

session_save :: proc(app: ^App) {
	if path, ok := config_path("session"); ok {
		session_write(app, path)
	}
}

// The workspace a bare launch should start in: the session's, else the most
// recent workspace. Temp-allocated.
session_restore_dir :: proc() -> (dir: string, ok: bool) {
	if path, pok := config_path("session"); pok {
		if d, _, rok := session_read(path); rok && dir_exists(d) {
			return d, true
		}
	}
	if path, pok := config_path("recent-dirs"); pok {
		if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
			rest := string(data)
			for line in strings.split_lines_iterator(&rest) {
				d := strings.trim_space(line)
				if d != "" && dir_exists(d) {
					return d, true
				}
			}
		}
	}
	return
}

impl App {
	// Reopen the session's documents (those that still exist), restoring
	// each cursor and finally the active tab.
	session_open_docs :: proc() {
		path, pok := config_path("session")
		if !pok {
			return
		}
		_, entries, ok := session_read(path)
		if !ok {
			return
		}
		active_idx := -1
		for e in entries {
			if fi, serr := os.stat(e.path, context.temp_allocator); serr != nil || fi.type == .Directory {
				continue
			}
			self.open_file(e.path)
			if buf.path != e.path {
				continue // not opened (or an odd path); leave it out
			}
			cursors[0] = cursor_at(buf.clamp_pos(Pos{e.line, e.col}))
			primary = 0
			if e.active {
				active_idx = active
			}
		}
		if active_idx >= 0 {
			self.doc_switch(active_idx)
		}
		want_follow = true
		want_center = true
	}
}
