// Hot-reload agent for `odin watch`.
//
// This package is force-imported by the compiler when building in hot-reload "host" mode
// (i.e. via `odin watch`). It is NOT meant to be imported by user code directly.
//
// At startup an `@(init)` proc discovers a manifest emitted by the compiler (the dispatch
// slots for the user package's procedures, plus the source/odin paths) and spawns a
// background thread that:
//   1. watches the package's `.odin` files for modification,
//   2. rebuilds the package as a dynamic library (`-build-mode:dll -hot-reload:reload`),
//   3. dlopen's the result and overwrites each dispatch slot with the new proc address.
//
// Package globals are exported by the host and imported by the reload dylib, so program
// state (globals) is preserved across reloads — only code changes.
package hot_reload

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "core:sys/posix"

// Must match the struct the compiler emits for `odin_hr_entries` (see lb_emit_hot_reload_manifest).
Entry :: struct {
	name: cstring, // mangled proc symbol, looked up in the reload dylib
	slot: ^rawptr, // address of the host's writable dispatch slot to overwrite
}

@(private) State :: struct {
	entries:   []Entry,
	src_path:  string,
	odin_path: string,
	is_file:   bool,
	gen:       int,
}

@(private) g: State

@(init, private)
_hot_reload_boot :: proc "contextless" () {
	context = _ctx()

	// The manifest symbols are exported by the host executable (built with -export_dynamic),
	// so we can resolve them against the running program itself.
	main := posix.dlopen(nil, {.LAZY})
	if main == nil {
		return
	}

	count_ptr   := cast(^int)posix.dlsym(main, "odin_hr_entry_count")
	entries_ptr := cast([^]Entry)posix.dlsym(main, "odin_hr_entries")
	if count_ptr == nil || entries_ptr == nil {
		return // not a hot-reload host build
	}

	g.entries   = entries_ptr[:count_ptr^]
	g.src_path  = _cstr(posix.dlsym(main, "odin_hr_src_path"))
	g.odin_path = _cstr(posix.dlsym(main, "odin_hr_odin_path"))
	g.is_file   = strings.has_suffix(g.src_path, ".odin")

	if g.src_path == "" || g.odin_path == "" {
		return
	}

	fmt.eprintfln("[hot-reload] watching %q (%d reloadable procs)", g.src_path, len(g.entries))
	thread.create_and_start(_watch_loop, self_cleanup = true)
}

@(private) _ctx :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

@(private) _cstr :: proc(p: rawptr) -> string {
	if p == nil {
		return ""
	}
	return string(cast(cstring)p)
}

@(private)
_watch_loop :: proc() {
	last := _latest_mtime()
	for {
		time.sleep(300 * time.Millisecond)
		now := _latest_mtime()
		if now <= last {
			continue
		}
		// Debounce: let a burst of writes settle before rebuilding.
		time.sleep(150 * time.Millisecond)
		last = _latest_mtime()
		_reload()
	}
}

// Newest modification time across the watched `.odin` sources.
@(private)
_latest_mtime :: proc() -> i64 {
	newest: i64 = 0
	consider :: proc(newest: ^i64, path: string) {
		if t, err := os.last_write_time_by_name(path); err == nil {
			n := t._nsec
			if n > newest^ {
				newest^ = n
			}
		}
	}
	if g.is_file {
		consider(&newest, g.src_path)
		return newest
	}
	dir, derr := os.open(g.src_path)
	if derr != nil {
		return newest
	}
	defer os.close(dir)
	infos, _ := os.read_dir(dir, -1, context.temp_allocator)
	for fi in infos {
		if strings.has_suffix(fi.name, ".odin") {
			consider(&newest, fi.fullpath)
		}
	}
	return newest
}

@(private)
_reload :: proc() {
	g.gen += 1
	// A fresh path each reload: dlopen caches by path, so reusing a name would return the
	// stale image instead of loading the newly-built one.
	out := fmt.tprintf("/tmp/.odin_hot_reload_%d_%d.dylib", int(posix.getpid()), g.gen)

	cmd := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&cmd, g.odin_path, "build", g.src_path)
	if g.is_file {
		append(&cmd, "-file")
	}
	append(&cmd, "-build-mode:dll", "-hot-reload:reload", fmt.tprintf("-out:%s", out))

	fmt.eprintln("[hot-reload] change detected, rebuilding…")
	state, _, stderr, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil {
		fmt.println("[hot-reload] could not start the compiler:", err)
		return
	}
	if !state.exited || state.exit_code != 0 {
		fmt.println("[hot-reload] build failed — keeping the running code")
		if len(stderr) > 0 {
			fmt.print(string(stderr))
		}
		return
	}

	lib, ok := dynlib.load_library(out)
	if !ok {
		fmt.println("[hot-reload] failed to load rebuilt library")
		return
	}

	swapped := 0
	hook: rawptr
	for e in g.entries {
		if addr, found := dynlib.symbol_address(lib, string(e.name)); found && addr != nil {
			e.slot^ = addr
			swapped += 1
			if _is_hook(string(e.name)) {
				hook = addr
			}
		}
	}
	fmt.eprintfln("[hot-reload] reloaded ✓ (%d/%d procs swapped)", swapped, len(g.entries))

	// Optional userland hook: a package proc named `hot_reloaded :: proc()` is called once
	// after every successful reload, so the program can react (re-open files, log, etc.).
	if hook != nil {
		(cast(proc())hook)()
	}
}

// True if a mangled proc symbol's final segment is the reserved hook name `hot_reloaded`.
@(private)
_is_hook :: proc(sym: string) -> bool {
	tail := sym
	for sep in ([]string{"::", "."}) {
		if i := strings.last_index(tail, sep); i >= 0 {
			tail = tail[i + len(sep):]
		}
	}
	return tail == "hot_reloaded"
}
