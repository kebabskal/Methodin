package main

import "core:fmt"

// ---------------------------------------------------------------------------
// Type-scoped constants: any non-proc `Name :: <expr>` inside a struct body
// or an `impl` block becomes a constant accessed as `Type.Name`. The compiler
// lifts it to a package-scope `Type__Name`, so it works in constant contexts
// (array sizes, other constants) and across packages.
// ---------------------------------------------------------------------------

// `impl` also works on NON-struct named types. A method whose first
// parameter names the target keeps its explicit receiver (nothing is
// injected), and still resolves through UFCS: `v.scaled(2)`.
Vec3 :: distinct [3]f32

impl Vec3 {
	ZERO  :: Vec3{0, 0, 0},
	UP    :: Vec3{0, 1, 0},
	RIGHT :: Vec3{1, 0, 0},

	scaled :: proc(v: Vec3, f: f32) -> Vec3 {
		return Vec3{v.x * f, v.y * f, v.z * f}
	},
}

// ---------------------------------------------------------------------------
// Default field values: `field: T = <constant>` in a struct body. Anything
// constant-expressible works — numbers, strings, enums, compound literals,
// nested structs, fixed arrays. Defaults apply wherever the compiler
// initializes the type: declarations without an initializer, compound
// literals that omit the field, globals, and arrays of the type.
//
// Heap memory keeps Odin's zero semantics (new/make don't run defaults —
// a default is a constant, never code); `ptr^ = {}` applies them explicitly.
// ---------------------------------------------------------------------------

Stats :: struct {
	speed: f32 = 1.5,
	armor: int, // no default: zero
}

World :: struct {
	MAX_ENTITIES :: 128,
	Id :: distinct u32, // nested type alias: World.Id

	hp:     int    = 100,
	name:   string = "unnamed",
	dir:    Vec3   = Vec3.UP,   // a type-scoped constant as a default
	stats:  Stats,              // nested defaults apply without an explicit `=`
	lookup: [3]int = {7, 8, 9},

	describe :: proc() {
		fmt.printfln("%s: hp=%d dir=%v speed=%v lookup=%v", name, hp, dir, stats.speed, lookup)
	},
}

g_world: World // globals get defaults too

main :: proc() {
	fmt.println("Vec3.UP =", Vec3.UP, " scaled:", Vec3.scaled(Vec3.UP, 2))

	v := Vec3{3, 0, 0}
	fmt.println("v.scaled(2) =", v.scaled(2)) // UFCS on the impl method

	w: World // no initializer: all defaults
	w.describe()

	w2 := World{hp = 5, name = "boss"} // partial literal: rest defaulted
	w2.describe()

	g_world.describe()

	id: World.Id = 7
	buf: [World.MAX_ENTITIES]u8 // constant context
	fmt.println("id =", id, " capacity =", len(buf))

	p := new(World) // heap stays zero...
	p^ = {}         // ...until an empty literal applies the defaults
	p.describe()
	free(p)
}
