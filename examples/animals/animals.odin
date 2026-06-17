// Smallest possible demo of in-struct procs + auto-dispatch on a union.
//
// `Animal`, `Dog`, and `Cat` each declare their own `greet`. The compiler
// lifts each to a free proc, mangles the names, and synthesises a
// procedure group `greet :: proc { Animal__greet, Dog__greet, Cat__greet }`.
// Calling `thing.greet(...)` on a `union { Animal, Dog }` expands to a
// `switch v in thing` at compile time — no vtable, no indirection.

package animals

import "core:fmt"

Animal :: struct {
	greet :: proc(name: string) {
		fmt.println("Hi,", name, "!")
	},
}

Dog :: struct {
	using animal: Animal,
	greet :: proc(name: string) {
		fmt.println("Woof,", name, "!")
	},
}

Cat :: struct {
	using animal: Animal,
	greet :: proc(name: string) {
		fmt.println("Meow,", name, "!")
	},
}

Thing :: union {
	Animal,
	Dog,
	Cat,
}

main :: proc() {
	things: []Thing = {Animal{}, Dog{}, Cat{}}

	for &thing in things {
		thing.greet("MineDrabe")
	}
}
