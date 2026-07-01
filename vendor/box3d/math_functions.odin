package vendor_box3d

import "core:c"

// Cosine and sine pair.
// This uses a custom implementation designed for cross-platform determinism.
CosSin :: struct {
	cosine: f32,
	sine: f32,
}

// Axis aligned bounding box.
AABB :: struct {
	lowerBound: Vec3,
	upperBound: Vec3,
}

// The closest points between to segments or infinite lines.
SegmentDistanceResult :: struct {
	point1: Vec3,
	fraction1: f32,
	point2: Vec3,
	fraction2: f32,
}

foreign import lib { LIB_PATH }

@(link_prefix="b3", default_calling_convention="c")
foreign lib {
	// @return is this float valid (finite and not NaN).
	IsValidFloat :: proc(a: f32) -> bool ---
	// Compute an approximate arctangent in the range [-pi, pi]
	// This is hand coded for cross-platform determinism. The atan2f
	// function in the standard library is not cross-platform deterministic.
	// Accurate to around 0.0023 degrees.
	Atan2 :: proc(y: f32, x: f32) -> f32 ---
	// Compute the cosine and sine of an angle in radians. Implemented
	// for cross-platform determinism.
	ComputeCosSin :: proc(radians: f32) -> CosSin ---
	// Extract a quaternion from a rotation matrix.
	MakeQuatFromMatrix :: proc(m: ^Matrix3) -> Quat ---
	// Find a quaternion that rotates one vector to another.
	ComputeQuatBetweenUnitVectors :: proc(v1: Vec3, v2: Vec3) -> Quat ---
	// Get the inertia tensor of an offset point.
	// https://en.wikipedia.org/wiki/Parallel_axis_theorem
	Steiner :: proc(mass: f32, origin: Vec3) -> Matrix3 ---
	// Compute the closest point on the segment a-b to the target q.
	PointToSegmentDistance :: proc(a: Vec3, b: Vec3, q: Vec3) -> Vec3 ---
	// Compute the closest points on two infinite lines.
	LineDistance :: proc(p1: Vec3, d1: Vec3, p2: Vec3, d2: Vec3) -> SegmentDistanceResult ---
	// Compute the closest points on two line segments.
	SegmentDistance :: proc(p1: Vec3, q1: Vec3, p2: Vec3, q2: Vec3) -> SegmentDistanceResult ---
	// Is this a valid vector? Not NaN or infinity.
	IsValidVec3 :: proc(a: Vec3) -> bool ---
	// Is this a valid quaternion? Not NaN or infinity. Is normalized.
	IsValidQuat :: proc(q: Quat) -> bool ---
	// Is this a valid transform? Not NaN or infinity. Is normalized.
	IsValidTransform :: proc(a: Transform) -> bool ---
	// Is this a valid matrix? Not NaN or infinity.
	IsValidMatrix3 :: proc(a: Matrix3) -> bool ---
	// Is this a valid bounding box? Not Nan or infinity. Upper bound greater than or equal to lower bound.
	IsValidAABB :: proc(a: AABB) -> bool ---
	// Is this AABB reasonably close to the origin? See B3_HUGE.
	IsBoundedAABB :: proc(a: AABB) -> bool ---
	// Is this AABB valid and reasonable?
	IsSaneAABB :: proc(a: AABB) -> bool ---
	// Is this a valid plane? Normal is a unit vector. Not Nan or infinity.
	IsValidPlane :: proc(a: Plane) -> bool ---
	// Is this a valid world position? Not NaN or infinity.
	IsValidPosition :: proc(p: Vec3) -> bool ---
	// Is this a valid world transform? Not NaN or infinity. Rotation is normalized.
	IsValidWorldTransform :: proc(t: Transform) -> bool ---
}
