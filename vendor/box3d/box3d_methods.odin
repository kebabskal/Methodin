package vendor_box3d

import "core:c"

// Optional Methodin sugar over the flat C binding. The id handles are wrapped in tiny
// structs with methods hung off them, so `world.step(dt)` / `body.add_sphere(...)` reads
// instead of `World_Step(id, dt, 4)`. Zero-cost — each wrapper is just its id handle.
// Reach for the flat b3 API for anything not wrapped here.

DEFAULT_QUERY_FILTER :: QueryFilter{categoryBits = 1, maskBits = 0xffff_ffff_ffff_ffff}

World :: struct {
	using id: WorldId,

	step :: proc(dt: f32, sub_steps: c.int = 4) {
		World_Step(id, dt, sub_steps)
	},
	// Closest hit along the segment origin -> origin+translation (check .hit).
	cast_ray :: proc(origin, translation: Vec3, filter := DEFAULT_QUERY_FILTER) -> RayResult {
		return World_CastRayClosest(id, origin, translation, filter)
	},
	// Sweep a capsule mover; returns the fraction [0,1] it travels before hitting.
	cast_mover :: proc(origin: Vec3, mover: Capsule, translation: Vec3, filter := DEFAULT_QUERY_FILTER) -> f32 {
		m := mover
		return World_CastMover(id, origin, &m, translation, filter, nil, nil)
	},
	add_body :: proc(def: BodyDef) -> Body {
		d := def
		return Body{id = CreateBody(id, &d)}
	},
	add_static_body :: proc(position: Vec3) -> Body {
		d := DefaultBodyDef()
		d.type = .staticBody
		d.position = position
		return Body{id = CreateBody(id, &d)}
	},
	add_dynamic_body :: proc(position: Vec3) -> Body {
		d := DefaultBodyDef()
		d.type = .dynamicBody
		d.position = position
		return Body{id = CreateBody(id, &d)}
	},
	destroy :: proc() {DestroyWorld(id)},
}

Body :: struct {
	using id: BodyId,

	position     :: proc() -> Vec3 {return Body_GetPosition(id)},
	velocity     :: proc() -> Vec3 {return Body_GetLinearVelocity(id)},
	set_velocity :: proc(v: Vec3) {Body_SetLinearVelocity(id, v)},
	rotation     :: proc() -> Quat {return Body_GetRotation(id)},
	teleport     :: proc(position: Vec3, rotation := QUAT_IDENTITY) {Body_SetTransform(id, position, rotation)},
	apply_force  :: proc(force: Vec3, wake := true) {Body_ApplyForceToCenter(id, force, wake)},
	apply_impulse :: proc(impulse: Vec3, wake := true) {Body_ApplyLinearImpulseToCenter(id, impulse, wake)},

	add_sphere :: proc(sphere: Sphere, density: f32 = 1) -> Shape {
		d := DefaultShapeDef()
		d.density = density
		s := sphere
		return Shape{id = CreateSphereShape(id, &d, &s)}
	},
	add_capsule :: proc(capsule: Capsule, density: f32 = 1) -> Shape {
		d := DefaultShapeDef()
		d.density = density
		cap := capsule
		return Shape{id = CreateCapsuleShape(id, &d, &cap)}
	},
	add_box :: proc(half_extents: Vec3, density: f32 = 1) -> Shape {
		d := DefaultShapeDef()
		d.density = density
		// BoxHull.base (a HullData) sits at offset 0, so &hull is a valid ^HullData.
		hull := MakeBoxHull(half_extents.x, half_extents.y, half_extents.z)
		return Shape{id = CreateHullShape(id, &d, cast(^HullData)&hull)}
	},
	destroy :: proc() {DestroyBody(id)},
}

Shape :: struct {
	using id: ShapeId,
}

// Constructor mirroring DefaultWorldDef + CreateWorld, with a gravity shortcut.
create_world :: proc(gravity := Vec3{0, -10, 0}) -> World {
	def := DefaultWorldDef()
	def.gravity = gravity
	return World{id = CreateWorld(&def)}
}
