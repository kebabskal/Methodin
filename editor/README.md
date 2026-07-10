# medit — a tight little code editor, written in Methodin

A small, fast, GPU-rendered code editor that dogfoods the Methodin language:
the editor's own internals use in-struct procs and `impl` blocks throughout
(`Buffer.commit`, `App.select_next_match`, ...).

![medit editing its own buffer code](screenshot.png)

## What it does

- **Command palette** — `ctrl+p`, vscode-style. Fuzzy file finder by default
  (`/` and `\` are interchangeable, matches highlighted, filename hits ranked
  first); prefix `>` for app commands and settings (`ctrl+shift+p` jumps
  straight there), `/term` for live document search (up/down hops between
  matches, esc restores the view), `:line[:col]` to jump. Modes are a table in
  `palette.odin` — a new one is a prefix plus refresh/accept/preview procs.
  The context menu (`ctrl+.`, or right-click) is a palette mode too: actions
  for the current selection or symbol (select all occurrences, search, case
  transforms, ...), or for a file when triggered on the sidebar or a palette
  file item (open, copy path/name).
- **LSP** — go to definition (`ctrl+g` / ctrl+click), find usages (`ctrl+h` /
  ctrl+shift+click, results in the palette with live preview), rename symbol
  (`F2`; edits to the current buffer are undoable, other files are updated on
  disk), and hover: rest the mouse on a symbol to get its signature/type in
  a tooltip (markdown code blocks rendered bright, prose dim). Autocomplete
  pops up as you type identifiers and after `.` (fields, procs, methods —
  fuzzy-filtered client-side, tab/enter accepts at every cursor, `ctrl+space`
  to summon); typing `(` or `,` shows the call's signature with the current
  argument highlighted, tracking as you type. Talks to [Methodin-ols](https://github.com/kebabskal/Methodin-ols)
  for `.odin` files — found automatically in a `Methodin-ols` (or `ols`)
  checkout next to any ancestor of the working directory, else `ols` on
  PATH; `MEDIT_OLS` overrides. `>LSP: Restart Language Server` after
  installing it mid-session.
  Other languages are one case in `lsp_server_exe` (`lsp.odin`). The client
  is thread-free: JSON-RPC over stdio, polled from the main loop.
- **File tree sidebar** — the working directory as a lazily-loaded tree
  (`ctrl+b` to toggle). Click a directory to expand it, a file to open it;
  collapsing and re-expanding a directory re-reads it from disk. Opening over
  unsaved changes takes a confirming second click.
- **Multiple cursors** — `ctrl+alt+↑/↓` to stack cursors, `ctrl+d` to select
  the next occurrence, `alt+click` to add a cursor anywhere. Every editing
  action is a batch of `(range, text)` replacements, one per cursor, applied
  through a single code path shared with undo/redo (and, later, LSP
  `didChange`).
- **Syntax highlighting** — Methodin/Odin via `core:odin/tokenizer` (the
  compiler's own lexer, so it always agrees with the language), a
  data-driven generic lexer covering C, C++, Python, JavaScript, TypeScript,
  Rust, Go, Java, C#, Lua, shell, PowerShell, batch, YAML, TOML, INI, CSS,
  JSON, GLSL, HLSL and WGSL (a new language is a `Lex_Config` table entry),
  and small dedicated lexers for Markdown and HTML/XML. Language is guessed
  from the extension and overridable via `>language` in the palette.
  Whole-buffer relex on edit; plenty fast for real files.
- **Exact dirty tracking** — undo back to the saved state and the dirty
  marker goes away.
- **Cross platform** — SDL3 + OpenGL 3.3 + stb_truetype, all from this
  repo's `vendor/`. Linux, Windows, macOS. Finds a system monospace font
  automatically (`MEDIT_FONT=/path/to/font.ttf` to override).
- Smooth scrolling, drag / double-click-drag word selection, alt+drag column
  selection, smart home, auto-indent on enter, tab/shift+tab block (de)indent,
  move lines (`alt+↑/↓`), duplicate (`ctrl+shift+d`), toggle line comment
  (`ctrl+'`), multi-cursor-aware copy/cut/paste (N clipboard lines paste onto
  N cursors), selection undo (`ctrl+u`), system open/save dialogs, line
  numbers, current-line highlight, status bar.

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
editor/medit path/to/file.odin   # open a file
editor/medit path/to/project     # open a directory as the workspace
editor/medit                     # workspace = current directory
```

The sidebar, the ctrl+p file finder and the language server all root at the
workspace directory. `>File: Open Folder…` in the palette switches workspace
at runtime (the current buffer survives the move).

## Keys

| | |
|---|---|
| `ctrl+alt+↑/↓` | add cursor above/below |
| `ctrl+d` | select word / add next occurrence |
| `alt+click` / `alt+drag` | add cursor / column selection |
| `ctrl+u` | undo last selection change |
| `esc` | one caret at the last cursor; then collapse selection |
| `alt+↑/↓` | move lines up/down |
| `ctrl+shift+d` | duplicate selection (or line) |
| `ctrl+'` | toggle line comment |
| `ctrl+←/→` | smart word move (subwords; toggleable to whole words) |
| `ctrl+.` / right-click | context menu (selection, symbol, or file) |
| `ctrl+g` / ctrl+click | go to definition |
| `ctrl+h` / ctrl+shift+click | find usages |
| `F2` | rename symbol |
| `ctrl+space` | trigger completion (auto on identifiers and `.`) |
| `home` | first non-blank ↔ column 0 |
| `ctrl+home/end` | start/end of file |
| `shift` + any movement | extend selection |
| `ctrl+z` / `ctrl+shift+z` / `ctrl+y` | undo / redo |
| `ctrl+x/c/v` | cut/copy/paste (no selection: whole line) |
| `tab` / `shift+tab` | indent / dedent selection |
| `ctrl+a` | select all |
| `ctrl+p` | command palette (files; `>` commands, `/` search, `:` goto) |
| `ctrl+shift+p` | command palette, commands mode |
| `ctrl+b` | toggle the file tree sidebar |
| `ctrl+n` | new untitled file |
| `ctrl+o` | open file (system dialog) |
| `ctrl+s` | save (untitled: system save dialog) |

`cmd` works as `ctrl` on macOS.

## Architecture (and what's next)

```
buffer.odin     line-array buffer, batched edits, undo/redo   (tested)
filetree.odin   file tree sidebar (lazy directory nodes, open-on-click)
palette.odin    ctrl+p palette (mode registry: files / commands / search / goto / ...)
lsp.odin        LSP client (stdio JSON-RPC, polled; definition/references/rename/hover)
complete.odin   completion popup + signature help (active param highlighted)
highlight.odin  per-line span lexers (odin tokenizer + generic)
render.odin     GL 3.3 quad batch + stb_truetype atlas
app.odin        cursors, actions, mouse, drawing
main.odin       SDL3 window, event loop, keymap, clipboard
```

The renderer exposes exactly two primitives (`push_rect`, `push_glyph`), so
a terminal backend stays a realistic option. The LSP client covers
definition / references / rename today; the natural next steps on top of it
are completion, hover, and `publishDiagnostics` squiggles (notifications are
already received, just ignored), plus per-language server configs
(`glsl_analyzer`, `vscode-json-language-server`, ...).

Known limits, deliberately: one buffer per window, no splits yet, undo is
per-keystroke (not coalesced), whole-buffer relex, glyph atlas covers
ASCII + Latin-1 + common punctuation (anything else renders as a box).
