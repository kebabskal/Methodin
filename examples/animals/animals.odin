// Methodin demo: inheritance via `using` + `impl` blocks + union dispatch.
//
// `Animal` declares `introduce` as an in-struct proc. `Dog` and `Cat` each
// embed `Animal` with `using`, so they inherit `introduce` automatically.
// Their own `speak` method is declared in a separate `impl` block — same
// desugaring as an in-struct proc, just lifted from a different syntax.
// Calling `p.speak()` on `Pet` expands to a `switch v in p` over the
// known variants.

package animals

import "core:fmt"

Animal :: struct {
	name: string,

	introduce :: proc() {
		fmt.printfln("Hi, I'm %s.", name)
	},
}

Dog :: struct {
	using animal: Animal,
}

impl Dog {
	speak :: proc() {
		fmt.printfln("%s: woof!", name)
	}
}

Cat :: struct {
	using animal: Animal,
}

impl Cat {
	speak :: proc() {
		fmt.printfln("%s: meow.", name)
	}
}

Pet :: union {
	Dog,
	Cat,
}

main :: proc() {
	rex     := Dog{animal = {name = "Rex"}}
	mittens := Cat{animal = {name = "Mittens"}}

	rex.introduce()     // inherited from Animal via `using`
	mittens.introduce()

	pets := []Pet{rex, mittens}
	for &p in pets {
		p.speak()       // union-dispatched: Dog__speak vs Cat__speak
	}
}
