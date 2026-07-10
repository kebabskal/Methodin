// medit — a tight little code editor, written in Methodin.
//
//     medit path/to/file.odin
//
// SDL3 + OpenGL 3.3. All editor logic lives in app.odin; this file owns the
// window, the event loop, the keymap, and the clipboard.
package medit

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

FONT_PT :: 15.0

@(private = "file") cursor_ibeam: ^sdl.Cursor
@(private = "file") cursor_arrow: ^sdl.Cursor

// Custom event type carrying a system file-dialog result back to the loop
// (the dialog callback may run on another thread; PushEvent is thread-safe).
@(private = "file") ev_file_picked: u32

@(private = "file")
DIALOG_OPEN :: 0
@(private = "file")
DIALOG_SAVE_AS :: 1
@(private = "file")
DIALOG_OPEN_DIR :: 2

@(private = "file") main_window: ^sdl.Window

// Package-visible so the palette's "Open Folder…" command can call it.
open_folder_dialog :: proc() {
	sdl.ShowOpenFolderDialog(dialog_done, rawptr(uintptr(DIALOG_OPEN_DIR)), main_window, nil, false)
}

@(private = "file")
dialog_done :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	if filelist == nil || filelist[0] == nil {
		return // failed or cancelled
	}
	e: sdl.Event
	e.type = sdl.EventType(ev_file_picked)
	e.user.code = i32(uintptr(userdata))
	e.user.data1 = rawptr(sdl.strdup(filelist[0])) // freed by the handler
	_ = sdl.PushEvent(&e)
}

