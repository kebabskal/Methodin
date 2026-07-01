package vendor_box3d

// Hand-written math primitives (the generator skips these). Declared as Odin array /
// matrix types so they get native arithmetic and swizzles — mirrors vendor:box2d's
// `Vec2 :: [2]f32`. Layouts are ABI-identical to the box3d C structs.

Vec2 :: [2]f32 // b3Vec2 { float x, y }
Vec3 :: [3]f32 // b3Vec3 { float x, y, z }
Pos  :: [3]f64 // b3Pos  { double x, y, z } — double-precision world translation

// b3Quat { b3Vec3 v; float s } — imaginary xyz then scalar w.
Quat :: struct {
	x, y, z, w: f32,
}
QUAT_IDENTITY :: Quat{0, 0, 0, 1}

// b3Matrix3 { b3Vec3 cx, cy, cz } — three columns; matches Odin's column-major layout.
Matrix3 :: matrix[3, 3]f32

// b3Transform { b3Vec3 p; b3Quat q }
Transform :: struct {
	p: Vec3,
	q: Quat,
}

// b3Plane { b3Vec3 normal; float offset }
Plane :: struct {
	normal: Vec3,
	offset: f32,
}
