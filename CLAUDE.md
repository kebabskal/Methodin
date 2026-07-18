# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the source of the **Odin programming language**: the C++ compiler (`src/`), the standard library shipped with Odin (`base/`, `core/`, `vendor/`), and tests/examples. The compiler emits LLVM IR and links it to produce native binaries. There is no other Odin toolchain — this repo *is* the toolchain.

## Building the compiler

The compiler is a C++14 program built with a single `clang++` invocation from `src/main.cpp` (which `#include`s all other `src/*.cpp` translation units — there is no per-file build). LLVM is a hard dependency.

- **Linux / macOS / *BSD:** `./build_odin.sh [debug|release|release-native|nightly]`. With no argument it builds debug and runs `examples/demo`. `make` / `make release` / `make debug` wrap the same script.
- **Windows:** `build.bat` from an MSVC x64 native tools prompt. Pass `1` or `release` for release mode.
- **LLVM version:** 14, or 17–22. The script auto-discovers `llvm-config` (`llvm-config-N` on Linux, `llvm-config@N` via brew on macOS); set `LLVM_CONFIG` to override. On NixOS, `shell.nix` provides clang_20 + llvm_20.
- **Vendor C libs:** some tests require precompiled C deps. Build them with `make -C vendor/stb/src`, `make -C vendor/cgltf/src`, `make -C vendor/miniaudio/src` (or `build_vendor.bat` on Windows). On Linux CI also installs `libcurl4-openssl-dev` and `libmbedtls-dev`.

The build script always runs `examples/demo` as a smoke test after a debug build. The output binary is `./odin` in the repo root.

## Running tests

Odin tests are written in Odin and run by the just-built `./odin test` subcommand. The canonical CI invocations are in `.github/workflows/ci.yml` — mirror those flags when reproducing CI locally. Key suites:

- **Core library (normal):** `./odin test tests/core/normal.odin -file -all-packages -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:address`
- **Core library (optimized):** same but `tests/core/speed.odin -o:speed` (no `-sanitize:address`).
- **Vendor libraries:** `./odin test tests/vendor -all-packages …` (needs the vendor C libs built first).
- **Compiler internals:** `./odin test tests/internal -all-packages …`.
- **Issue regressions:** `cd tests/issues && ./run.sh` (Windows: `run.bat`). Each `test_issue_NNNN.odin` reproduces a specific GitHub issue.
- **Cross-target sanity checks:** `./check_all.sh [freestanding|wasm|rare|<default>]` runs `odin check examples/all` against every supported target triple. Fast — no codegen, no linking.

To run a **single test package** (one directory of `@test` procs), point `odin test` at the directory: `./odin test tests/core/strings`. To run a **single test file**, add `-file`: `./odin test tests/core/strings/test_core_strings.odin -file`. Odin's `testing` package does not have a "select one `@test` proc" flag — narrow by file/package or temporarily mark others `@(disabled=true)`.

`tests/core/normal.odin` is a manifest that `@(require) import`s every core package so `-all-packages` pulls them all in; `tests/core/speed.odin` is the same idea for the optimized run. They are deliberately tiny — the actual tests live in `tests/core/<pkg>/`.

## Style / vet flags expected by CI

Every CI test/check invocation passes this set together:
`-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do`. New code that survives `odin check examples/all` with these flags will survive CI. `-vet-cast` is added for crypto suites.

## Architecture

### Compiler (`src/`, C++14, single TU)

The pipeline runs top-to-bottom through these stages, each implemented in dedicated `.cpp` files all stitched into `main.cpp`:

