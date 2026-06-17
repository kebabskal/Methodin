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

// Two structs in the same file declaring methods with the same name.
// Lifted versions are mangled (`Hero__attack`, `Goblin__attack`) and
// merged into a synthesised proc group `attack`. UFCS resolution
// auto-`&`s the receiver and overload resolution picks the right
// member by first-arg type.
Hero :: struct {
	mp: int,
	attack :: proc() -> int {
		mp -= 1
		return 50
	},
}

Goblin :: struct {
	rage: int,
	attack :: proc() -> int {
		rage += 1
		return 10 * rage
	},
}

@test
test_method_name_collision_becomes_proc_group :: proc(t: ^testing.T) {
	h := Hero{mp = 5}
	g := Goblin{rage = 0}

	testing.expect_value(t, h.attack(), 50)
	testing.expect_value(t, h.mp, 4)

	testing.expect_value(t, g.attack(), 10)
	testing.expect_value(t, g.attack(), 20)
	testing.expect_value(t, g.rage, 2)
}

// In-struct and impl methods can coexist on the same type — both
// forms feed the same lifting machinery.
Mage :: struct {
	mp:        int,
	cast_spell :: proc() {
		mp -= 1
	},
}

impl Mage {
	rest :: proc() {
		mp = 10
	}
}

@test
test_in_struct_and_impl_block_on_same_type :: proc(t: ^testing.T) {
	m := Mage{mp = 3}
	m.cast_spell()
	m.cast_spell()
	testing.expect_value(t, m.mp, 1)
	m.rest()
	testing.expect_value(t, m.mp, 10)
}

// A method can call another method on `self` via UFCS — `self.other()`
// works because `self` is in scope. This exercises the chained-call
// path through the lifted proc body.
Account :: struct {
	balance: int,

	deposit :: proc(amount: int) {
		balance += amount
	},

	withdraw :: proc(amount: int) {
		balance -= amount
	},

	transfer_to :: proc(other: ^Account, amount: int) {
		self.withdraw(amount)
		other.deposit(amount)
	},
}

@test
test_method_calls_method_via_self :: proc(t: ^testing.T) {
	a := Account{balance = 100}
	b := Account{balance = 0}
	a.transfer_to(&b, 30)
	testing.expect_value(t, a.balance, 70)
	testing.expect_value(t, b.balance, 30)
}
