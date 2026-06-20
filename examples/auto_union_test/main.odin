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

// Non-embedder structs may reference the union (by value or in a container)
// without being collected as variants — this must not trip the collector into a
// "not a type" / declaration-cycle error while the union is being resolved.
Inventory :: struct {
	holder: BaseEntity,
}
World :: struct {
	entities: [dynamic]BaseEntity,
}

main :: proc() {
	entities: [dynamic]BaseEntity
	defer delete(entities)

	// UFCS: `entities.append(...)` instead of `append(&entities, ...)`.
	entities.append(Player{entity = {hp = 100, alive = true}, score = 0})
	entities.append(Enemy{entity = {hp = 40, alive = true}, power = 8})
	entities.append(
		ExploderEnemy{enemy = {entity = {hp = 20, alive = true}, power = 25}, radius = 3},
	)

	// Shared-base fields are promoted onto the union (offset-0): no switch, no
	// narrowing. `for &e` gives a pointer into each slot, so writes land.
	for &e in entities {
		e.hp += 5
		e.alive = true
	}

	// Methods on a concrete value are promoted through `using` and mutate in
	// place (self is a pointer).
	p := Player {
		entity = {hp = 30, alive = true},
	}
	p.take_damage(5)
	fmt.println("player:", p.describe())

	// Base methods are promoted onto the union too: call `take_damage` directly
	// on each slot, switch-free. `for &e` gives a pointer, so self writes back.
	for &e in entities {
		e.take_damage(5)
	}

	// Base method returning a value, called directly on each slot (`for &e` so
	// the receiver is addressable, which promotion needs to reinterpret as ^T).
	for &e in entities {
		fmt.println("entity:", e.describe())
	}

	fmt.printfln(
		"sizeof(BaseEntity)=%d Inventory=%d World=%d",
		size_of(BaseEntity),
		size_of(Inventory),
		size_of(World),
	)
}
