// Transparent hot reloading with `odin watch`.
//
// Run it:
//     odin watch examples/hot_reload
//
// Then, while it is running, edit the `fmt.printfln` line in `tick` below (change the
// message) and save. The running program picks up the new code on the next call —
// the loop keeps going and `counter` keeps its value across the reload.
//
// No special structure is required: this is an ordinary `package main` with an ordinary
// `main`. The compiler routes calls to package procedures through a dispatch table and
// exports package globals; `odin watch` rebuilds the package as a library on change and
// swaps the new code in while preserving global state.
package main

import "core:fmt"
import "core:time"

// An ordinary package global — its value survives across hot reloads.
counter: int

// Optional: a proc named `hot_reloaded` is called once after every reload, if it exists.
// Use it to react to a reload from userland (re-open files, reset caches, log, …).
hot_reloaded :: proc() {
	fmt.printfln("[app] reloaded (counter is still %d)", counter)
}

tick :: proc() {
	counter += 1
	// Edit this line while `odin watch` is running:
	fmt.printfln("tick %d", counter)
	time.sleep(500 * time.Millisecond)
}

main :: proc() {
	fmt.println("running — edit tick() and save to hot reload")
	for {
		tick()
	}
}
