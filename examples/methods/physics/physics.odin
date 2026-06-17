// A sibling package used by the methods demo. Its only purpose is to live
// in a *different* package from the outer struct that embeds it — so that
// the UFCS lookup has to walk through `using` fields and into another
// package's scope to find the methods below.

package physics

Body :: struct {
	x, y:   f32,
	vx, vy: f32,
	mass:   f32,
}

apply_force :: proc(b: ^Body, fx, fy: f32) {
	if b.mass <= 0 {
		return
	}
	b.vx += fx / b.mass
	b.vy += fy / b.mass
}

integrate :: proc(b: ^Body, dt: f32) {
	b.x += b.vx * dt
	b.y += b.vy * dt
}
