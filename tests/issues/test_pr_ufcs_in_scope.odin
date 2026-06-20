package test_issues

import "core:testing"
import "core:math"
import "core:math/linalg"

// UFCS in-scope resolution (Methodin extension): when a method call `x.foo(...)`
// can't be resolved in the receiver type's own package or via its `using`
// chain, the compiler also searches the packages in scope at the call site —
// the current package plus everything it imports. This is what lets a method
// live in a package the receiver type has no nominal link to, e.g. calling
// `v.normalize()` on a plain `[3]f32` and having it route to
// `core:math/linalg.normalize`.

@test
test_ufcs_linalg_vector_methods :: proc(t: ^testing.T) {
	v := [3]f32{3, 0, 4}

	// `normalize` is a proc group in linalg whose vector overload takes
	// `$T/[$N]$E`; UFCS finds it because this file imports linalg.
	n := v.normalize()
	testing.expect_value(t, n, [3]f32{0.6, 0, 0.8})

	// Single (non-group) free proc in the same imported package.
	l := v.length()
	testing.expect_value(t, l, 5)

	a := [3]f32{1, 0, 0}
	b := [3]f32{0, 1, 0}
	testing.expect_value(t, a.cross(b), [3]f32{0, 0, 1})
	testing.expect_value(t, a.dot(b), 0)
}

// A free proc declared in the *current* package is reachable as a method on a
// fixed-array receiver too — the call-site package is searched alongside imports.
scaled :: proc(v: [2]f32, k: f32) -> [2]f32 {
	return {v.x * k, v.y * k}
}

@test
test_ufcs_local_package_array_method :: proc(t: ^testing.T) {
	v := [2]f32{2, 3}
	testing.expect_value(t, v.scaled(10), [2]f32{20, 30})
}

// Two in-scope packages can export the same name without making the call
// ambiguous, as long as only one actually accepts the receiver type. Here both
// `core:math` and `core:math/linalg` export `normalize`, but math's overloads
// take scalar floats while linalg's take vectors — so `v.normalize()` on a
// vector resolves unambiguously to linalg, and the scalar form is still usable
// explicitly.
@test
test_ufcs_same_name_different_receiver :: proc(t: ^testing.T) {
	v := [3]f32{3, 0, 4}
	testing.expect_value(t, v.normalize(), [3]f32{0.6, 0, 0.8})

	y, _ := math.normalize(f32(0.5))
	testing.expect_value(t, y, 0.5)
}
