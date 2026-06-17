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
  indirection.

Nothing here is dynamic dispatch — every call resolves statically to a
known procedure (or one variant of a procedure group), and the inliner
sees through it.

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
