// medit — external file change detection.
//
// Each buffer remembers the mtime of the file it was loaded from or last
// saved to. A cheap stat poll (~1s, and immediately on focus gain) spots
// writes made behind the editor's back: a clean buffer reloads in place —
// as a single commit, so the reload is undoable and highlighting/LSP resync
// off the version bump — while a dirty buffer keeps the user's text and
// arms a conflict: the status bar says so, overwriting takes a second
// ctrl+s, and "File: Reload from Disk" takes the disk version instead.
package medit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

WATCH_INTERVAL_MS :: 1000

// Modification time in unix nanoseconds; 0 when the file cannot be stat'ed.
file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	return time.to_unix_nanoseconds(fi.modification_time)
}

// The file no longer matches what this buffer last read or wrote.
buffer_disk_changed :: proc(b: ^Buffer) -> bool {
	if b.path == "" {
		return false
	}
	if b.conflict {
		return true
	}
	m := file_mtime(b.path)
	return m != 0 && m != b.disk_mtime
}

impl App {
	files_tick :: proc() {
		if now_ms - watch_ms < WATCH_INTERVAL_MS {
			return
		}
		watch_ms = now_ms
		for i in 0 ..< len(docs) {
			b := self.doc_buf(i)
			if b.path == "" || b.disk_mtime == 0 {
				continue
			}
			m := file_mtime(b.path)
			if m == 0 || m == b.disk_mtime {
				continue
			}
			if b.is_dirty() {
				if !b.conflict {
					b.conflict = true
					self.set_status(fmt.tprintf(
						"%s changed on disk — ctrl+s keeps yours, \"File: Reload from Disk\" takes the disk version",
						self.tab_label(i)))
				}
				b.disk_mtime = m
			} else {
				self.doc_reload(i)
			}
		}
	}

	// Replace tab i's contents with the file on disk, as one undoable commit.
	doc_reload :: proc(i: int) {
		b := self.doc_buf(i)
		if b.path == "" {
			return
		}
		data, err := os.read_entire_file(b.path, context.temp_allocator)
		if err != nil {
			self.set_status(fmt.tprintf("could not reload %s", self.tab_label(i)))
			return
		}
		b.disk_mtime = file_mtime(b.path)
		b.conflict = false
		text := string(data)
		if strings.contains(text, "\r\n") {
			b.line_ending = .CRLF
			text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
		}
		if text == b.text(context.temp_allocator) {
			b.saved_depth = len(b.undo_stack)
			return
		}
		cs := &cursors if i == active else &docs[i].cursors
		edits := []Edit{{range = {Pos{0, 0}, b.end_pos()}, text = text}}
		b.commit(edits, cs[:])
		b.saved_depth = len(b.undo_stack)
		for &c in cs {
			c.head = b.clamp_pos(c.head)
			c.anchor = b.clamp_pos(c.anchor)
			c.goal_col = -1
		}
		if i == active {
			self.normalize_cursors()
		} else {
			cursors_normalize(cs)
			docs[i].primary = min(docs[i].primary, len(cs) - 1)
		}
		self.set_status(fmt.tprintf("reloaded from disk: %s", self.tab_label(i)))
	}

	// A save that would clobber an external edit needs a second ctrl+s.
	save_conflicted :: proc() -> bool {
		if !buffer_disk_changed(&buf) {
			return false
		}
		buf.conflict = true
		if pending_overwrite == active {
			pending_overwrite = -1
			return false // second attempt: the user chose to overwrite
		}
		pending_overwrite = active
		self.set_status("changed on disk — save again to overwrite, or \"File: Reload from Disk\"")
		return true
	}
}
