package vendor_box3d

import "core:c"

// World id references a world instance. This should be treated as an opaque handle.
WorldId :: struct {
	index1: c.ushort,
	generation: c.ushort,
}

// Body id references a body instance. This should be treated as an opaque handle.
BodyId :: struct {
	index1: c.int,
	world0: c.ushort,
	generation: c.ushort,
}

// Shape id references a shape instance. This should be treated as an opaque handle.
ShapeId :: struct {
	index1: c.int,
	world0: c.ushort,
	generation: c.ushort,
}

// Joint id references a joint instance. This should be treated as an opaque handle.
JointId :: struct {
	index1: c.int,
	world0: c.ushort,
	generation: c.ushort,
}

// Contact id references a contact instance. This should be treated as an opaque handle.
ContactId :: struct {
	index1: c.int,
	world0: c.ushort,
	padding: c.short,
	generation: c.uint,
}

