package test_issues

import "core:testing"

// In-struct proc decls (Methodin extension): `name :: proc(...) { body }`
// declared inside a struct body desugars to a package-scope free proc
// `name :: proc(using self: ^Struct, ...) { body }`. UFCS then routes
// `x.name(...)` to it; `using self` makes struct fields directly visible.

Player :: struct {
	hp: int,

	damage :: proc(amount: int) {
		hp -= amount
	},

	heal :: proc(amount: int) {
		hp += amount
	},
}

@test
test_in_struct_proc_basic :: proc(t: ^testing.T) {
	p := Player{hp = 100}
	p.damage(30)
	testing.expect_value(t, p.hp, 70)
	p.heal(5)
	testing.expect_value(t, p.hp, 75)
}

// Methods can also be the only members of a struct — no regular fields
// required.
Counter :: struct {
	value: int,

	bump :: proc() {
		value += 1
	},
}

@test
test_in_struct_proc_only_method :: proc(t: ^testing.T) {
	c := Counter{value = 0}
	c.bump()
	c.bump()
	c.bump()
	testing.expect_value(t, c.value, 3)
}

// Methods can be called directly as free procs too — they're regular
// package-scope procs, just declared in a different place.
@test
test_in_struct_proc_free_call_form :: proc(t: ^testing.T) {
	p := Player{hp = 100}
	damage(&p, 25)
	testing.expect_value(t, p.hp, 75)
}

// `impl Type { ... }` is the second supported form — methods declared
// in a block separate from the struct definition (often a different
// file). Same desugaring: each method becomes a free proc with `using
// self: ^Type` prepended.
Box :: struct {
	w, h: int,
}

impl Box {
	scale :: proc(factor: int) {
		w *= factor
		h *= factor
	}

	area :: proc() -> int {
		return w * h
	}
}

@test
test_impl_block :: proc(t: ^testing.T) {
	b := Box{w = 3, h = 4}
	testing.expect_value(t, b.area(), 12)
	b.scale(2)
	testing.expect_value(t, b.w, 6)
	testing.expect_value(t, b.h, 8)
	testing.expect_value(t, b.area(), 48)
}
