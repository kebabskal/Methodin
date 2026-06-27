# Transparent hot reloading (`odin watch`)

`odin watch` builds and runs a package, then live-reloads its code when the source
changes — **without restarting the program and without losing global state.**

```sh
odin watch examples/hot_reload
```

While it runs, edit the `fmt.printfln` line in [`main.odin`](main.odin) and save. The
running loop immediately starts using the new code; `counter` keeps counting.

## What makes it transparent

No special program structure is required — it is an ordinary `package main` with a normal
`main`. In `watch` (hot-reload) builds the compiler:

- routes every call to a package-level procedure through a writable **dispatch slot**
  (a function pointer) instead of a direct call;
- **exports** package globals as dynamic symbols.

On a source change the embedded reload agent rebuilds the package as a shared library
(`-build-mode:dll -hot-reload:reload`) in which the package globals are *imported* from the
running host. It `dlopen`s the result and overwrites each dispatch slot with the address of
the freshly-compiled procedure. Because globals were never reloaded — the new code binds to
the host's existing storage — program state is preserved automatically.

## Detecting a reload (optional)

If your package defines a proc named `hot_reloaded`:

```odin
hot_reloaded :: proc() {
    // called once after every successful reload
}
```

the agent calls it after swapping in the new code. It's entirely optional — omit it and
reloads happen silently. Nothing else about your program needs to change.

## Reloadable vs. restart

Some changes can't be patched into a running native process. The agent detects these and
**automatically restarts** the program (rebuilding with the new code) instead of swapping:

- editing `main`'s body (the running loop can't be re-entered);
- adding, removing, or changing the type of a package global (the layout would no longer
  match the host's storage).

Everything else — editing any other procedure's body — hot-reloads in place with global
state preserved. Restarts necessarily lose in-memory state, which is unavoidable for a
layout/loop change.

## Debugging a hot-reload session

The host is an ordinary native executable, so you can debug it — including reloaded code.
Instead of `odin watch`, build a self-watching host directly and launch it under a debugger:

```sh
odin build examples/hot_reload -hot-reload:host -debug -out:hot_reload_host
```

A `-hot-reload:host` build self-watches its sources (same agent as `odin watch`), so launching
the binary is equivalent to watching. Because it was built with `-debug`, the reload agent
mirrors `-debug` into every rebuilt library, so each reloaded `.so` carries DWARF. Debuggers
re-resolve file:line breakpoints against newly loaded modules, so a breakpoint in a proc you
edited re-binds automatically on the next reload. (Break by file:line, not by symbol — reloaded
calls are dispatched through a function-pointer slot to the new library's address.)

In VS Code, use the CodeLLDB extension: a launch config whose `program` is the
`-hot-reload:host -debug` binary above, with a matching build task, gives you breakpoints that
survive reloads.

## Limitations

- Restart detection covers global layout and `main`; a procedure that is *currently on the
  call stack* (other than `main`) still updates only on its next call.
- Currently targets macOS/Linux. Reloads only the initial (user) package's procedures.
- A "rude edit" (touching `main` or a global's layout) restarts the program, which also
  detaches an attached debugger.
