// Methodin demo: virtual dispatch of a method's *internal* sibling calls,
// with no vtable. An inherited method (`init`) whose body calls another
// method (`get_name`) gets a polymorphic `^$Self/Parent` receiver, so each
// concrete receiver monomorphises the body and re-resolves that call against
// its own override. An explicit base call (`parent.get_name()`) stays bound to
// Parent — that's the "super" idiom, and it terminates.
//
// Expected output:
//   Parent: Child_A
//   Child_B: Parent Child_B
#+feature dynamic-literals
package main

import "core:fmt"

Parent :: struct {
	name: string,
	init :: proc() { name = get_name() },              // inherited; calls a sibling -> self-dispatch
	get_name :: proc() -> string { return "Parent" },
	speak :: proc() { fmt.println("Parent:", name) },
}

Child_A :: struct {
	using parent: Parent,
	get_name :: proc() -> string { return "Child_A" },
}

Child_B :: struct {
	using child_a: Child_A,                            // 3-level chain: Child_B -> Child_A -> Parent
	get_name :: proc() -> string { return fmt.aprint(parent.get_name(), "Child_B") }, // "super" call
	speak :: proc() { fmt.println("Child_B:", name) },
}

Thing :: auto_union(Parent)

main :: proc() {
	parent: Parent
	child_a: Child_A
	child_b: Child_B

	parent.init()
	child_a.init()   // Self = Child_A -> get_name() re-dispatches to Child_A's
	child_b.init()   // Self = Child_B -> Child_B's get_name(), whose super call -> Parent's

	things := [dynamic]Thing{child_a, child_b}
	for &thing in things {
		thing.speak() // union tag-dispatch: Parent__speak vs Child_B__speak
	}
}
