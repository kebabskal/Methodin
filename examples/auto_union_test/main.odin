package main

import "core:fmt"

Entity :: struct {
	hp: int,

	describe :: proc() -> string {
		return fmt.tprintf("hp=%d", hp)
	},
}

Player :: struct {
	using entity: Entity,
	score: int,
}

Enemy :: struct {
	using entity: Entity,
	damage: int,
}

ExploderEnemy :: struct {
	using enemy: Enemy, // transitive: Enemy -> Entity at offset 0
	radius: f32,
}

// Not an entity: embeds something else, must NOT be collected.
Widget :: struct {
	label: string,
}

// Stores an auto_union by value in an unrelated struct (size must be correct).
Inventory :: struct {
	holder: BaseEntity,
}

BaseEntity :: auto_union(Entity)

take_enemy :: proc(en: Enemy) {
	fmt.printfln("take_enemy: hp=%d damage=%d", en.hp, en.damage)
}

main :: proc() {
	entities: [dynamic]BaseEntity
	defer delete(entities)

	append(&entities, Player{entity = {hp = 100}, score = 5})
	append(&entities, Enemy{entity = {hp = 30}, damage = 7})
	append(&entities, ExploderEnemy{enemy = {entity = {hp = 10}, damage = 50}, radius = 2.5})

	// (1) method on a concrete value: promoted through `using` (works today)
	p := Player{entity = {hp = 100}, score = 5}
	fmt.printfln("Player.describe() = %s", p.describe())

	// (2) method on a variant recovered from the union via a type switch.
	// NOTE: calling the method directly on the switch capture `v` currently
	// fails (Methodin UFCS doesn't take the address of a switch binding for
	// `self`); copying into a local works. Tracked as a Methodin gap.
	for e in entities {
		#partial switch v in e {
		case Player:
			inst := v
			fmt.printfln("Player %s score=%d", inst.describe(), inst.score)
		case Enemy:
			inst := v
			fmt.printfln("Enemy %s damage=%d", inst.describe(), inst.damage)
		case ExploderEnemy:
			inst := v
			fmt.printfln("ExploderEnemy %s damage=%d radius=%.1f", inst.describe(), inst.damage, inst.radius)
		}
	}

	// (3) passing a union value to a proc that takes a *subtype*: must narrow
	// with a type assertion (checked). Implicit `take_enemy(some_base)` is an
	// error, because the union might hold a different variant.
	be: BaseEntity = Enemy{entity = {hp = 30}, damage = 9}
	take_enemy(be.(Enemy)) // checked assertion
	if en, ok := be.(Enemy); ok {
		take_enemy(en) // safe form
	}

	// NOTE: a method call directly on the union value (e.describe()) is not yet
	// supported -- that needs offset-0 member promotion on the union itself.

	inv: Inventory
	inv.holder = Player{entity = {hp = 1}}
	fmt.printfln("sizeof(BaseEntity)=%d sizeof(Inventory)=%d", size_of(BaseEntity), size_of(Inventory))
}
