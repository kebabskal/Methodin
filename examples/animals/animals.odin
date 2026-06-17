package animals

import "core:fmt"

Animal :: struct {
	greet::proc(name:string) {
		fmt.println("Hi,", name, "!")
	}
}

Dog :: struct {
	using animal:Animal,
	greet::proc(name:string) {
		fmt.println("Woof,", name, "!")
	}
}

Cat :: struct {
	using animal:Animal,
	greet::proc(name:string) {
		fmt.println("Meow,", name, "!")
	}
}


Thing::union {
	Animal,
	Dog
}


main :: proc() {
	a:Animal
	b:Dog

	things:[]Thing = {
		a,
		b
	}

	for &thing in things {
		thing.greet("MineDrabe")
	}
}