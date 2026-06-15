// Demonstrates method-call syntax (UFCS) in Odin.
//
// `x.foo(args)` desugars to `foo(x, args)` when `foo` is not a field of x
// but IS a free procedure declared in x's type's owning package. The
// receiver is implicitly addressed when the parameter is a pointer (and
// the receiver is addressable). Field selectors always take precedence
// over UFCS — there is no ambiguity.
//
// Nothing about this is dynamic dispatch: every call resolves at the call
// site to a known procedure (or one variant of a procedure group). There
// is no vtable, no extra indirection, and the inliner sees through it.

package main

import "core:fmt"

Vec2 :: struct { x, y: f32 }

// A handful of free procedures that take a Vec2 (or ^Vec2) as the first
// parameter. With UFCS these read like methods at the call site.

add :: proc(a, b: Vec2) -> Vec2 {
	return Vec2{a.x + b.x, a.y + b.y}
}

dot :: proc(a, b: Vec2) -> f32 {
	return a.x*b.x + a.y*b.y
}

length_squared :: proc(v: Vec2) -> f32 {
	return v.x*v.x + v.y*v.y
}

scale_by :: proc(v: ^Vec2, k: f32) {
	v.x *= k
	v.y *= k
}

// A `Player` whose physics step is built out of those Vec2 helpers,
// written method-style for readability.

Player :: struct {
	pos, vel: Vec2,
	hp:       int,
}

step :: proc(p: ^Player, dt: f32) {
	// `p.vel.scale_by(...)` — receiver `p.vel` is addressable
	// (it's a field of `p^`), so the compiler auto-takes its address
	// to match scale_by's `^Vec2` parameter.
	p.vel.scale_by(0.98)            // drag
	p.pos = p.pos.add(p.vel)        // value receiver, no auto-&
}

damage :: proc(p: ^Player, amount: int) {
	p.hp -= amount
}

// A tagged union of shape variants. Methods on the union itself dispatch
// via `switch v in s` at compile time — the compiler statically knows all
// variants, so there's no vtable. Each variant is a plain struct that can
// also carry its own methods.

Circle    :: struct { r: f32 }
Rectangle :: struct { w, h: f32 }
Triangle  :: struct { base, height: f32 }

Shape :: union { Circle, Rectangle, Triangle }

area :: proc(s: Shape) -> f32 {
	switch v in s {
	case Circle:    return 3.14159265 * v.r * v.r
	case Rectangle: return v.w * v.h
	case Triangle:  return 0.5 * v.base * v.height
	}
	return 0
}

scale :: proc(s: ^Shape, k: f32) {
	switch &v in s {
	case Circle:    v.r *= k
	case Rectangle: v.w *= k; v.h *= k
	case Triangle:  v.base *= k; v.height *= k
	}
}

// A free proc on the array itself: `shapes.total_area()` reads naturally
// even though it's just iterating an Odin slice/dynamic array.
total_area :: proc(shapes: []Shape) -> f32 {
	sum: f32
	for s in shapes {
		sum += s.area()
	}
	return sum
}

main :: proc() {
	// --- methods on a user struct ---
	p := Player{
		pos = Vec2{0, 0},
		vel = Vec2{3, 4},
		hp  = 100,
	}

	for _ in 0..<3 {
		p.step(1.0/60)
	}
	p.damage(15)

	fmt.printfln("player after 3 steps + 1 hit: pos=%v hp=%d", p.pos, p.hp)

	// --- methods on built-in containers (resolved in base:runtime) ---
	// `append`, `clear`, `delete` are all regular procedure groups that
	// take a pointer to the container as the first parameter — they light
	// up automatically under UFCS.

	scores: [dynamic]int
	scores.append(10)
	scores.append(20, 30, 40)
	fmt.printfln("scores: %v (len=%d)", scores, len(scores))

	scores.clear()
	scores.append(99)
	fmt.printfln("after clear+append: %v", scores)

	delete(scores) // either form works — `scores.delete()` would too

	// --- methods on a tagged union held in a [dynamic] array ---
	// Each Shape is one of {Circle, Rectangle, Triangle}. `shape.area()`
	// expands to `area(shape)`, which switches on the variant. There is
	// no vtable: the switch is statically known and inlinable.

	shapes: [dynamic]Shape
	shapes.append(Circle{r = 2}, Rectangle{w = 3, h = 4}, Triangle{base = 5, height = 6})

	shapes[1].scale(2)

	for s, i in shapes {
		fmt.printfln("  shape[%d] area = %.2f", i, s.area())
	}
	fmt.printfln("total area = %.2f", total_area(shapes[:]))

	delete(shapes)

	// --- comparison: the same physics step without method syntax ---
	// step(&p, 1.0/60) and dot(p.vel, p.vel) still work; UFCS is purely
	// additive — every call is equivalent to its free-proc form.
	speed_sq := dot(p.vel, p.vel)
	speed_sq2 := p.vel.dot(p.vel)
	fmt.assertf(speed_sq == speed_sq2, "UFCS and free-call must agree (%v vs %v)", speed_sq, speed_sq2)

	fmt.println("OK")
}
