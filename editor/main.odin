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
FONT_PT_MIN :: 7.0
FONT_PT_MAX :: 40.0

// Current font size; ctrl +/-/0 adjusts it at runtime.
@(private = "file") font_pt: f32 = FONT_PT

@(private = "file") cursor_ibeam: ^sdl.Cursor
@(private = "file") cursor_arrow: ^sdl.Cursor
@(private = "file") cursor_hand: ^sdl.Cursor
@(private = "file") cursor_ew: ^sdl.Cursor
@(private = "file") cursor_ns: ^sdl.Cursor

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

// One cmd+w press can arrive twice on macOS: as a KEY_DOWN and as the window
// menu's Close action (WINDOW_CLOSE_REQUESTED). Each source stamps its tab
// close so the other can skip the duplicate — without suppressing repeats
// from the same source (holding ctrl+w keeps closing on Linux/Windows).
@(private = "file") close_key_ms: u64
@(private = "file") close_req_ms: u64

@(private = "file")
CLOSE_DEDUP_MS :: 500

// Package-visible so the palette's "Open Folder…" command can call it.
open_folder_dialog :: proc() {
	sdl.ShowOpenFolderDialog(dialog_done, rawptr(uintptr(DIALOG_OPEN_DIR)), main_window, nil, false)
}

// Keys whose held-down repeats may be dropped when frames fall behind:
// movement and single-step deletion, where each step is visible feedback.
// Typing (TEXT_INPUT) is never dropped.
@(private = "file")
coalesce_repeat :: proc(key: sdl.Keycode) -> bool {
	switch key {
	case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_UP, sdl.K_DOWN,
	     sdl.K_PAGEUP, sdl.K_PAGEDOWN, sdl.K_HOME, sdl.K_END,
	     sdl.K_BACKSPACE, sdl.K_DELETE:
		return true
	}
	return false
}

