# medit — a tight little code editor, written in Methodin

A small, fast, GPU-rendered code editor that dogfoods the Methodin language:
the editor's own internals use in-struct procs and `impl` blocks throughout
(`Buffer.commit`, `App.select_next_match`, ...).

![medit editing its own buffer code](screenshot.png)

## What it does

- **Multiple cursors** — `ctrl+alt+↑/↓` to stack cursors, `ctrl+d` to select
  the next occurrence, `alt+click` to add a cursor anywhere. Every editing
  action is a batch of `(range, text)` replacements, one per cursor, applied
  through a single code path shared with undo/redo (and, later, LSP
  `didChange`).
- **Syntax highlighting** — Methodin/Odin via `core:odin/tokenizer` (the
  compiler's own lexer, so it always agrees with the language), plus small
  lexers for JSON, GLSL, HLSL and WGSL. Whole-buffer relex on edit; plenty
  fast for real files.
- **Exact dirty tracking** — undo back to the saved state and the dirty
  marker goes away.
- **Cross platform** — SDL3 + OpenGL 3.3 + stb_truetype, all from this
  repo's `vendor/`. Linux, Windows, macOS. Finds a system monospace font
  automatically (`MEDIT_FONT=/path/to/font.ttf` to override).
- Smooth scrolling, drag / double-click-drag word selection, smart home,
  auto-indent on enter, tab/shift+tab block (de)indent, multi-cursor-aware
  copy/cut/paste (N clipboard lines paste onto N cursors), line numbers,
  current-line highlight, status bar.

## Build

Needs the Methodin compiler built at the repo root first
(`./build_odin.sh release`, or `build.bat release` on Windows).

```sh
editor/build.sh          # -> editor/medit
editor\build.bat         # -> editor\medit.exe (Windows)
```

On Linux/macOS the stb static libs must exist once:
`make -C vendor/stb/src` (build.sh does this for you). On Linux you also
need SDL3 (`libSDL3.so`) installed; on Windows `vendor/sdl3/SDL3.dll` ships
with the repo.

Run it:

```sh
editor/medit path/to/file.odin
```

## Keys

| | |
|---|---|
| `ctrl+alt+↑/↓` | add cursor above/below |
| `ctrl+d` | select word / add next occurrence |
| `alt+click` | add cursor at mouse |
| `esc` | collapse to one cursor, then collapse selection |
| `ctrl+←/→` | word left/right |
| `home` | first non-blank ↔ column 0 |
| `ctrl+home/end` | start/end of file |
| `shift` + any movement | extend selection |
| `ctrl+z` / `ctrl+shift+z` / `ctrl+y` | undo / redo |
| `ctrl+x/c/v` | cut/copy/paste (no selection: whole line) |
| `tab` / `shift+tab` | indent / dedent selection |
| `ctrl+a` | select all |
| `ctrl+s` | save |

`cmd` works as `ctrl` on macOS.

## Architecture (and what's next)

```
buffer.odin     line-array buffer, batched edits, undo/redo   (tested)
highlight.odin  per-line span lexers (odin tokenizer + generic)
render.odin     GL 3.3 quad batch + stb_truetype atlas
app.odin        cursors, actions, mouse, drawing
main.odin       SDL3 window, event loop, keymap, clipboard
```

The renderer exposes exactly two primitives (`push_rect`, `push_glyph`), so
a terminal backend stays a realistic option. The planned next step is an LSP
client (JSON-RPC over stdio with `core:os` process pipes + `core:encoding/json`)
talking to [Methodin-ols](https://github.com/kebabskal/Methodin-ols) for
completion, hover, goto-definition and diagnostics, with
`glsl_analyzer` / `vscode-json-language-server` for the other languages.

Known limits, deliberately: one buffer per window, no splits yet, undo is
per-keystroke (not coalesced), whole-buffer relex, glyph atlas covers
ASCII + Latin-1 + common punctuation (anything else renders as a box).