1. **Tokenize → Parse** (`tokenizer.cpp`, `parser.cpp`): produces `AstFile`/`AstPackage` trees. The parser is multi-threaded via `thread_pool.cpp` — each file parses on a worker.
2. **Check** (`checker.cpp`, `check_decl.cpp`, `check_expr.cpp`, `check_stmt.cpp`, `check_type.cpp`, `check_builtin.cpp`): semantic analysis, name resolution, type inference, constant folding. `AddressingMode` (in `parser.hpp`) classifies every expression result. `Entity`/`Scope`/`Type` are the central data structures (`entity.cpp`, `types.cpp`). Constant evaluation uses `exact_value.cpp` + `big_int.cpp` (libtommath, vendored as `src/libtommath/`).
3. **Codegen** (`llvm_backend*.cpp`): walks checked AST and emits LLVM IR via the LLVM C API. Split by concern: `_general`, `_proc`, `_stmt`, `_expr`, `_const`, `_type`, `_debug`, `_opt`, `_passes`, `_utility`. `llvm_abi.cpp` handles per-target ABI lowering.
4. **Link** (`linker.cpp`): invokes the system linker (`ld`/`lld`/MSVC `link.exe`); `bundle_command.cpp` handles macOS app bundles. `build_settings.cpp` + `build_settings_microarch.cpp` parse `-target:` / `-microarch:` and drive target selection.

Supporting infrastructure: `gb/` (Ginger Bill's `gb` C library — base utilities, allocators, string handling), `common.cpp`/`common_memory.cpp` (arenas, hash maps), `string_map.cpp`/`ptr_map.cpp`/`string_set.cpp` (typed hash containers), `string_interner.cpp` (canonical strings), `threading.cpp`/`thread_pool.cpp`. `utf8proc/` and `ucg/` are vendored Unicode data.

`cached.cpp` implements the build cache. `docs.cpp` + `docs_format.cpp` + `docs_writer.cpp` power `odin doc`. `bug_report.cpp` powers `odin report`.

### Odin standard library

Three import-prefix roots, all written in Odin:

- **`base:…`** — implicit runtime that ships in every Odin binary. `base/runtime/` is the runtime (allocators, panic, `context`, dynamic arrays/maps internals, OS-specific entry points like `entry_unix.odin` / `entry_windows.odin` / `entry_wasm.odin`). `base/builtin/` and `base/intrinsics/` are pseudo-packages whose symbols are recognized by the compiler. `base/sanitizer/` is the ASan/UBSan glue.
- **`core:…`** — opt-in standard library (`core/fmt`, `core/strings`, `core/os`, `core/net`, `core/crypto`, `core/math`, etc.). Pure Odin; safe across all supported platforms.
- **`vendor:…`** — bindings to third-party C libraries (`vendor/raylib`, `vendor/sdl3`, `vendor/vulkan`, `vendor/glfw`, `vendor/stb`, `vendor/cgltf`, `vendor/miniaudio`, …). Some require building the C library first (see "Vendor C libs" above).

When editing standard library code, `examples/all` is the canonical "does everything still import & check?" target; `check_all.sh` runs it across platforms.

### Tests (`tests/`)

- `tests/core/<pkg>/` — per-core-package unit tests.
- `tests/vendor/` — vendor binding tests.
- `tests/internal/` — compiler-level invariants (e.g. `test_intrinsics_*.odin`, RTTI, alignment).
- `tests/issues/test_issue_NNNN.odin` — regressions for specific GitHub issues; the `run.sh`/`run.bat` driver lists which ones to run and with which `odin` subcommand (`test`/`build`).
- `tests/benchmark/` — checked-only (`-no-entry-point`), not executed in CI.
- `tests/documentation/` — verifies the doc generator round-trips.

`tests/core/download_assets.py` downloads large binary test fixtures on first run (called from `tests/core/normal.odin`'s `@(init)`); it needs `python3` on PATH.

## Conventions worth knowing

- Don't `cd` into the repo before invoking `odin`; CI scripts assume the binary is `./odin` at the repo root.
- The compiler is a single-TU C++ build. Adding a new `.cpp` file means adding a corresponding `#include` to `src/main.cpp` (look at the order — declarations matter).
- The `gb_internal` / `gb_global` / `gb_inline` macros come from `src/gb/gb.h`; use them rather than `static` for consistency with the surrounding code.
- Changes that alter language semantics or stdlib surface require an issue/proposal per `PROPOSAL-PROCESS.md` before implementation.
