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

main :: proc() {
	path := ""
	if len(runtime.args__) > 1 {
		path = string(os.args[1])
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

	_ = sdl.StartTextInput(window)
	defer { _ = sdl.StopTextInput(window) }
	ibeam := sdl.CreateSystemCursor(.TEXT)
	defer sdl.DestroyCursor(ibeam)
	_ = sdl.SetCursor(ibeam)

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

		pw, ph: c.int
		sdl.GetWindowSizeInPixels(window, &pw, &ph)
		frame_begin(&rend, pw, ph, app.theme.bg)
		app.draw(&rend, f32(pw), f32(ph))
		flush(&rend)
		sdl.GL_SwapWindow(window)
	}
}

@(private = "file")
handle_event :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window, ev: ^sdl.Event, density: f32) -> bool {
	#partial switch ev.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return false

	case .KEY_DOWN:
		handle_key(app, rend, window, ev)

	case .TEXT_INPUT:
		text := string(ev.text.text)
		if len(text) > 0 {
			app.insert_text(text)
			app.ensure_cursor_visible(rend.cell_w, rend.line_h)
		}

	case .MOUSE_BUTTON_DOWN:
		if ev.button.button == sdl.BUTTON_LEFT {
			mods := sdl.GetModState()
			p := app.pos_at_pixel(ev.button.x*density, ev.button.y*density, rend.cell_w, rend.line_h)
			app.click(p, int(ev.button.clicks),
				mods&sdl.KMOD_SHIFT != {},
				mods&sdl.KMOD_ALT != {})
		}

	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_LEFT {
			app.mouse_up()
		}

	case .MOUSE_MOTION:
		if app.selecting {
			p := app.pos_at_pixel(ev.motion.x*density, ev.motion.y*density, rend.cell_w, rend.line_h)
			app.drag(p)
			app.ensure_cursor_visible(rend.cell_w, rend.line_h)
		}

	case .MOUSE_WHEEL:
		dy := ev.wheel.y
		dx := ev.wheel.x
		if ev.wheel.direction == .FLIPPED {
			dy = -dy
			dx = -dx
		}
		app.scroll_y -= dy * rend.line_h * 3
		app.scroll_x += dx * rend.cell_w * 6
		app.clamp_scroll(rend.line_h)
	}
	return true
}

@(private = "file")
handle_key :: proc(app: ^App, rend: ^Renderer, window: ^sdl.Window, ev: ^sdl.Event) {
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

	switch {
	// --- multi-cursor ---
	case ctrl && alt && key == sdl.K_UP:
		app.add_cursor_line(below = false)
	case ctrl && alt && key == sdl.K_DOWN:
		app.add_cursor_line(below = true)
	case ctrl && key == sdl.K_D:
		app.select_next_match()
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
	case key == sdl.K_DELETE:
		app.delete_forward()
	case key == sdl.K_TAB:
		if shift {
			app.dedent()
		} else {
			app.indent()
		}

	// --- commands ---
	case ctrl && key == sdl.K_A:
		app.select_all()
		follow = false
	case ctrl && key == sdl.K_S:
		app.save()
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

@(private = "file")
clipboard_set :: proc(text: string) {
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	sdl.SetClipboardText(ctext)
}

@(private = "file")
clipboard_get :: proc() -> string {
	raw := sdl.GetClipboardText()
	defer sdl.free(raw)
	text := strings.clone(string(cstring(raw)), context.temp_allocator)
	// Normalize Windows line endings; the buffer stores bare '\n'.
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return text
}