// Dialogs and LSP URIs hand back absolute paths; strip the working directory
// prefix so they match the sidebar/palette style (and keep the title short).
shorten_path :: proc(path: string) -> string {
	fold :: proc(c: u8) -> u8 {
		switch {
		case c == '\\':
			return '/'
		case 'A' <= c && c <= 'Z':
			return c + 32
		}
		return c
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || len(path) <= len(cwd)+1 {
		return path
	}
	for i in 0 ..< len(cwd) {
		if fold(path[i]) != fold(cwd[i]) {
			return path
		}
	}
	if path[len(cwd)] != '\\' && path[len(cwd)] != '/' {
		return path
	}
	return path[len(cwd)+1:]
}

main :: proc() {
	path := ""
	if len(runtime.args__) > 1 {
		path = string(os.args[1])
		// A directory argument becomes the workspace: sidebar, file finder
		// and language server all root at the working directory.
		if fi, err := os.stat(path, context.temp_allocator); err == nil && fi.type == .Directory {
			if os.set_working_directory(path) == nil {
				path = ""
			}
		}
	}

	if !sdl.Init({.VIDEO, .EVENTS}) {
		fmt.eprintfln("medit: SDL init failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)

	title := fmt.ctprintf("medit — %s", path if path != "" else "[untitled]")
	window := sdl.CreateWindow(title, 1200, 800, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		fmt.eprintfln("medit: window creation failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(window)
	main_window = window

	glctx := sdl.GL_CreateContext(window)
	if glctx == nil {
		fmt.eprintfln("medit: GL context failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.GL_DestroyContext(glctx)
	sdl.GL_MakeCurrent(window, glctx)
	sdl.GL_SetSwapInterval(1)
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)

	scale := sdl.GetWindowDisplayScale(window)
	if scale <= 0 {
		scale = 1
	}

	rend: Renderer
	if !renderer_init(&rend, FONT_PT*scale) {
		os.exit(1)
	}
	defer renderer_destroy(&rend)

	app: App
	app_init(&app, path)
	defer app_destroy(&app)

	// While the user drags a window edge, the OS traps the event loop in a
	// modal resize loop and WaitEventTimeout never returns — the window would
	// stay black until release. Event watchers run synchronously from inside
	// that loop, so redraw from one.
	watch := Watch_Ctx{&app, &rend, window}
	_ = sdl.AddEventWatch(resize_watch, &watch)
	ev_file_picked = sdl.RegisterEvents(1)

	_ = sdl.StartTextInput(window)
	defer { _ = sdl.StopTextInput(window) }
	cursor_ibeam = sdl.CreateSystemCursor(.TEXT)
	cursor_arrow = sdl.CreateSystemCursor(.DEFAULT)
	defer sdl.DestroyCursor(cursor_ibeam)
	defer sdl.DestroyCursor(cursor_arrow)
	_ = sdl.SetCursor(cursor_ibeam)

	running := true
	for running {
		free_all(context.temp_allocator)
		app.now_ms = sdl.GetTicks()

		density := sdl.GetWindowPixelDensity(window)
		if density <= 0 {
			density = 1
		}

		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, 120) {
			for {
				if !handle_event(&app, &rend, window, &ev, density) {
					running = false
				}
				if !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		lsp_update(&app)
		lsp_poll(&app)
		app.lsp_hover_tick(rend.cell_w, rend.line_h)

		if app.want_follow {
			app.want_follow = false
			app.ensure_cursor_visible(rend.cell_w, rend.line_h)
		}

		if app.retitle {
			app.retitle = false
			t := fmt.ctprintf("medit — %s", app.buf.path if app.buf.path != "" else "[untitled]")
			_ = sdl.SetWindowTitle(window, t)
		}

		render_frame(&app, &rend, window)
	}
}

@(private = "file")
render_frame :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window) {
	pw, ph: c.int
	sdl.GetWindowSizeInPixels(window, &pw, &ph)
	frame_begin(rend, pw, ph, app.theme.bg)
	app.draw(rend, f32(pw), f32(ph))
	flush(rend)
	sdl.GL_SwapWindow(window)
}

@(private = "file")
Watch_Ctx :: struct {
	app:    ^App,
	rend:   ^Renderer,
	window: ^sdl.Window,
}

@(private = "file")
resize_watch :: proc "c" (userdata: rawptr, ev: ^sdl.Event) -> bool {
	#partial switch ev.type {
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		wc := (^Watch_Ctx)(userdata)
		if ev.window.windowID == sdl.GetWindowID(wc.window) {
			wc.app.now_ms = sdl.GetTicks()
			render_frame(wc.app, wc.rend, wc.window)
		}
	}
	return true
}

@(private = "file")
handle_event :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window, ev: ^sdl.Event, density: f32) -> bool {
	if ev_file_picked != 0 && u32(ev.type) == ev_file_picked {
		raw := string(cstring(ev.user.data1))
		switch ev.user.code {
		case DIALOG_OPEN:
			app.request_open(shorten_path(raw))
		case DIALOG_SAVE_AS:
			app.save_as(shorten_path(raw))
		case DIALOG_OPEN_DIR:
			app.open_workspace(raw)
		}
		sdl.free(ev.user.data1)
		return true
	}

	#partial switch ev.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return false

	case .KEY_DOWN:
		handle_key(app, rend, window, ev)

	case .TEXT_INPUT:
		text := string(ev.text.text)
		if len(text) > 0 {
			if app.palette.open {
				app.palette_insert(text)
			} else {
				app.insert_text(text)
				app.completion_after_insert(text)
				app.sighelp_after_insert(text)
				app.ensure_cursor_visible(rend.cell_w, rend.line_h)
			}
		}

	case .MOUSE_BUTTON_DOWN:
		app.hover_hide()
		app.completion_close()
		app.sighelp_close()
		px := ev.button.x * density
		py := ev.button.y * density
		if ev.button.button == sdl.BUTTON_LEFT {
			if app.palette.open {
				app.palette_mouse(px, py, rend.line_h)
			} else if px < app.sidebar_px {
				app.sidebar_click(py, rend.line_h)
			} else {
				mods := sdl.GetModState()
				p := app.pos_at_pixel(px, py, rend.cell_w, rend.line_h)
				if mods&sdl.KMOD_CTRL != {} && mods&sdl.KMOD_ALT == {} {
					// ctrl+click: go to definition; +shift: usages.
					app.click(p, app.vis_at_pixel(px, rend.cell_w), 1, false, false)
					app.mouse_up()
					if mods&sdl.KMOD_SHIFT != {} {
						app.lsp_find_references()
					} else {
						app.lsp_goto_definition()
					}
				} else {
					app.click(p, app.vis_at_pixel(px, rend.cell_w), int(ev.button.clicks),
						mods&sdl.KMOD_SHIFT != {},
						mods&sdl.KMOD_ALT != {})
				}
			}
		} else if ev.button.button == sdl.BUTTON_RIGHT && !app.palette.open {
			if px < app.sidebar_px {
				app.sidebar_context(py, rend.line_h)
			} else {
				app.right_click(app.pos_at_pixel(px, py, rend.cell_w, rend.line_h))
			}
		}

	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_LEFT {
			app.mouse_up()
		}

	case .MOUSE_MOTION:
		_ = sdl.SetCursor(cursor_arrow if ev.motion.x*density < app.sidebar_px else cursor_ibeam)
		app.hover_motion(ev.motion.x*density, ev.motion.y*density, rend.cell_w, rend.line_h)
		if app.selecting && !app.palette.open {
			p := app.pos_at_pixel(ev.motion.x*density, ev.motion.y*density, rend.cell_w, rend.line_h)
			app.drag(p, app.vis_at_pixel(ev.motion.x*density, rend.cell_w))
			app.ensure_cursor_visible(rend.cell_w, rend.line_h)
		}

	case .MOUSE_WHEEL:
		app.hover_hide()
		app.completion_close()
		app.sighelp_close()
		dy := ev.wheel.y
		dx := ev.wheel.x
		if ev.wheel.direction == .FLIPPED {
			dy = -dy
			dx = -dx
		}
		if app.palette.open {
			app.palette_wheel(dy)
		} else if ev.wheel.mouse_x*density < app.sidebar_px {
			// Over the sidebar: scroll the tree (clamped next draw).
			app.sidebar.scroll_y -= dy * rend.line_h * 3
		} else {
			app.scroll_y -= dy * rend.line_h * 3
			app.scroll_x += dx * rend.cell_w * 6
			app.clamp_scroll(rend.line_h)
		}
	}

	return true
}

@(private = "file")
handle_key :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window, ev: ^sdl.Event) {
	app.hover_hide()
	mod := ev.key.mod
	ctrl := mod&sdl.KMOD_CTRL != {} || mod&sdl.KMOD_GUI != {} // cmd == ctrl on macOS
	shift := mod&sdl.KMOD_SHIFT != {}
	alt := mod&sdl.KMOD_ALT != {}
	key := ev.key.key

	page_lines := max(1, int(app.view_h/rend.line_h)-2)
	follow := true
	defer if follow {
		app.ensure_cursor_visible(rend.cell_w, rend.line_h)
	}

	// The palette swallows all keys while open.
	if app.palette.open {
		follow = false
		switch {
		case key == sdl.K_ESCAPE:
			app.palette_cancel()
		case key == sdl.K_RETURN || key == sdl.K_KP_ENTER:
			app.palette_accept()
		case key == sdl.K_UP:
			app.palette_move(-1)
		case key == sdl.K_DOWN:
			app.palette_move(1)
		case key == sdl.K_PAGEUP:
			app.palette_move(-10)
		case key == sdl.K_PAGEDOWN:
			app.palette_move(10)
		case key == sdl.K_HOME:
			app.palette_caret_move(-2)
		case key == sdl.K_END:
			app.palette_caret_move(2)
		case key == sdl.K_LEFT:
			app.palette_caret_move(-1)
		case key == sdl.K_RIGHT:
			app.palette_caret_move(1)
		case key == sdl.K_BACKSPACE:
			app.palette_backspace()
		case key == sdl.K_DELETE:
			app.palette_delete_forward()
		case ctrl && key == sdl.K_V:
			app.palette_insert(clipboard_get())
		case ctrl && key == sdl.K_PERIOD:
			app.palette_context_here()
		case ctrl && key == sdl.K_P:
			app.palette_cancel()
		}
		return
	}

	// The completion popup claims navigation/accept keys; everything else
	// falls through (typing keeps filtering via TEXT_INPUT).
	if app.completion.open {
		handled := true
		switch {
		case key == sdl.K_ESCAPE:
			app.completion_close()
		case key == sdl.K_UP && !ctrl && !alt:
			app.completion_move(-1)
		case key == sdl.K_DOWN && !ctrl && !alt:
			app.completion_move(1)
		case key == sdl.K_PAGEUP:
			app.completion_move(-COMPLETION_VISIBLE)
		case key == sdl.K_PAGEDOWN:
			app.completion_move(COMPLETION_VISIBLE)
		case key == sdl.K_TAB || key == sdl.K_RETURN || key == sdl.K_KP_ENTER:
			app.completion_accept()
		case:
			handled = false
			// Cursor movement and command chords invalidate the popup;
			// backspace/delete keep filtering, bare modifiers are inert.
			is_mod := key == sdl.K_LSHIFT || key == sdl.K_RSHIFT ||
				key == sdl.K_LCTRL || key == sdl.K_RCTRL ||
				key == sdl.K_LALT || key == sdl.K_RALT ||
				key == sdl.K_LGUI || key == sdl.K_RGUI
			if ((ctrl || alt) && !is_mod) ||
			   key == sdl.K_LEFT || key == sdl.K_RIGHT ||
			   key == sdl.K_HOME || key == sdl.K_END {
				app.completion_close()
			}
		}
		if handled {
			return
		}
	}

	if app.sighelp.open {
		switch {
		case key == sdl.K_ESCAPE:
			app.sighelp_close()
			return
		case key == sdl.K_UP, key == sdl.K_DOWN, key == sdl.K_PAGEUP, key == sdl.K_PAGEDOWN,
		     key == sdl.K_RETURN, key == sdl.K_KP_ENTER:
			app.sighelp_close() // and fall through to the normal action
		}
	}

	switch {
	// --- multi-cursor ---
	case ctrl && alt && key == sdl.K_UP:
		app.add_cursor_line(below = false)
	case ctrl && alt && key == sdl.K_DOWN:
		app.add_cursor_line(below = true)
	case alt && key == sdl.K_UP:
		app.move_lines(down = false)
	case alt && key == sdl.K_DOWN:
		app.move_lines(down = true)
	case ctrl && shift && key == sdl.K_D:
		app.duplicate()
	case ctrl && key == sdl.K_D:
		app.select_next_match()
	case ctrl && key == sdl.K_U:
		app.undo_selection()
	case key == sdl.K_ESCAPE:
		app.escape()

	// --- movement ---
	case key == sdl.K_LEFT:
		app.move_cursors(.Word_Left if ctrl else .Left, shift)
	case key == sdl.K_RIGHT:
		app.move_cursors(.Word_Right if ctrl else .Right, shift)
	case key == sdl.K_UP:
		app.move_cursors(.Up, shift)
	case key == sdl.K_DOWN:
		app.move_cursors(.Down, shift)
	case key == sdl.K_HOME:
		app.move_cursors(.Doc_Start if ctrl else .Line_Start, shift)
	case key == sdl.K_END:
		app.move_cursors(.Doc_End if ctrl else .Line_End, shift)
	case key == sdl.K_PAGEUP:
		app.move_page(true, shift, page_lines)
	case key == sdl.K_PAGEDOWN:
		app.move_page(false, shift, page_lines)

	// --- editing ---
	case key == sdl.K_RETURN || key == sdl.K_KP_ENTER:
		app.insert_newline()
	case key == sdl.K_BACKSPACE:
		app.delete_backward()
		app.completion_after_backspace()
		if app.sighelp.open {
			app.sighelp_trigger()
		}
	case key == sdl.K_DELETE:
		app.delete_forward()
	case key == sdl.K_TAB:
		if shift {
			app.dedent()
		} else {
			app.indent()
		}

	// --- commands ---
	case ctrl && shift && key == sdl.K_P:
		app.palette_open_with(">")
		follow = false
	case ctrl && key == sdl.K_P:
		app.palette_open_with("")
		follow = false
	case ctrl && key == sdl.K_B:
		app.sidebar.visible = !app.sidebar.visible
		follow = false
	case ctrl && key == sdl.K_A:
		app.select_all()
		follow = false
	case ctrl && key == sdl.K_APOSTROPHE:
		app.toggle_comment()
	case ctrl && key == sdl.K_PERIOD:
		app.open_context_editor()
		follow = false
	case ctrl && key == sdl.K_SPACE:
		app.completion_trigger()
	case ctrl && key == sdl.K_G:
		app.lsp_goto_definition()
		follow = false
	case ctrl && key == sdl.K_H:
		app.lsp_find_references()
		follow = false
	case key == sdl.K_F2:
		app.lsp_rename_prompt()
		follow = false
	case ctrl && key == sdl.K_N:
		app.new_file()
		follow = false
	case ctrl && key == sdl.K_O:
		sdl.ShowOpenFileDialog(dialog_done, rawptr(uintptr(DIALOG_OPEN)), window, nil, 0, nil, false)
		follow = false
	case ctrl && key == sdl.K_S:
		if app.buf.path == "" {
			// Untitled: pick a path first.
			sdl.ShowSaveFileDialog(dialog_done, rawptr(uintptr(DIALOG_SAVE_AS)), window, nil, 0, nil)
		} else {
			app.save()
		}
		follow = false
	case ctrl && shift && key == sdl.K_Z, ctrl && key == sdl.K_Y:
		app.redo()
	case ctrl && key == sdl.K_Z:
		app.undo()
	case ctrl && key == sdl.K_C:
		clipboard_set(app.copy_text())
		follow = false
	case ctrl && key == sdl.K_X:
		clipboard_set(app.cut_text())
	case ctrl && key == sdl.K_V:
		app.paste(clipboard_get())
	case:
		follow = false
	}
}

// Package-visible: the palette's context actions copy paths and text.
clipboard_set :: proc(text: string) {
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	sdl.SetClipboardText(ctext)
}

clipboard_get :: proc() -> string {
	raw := sdl.GetClipboardText()
	defer sdl.free(raw)
	text := strings.clone(string(cstring(raw)), context.temp_allocator)
	// Normalize Windows line endings; the buffer stores bare '\n'.
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return text
}
