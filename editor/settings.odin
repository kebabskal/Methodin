// medit — settings files. Two INI files, the user-wide one and a per-project
// overlay; both contribute:
//
//   <user config>/medit/settings.ini    ">Settings: Open Settings"
//   .medit/settings.ini                 ">Settings: Open Project Settings"
//
// Read at startup, on workspace switch, when saved from a medit tab, and on
// window focus (so external edits count too). Currently:
//
//   [files]
//   hide = *.exe *.pdb bin    ; globs hidden from the file tree
package medit

import "core:encoding/ini"
import "core:os"
import "core:path/filepath"
import "core:strings"

PROJECT_SETTINGS_PATH :: ".medit/settings.ini"

SETTINGS_TEMPLATE :: `; medit settings — the project's .medit/settings.ini adds to the user-wide one.
[files]
; space-separated globs hidden from the file tree, e.g.:
; hide = *.exe *.pdb *.obj bin
hide =
`

settings_user_path :: proc() -> (string, bool) {
	cfg, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	path, jerr := filepath.join({cfg, "medit", "settings.ini"}, context.temp_allocator)
	return path, jerr == nil
}

// Parse one settings source, appending to the app's state.
settings_parse :: proc(app: ^App, src: string) {
	it := ini.iterator_from_string(src)
	for key, value in ini.iterate(&it) {
		if it.section == "files" && key == "hide" {
			globs := strings.fields(value, context.temp_allocator)
			for g in globs {
				append(&app.sidebar.hide, strings.clone(g))
			}
		}
	}
}

// (Re)read the user and project settings.
settings_load :: proc(app: ^App) {
	for g in app.sidebar.hide {
		delete(g)
	}
	clear(&app.sidebar.hide)
	if up, ok := settings_user_path(); ok {
		if data, err := os.read_entire_file(up, context.temp_allocator); err == nil {
			settings_parse(app, string(data))
		}
	}
	if data, err := os.read_entire_file(PROJECT_SETTINGS_PATH, context.temp_allocator); err == nil {
		settings_parse(app, string(data))
	}
}

// Does name match any of the hide globs?
settings_hidden :: proc(name: string, hide: []string) -> bool {
	for g in hide {
		if m, err := filepath.match(g, name); err == nil && m {
			return true
		}
	}
	return false
}

impl App {
	// Open the user or project settings file, creating it (with a template)
	// on first use.
	settings_open :: proc(project: bool) {
		path := PROJECT_SETTINGS_PATH
		if !project {
			up, ok := settings_user_path()
			if !ok {
				self.set_status("no user config directory")
				return
			}
			path = up
		}
		if !os.exists(path) {
			if dir, _ := os.split_path(path); dir != "" {
				_ = os.make_directory_all(dir)
			}
			if os.write_entire_file(path, SETTINGS_TEMPLATE) != nil {
				self.set_status("could not create settings file")
				return
			}
			if project {
				sidebar_refresh(&sidebar)
			}
		}
		self.open_file(path)
	}
}
