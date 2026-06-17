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

// Union variant dispatch: when every variant of a union has a method
// of the same name, the compiler synthesises a dispatcher that
// type-switches on the runtime variant and forwards to the matching
// per-variant method. Calling `u.method(...)` on a union value then
// works the same as calling it on a concrete variant.
Cat :: struct {
	noise: int,

	speak :: proc() -> int {
		noise += 1
		return noise * 10
	},
}

Mouse :: struct {
	noise: int,

	speak :: proc() -> int {
		noise += 1
		return noise
	},
}

Critter :: union {
	Cat,
	Mouse,
}

// Inside an in-struct method body, a bare call to another method on
// the same struct should resolve via UFCS as `self.<method>(...)`. The
// lift pass rewrites the body so the user doesn't have to write the
// `self.` prefix explicitly — mirrors implicit field access under
// `using self`.
Counter2 :: struct {
	value: int,

	bump :: proc() {
		value += 1
	},

	bump_n :: proc(n: int) {
		for _ in 0 ..< n {
			bump() // bare call → rewritten to self.bump()
		}
	},
}

@test
test_intra_struct_method_call :: proc(t: ^testing.T) {
	c := Counter2{value = 0}
	c.bump_n(5)
	testing.expect_value(t, c.value, 5)
}

@test
test_union_dispatch :: proc(t: ^testing.T) {
	critters: [2]Critter = {Cat{noise = 0}, Mouse{noise = 0}}

	cat_first  := critters[0].speak() // → Cat__speak: noise=1, returns 10
	mouse_first := critters[1].speak() // → Mouse__speak: noise=1, returns 1
	cat_again  := critters[0].speak() // → Cat__speak: noise=2, returns 20

	testing.expect_value(t, cat_first, 10)
	testing.expect_value(t, mouse_first, 1)
	testing.expect_value(t, cat_again, 20)
}

// Inheritance-aware union dispatch: a method that every variant
// reaches via a same-file `using` field (not declared directly on the
// variants themselves) must still synthesise a dispatcher. The
// dispatcher body is plain UFCS, so the `using`-walk picks up the
// inherited method on each branch.
Critter_Base :: struct {
	noise: int,
	bump :: proc() {
		noise += 1
	},
}

Wolf :: struct {
	using base: Critter_Base,
}

impl Wolf {
	speak :: proc() -> int {
		return noise * 10
	}
}

Owl :: struct {
	using base: Critter_Base,
}

impl Owl {
	speak :: proc() -> int {
		return noise
	}
}

Forest_Critter :: union {
	Wolf,
	Owl,
}

@test
test_union_dispatch_via_using :: proc(t: ^testing.T) {
	creatures: [2]Forest_Critter = {Wolf{}, Owl{}}

	creatures[0].bump() // dispatched on union, inherited from Critter_Base
	creatures[0].bump()
	creatures[1].bump()

	testing.expect_value(t, creatures[0].speak(), 20) // Wolf__speak: 2*10
	testing.expect_value(t, creatures[1].speak(), 1)  // Owl__speak: 1
}

// Polymorphic struct methods: when a struct has polymorphic params, the
// lift pass has to carry them through to the receiver type so the body
// can see the params and the checker can bind a concrete instantiation.
// Receiver becomes `^Volume($T, $N, ...)` — same dollar-prefixed names
// the struct uses, reintroduced on the lifted proc.
Volume :: struct($VOXEL_T: typeid, $SIZE_X, $SIZE_Y, $SIZE_Z: int) {
	voxels: [SIZE_X * SIZE_Y * SIZE_Z]VOXEL_T,

	index :: proc(x, y, z: int) -> int {
		return x + y * SIZE_X + z * SIZE_X * SIZE_Y
	},

	get :: proc(x, y, z: int) -> VOXEL_T {
		return voxels[index(x, y, z)]
	},

	in_bounds :: proc(x, y, z: int) -> bool {
		return x >= 0 && x < SIZE_X &&
		       y >= 0 && y < SIZE_Y &&
		       z >= 0 && z < SIZE_Z
	},
}

@test
test_polymorphic_struct_methods :: proc(t: ^testing.T) {
	v: Volume(int, 4, 4, 4)
	v.voxels[v.index(1, 2, 3)] = 42

	testing.expect_value(t, v.get(1, 2, 3), 42)
	testing.expect_value(t, v.in_bounds(1, 2, 3), true)
	testing.expect_value(t, v.in_bounds(-1, 0, 0), false)
	testing.expect_value(t, v.in_bounds(0, 4, 0), false)
}
