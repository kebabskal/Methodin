// medit — tiny per-user persistence (under the user config directory):
// recently opened folders, offered in the command palette as "Open Recent: …"
// entries, the last zoom level, and the last window size.
package medit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

RECENT_DIRS_MAX :: 20

@(private = "file")
config_path :: proc(name: string) -> (string, bool) {
	cfg, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	path, jerr := filepath.join({cfg, "medit", name}, context.temp_allocator)
	return path, jerr == nil
}

@(private = "file")
recent_file_path :: proc() -> (string, bool) {
	return config_path("recent-dirs")
}

// --- Zoom level (main owns font_pt; loads at startup, saves on change) ------------

zoom_pt_load :: proc() -> (pt: f32, ok: bool) {
	path, pok := config_path("zoom")
	if !pok {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	return strconv.parse_f32(strings.trim_space(string(data)))
}

zoom_pt_save :: proc(pt: f32) {
	path, pok := config_path("zoom")
	if !pok {
		return
	}
	cfg_dir, _ := os.split_path(path)
	_ = os.make_directory_all(cfg_dir)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("%.1f", pt))
}

// --- Window size (logical points; saved on quit, restored at startup) --------

window_size_load :: proc() -> (w, h: int, ok: bool) {
	path, pok := config_path("window")
	if !pok {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	ws, _, hs := strings.partition(strings.trim_space(string(data)), " ")
	wv, wok := strconv.parse_int(strings.trim_space(ws))
	hv, hok := strconv.parse_int(strings.trim_space(hs))
	return wv, hv, wok && hok
}

window_size_save :: proc(w, h: int) {
	path, pok := config_path("window")
	if !pok {
		return
	}
	cfg_dir, _ := os.split_path(path)
	_ = os.make_directory_all(cfg_dir)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("%d %d", w, h))
}

impl App {
	recent_dirs_load :: proc() {
		path, ok := recent_file_path()
		if !ok {
			return
		}
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {
			return
		}
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(line)
			if t != "" && len(recent_dirs) < RECENT_DIRS_MAX {
				append(&recent_dirs, strings.clone(t))
			}
		}
	}

	// Move dir to the front (open_workspace calls this with the fresh cwd,
	// so the stored path is always absolute and canonical).
	recent_dirs_add :: proc(dir: string) {
		for i in 0 ..< len(recent_dirs) {
			if recent_dirs[i] == dir {
				delete(recent_dirs[i])
				ordered_remove(&recent_dirs, i)
				break
			}
		}
		inject_at(&recent_dirs, 0, strings.clone(dir))
		for len(recent_dirs) > RECENT_DIRS_MAX {
			delete(pop(&recent_dirs))
		}
		self.recent_dirs_save()
	}

	recent_dirs_save :: proc() {
		path, ok := recent_file_path()
		if !ok {
			return
		}
		cfg_dir, _ := os.split_path(path)
		_ = os.make_directory_all(cfg_dir)
		sb := strings.builder_make(context.temp_allocator)
		for dir in recent_dirs {
			strings.write_string(&sb, dir)
			strings.write_byte(&sb, '\n')
		}
		_ = os.write_entire_file(path, transmute([]u8)strings.to_string(sb))
	}
}
