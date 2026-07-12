// medit — file system operations behind the sidebar context menu: create,
// rename and delete files and folders, reveal in the system file manager,
// and absolute/relative path helpers. The palette's context menu and its
// name prompt drive these (palette.odin); this file touches the disk and
// re-anchors the open tabs.
package medit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

REVEAL_LABEL ::
	"Reveal in Finder" when ODIN_OS == .Darwin else
	"Show in File Explorer" when ODIN_OS == .Windows else
	"Show in File Manager"

// Absolute form of a (usually workspace-relative) path. Temp-allocated.
abs_path :: proc(path: string) -> string {
	if abs, err := filepath.abs(path if path != "" else ".", context.temp_allocator); err == nil {
		return abs
	}
	return path
}

// Rewrite path after old was renamed to new: an exact match, or a path
// inside a renamed directory. ok=false when path is unaffected.
retarget_path :: proc(path, old, new: string, allocator := context.allocator) -> (out: string, ok: bool) {
	if path == old {
		return strings.clone(new, allocator), true
	}
	if len(path) > len(old) && strings.has_prefix(path, old) &&
	   (path[len(old)] == '/' || path[len(old)] == '\\') {
		return strings.concatenate({new, path[len(old):]}, allocator), true
	}
	return "", false
}

impl App {
	// Create dir/name — an empty file, or a directory when is_dir. Missing
	// directories along the way are created; existing paths are refused. A
	// new file opens in a tab right away.
	fs_create :: proc(dir, name: string, is_dir: bool) {
		path, jerr := filepath.join({dir if dir != "" else ".", name}, context.temp_allocator)
		if jerr != nil || len(strings.trim_space(name)) == 0 {
			return
		}
		if os.exists(path) {
			self.set_status(fmt.tprintf("already exists: %s", path))
			return
		}
		if is_dir {
			if os.make_directory_all(path) != nil {
				self.set_status("could not create folder")
				return
			}
		} else {
			if parent, _ := os.split_path(path); parent != "" {
				_ = os.make_directory_all(parent)
			}
			if os.write_entire_file(path, []byte{}) != nil {
				self.set_status("could not create file")
				return
			}
		}
		sidebar_refresh(&sidebar)
		sidebar_reveal(&sidebar, path)
		if !is_dir {
			self.open_file(path)
		}
		self.set_status(fmt.tprintf("created %s", path))
	}

	// Rename src (file or directory) to name inside its own directory. Open
	// tabs whose file is src, or lives under a renamed directory, follow.
	fs_rename :: proc(src, name: string) {
		dir, _ := os.split_path(src)
		dst, jerr := filepath.join({dir if dir != "" else ".", name}, context.temp_allocator)
		if jerr != nil || len(strings.trim_space(name)) == 0 || dst == src {
			return
		}
		if os.exists(dst) {
			self.set_status(fmt.tprintf("already exists: %s", dst))
			return
		}
		if os.rename(src, dst) != nil {
			self.set_status("rename failed")
			return
		}
		for i in 0 ..< len(docs) {
			b := self.doc_buf(i)
			np, hit := retarget_path(b.path, src, dst)
			if !hit {
				continue
			}
			delete(b.path)
			b.path = np
			// The extension may have changed: re-guess the language.
			if i == active {
				self.set_language(lang_from_path(np))
			} else {
				docs[i].hl.lang = lang_from_path(np)
				docs[i].hl.version = docs[i].buf.version - 1 // force a relex
			}
		}
		retitle = true
		sidebar_refresh(&sidebar)
		self.set_status(fmt.tprintf("renamed to %s", dst))
	}

	// Delete a file or a directory tree. The context menu asks twice before
	// calling this; tabs holding a deleted file stay open (saving recreates).
	fs_delete :: proc(path: string, is_dir: bool) {
		err := os.remove_all(path) if is_dir else os.remove(path)
		if err != nil {
			self.set_status(fmt.tprintf("could not delete %s", path))
			return
		}
		sidebar_refresh(&sidebar)
		self.set_status(fmt.tprintf("deleted %s", path))
	}

	// reveal_in_file_manager lives in fileops_windows.odin and
	// fileops_posix.odin — showing a path in the system file manager is
	// per-platform down to how the arguments must be quoted.
}
