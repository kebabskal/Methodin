// Methodin demo: in-struct procs + union dispatch.
//
// Each variant declares its own `area` inline. The compiler lifts each to a
// free proc, mangles names, and synthesises a procedure group at file scope.
// Calling `s.area()` on a `union { Circle, Rectangle, Triangle }` expands to
// a `switch v in s` over the known variants — no vtable, no indirection.

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
