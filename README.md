# Methodin — Odin with Methods

This is an experimental fork of the Odin Programming language that adds Methods and somewhat smart dispatch. It doesn't use vtables; instead it implements dispatch as compile time switch statements. Definitely not in line with Odin design principles and not intended to ever be merged or even used by anyone but me.

That said, pretty cute!

> Implemented by Claude (Opus 4.7). I haven't looked at a single line of the code.

> Companion language server fork: **[Methodin-ols](https://github.com/kebabskal/Methodin-ols)**
> (a fork of [DanielGavin/ols](https://github.com/DanielGavin/ols) that understands the new syntax).


## Example

```odin
package main

import "core:fmt"

Circle :: struct {
    r: f32,
    area :: proc() -> f32 {
        return 3.14159265 * r * r
    },
}

Rectangle :: struct {
    w, h: f32,
    area :: proc() -> f32 {
        return w * h
    },
}

Triangle :: struct {
    base, height: f32,
    area :: proc() -> f32 {
        return 0.5 * base * height
    },
}

Shape :: union {
    Circle,
    Rectangle,
    Triangle,
}

main :: proc() {
    shapes := []Shape{
        Circle{r = 2},
        Rectangle{w = 3, h = 4},
        Triangle{base = 5, height = 6},
    }

    for &s in shapes {
        fmt.printfln("%v -> area = %.2f", s, s.area())
    }
}
```

Each variant declares its own `area` inline. The compiler lifts each to a
free proc (`Circle__area`, `Rectangle__area`, `Triangle__area`), synthesises
a procedure group at file scope, and expands `s.area()` on the union to a
`switch v in s` over the known variants. No vtable, no indirection.

### …with `using` inheritance and `impl` blocks

```odin
package main

import "core:fmt"

Animal :: struct {
    name: string,

    introduce :: proc() {
        fmt.printfln("Hi, I'm %s.", name)
    },
}

Dog :: struct {
    using animal: Animal,
}

impl Dog {
    speak :: proc() {
        fmt.printfln("%s: woof!", name)
    }
}

Cat :: struct {
    using animal: Animal,
}

impl Cat {
    speak :: proc() {
        fmt.printfln("%s: meow.", name)
    }
}

Pet :: union { Dog, Cat }

main :: proc() {
    rex     := Dog{animal = {name = "Rex"}}
    mittens := Cat{animal = {name = "Mittens"}}

    rex.introduce()     // inherited from Animal via `using`
    mittens.introduce()

    pets := []Pet{rex, mittens}
    for &p in pets {
        p.speak()       // union-dispatched: Dog__speak vs Cat__speak
    }
}
```

`Dog` and `Cat` don't redeclare `introduce` — they inherit it by embedding
`Animal` with `using`, and the UFCS resolver walks the embed chain to find
it. `speak` is declared in an `impl` block, which is exactly the same
lifting as an in-struct proc — useful when you want the method to live in
a different file from the struct.

See [`examples/methods`](examples/methods) and
[`examples/animals`](examples/animals) for the runnable demos.

## What's added on top of upstream Odin

- **UFCS** — `x.foo(args)` desugars to `foo(x, args)` when `foo` is a free
  proc in the receiver type's package. The compiler auto-takes the
  receiver's address when the parameter is a pointer and the receiver is
  addressable. Field selectors always win over UFCS, so there is no
  ambiguity. Resolution walks `using` chains, including across packages.
- **In-struct proc declarations** — methods can be declared directly inside
  a struct body. Each is lifted to a free
  `name :: proc(using self: ^Struct, ...) { ... }` at package scope, so the
  body reads fields without a `self.` prefix.
- **`impl Type { ... }` blocks** — same desugaring as in-struct procs, but
  declared in a block separate from the struct, optionally in another file.
- **Auto procedure groups on name collisions** — when two structs in the
  same package declare a method with the same name, the compiler mangles
  each lifted proc (`Knight__hit`, `Wizard__hit`) and synthesises a
  procedure group (`hit :: proc { Knight__hit, Wizard__hit }`) at file
  scope. UFCS dispatches via overload resolution on the receiver type.
- **Union method dispatch** — calling a method on a tagged union expands to
  a `switch v in s` over the known variants at compile time. No vtable, no
  indirection. Variadic methods forward correctly, and calling a method on a
  nil union value panics with the union and method name instead of silently
  doing nothing.
- **`auto_union(T)`** — a tagged union of every struct in the program that
  `using`-embeds `T` at offset 0 (directly or transitively). Bind it to a
  named alias (`AnyEntity :: auto_union(Entity)`) and method calls on it
  virtually dispatch to each variant's override; base fields are promoted
  through the offset-0 layout. Cross-package variants work. See
  [`examples/auto_union_test`](examples/auto_union_test).
- **Virtual sibling dispatch** — a method that calls a sibling method gets a
  polymorphic `^$Self` receiver, so each concrete receiver re-resolves the
  call against its own overrides (virtual dispatch, still no vtable). See
  [`examples/self_dispatch`](examples/self_dispatch).
- **Type-scoped constants** — any non-proc `Name :: <expr>` inside a struct
  body or `impl` block is a constant (or nested type alias) accessed as
  `Vec3.UP`, `World.MAX_ENTITIES`, `World.Id` — usable in constant contexts
  like array sizes. `impl` works on non-struct named types too (a method
  whose first parameter names the target keeps its explicit receiver), so
  `impl Vec3 { UP :: Vec3{0, 1, 0} }` works on a `distinct [3]f32`.
- **Rvalue receivers** — methods work on temporaries: function results
  (`make_world().describe()`), constants (`Vec3.UP.scaled(2)`), struct
  literals, and immutable parameters. A hidden local is materialized for the
  `^self` receiver — but ONLY when the checker proves the method never
  mutates its receiver. Calling a mutating method on a temporary is a
  compile error that names the exact write that would be lost:

  ```
  Error: Cannot call 'take_damage' on 'make_world()', which is a temporary
  value: the method mutates its receiver and the mutation would be lost
      'hp' is written at world.odin(25:3)
      Suggestion: store the value in a variable first, then call the method on it
  ```

  The analysis is transitive through sibling calls and conservative:
  address-taken fields, slices of fields, passing `self` onward, and
  anything it can't prove read-only count as mutating.
- **Default struct field values** — `hp: int = 100` in a struct body, for
  any constant-expressible value (numbers, strings, compound literals,
  nested structs, fixed arrays). Applied wherever the compiler initializes
  the type: declarations without an initializer, compound literals that omit
  the field, globals, and arrays. Heap memory keeps zero semantics
  (`new`/`make` never run defaults — a default is a constant, never code);
  `ptr^ = {}` applies them explicitly. See
  [`examples/type_members`](examples/type_members).

Nothing here is dynamic dispatch through function pointers — every call
resolves statically to a known procedure (or one variant of a procedure
group / one case of a compile-time switch), and the inliner sees through it.

## `odin watch` — transparent hot reload

`odin watch` builds and runs a package, then live-reloads its code when the
source changes — **without restarting the program and without losing global
state.**

```sh
odin watch examples/hot_reload
```

While it runs, edit a procedure body and save; the running program
immediately starts using the new code, and globals keep their values. No
special program structure or contract is required — an ordinary
`package main` with a normal `main` just works.

How it works (all guarded so normal builds are unaffected):

- In a `watch` build the compiler routes every call to a package-level
  procedure through a writable **dispatch slot** (a function pointer) instead
  of a direct call, and **exports** package globals as dynamic symbols.
- On a source change an embedded reload agent rebuilds the package as a shared
  library whose package globals are *imported* from the running host, `dlopen`s
  it, and overwrites each dispatch slot with the new procedure address. Because
  globals are never reloaded, program state is preserved automatically.

An optional `hot_reloaded :: proc()` in your package is called once after each
successful reload — handy for re-deriving cached state. Omit it and reloads
happen silently.

Some edits can't be patched into a running native process. The agent detects
these via a compiler-emitted structural signature and **automatically
restarts** (losing in-memory state) instead of corrupting it:

- editing `main`'s body (the running loop can't be re-entered);
- adding, removing, or changing the type of a package global;
- editing the **layout of any type** declared in the package (fields,
  offsets, sizes — live globals and heap objects hold the old layout).

Everything else — editing any other procedure's body — hot-reloads in place.
The restart is handled by the parent `odin watch` process re-exec'ing
itself, so the process tree stays flat no matter how many restarts happen.

Odds and ends:

- `ODIN_HOT_RELOAD` is a built-in `bool` constant — `when ODIN_HOT_RELOAD`
  gates code to hot-reload builds (true in the host and in reload libraries).
- Reload rebuilds inherit the host's `-define:` flags, `-debug`, and checker
  threading, so each per-edit rebuild matches the original build.
- Both directory and single-file (`-file`) packages work, on Linux, macOS,
  and Windows; only the initial package is watched/reloaded. See
  [`examples/hot_reload`](examples/hot_reload) for a runnable demo.

## Compiler notes

The checker runs multithreaded by default (matching upstream); pass
`-no-threaded-checker` to serialize it if you ever suspect a
checker race. Methodin's polymorphic method machinery serializes its own
shared-state binding internally — everything else checks in parallel.

---

<p align="center">
    <img src="misc/logo-slim.png" alt="Odin logo" style="width:65%">
    <br/>
   The Data-Oriented Language for Sane Software Development.
    <br/>
    <br/>
    <a href="https://github.com/odin-lang/odin/releases/latest">
        <img src="https://img.shields.io/github/release/odin-lang/odin.svg">
    </a>
    <a href="https://github.com/odin-lang/odin/releases/latest">
        <img src="https://img.shields.io/badge/platforms-Windows%20|%20Linux%20|%20macOS-green.svg">
    </a>
    <br>
    <a href="https://discord.com/invite/sVBPHEv">
        <img src="https://img.shields.io/discord/568138951836172421?logo=discord">
    </a>
    <a href="https://github.com/odin-lang/odin/actions">
        <img src="https://github.com/odin-lang/odin/actions/workflows/ci.yml/badge.svg?branch=master&event=push">
    </a>
</p>

# The Odin Programming Language


Odin is a general-purpose programming language with distinct typing, built for high performance, modern systems, and built-in data-oriented data types. The Odin Programming Language, the C alternative for the joy of programming.

Website: [https://odin-lang.org/](https://odin-lang.org/)

```odin
package main

import "core:fmt"

main :: proc() {
	program := "+ + * 😃 - /"
	accumulator := 0

	for token in program {
		switch token {
		case '+': accumulator += 1
		case '-': accumulator -= 1
		case '*': accumulator *= 2
		case '/': accumulator /= 2
		case '😃': accumulator *= accumulator
		case: // Ignore everything else
		}
	}

	fmt.printf("The program \"%s\" calculates the value %d\n",
	           program, accumulator)
}

```

## Documentation

#### [Getting Started](https://odin-lang.org/docs/install)

Instructions for downloading and installing the Odin compiler and libraries.

#### [Nightly Builds](https://odin-lang.org/docs/nightly/)

Get the latest nightly builds of Odin.

### Learning Odin

#### [Overview of Odin](https://odin-lang.org/docs/overview)

An overview of the Odin programming language.

#### [Frequently Asked Questions (FAQ)](https://odin-lang.org/docs/faq)

Answers to common questions about Odin.

#### [Packages](https://pkg.odin-lang.org/)

Documentation for all the official packages part of the [core](https://pkg.odin-lang.org/core/) and [vendor](https://pkg.odin-lang.org/vendor/) library collections.

#### [Examples](https://github.com/odin-lang/examples)

Examples on how to write idiomatic Odin code. Shows how to accomplish specific tasks in Odin, as well as how to use packages from `core` and `vendor`.

#### [Odin Documentation](https://odin-lang.org/docs/)

Documentation for the Odin language itself.

#### [Odin Discord](https://discord.gg/sVBPHEv)

Get live support and talk with other Odin programmers on the Odin Discord.

### Articles

#### [The Odin Blog](https://odin-lang.org/news/)

The official blog of the Odin programming language, featuring announcements, news, and in-depth articles by the Odin team and guests.

## Warnings

* The Odin compiler is still in development.
