#+build windows
#+private
package hot_reload

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// The host executable itself. Its exported symbols (the manifest and the package globals, all
// marked dllexport by the compiler) are reachable through the module handle of the running
// process, which is what GetModuleHandleW(nil) returns.
_self_module :: proc() -> rawptr {
	return rawptr(win.GetModuleHandleW(nil))
}

_self_sym :: proc(h: rawptr, name: cstring) -> rawptr {
	return win.GetProcAddress(cast(win.HMODULE)h, name)
}

// The user's temp directory, with a trailing backslash (as GetTempPathW returns it).
_temp_dir :: proc() -> string {
	buf: [win.MAX_PATH + 1]u16
	n := win.GetTempPathW(len(buf), transmute(win.LPCWSTR)raw_data(buf[:]))
	dir, _ := win.wstring_to_utf8(transmute(win.wstring)raw_data(buf[:]), int(n))
	return dir
}

// The reload library to (re)build: a fresh per-generation `.dll` in the user's temp directory.
// A new path each time because LoadLibrary caches by path.
_temp_lib_path :: proc(gen: int) -> string {
	return fmt.tprintf("%s.odin_hot_reload_%d_%d.dll", _temp_dir(), int(win.GetCurrentProcessId()), gen)
}

// Run the reload build and report whether it succeeded.
//
// Unlike the Unix path, this does NOT use core:os/process_exec: that captures the child's
// stdout/stderr through pipes, and on Windows the child (the compiler, plus the link.exe it
// spawns) stalls once a pipe fills because nothing drains it concurrently — the reload never
// completes. Instead the child's output is redirected to a temp file we read back only on
// failure, so a clean reload stays quiet and a broken one still shows the compiler errors.
_run_compiler :: proc(cmd: []string) -> (ok: bool, fail_output: string) {
	logpath := fmt.tprintf("%s.odin_hot_reload_build_%d.log", _temp_dir(), int(win.GetCurrentProcessId()))

	sa: win.SECURITY_ATTRIBUTES
	sa.nLength = size_of(sa)
	sa.bInheritHandle = win.TRUE // the child must inherit the log handle

	logh := win.CreateFileW(
		win.utf8_to_wstring(logpath),
		win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa,
		win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil,
	)
	if logh == win.INVALID_HANDLE_VALUE {
		return false, "could not create the build log file\n"
	}

	si: win.STARTUPINFOW
	si.cb = size_of(si)
	si.dwFlags    = win.STARTF_USESTDHANDLES
	si.hStdInput  = win.GetStdHandle(win.STD_INPUT_HANDLE)
	si.hStdOutput = logh
	si.hStdError  = logh

	pi: win.PROCESS_INFORMATION
	created := win.CreateProcessW(nil, win.utf8_to_wstring(_join_cmdline(cmd)), nil, nil, win.TRUE, 0, nil, nil, &si, &pi)
	win.CloseHandle(logh)
	if !created {
		return false, "could not start the compiler\n"
	}

	win.WaitForSingleObject(pi.hProcess, win.INFINITE)
	code: win.DWORD = 1
	win.GetExitCodeProcess(pi.hProcess, &code)
	win.CloseHandle(pi.hThread)
	win.CloseHandle(pi.hProcess)

	if code == 0 {
		return true, ""
	}
	data, _ := os.read_entire_file_from_path(logpath, context.temp_allocator)
	return false, string(data)
}

// Join an argv into a single command line for CreateProcessW, quoting each element so
// CommandLineToArgvW reconstructs it verbatim (Microsoft's documented round-trip rules). This
// matters for `-extra-linker-flags:"...path..."`, whose embedded quotes must survive intact.
_join_cmdline :: proc(cmd: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for arg, i in cmd {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		_quote_arg(&sb, arg)
	}
	return strings.to_string(sb)
}

_quote_arg :: proc(sb: ^strings.Builder, arg: string) {
	strings.write_byte(sb, '"')
	i := 0
	for i < len(arg) {
		nbs := 0
		for i < len(arg) && arg[i] == '\\' {
			nbs += 1
			i += 1
		}
		if i == len(arg) {
			// Backslashes immediately before the closing quote must all be doubled.
			for _ in 0 ..< nbs * 2 {
				strings.write_byte(sb, '\\')
			}
		} else if arg[i] == '"' {
			// Backslashes before a literal quote are doubled, then the quote is escaped.
			for _ in 0 ..< nbs * 2 + 1 {
				strings.write_byte(sb, '\\')
			}
			strings.write_byte(sb, '"')
			i += 1
		} else {
			// Backslashes not before a quote are literal.
			for _ in 0 ..< nbs {
				strings.write_byte(sb, '\\')
			}
			strings.write_byte(sb, arg[i])
			i += 1
		}
	}
	strings.write_byte(sb, '"')
}