// Package-visible so the palette's "Quit" command can call it. Pushes a
// regular .QUIT event, so the unsaved-changes guard still gets its say.
request_quit :: proc() {
	e: sdl.Event
	e.type = .QUIT
	_ = sdl.PushEvent(&e)
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

	// By default SDL also posts QUIT when the last (only) window asks to
	// close; that would turn a cmd+w tab close into an app exit. Quitting is
	// handled explicitly in handle_event instead.
	_ = sdl.SetHint(sdl.HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0")

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
	// A roomy default, clamped to the display; the size of the previous run
	// wins when there was one (saved on quit).
	usable := sdl.Rect{0, 0, 3840, 2160}
	_ = sdl.GetDisplayUsableBounds(sdl.GetPrimaryDisplay(), &usable)
	win_w := min(c.int(1700), usable.w - 60)
	win_h := min(c.int(1050), usable.h - 60)
	if w, h, wok := window_size_load(); wok {
		win_w = clamp(c.int(w), 640, usable.w)
		win_h = clamp(c.int(h), 480, usable.h)
	}
	// Borderless: the tab bar doubles as the title bar (drag, window buttons);
	// hit_test below tells the OS which regions drag and resize.
	window := sdl.CreateWindow(title, win_w, win_h, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY, .BORDERLESS})
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

	// The zoom level survives restarts (ctrl+0 still resets to FONT_PT).
	if pt, zok := zoom_pt_load(); zok {
		font_pt = clamp(pt, FONT_PT_MIN, FONT_PT_MAX)
	}

	rend: Renderer
	if !renderer_init(&rend, font_pt*scale) {
		os.exit(1)
	}
	defer renderer_destroy(&rend)

	app: App
	app_init(&app, path)
	app.recent_dirs_load()
	defer app_destroy(&app)

	// While the user drags a window edge, the OS traps the event loop in a
	// modal resize loop and WaitEventTimeout never returns — the window would
	// stay black until release. Event watchers run synchronously from inside
	// that loop, so redraw from one.
	watch := Watch_Ctx{&app, &rend, window}
	_ = sdl.AddEventWatch(resize_watch, &watch)
	_ = sdl.SetWindowHitTest(window, hit_test, &app)
	ev_file_picked = sdl.RegisterEvents(1)

	_ = sdl.StartTextInput(window)
	defer { _ = sdl.StopTextInput(window) }
	cursor_ibeam = sdl.CreateSystemCursor(.TEXT)
	cursor_arrow = sdl.CreateSystemCursor(.DEFAULT)
	cursor_hand = sdl.CreateSystemCursor(.POINTER)
	cursor_ew = sdl.CreateSystemCursor(.EW_RESIZE)
	cursor_ns = sdl.CreateSystemCursor(.NS_RESIZE)
	defer sdl.DestroyCursor(cursor_ibeam)
	defer sdl.DestroyCursor(cursor_arrow)
	defer sdl.DestroyCursor(cursor_hand)
	defer sdl.DestroyCursor(cursor_ew)
	defer sdl.DestroyCursor(cursor_ns)
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
			// Key-repeat can outpace vsync'd frames; extra repeats would
			// queue up and play out after release, sailing the cursor past
			// where the user saw it. Cap repeats at one per key per frame
			// for keys whose effect must track the screen.
			seen: [8]sdl.Keycode
			seen_n := 0
			for {
				skip := false
				if ev.type == .KEY_DOWN && ev.key.repeat && coalesce_repeat(ev.key.key) {
					for i in 0 ..< seen_n {
						if seen[i] == ev.key.key {
							skip = true
						}
					}
					if !skip && seen_n < len(seen) {
						seen[seen_n] = ev.key.key
						seen_n += 1
					}
				}
				if !skip && !handle_event(&app, &rend, window, &ev, density) {
					running = false
				}
				if !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		if app.zoom_req != .None {
			zoom(&app, &rend, window, app.zoom_req)
			app.zoom_req = .None
		}

		lsp_update(&app)
		lsp_poll(&app)
		task_poll(&app)
		dap_poll(&app)
		app.format_save_tick()
		app.lsp_hover_tick(rend.cell_w, rend.line_h)

		if app.want_follow {
			app.want_follow = false
			app.ensure_cursor_visible(rend.cell_w, rend.line_h, center = app.want_center)
			app.want_center = false
		}

		if app.retitle {
			app.retitle = false
			t := fmt.ctprintf("medit — %s", app.buf.path if app.buf.path != "" else "[untitled]")
			_ = sdl.SetWindowTitle(window, t)
		}

		render_frame(&app, &rend, window)
	}

	// The window size survives restarts.
	ww, wh: c.int
	if sdl.GetWindowSize(window, &ww, &wh) {
		window_size_save(int(ww), int(wh))
	}
}

// Change the font size: rebuild the glyph atlas and rescale every pixel
// scroll so each view keeps showing the same spot.
@(private = "file")
zoom :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window, req: Zoom_Req) {
	old_pt := font_pt
	switch req {
	case .In:
		font_pt = min(font_pt+1, FONT_PT_MAX)
	case .Out:
		font_pt = max(font_pt-1, FONT_PT_MIN)
	case .Reset:
		font_pt = FONT_PT
	case .None:
		return
	}
	if font_pt == old_pt {
		return
	}
	scale := sdl.GetWindowDisplayScale(window)
	if scale <= 0 {
		scale = 1
	}
	old_cell := rend.cell_w
	old_line := rend.line_h
	if !renderer_build_atlas(rend, font_pt*scale) {
		font_pt = old_pt // atlas kept the old glyphs; keep the old size
		app.set_status("could not rebuild the font atlas at that size")
		return
	}
	kx := rend.cell_w / old_cell
	ky := rend.line_h / old_line
	app.scroll_x *= kx
	app.scroll_y *= ky
	for &d, i in app.docs {
		if i != app.active {
			d.scroll_x *= kx
			d.scroll_y *= ky
		}
	}
	app.sidebar.scroll_y *= ky
	app.tab_follow = true
	zoom_pt_save(font_pt)
	app.set_status(fmt.tprintf("font size: %.0f pt", font_pt))
}

