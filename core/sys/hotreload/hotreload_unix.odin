#+build linux, darwin, freebsd, openbsd, netbsd
#+private
package hot_reload

import "core:fmt"
import "core:os"
import "core:sys/posix"

// Run the reload build and report whether it succeeded. Output is captured; on failure the
// compiler's stderr is returned so the agent can show why. On success nothing is printed, so a
// clean reload stays quiet.
_run_compiler :: proc(cmd: []string) -> (ok: bool, fail_output: string) {
	state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil {
		return false, fmt.tprintf("could not start the compiler: %v\n", err)
	}
	if !state.exited || state.exit_code != 0 {
		return false, string(stderr)
	}
	return true, ""
}

// The host executable itself: built with -export_dynamic, so its exported symbols (the manifest
// and the package globals) are visible through a handle to the running program.
_self_module :: proc() -> rawptr {
	return rawptr(posix.dlopen(nil, {.LAZY}))
}

_self_sym :: proc(h: rawptr, name: cstring) -> rawptr {
	return posix.dlsym(posix.Symbol_Table(h), name)
}

// The reload library to (re)build. A fresh per-generation name under /tmp; the extension is
// nominal — the loader resolves by path, not suffix.
_temp_lib_path :: proc(gen: int) -> string {
	return fmt.tprintf("/tmp/.odin_hot_reload_%d_%d.dylib", int(posix.getpid()), gen)
}

