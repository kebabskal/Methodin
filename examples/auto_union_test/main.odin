package main

import "core:fmt"

// A base "class" with in-struct methods (Methodin). Methods operate on the
// implicit `self`, so they read/write the struct's own fields directly.
Entity :: struct {
	hp:    int,
	alive: bool,

	take_damage :: proc(amount: int) {
		hp -= amount
		if hp <= 0 {
			alive = false
		}
	},

	describe :: proc() -> string {
		return fmt.tprintf("hp=%d alive=%t", hp, alive)
	},
}

// Subtypes embed the base at offset 0 via `using` (single inheritance).
Player :: struct {
	using entity: Entity,
	score:        int,
}

Enemy :: struct {
	using entity: Entity,
	power:        int,
}

ExploderEnemy :: struct {
	using enemy: Enemy, // transitive: Enemy -> Entity, still at offset 0
	radius:      f32,
}

// The polymorphic value type: a tagged union of every struct that `using`-embeds
// Entity. Sized to the largest variant; stored inline, no pointers/boxing.
BaseEntity :: auto_union(Entity)

main :: proc() {
	entities: [dynamic]BaseEntity
	defer delete(entities)

	// UFCS: `entities.append(...)` instead of `append(&entities, ...)`.
	entities.append(Player{entity = {hp = 100, alive = true}, score = 0})
	entities.append(Enemy{entity = {hp = 40, alive = true}, power = 8})
	entities.append(ExploderEnemy{enemy = {entity = {hp = 20, alive = true}, power = 25}, radius = 3})

	// Shared-base fields are promoted onto the union (offset-0): no switch, no
	// narrowing. `for &e` gives a pointer into each slot, so writes land.
	for &e in entities {
		e.hp += 5
		e.alive = true
	}

	// Methods on a concrete value are promoted through `using` and mutate in
	// place (self is a pointer).
	p := Player{entity = {hp = 30, alive = true}}
	p.take_damage(5)
	fmt.println("player:", p.describe())

	// Variant-specific behavior: narrow to the variant, then call its (promoted)
	// method through the in-place pointer so mutation writes back to the slot.
	for &e in entities {
		#partial switch _ in e {
		case Player:
			(&e.(Player)).take_damage(1)
		case Enemy:
			(&e.(Enemy)).take_damage(2)
		case ExploderEnemy:
			(&e.(ExploderEnemy)).take_damage(3)
		}
	}

	// Read the promoted base fields directly off each union value (no narrowing).
	// NOTE: a base *method* call on the union (e.g. `e.describe()`) is not yet
	// supported -- that needs method promotion through the union receiver. Field
	// promotion (`e.hp`, `e.alive`) works today.
	for e in entities {
		fmt.printfln("entity: hp=%d alive=%t", e.hp, e.alive)
	}

	fmt.printfln("sizeof(BaseEntity)=%d", size_of(BaseEntity))
}
