package vendor_box3d

import "core:c"

MeshQueryFcn :: rawptr  /* ? _Bool (b3Vec3, b3Vec3, b3Vec3, int, void *) */

foreign import lib { LIB_PATH }

@(link_prefix="b3", default_calling_convention="c")
foreign lib {
	// Constructing the tree initializes the node pool.
	DynamicTree_Create :: proc(proxyCapacity: c.int) -> DynamicTree ---
	// Destroy the tree, freeing the node pool.
	DynamicTree_Destroy :: proc(tree: ^DynamicTree) ---
	// Create a proxy. Provide an AABB and a userData value.
	DynamicTree_CreateProxy :: proc(tree: ^DynamicTree, aabb: AABB, categoryBits: c.ulong, userData: c.ulong) -> c.int ---
	// Destroy a proxy. This asserts if the id is invalid.
	DynamicTree_DestroyProxy :: proc(tree: ^DynamicTree, proxyId: c.int) ---
	// Move a proxy to a new AABB by removing and reinserting into the tree.
	DynamicTree_MoveProxy :: proc(tree: ^DynamicTree, proxyId: c.int, aabb: AABB) ---
	// Enlarge a proxy and enlarge ancestors as necessary.
	DynamicTree_EnlargeProxy :: proc(tree: ^DynamicTree, proxyId: c.int, aabb: AABB) ---
	// Modify the category bits on a proxy. This is an expensive operation.
	DynamicTree_SetCategoryBits :: proc(tree: ^DynamicTree, proxyId: c.int, categoryBits: c.ulong) ---
	// Get the category bits on a proxy.
	DynamicTree_GetCategoryBits :: proc(tree: ^DynamicTree, proxyId: c.int) -> c.ulong ---
	// Query an AABB for overlapping proxies. The callback function is called for each proxy that overlaps the supplied AABB.
	// @return performance data
	DynamicTree_Query :: proc(tree: ^DynamicTree, aabb: AABB, maskBits: c.ulong, requireAllBits: bool, callback: TreeQueryCallbackFcn, context_: rawptr) -> TreeStats ---
	// Query an AABB for the closest object. The callback function is called for each proxy that might be closest to the supplied point.
	// @param tree the dynamic tree to query
	// @param point the query point
	// @param maskBits nodes are skipped if the bit-wise AND with the node category bits is zero
	// @param requireAllBits nodes are skipped if the bit-wise AND with the node category bits does not equal the maskBits
	// @param callback a user provided instance of b3TreeQueryClosestCallbackFcn
	// @param context a user context object that is provided to the callback
	// @param minDistanceSqr the initial and final minimum squared distance. Provide a small initial to restrict the search and
	// improve performance. If the value is large this query has performance that scales linearly with the number of proxies and
	// would be slower than a brute force search.
	// @return performance data
	DynamicTree_QueryClosest :: proc(tree: ^DynamicTree, point: Vec3, maskBits: c.ulong, requireAllBits: bool, callback: TreeQueryClosestCallbackFcn, context_: rawptr, minDistanceSqr: ^f32) -> TreeStats ---
	// Ray cast against the proxies in the tree. This relies on the callback
	// to perform an exact ray cast in the case where the proxy contains a shape.
	// The callback also performs any collision filtering. This has performance
	// roughly equal to k * log(n), where k is the number of collisions and n is the
	// number of proxies in the tree.
	// Bit-wise filtering using mask bits can greatly improve performance in some scenarios.
	// However, this filtering may be approximate, so the user should still apply filtering to results.
	// @param tree the dynamic tree to ray cast
	// @param input the ray cast input data. The ray extends from p1 to p1 + maxFraction * (p2 - p1)
	// @param maskBits bit mask test: `bool accept = (maskBits & node->categoryBits) != 0;`
	// @param requireAllBits modifies bit mask test: `bool accept = (maskBits & node->categoryBits) == maskBits;`
	// @param callback a callback function that is called for each proxy that is hit by the ray
	// @param context user context that is passed to the callback
	// @return performance data
	DynamicTree_RayCast :: proc(tree: ^DynamicTree, input: ^RayCastInput, maskBits: c.ulong, requireAllBits: bool, callback: TreeRayCastCallbackFcn, context_: rawptr) -> TreeStats ---
	// Sweep an AABB through the tree. The box is in the tree's world float frame and the callback
	// re-differences each shape at full precision against the query origin. Used by the large world
	// spatial queries so the tree traversal stays float while the narrow phase stays precise.
	DynamicTree_BoxCast :: proc(tree: ^DynamicTree, input: ^BoxCastInput, maskBits: c.ulong, requireAllBits: bool, callback: TreeBoxCastCallbackFcn, context_: rawptr) -> TreeStats ---
	// Validate this tree. For testing.
	DynamicTree_Validate :: proc(tree: ^DynamicTree) ---
	// Get the height of the binary tree.
	DynamicTree_GetHeight :: proc(tree: ^DynamicTree) -> c.int ---
	// Get the ratio of the sum of the node areas to the root area.
	DynamicTree_GetAreaRatio :: proc(tree: ^DynamicTree) -> f32 ---
	// Get the bounding box that contains the entire tree
	DynamicTree_GetRootBounds :: proc(tree: ^DynamicTree) -> AABB ---
	// Get the number of proxies created
	DynamicTree_GetProxyCount :: proc(tree: ^DynamicTree) -> c.int ---
	// Rebuild the tree while retaining subtrees that haven't changed. Returns the number of boxes sorted.
	DynamicTree_Rebuild :: proc(tree: ^DynamicTree, fullBuild: bool) -> c.int ---
	// Get the number of bytes used by this tree
	DynamicTree_GetByteCount :: proc(tree: ^DynamicTree) -> c.int ---
	// Validate this tree has no enlarged AABBs. For testing.
	DynamicTree_ValidateNoEnlarged :: proc(tree: ^DynamicTree) ---
	// Save this tree to a file for debugging
	DynamicTree_Save :: proc(tree: ^DynamicTree, fileName: cstring) ---
	// Load a file for debugging
	DynamicTree_Load :: proc(fileName: cstring, scale: f32) -> DynamicTree ---
	// Create a tessellated cylinder as a hull.
	CreateCylinder :: proc(height: f32, radius: f32, yOffset: f32, sides: c.int) -> ^HullData ---
	// Create a tessellated cone as a hull.
	CreateCone :: proc(height: f32, radius1: f32, radius2: f32, slices: c.int) -> ^HullData ---
	// Create a rock shaped hull.
	CreateRock :: proc(radius: f32) -> ^HullData ---
	// Create a generic convex hull.
	CreateHull :: proc(points: ^Vec3, pointCount: c.int, maxVertexCount: c.int) -> ^HullData ---
	// Deep clone a hull.
	CloneHull :: proc(hull: ^HullData) -> ^HullData ---
	// Clone and transform a hull. Supports non-uniform and mirroring scale.
	CloneAndTransformHull :: proc(original: ^HullData, transform: Transform, scale: Vec3) -> ^HullData ---
	// Destroy a hull.
	DestroyHull :: proc(hull: ^HullData) ---
	// Make a cube as a hull. Do not call b3DestroyHull on this.
	MakeCubeHull :: proc(halfWidth: f32) -> BoxHull ---
	// Make a box as a hull. Do not call b3DestroyHull on this.
	MakeBoxHull :: proc(hx: f32, hy: f32, hz: f32) -> BoxHull ---
	// Make an offset box as a hull. Do not call b3DestroyHull on this.
	MakeOffsetBoxHull :: proc(hx: f32, hy: f32, hz: f32, offset: Vec3) -> BoxHull ---
	// Make a transformed box as a hull. Do not call b3DestroyHull on this.
	// @param hx, hy, hz positive half widths
	// @param transform local transform of box
	MakeTransformedBoxHull :: proc(hx: f32, hy: f32, hz: f32, transform: Transform) -> BoxHull ---
	// This makes a transformed box hull with post scaling. This is useful for boxes that are scaled in
	// a level editor. Such scaling can have reflection and shear. In the case of shear the result
	// may be approximate. If you need to support shear consider using b3CreateHull.
	// Do not call b3DestroyHull on this.
	// @param halfWidths positive half widths
	// @param transform local transform of box
	// @param postScale scale applied after the transform, may be negative
	MakeScaledBoxHull :: proc(halfWidths: Vec3, transform: Transform, postScale: Vec3) -> BoxHull ---
	// This takes a box with a transform and post scale and converts it into a box with the post scale
	// resolved with new half-widths and transform. This accepts non-uniform and negative scale.
	// This is approximate if there is shear.
	// @param halfWidths [in/out] the box half widths
	// @param transform [in/out] the box transform with rotation and translation
	// @param postScale the post scale being applied to the box after the transform
	// @param minHalfWidth the minimum half width after scale is applied
	ScaleBox :: proc(halfWidths: ^Vec3, transform: ^Transform, postScale: Vec3, minHalfWidth: f32) ---
	// Create a grid mesh along the x and z axes.
	// @param xCount the number of rows in the x direction
	// @param zCount the number of rows in the z direction
	// @param cellWidth the width of each cell
	// @param materialCount the number of materials to generate
	// @param identifyEdges compute adjacency information
	CreateGridMesh :: proc(xCount: c.int, zCount: c.int, cellWidth: f32, materialCount: c.int, identifyEdges: bool) -> ^MeshData ---
	// Create a wave mesh along the x and z axes.
	CreateWaveMesh :: proc(xCount: c.int, zCount: c.int, cellWidth: f32, amplitude: f32, rowFrequency: f32, columnFrequency: f32) -> ^MeshData ---
	// Create a torus mesh.
	CreateTorusMesh :: proc(radialResolution: c.int, tubularResolution: c.int, radius: f32, thickness: f32) -> ^MeshData ---
	// Create a box mesh.
	CreateBoxMesh :: proc(center: Vec3, extent: Vec3, identifyEdges: bool) -> ^MeshData ---
	// Create a hollow box mesh.
	CreateHollowBoxMesh :: proc(center: Vec3, extent: Vec3) -> ^MeshData ---
	// Create a platform mesh. A truncated pyramid.
	CreatePlatformMesh :: proc(center: Vec3, height: f32, topWidth: f32, bottomWidth: f32) -> ^MeshData ---
	// Create a generic mesh.
	CreateMesh :: proc(def: ^MeshDef, degenerateTriangleIndices: ^c.int, degenerateCapacity: c.int) -> ^MeshData ---
	// Destroy a mesh.
	DestroyMesh :: proc(mesh: ^MeshData) ---
	// Get the height of the mesh BVH.
	GetHeight :: proc(mesh: ^MeshData) -> c.int ---
	// Create a generic height field.
	CreateHeightField :: proc(data: ^HeightFieldDef) -> ^HeightFieldData ---
	// Create a grid as a height field.
	CreateGrid :: proc(rowCount: c.int, columnCount: c.int, scale: Vec3, makeHoles: bool) -> ^HeightFieldData ---
	// Create a wave grid as a height field.
	CreateWave :: proc(rowCount: c.int, columnCount: c.int, scale: Vec3, rowFrequency: f32, columnFrequency: f32, makeHoles: bool) -> ^HeightFieldData ---
	// Destroy a height field.
	DestroyHeightField :: proc(heightField: ^HeightFieldData) ---
	// Save input height data to a file
	DumpHeightData :: proc(data: ^HeightFieldDef, fileName: cstring) ---
	// Create a height field by loading a previously saved height data
	LoadHeightField :: proc(fileName: cstring) -> ^HeightFieldData ---
	// Get a child shape of a compound.
	GetCompoundChild :: proc(compound: ^CompoundData, childIndex: c.int) -> ChildShape ---
	// Query a compound shape for children that overlap an AABB.
	QueryCompound :: proc(compound: ^CompoundData, aabb: AABB, fcn: CompoundQueryFcn, context_: rawptr) ---
	// Access a child capsule by index.
	GetCompoundCapsule :: proc(compound: ^CompoundData, index: c.int) -> CompoundCapsule ---
	// Access a child hull by index.
	GetCompoundHull :: proc(compound: ^CompoundData, index: c.int) -> CompoundHull ---
	// Access a child mesh by index.
	GetCompoundMesh :: proc(compound: ^CompoundData, index: c.int) -> CompoundMesh ---
	// Access a child sphere by index.
	GetCompoundSphere :: proc(compound: ^CompoundData, index: c.int) -> CompoundSphere ---
	// Access the compound material array.
	GetCompoundMaterials :: proc(compound: ^CompoundData) -> ^SurfaceMaterial ---
	// Create a compound shape. All input data in the definition is cloned into the resulting compound.
	CreateCompound :: proc(def: ^CompoundDef) -> ^CompoundData ---
	// Destroy a compound shape.
	DestroyCompound :: proc(compound: ^CompoundData) ---
	// If bytes is null then this returns the number of required bytes. This clones all the
	// data into the bytes buffer. This is expected to run offline or asynchronously.
	// This mutates the compound to nullify pointers, leaving the compound in an unusable state.
	ConvertCompoundToBytes :: proc(compound: ^CompoundData) -> ^u8 ---
	// Convert bytes to compound. This does not clone. The bytes must remain in scope while the
	// compound is used. This is done to improve run-time performance and allow for instancing.
	// The bytes are mutated to fixup pointers.
	ConvertBytesToCompound :: proc(bytes: ^u8, byteCount: c.int) -> ^CompoundData ---
	// Compute mass properties of a sphere
	ComputeSphereMass :: proc(shape: ^Sphere, density: f32) -> MassData ---
	// Compute mass properties of a capsule
	ComputeCapsuleMass :: proc(shape: ^Capsule, density: f32) -> MassData ---
	// Compute mass properties of a hull
	ComputeHullMass :: proc(shape: ^HullData, density: f32) -> MassData ---
	// Compute the bounding box of a transformed sphere
	ComputeSphereAABB :: proc(shape: ^Sphere, transform: Transform) -> AABB ---
	// Compute the bounding box of a transformed capsule
	ComputeCapsuleAABB :: proc(shape: ^Capsule, transform: Transform) -> AABB ---
	// Compute the bounding box of a transformed hull
	ComputeHullAABB :: proc(shape: ^HullData, transform: Transform) -> AABB ---
	// Compute the bounding box of a transformed mesh. Scale may be non-uniform and have negative components.
	ComputeMeshAABB :: proc(shape: ^MeshData, transform: Transform, scale: Vec3) -> AABB ---
	// Compute the bounding box of a transformed height-field
	ComputeHeightFieldAABB :: proc(shape: ^HeightFieldData, transform: Transform) -> AABB ---
	// Compute the bounding box of a compound
	ComputeCompoundAABB :: proc(shape: ^CompoundData, transform: Transform) -> AABB ---
	// Use this to ensure your ray cast input is valid and avoid internal assertions.
	IsValidRay :: proc(input: ^RayCastInput) -> bool ---
	// Overlap shape versus capsule
	OverlapCapsule :: proc(shape: ^Capsule, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Overlap shape versus compound
	OverlapCompound :: proc(shape: ^CompoundData, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Overlap shape versus height field
	OverlapHeightField :: proc(shape: ^HeightFieldData, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Overlap shape versus hull
	OverlapHull :: proc(shape: ^HullData, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Overlap shape versus mesh
	OverlapMesh :: proc(shape: ^Mesh, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Overlap shape versus sphere
	OverlapSphere :: proc(shape: ^Sphere, shapeTransform: Transform, proxy: ^ShapeProxy) -> bool ---
	// Ray cast versus sphere in local space. A zero length ray is a point query. Initial overlap
	// reports a hit at the ray origin with zero fraction and zero normal.
	RayCastSphere :: proc(shape: ^Sphere, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus a hollow sphere shell in local space. Unlike the solid sphere a ray starting
	// inside is not an overlap: it passes through and hits the far wall.
	RayCastHollowSphere :: proc(shape: ^Sphere, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus capsule in local space. A zero length ray is a point query. Initial overlap
	// reports a hit at the ray origin with zero fraction and zero normal.
	RayCastCapsule :: proc(shape: ^Capsule, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus compound in local space. A zero length ray is a point query. Initial overlap
	// with a child reports a hit at the ray origin with zero fraction and zero normal.
	RayCastCompound :: proc(shape: ^CompoundData, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus hull shape in local space. A zero length ray is a point query. Initial overlap
	// reports a hit at the ray origin with zero fraction and zero normal.
	RayCastHull :: proc(shape: ^HullData, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus mesh in local space. A thin surface with no interior, so there is no overlap case.
	RayCastMesh :: proc(shape: ^Mesh, input: ^RayCastInput) -> CastOutput ---
	// Ray cast versus height field in local space. A thin surface with no interior, so there is no overlap case.
	RayCastHeightField :: proc(shape: ^HeightFieldData, input: ^RayCastInput) -> CastOutput ---
	// Shape cast versus a sphere. Initial overlap is treated as a miss.
	ShapeCastSphere :: proc(shape: ^Sphere, input: ^ShapeCastInput) -> CastOutput ---
	// Shape cast versus a capsule. Initial overlap is treated as a miss.
	ShapeCastCapsule :: proc(shape: ^Capsule, input: ^ShapeCastInput) -> CastOutput ---
	// Shape cast versus compound. Initial overlap is treated as a miss.
	ShapeCastCompound :: proc(shape: ^CompoundData, input: ^ShapeCastInput) -> CastOutput ---
	// Shape cast versus a hull. Initial overlap is treated as a miss.
	ShapeCastHull :: proc(shape: ^HullData, input: ^ShapeCastInput) -> CastOutput ---
	// Shape cast versus a mesh. Initial overlap is treated as a miss.
	ShapeCastMesh :: proc(shape: ^Mesh, input: ^ShapeCastInput) -> CastOutput ---
	// Shape cast versus a height field. Initial overlap is treated as a miss.
	ShapeCastHeightField :: proc(shape: ^HeightFieldData, input: ^ShapeCastInput) -> CastOutput ---
	// Query a mesh for triangles overlapping a bounding box in local space. May have false positives. Useful for debug draw.
	// @param mesh the mesh to query, includes scale
	// @param bounds the bounding box in local space
	// @param fcn a user function to collect triangles
	// @param context the context sent to the user function.
	QueryMesh :: proc(mesh: ^Mesh, bounds: AABB, fcn: MeshQueryFcn, context_: rawptr) ---
	// Query a height field for triangles overlapping a bounding box in local space. May have false positives. Useful for debug draw.
	// @param heightField the height field to query
	// @param bounds the bounding box in local space
	// @param fcn a user function to collect triangles
	// @param context the context sent to the user function.
	QueryHeightField :: proc(heightField: ^HeightFieldData, bounds: AABB, fcn: MeshQueryFcn, context_: rawptr) ---
	// Compute the closest points between two shapes represented as point clouds.
	// b3SimplexCache cache is input/output. On the first call set b3SimplexCache.count to zero.
	// The query runs in frame A, so the witness points and normal are returned in frame A.
	// The underlying GJK algorithm may be debugged by passing in debug simplexes and capacity. You may pass in NULL and 0 for these.
	ShapeDistance :: proc(input: ^DistanceInput, cache: ^SimplexCache, simplexes: ^Simplex, simplexCapacity: c.int) -> DistanceOutput ---
	// Perform a linear shape cast of shape B moving and shape A fixed. Determines the hit point, normal, and translation fraction.
	// The query runs in frame A, so the hit point and normal are returned in frame A. Initially touching shapes are a miss.
	ShapeCast :: proc(input: ^ShapeCastPairInput) -> CastOutput ---
	// Evaluate the transform sweep at a specific time.
	GetSweepTransform :: proc(sweep: ^Sweep, time: f32) -> Transform ---
	// Compute the upper bound on time before two shapes penetrate. Time is represented as
	// a fraction between [0,tMax]. This uses a swept separating axis and may miss some intermediate,
	// non-tunneling collisions. If you change the time interval, you should call this function
	// again.
	TimeOfImpact :: proc(input: ^TOIInput) -> TOIOutput ---
	// Collide two spheres.
	CollideSpheres :: proc(manifold: ^LocalManifold, capacity: c.int, sphereA: ^Sphere, sphereB: ^Sphere, transformBtoA: Transform) ---
	// Collide a capsule and a sphere.
	CollideCapsuleAndSphere :: proc(manifold: ^LocalManifold, capacity: c.int, capsuleA: ^Capsule, sphereB: ^Sphere, transformBtoA: Transform) ---
	// Collide a hull and a sphere.
	CollideHullAndSphere :: proc(manifold: ^LocalManifold, capacity: c.int, hullA: ^HullData, sphereB: ^Sphere, transformBtoA: Transform, cache: ^SimplexCache) ---
	// Collide two capsules.
	CollideCapsules :: proc(manifold: ^LocalManifold, capacity: c.int, capsuleA: ^Capsule, capsuleB: ^Capsule, transformBtoA: Transform) ---
	// Collide a hull and a capsule.
	CollideHullAndCapsule :: proc(manifold: ^LocalManifold, capacity: c.int, hullA: ^HullData, capsuleB: ^Capsule, transformBtoA: Transform, cache: ^SimplexCache) ---
	// Collide two hulls.
	CollideHulls :: proc(manifold: ^LocalManifold, capacity: c.int, hullA: ^HullData, hullB: ^HullData, transformBtoA: Transform, cache: ^SATCache) ---
	// Collide a capsule and a triangle.
	CollideCapsuleAndTriangle :: proc(manifold: ^LocalManifold, capacity: c.int, capsuleA: ^Capsule, triangleB: ^Vec3, cache: ^SimplexCache) ---
	// Collide a hull and a triangle.
	CollideHullAndTriangle :: proc(manifold: ^LocalManifold, capacity: c.int, hullA: ^HullData, v1: Vec3, v2: Vec3, v3: Vec3, triangleFlags: c.int, cache: ^SATCache) ---
	// Collide a sphere and a triangle.
	CollideSphereAndTriangle :: proc(manifold: ^LocalManifold, capacity: c.int, sphereA: ^Sphere, triangleB: ^Vec3) ---
	// Solves the position of a mover that satisfies the given collision planes.
	// @param targetDelta the desired translation from the position used to generate the collision planes
	// @param planes the collision planes
	// @param count the number of collision planes
	SolvePlanes :: proc(targetDelta: Vec3, planes: ^CollisionPlane, count: c.int) -> PlaneSolverResult ---
	// Clips the velocity against the given collision planes. Planes with zero push or clipVelocity
	// set to false are skipped.
	ClipVector :: proc(vector: Vec3, planes: ^CollisionPlane, count: c.int) -> Vec3 ---
}
