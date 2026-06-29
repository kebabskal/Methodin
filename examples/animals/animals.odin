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
	rex := Dog {
		animal = {name = "Rex"},
	}
	zelda := Cat {
		animal = {name = "Mittens"},
	}

	pets := []Pet{rex, zelda}
	for &p in pets {
		p.introduce() // union-dispatched even though `introduce` is inherited
		p.speak() // union-dispatched: Dog__speak vs Cat__speak
	}
}
