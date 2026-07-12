// medit — settings files. Two INI files, the user-wide one and a per-project
// overlay; both contribute:
//
//   <user config>/medit/settings.ini    ">Settings: Open Settings"
//   .medit/settings.ini                 ">Settings: Open Project Settings"
//
// Read at startup, on workspace switch, when saved from a medit tab, and on
// window focus (so external edits count too). The palette's Settings/Theme
// commands and the sidebar/panel resize drags write their keys back into
// the user-wide file (settings_save_key). Currently:
//
//   [ui]
//   theme = tokyo-night       ; see THEMES in theme.odin
//   sidebar-cells = 32        ; sidebar width in text columns
//   output-rows = 12          ; output panel height in rows
//   [editor]
//   tab-width = 2
//   smart-word = true         ; word movement stops at subwords
//   format-on-save = true
//   outline-fields = false    ; fields/enum members in the outline
//   [files]
//   hide = *.exe *.pdb bin    ; globs hidden from the file tree
package medit

import "core:encoding/ini"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

PROJECT_SETTINGS_PATH :: ".medit/settings.ini"

SETTINGS_TEMPLATE :: `; medit settings — the project's .medit/settings.ini adds to the user-wide one.
; The palette's Settings/Theme commands keep the user-wide file up to date.
[ui]
; color theme: tokyo-night, tokyo-day, paper, gruvbox
theme = tokyo-night
; sidebar-cells = 32   ; sidebar width in text columns (drag its border)
; output-rows = 12     ; output panel height in rows (drag its top edge)
; panel-cols = 0.24 0.28 ; debug column widths (drag their dividers)

[editor]
; tab-width = 2        ; the palette cycles 2/4/8
; smart-word = true    ; word movement stops at subwords
; format-on-save = true
; outline-fields = false ; fields/enum members in the outline

[files]
; space-separated globs hidden from the file tree, e.g.:
; hide = *.exe *.pdb *.obj bin
hide =
`

@(private = "file")
settings_bool :: proc(value: string) -> bool {
	v := strings.trim_space(value)
	return v == "true" || v == "1" || v == "on"
}

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
		if it.section == "ui" {
			switch key {
			case "theme":
				if t, ok := theme_by_name(strings.trim_space(value)); ok {
					app.theme = t
				}
			case "sidebar-cells":
				if v, vok := strconv.parse_f32(strings.trim_space(value)); vok {
					sidebar_cells = clamp(v, 14, 90)
				}
			case "output-rows":
				if v, vok := strconv.parse_int(strings.trim_space(value)); vok {
					output_rows = clamp(v, 3, 40)
				}
			case "panel-cols":
				f := strings.fields(value, context.temp_allocator)
				if len(f) == 2 {
					if v, vok := strconv.parse_f32(f[0]); vok {
						app.task.stack_frac = clamp(v, 0.08, 0.5)
					}
					if v, vok := strconv.parse_f32(f[1]); vok {
						app.task.locals_frac = clamp(v, 0.08, 0.5)
					}
				}
			}
		}
		if it.section == "editor" {
			switch key {
			case "tab-width":
				if v, vok := strconv.parse_int(strings.trim_space(value)); vok {
					tab_w = clamp(v, 1, 16)
				}
			case "smart-word":
				smart_word = settings_bool(value)
			case "format-on-save":
				app.format_on_save = settings_bool(value)
			case "outline-fields":
				app.outline_fields = settings_bool(value)
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

// Persist one key into the user settings.ini: replace the first `key`
// line of [section], or append the section (last key wins on load, so a
// trailing section also overrides an untouched earlier one).
settings_save_key :: proc(section, key, value: string) -> bool {
	path, ok := settings_user_path()
	if !ok {
		return false
	}
	src := ""
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		src = string(data)
	} else {
		src = SETTINGS_TEMPLATE
	}

	sb := strings.builder_make(context.temp_allocator)
	cur := ""
	replaced := false
	rest := src
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") && strings.has_suffix(t, "]") {
			cur = t[1:len(t)-1]
		}
		if !replaced && cur == section {
			if k, eq, _ := strings.partition(t, "="); eq == "=" &&
			   strings.trim_space(k) == key {
				strings.write_string(&sb, key)
				strings.write_string(&sb, " = ")
				strings.write_string(&sb, value)
				strings.write_byte(&sb, '\n')
				replaced = true
				continue
			}
		}
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}
	if !replaced {
		strings.write_string(&sb, "\n[")
		strings.write_string(&sb, section)
		strings.write_string(&sb, "]\n")
		strings.write_string(&sb, key)
		strings.write_string(&sb, " = ")
		strings.write_string(&sb, value)
		strings.write_byte(&sb, '\n')
	}

	if dir, _ := os.split_path(path); dir != "" {
		_ = os.make_directory_all(dir)
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(sb)) == nil
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