@(private = "file")
render_frame :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window) {
	// Hot reload: each reload dylib carries its own (zeroed) copies of
	// vendor:OpenGL's impl_* function pointers — dependency-package globals
	// are not shared with the host. Reload them once per code generation.
	// (gl.Viewport itself is a wrapper proc, never nil — the loaded pointer
	// behind it is impl_Viewport.)
	if gl.impl_Viewport == nil {
		gl.load_up_to(3, 3, sdl.gl_set_proc_address)
	}
	pw, ph: c.int
	sdl.GetWindowSizeInPixels(window, &pw, &ph)
	frame_begin(rend, pw, ph, app.theme.bg)
	app.draw(rend, f32(pw), f32(ph))
	flush(rend)
	sdl.GL_SwapWindow(window)
}

// Tell the OS which parts of the borderless window drag and resize it.
// Buttons and tabs return NORMAL so they keep receiving clicks; the rest of
// the tab bar is the drag region.
@(private = "file")
hit_test :: proc "c" (win: ^sdl.Window, area: ^sdl.Point, data: rawptr) -> sdl.HitTestResult {
	context = runtime.default_context()
	app := (^App)(data)

	// Resize borders (window coordinates, generous edges).
	w, h: c.int
	_ = sdl.GetWindowSize(win, &w, &h)
	M :: 6
	l := area.x < M
	rt := area.x >= w-M
	t := area.y < M
	b := area.y >= h-M
	switch {
	case t && l:
		return .RESIZE_TOPLEFT
	case t && rt:
		return .RESIZE_TOPRIGHT
	case b && l:
		return .RESIZE_BOTTOMLEFT
	case b && rt:
		return .RESIZE_BOTTOMRIGHT
	case t:
		return .RESIZE_TOP
	case b:
		return .RESIZE_BOTTOM
	case l:
		return .RESIZE_LEFT
	case rt:
		return .RESIZE_RIGHT
	}

	density := sdl.GetWindowPixelDensity(win)
	if density <= 0 {
		density = 1
	}
	px := f32(area.x) * density
	py := f32(area.y) * density
	if py < app.tabbar_h {
		if app.traffic_hit(px, py) >= 0 {
			return .NORMAL
		}
		for rect in app.tab_rects {
			if px >= rect[0] && px < rect[1] {
				return .NORMAL
			}
		}
		return .DRAGGABLE
	}
	return .NORMAL
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
			app.open_file(shorten_path(raw))
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
		// On macOS cmd+w also triggers the window menu's Close item, arriving
		// here as well as as a key event; it means "close tab", not quit.
		if ev.type == .WINDOW_CLOSE_REQUESTED {
			mods := sdl.GetModState()
			if mods&sdl.KMOD_GUI != {} || mods&sdl.KMOD_CTRL != {} {
				if close_key_ms == 0 || app.now_ms-close_key_ms > CLOSE_DEDUP_MS {
					close_req_ms = app.now_ms
					app.tab_close(app.active)
				}
				return true
			}
		}
		// Quitting over unsaved changes takes a second attempt.
		dirty := 0
		for i in 0 ..< len(app.docs) {
			if app.doc_buf(i).is_dirty() {
				dirty += 1
			}
		}
		if dirty > 0 && !app.pending_quit {
			app.pending_quit = true
			app.set_status(fmt.tprintf("%d unsaved file(s) — close again to quit anyway", dirty))
			return true
		}
		return false

	case .WINDOW_FOCUS_GAINED:
		app.focused = true
		app.blink_reset() // start with a full visible phase
		// Coming back from elsewhere: files (or settings) may have changed.
		settings_load(app)
		sidebar_refresh(&app.sidebar)

	case .WINDOW_FOCUS_LOST:
		app.focused = false

	case .KEY_DOWN:
		app.pending_quit = false
		handle_key(app, rend, window, ev)

	case .TEXT_INPUT:
		text := string(ev.text.text)
		if len(text) > 0 {
			if app.palette.open {
				app.palette_insert(text)
			} else if app.task.filter_focus {
				append(&app.task.filter, text)
			} else {
				app.type_text(text)
				app.completion_after_insert(text)
				app.sighelp_after_insert(text)
				app.ensure_cursor_visible(rend.cell_w, rend.line_h)
			}
		}

	case .MOUSE_BUTTON_DOWN:
		app.pending_quit = false
		app.hover_hide()
		app.completion_close()
		app.sighelp_close()
		px := ev.button.x * density
		py := ev.button.y * density
		if ev.button.button == sdl.BUTTON_LEFT {
			app.task.filter_focus = false // clicks re-focus (locals header re-arms it)
			if app.palette.open {
				app.palette_mouse(px, py, rend.cell_w, rend.line_h)
			} else if app.edge_hover != 0 {
				app.resizing = app.edge_hover // grab the hovered resize edge
			} else if py < app.tabbar_h {
				switch app.traffic_hit(px, py) {
				case 0: // close: through the regular quit path (dirty guard)
					e: sdl.Event
					e.type = .QUIT
					_ = sdl.PushEvent(&e)
				case 1:
					_ = sdl.MinimizeWindow(window)
				case 2:
					fs := sdl.GetWindowFlags(window)&sdl.WINDOW_FULLSCREEN != {}
					_ = sdl.SetWindowFullscreen(window, !fs)
				case:
					app.tabbar_click(px, rend.cell_w, 0)
				}
			} else if app.task.open && py >= app.task.top && py < app.task.top+app.task.h {
				app.task_click(px, py, rend.cell_w)
			} else if app.problems_open && py >= app.problems_top && py < app.problems_top+app.problems_h {
				// Before the sidebar: the panel spans the full width.
				app.problems_click(px, py)
			} else if px < app.sidebar_px {
				app.sidebar_click(py, rend.line_h)
			} else if px < app.gutter_px-rend.cell_w {
				// The gutter: toggle a breakpoint on that line.
				line := clamp(int((py-app.tabbar_h+app.scroll_y)/rend.line_h), 0, app.buf.line_count()-1)
				app.breakpoint_toggle(app.buf.path, line)
			} else {
				mods := sdl.GetModState()
				p := app.pos_at_pixel(px, py, rend.cell_w, rend.line_h)
				cmd := mods&sdl.KMOD_CTRL != {} || mods&sdl.KMOD_GUI != {} // cmd == ctrl on macOS
				if cmd && mods&sdl.KMOD_ALT == {} {
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
			if py < app.tabbar_h {
				app.tabbar_click(px, rend.cell_w, 2)
			} else if app.task.open && py >= app.task.top {
				app.task_context(px, py)
			} else if app.problems_open && py >= app.problems_top {
				// No context menu; must not fall through to the editor text.
			} else if px < app.sidebar_px {
				app.sidebar_context(py, rend.line_h)
			} else {
				app.right_click(app.pos_at_pixel(px, py, rend.cell_w, rend.line_h))
			}
		} else if ev.button.button == sdl.BUTTON_MIDDLE && !app.palette.open {
			if py < app.tabbar_h {
				app.tabbar_click(px, rend.cell_w, 1)
			}
		}

	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_LEFT {
			// A finished sidebar/panel resize is worth keeping.
			if app.resizing == 1 {
				_ = settings_save_key("ui", "sidebar-cells", fmt.tprintf("%.0f", sidebar_cells))
			} else if app.resizing == 2 {
				_ = settings_save_key("ui", "output-rows", fmt.tprintf("%d", output_rows))
			}
			app.resizing = 0
			app.task_drag_end(ev.button.x*density, ev.button.y*density, rend.cell_w)
			app.mouse_up()
		}

	case .MOUSE_MOTION:
		if app.resizing == 1 {
			sidebar_cells = clamp(ev.motion.x*density/rend.cell_w, 14, 90)
			return true
		} else if app.resizing == 2 {
			// The panel bottom edge is fixed; rows follow the dragged top.
			bottom := app.task.top + app.task.h
			output_rows = clamp(int((bottom-ev.motion.y*density-rend.line_h*PANEL_HEAD_SCALE)/(rend.line_h*PANEL_ROW_SCALE)), 3, 40)
			return true
		}
		over_ui := app.palette.open ||
			ev.motion.x*density < app.sidebar_px || ev.motion.y*density < app.tabbar_h ||
			(app.problems_open && ev.motion.y*density >= app.problems_top) ||
			(app.task.open && ev.motion.y*density >= app.task.top)
		over_link := app.task_motion(ev.motion.x*density, ev.motion.y*density, rend.cell_w) &&
			!app.palette.open
		// Resize edges: generous grab zones with cursor feedback.
		app.edge_hover = 0
		if !app.palette.open && ev.motion.y*density > app.tabbar_h {
			if app.task.open && abs(ev.motion.y*density-app.task.top) < 8 {
				app.edge_hover = 2
			} else if app.sidebar_px > 0 && abs(ev.motion.x*density-app.sidebar_px) < 8 {
				app.edge_hover = 1
			}
		}
		cur := cursor_hand if over_link else cursor_arrow if over_ui else cursor_ibeam
		if app.edge_hover == 1 || app.resizing == 1 {
			cur = cursor_ew
		} else if app.edge_hover == 2 || app.resizing == 2 {
			cur = cursor_ns
		}
		_ = sdl.SetCursor(cur)
		app.hover_motion(ev.motion.x*density, ev.motion.y*density, rend.cell_w, rend.line_h)
		if app.palette.open {
			app.palette_motion(ev.motion.x*density, ev.motion.y*density, rend.line_h)
		}
		if app.selecting && !app.palette.open {
			p := app.pos_at_pixel(ev.motion.x*density, ev.motion.y*density, rend.cell_w, rend.line_h)
			app.drag(p, app.vis_at_pixel(ev.motion.x*density, rend.cell_w))
			app.ensure_cursor_visible(rend.cell_w, rend.line_h)
		}

	case .MOUSE_WHEEL:
		app.hover_hide()
		app.completion_close()
		app.sighelp_close()
		// Deltas already follow the system scroll direction (macOS natural
		// scrolling arrives as .FLIPPED values); use them as-is so content
		// tracks the fingers, and momentum events just keep scrolling.
		dy := ev.wheel.y
		dx := ev.wheel.x
		mods := sdl.GetModState()
		if mods&sdl.KMOD_CTRL != {} || mods&sdl.KMOD_GUI != {} {
			// Zoom wants the physical direction: wheel/fingers up = in.
			zy := -dy if ev.wheel.direction == .FLIPPED else dy
			if zy != 0 {
				app.zoom_req = .In if zy > 0 else .Out
			}
		} else if app.palette.open {
			app.palette_wheel(dy, rend.line_h)
		} else if ev.wheel.mouse_y*density < app.tabbar_h {
			// Over the tab bar: scroll the tabs (clamped next draw).
			app.tab_scroll -= (dy + dx) * rend.cell_w * 6
		} else if app.task.open && ev.wheel.mouse_y*density >= app.task.top &&
		   ev.wheel.mouse_y*density < app.task.top+app.task.h {
			// Over the task output panel: scroll its lines (or a column).
			app.task_wheel(dy, rend.cell_w, ev.wheel.mouse_x*density)
		} else if app.problems_open && ev.wheel.mouse_y*density >= app.problems_top &&
		   ev.wheel.mouse_y*density < app.problems_top+app.problems_h {
			// Over the problems panel: scroll its rows (clamped next draw).
			app.problems_scroll -= dy
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
			app.palette_caret_move(-2, extend = shift)
		case key == sdl.K_END:
			app.palette_caret_move(2, extend = shift)
		case key == sdl.K_LEFT:
			app.palette_caret_move(-1, extend = shift, word = ctrl)
		case key == sdl.K_RIGHT:
			app.palette_caret_move(1, extend = shift, word = ctrl)
		case key == sdl.K_BACKSPACE:
			app.palette_backspace()
		case key == sdl.K_DELETE:
			app.palette_delete_forward()
		case ctrl && key == sdl.K_A:
			app.palette_select_all()
		case ctrl && key == sdl.K_C:
			app.palette_copy(cut = false)
		case ctrl && key == sdl.K_X:
			app.palette_copy(cut = true)
		case ctrl && key == sdl.K_V:
			app.palette_insert(clipboard_get())
		case ctrl && key == sdl.K_PERIOD:
			app.palette_context_here()
		// Another palette hotkey while open: switch modes in place, no esc
		// needed (the original view/cursors stay saved for esc).
		case ctrl && shift && key == sdl.K_P:
			app.palette_open_with(">")
		case ctrl && key == sdl.K_P:
			app.palette_toggle_files()
		case ctrl && key == sdl.K_E:
			app.palette_open_with("!")
		case ctrl && key == sdl.K_T:
			app.palette_open_with("#")
		case ctrl && key == sdl.K_M:
			app.palette_open_with("?")
		case ctrl && key == sdl.K_F:
			app.open_search()
		}
		return
	}

	// The panel's locals filter, while focused: backspace edits, esc leaves.
	if app.task.filter_focus {
		switch {
		case key == sdl.K_ESCAPE:
			app.task.filter_focus = false
			clear(&app.task.filter)
			return
		case key == sdl.K_BACKSPACE:
			if n := len(app.task.filter); n > 0 {
				resize(&app.task.filter, n-1)
			}
			return
		case key == sdl.K_RETURN:
			app.task.filter_focus = false
			return
		}
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

	// --- tabs ---
	case ctrl && key == sdl.K_TAB:
		app.tab_cycle(-1 if shift else 1)
		follow = false
	case ctrl && key == sdl.K_PAGEUP:
		app.tab_cycle(-1)
		follow = false
	case ctrl && key == sdl.K_PAGEDOWN:
		app.tab_cycle(1)
		follow = false
	case ctrl && key == sdl.K_W:
		if close_req_ms == 0 || app.now_ms-close_req_ms > CLOSE_DEDUP_MS {
			close_key_ms = app.now_ms
			app.tab_close(app.active)
		}
		follow = false
	case ctrl && !shift && !alt && key >= sdl.K_1 && key <= sdl.K_9:
		app.tab_select(int(key - sdl.K_1))
		follow = false

	// --- movement ---
	case key == sdl.K_LEFT:
		app.move_cursors(.Word_Left if ctrl else .Left, shift)
	case key == sdl.K_RIGHT:
		app.move_cursors(.Word_Right if ctrl else .Right, shift)
	case ctrl && key == sdl.K_UP:
		app.semantic_move(-1, shift)
	case ctrl && key == sdl.K_DOWN:
		app.semantic_move(1, shift)
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
	case ctrl && key == sdl.K_F:
		app.open_search()
		follow = false
	case ctrl && key == sdl.K_E:
		app.palette_open_with("!")
		follow = false
	case ctrl && key == sdl.K_T:
		app.palette_open_with("#")
		follow = false
	case ctrl && (key == sdl.K_PLUS || key == sdl.K_EQUALS || key == sdl.K_KP_PLUS):
		app.zoom_req = .In
		follow = false
	case ctrl && (key == sdl.K_MINUS || key == sdl.K_KP_MINUS):
		app.zoom_req = .Out
		follow = false
	case ctrl && key == sdl.K_0:
		app.zoom_req = .Reset
		follow = false
	case ctrl && key == sdl.K_B:
		app.sidebar.visible = !app.sidebar.visible
		follow = false
	case ctrl && key == sdl.K_Q:
		request_quit()
		follow = false
	case ctrl && shift && key == sdl.K_M:
		app.problems_open = !app.problems_open
		if app.problems_open {
			app.task.open = false // the panels share the slot above the status bar
		}
		follow = false
	case ctrl && key == sdl.K_M:
		app.palette_open_with("?")
		follow = false
	case ctrl && shift && key == sdl.K_R:
		_ = app.task_picker()
		follow = false
	case ctrl && key == sdl.K_R:
		app.task_run_default()
		follow = false
	case key == sdl.K_F9:
		app.breakpoint_toggle_at_cursor()
		follow = false
	case shift && key == sdl.K_F5:
		app.dap_stop()
		follow = false
	case key == sdl.K_F5:
		app.dap_f5()
		follow = false
	case key == sdl.K_F10:
		app.dap_resume("next")
		follow = false
	case shift && key == sdl.K_F11:
		app.dap_resume("stepOut")
		follow = false
	case key == sdl.K_F11:
		app.dap_resume("stepIn")
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
