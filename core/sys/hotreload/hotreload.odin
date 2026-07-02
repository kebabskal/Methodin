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
//   3. loads the result and overwrites each dispatch slot with the new proc address.
//
// Package globals are exported by the host and imported by the reload library, so program
// state (globals) is preserved across reloads — only code changes.
//
// This file is platform-neutral. The OS primitives it relies on — resolving symbols in the
// running host, loading the reload library, naming a scratch path, and restarting the process
// — live in `hotreload_unix.odin` / `hotreload_windows.odin`.
package hot_reload

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

// Must match the struct the compiler emits for `odin_hr_entries` (see lb_emit_hot_reload_manifest).
Entry :: struct {
	name: cstring, // mangled proc symbol, looked up in the reload library
	slot: ^rawptr, // address of the host's writable dispatch slot to overwrite
}

@(private) State :: struct {
	entries:     []Entry,
	src_path:    string,
	odin_path:   string,
	host_implib: string, // Windows: host import library the reload build links against; "" elsewhere
	is_file:     bool,
	host_debug:  bool, // host was built with -debug; mirror it into reload dylibs so they stay debuggable
	host_threaded_checker: bool, // host's effective checker threading; false mirrors -no-threaded-checker into rebuilds
	host_sig:    u64, // rude-edit signature of the running program; a mismatch forces a restart
	build_flags: []cstring, // host's -define flags; replayed so the reload build picks the same config
	gen:         int,
}

@(private) g: State

@(init, private)
_hot_reload_boot :: proc "contextless" () {
	context = _ctx()

	// The manifest symbols are exported by the host executable (via -export_dynamic on Unix or
	// dllexport on Windows), so we can resolve them against the running program itself.
	self := _self_module()
	if self == nil {
		return
	}

	count_ptr   := cast(^int)_self_sym(self, "odin_hr_entry_count")
	entries_ptr := cast([^]Entry)_self_sym(self, "odin_hr_entries")
	if count_ptr == nil || entries_ptr == nil {
		return // not a hot-reload host build
	}

	g.entries     = entries_ptr[:count_ptr^]
	g.src_path    = _cstr(_self_sym(self, "odin_hr_src_path"))
	g.odin_path   = _cstr(_self_sym(self, "odin_hr_odin_path"))
	g.host_implib = _cstr(_self_sym(self, "odin_hr_host_implib"))
	g.is_file     = strings.has_suffix(g.src_path, ".odin")
	if sig := cast(^u64)_self_sym(self, "odin_hr_signature"); sig != nil {
		g.host_sig = sig^
	}
	if dbg := cast(^int)_self_sym(self, "odin_hr_debug"); dbg != nil {
		g.host_debug = dbg^ != 0
	}
	if tc := cast(^int)_self_sym(self, "odin_hr_threaded_checker"); tc != nil {
		g.host_threaded_checker = tc^ != 0
	}
	// The host's -define flags, so the reload build selects the same configuration (e.g. shared vs
	// static foreign libs). Emitted by the compiler as a parallel count + cstring array.
	fcount := cast(^int)_self_sym(self, "odin_hr_build_flag_count")
	fptr   := cast([^]cstring)_self_sym(self, "odin_hr_build_flags")
	if fcount != nil && fptr != nil {
		g.build_flags = fptr[:fcount^]
	}

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
	// A fresh path each reload: the loader caches by path, so reusing a name would return the
	// stale image instead of loading the newly-built one.
	out := _temp_lib_path(g.gen)

	cmd := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&cmd, g.odin_path, "build", g.src_path)
	if g.is_file {
		append(&cmd, "-file")
	}
	append(&cmd, "-build-mode:dll", "-hot-reload:reload", fmt.tprintf("-out:%s", out))
	if g.host_debug {
		// Match the host's debug info so breakpoints in reloaded procs keep binding.
		append(&cmd, "-debug")
	}
	if !g.host_threaded_checker {
		// Parallel is the default; mirror the host's opt-out.
		append(&cmd, "-no-threaded-checker")
	}
	// Replay the host's -define flags so the reload DLL is built with the same configuration —
	// crucially the same foreign-library selection (e.g. -define:RAYLIB_SHARED=true), so host and
	// reload share one library instance instead of each linking a separate, divergent copy.
	for f in g.build_flags {
		append(&cmd, string(f))
	}
	// Windows: the reload DLL imports the host's package globals through the host's import
	// library (PE has no equivalent of ELF's runtime symbol interposition). Empty on Unix, where
	// the loader binds the globals directly. The agent quotes this whole argument for the child
	// process, but odin re-emits the bare value into its own linker command line, so a host path
	// containing spaces would still need handling there.
	if g.host_implib != "" {
		append(&cmd, fmt.tprintf("-extra-linker-flags:%s", g.host_implib))
	}

	fmt.eprintln("[hot-reload] change detected, rebuilding…")
	build_ok, fail_output := _run_compiler(cmd[:])
	if !build_ok {
		fmt.eprintln("[hot-reload] build failed — keeping the running code")
		if len(fail_output) > 0 {
			fmt.eprint(fail_output)
		}
		return
	}

	lib, ok := dynlib.load_library(out)
	if !ok {
		// Most often this means the package's set of globals changed (a symbol the new code
		// imports is not exported by the running host), which is a rude edit -> restart.
		fmt.eprintln("[hot-reload] rebuilt library could not be loaded into the running program")
		_restart()
		return
	}

	// Rude-edit check: if the global layout or the main loop changed, the running process
	// cannot be patched in place — restart it with the new code instead.
	if sig, found := dynlib.symbol_address(lib, "odin_hr_signature"); found && sig != nil {
		if (cast(^u64)sig)^ != g.host_sig {
			fmt.eprintln("[hot-reload] non-reloadable change (globals or main loop) — restarting…")
			_restart()
			return
		}
	}

	swapped := 0
	hook: rawptr
	for e in g.entries {
		if addr, found := dynlib.symbol_address(lib, string(e.name)); found && addr != nil {
			// Release store paired with the monotonic slot loads the compiler
			// emits at call sites: the main thread must not observe the new
			// pointer before the dylib's code is fully mapped, and the store
			// itself must not tear on weakly-ordered targets.
			intrinsics.atomic_store_explicit(e.slot, addr, .Release)
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

// Exit code the watch parent (`odin watch`) recognizes as "rude edit: rebuild
// the host and run it again". Keep in sync with ODIN_HR_RESTART_EXIT_CODE in
// src/main.cpp.
@(private)
HR_RESTART_EXIT_CODE :: 211

// A rude edit (changed globals/types/main) cannot be patched in place: exit
// with the magic code and let the parent `odin watch` rebuild and respawn us.
// The old implementation replaced this process with a fresh `odin watch`; on
// unix that parked the previous compiler in the process tree — one more per
// restart — and each parked parent re-raised the app's crash signal, filling
// coredumpctl with misleading paired SIGSEGVs.
@(private)
_restart :: proc() {
	os.exit(HR_RESTART_EXIT_CODE)
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
