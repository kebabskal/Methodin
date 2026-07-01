package vendor_box3d

import "core:c"

__u_char :: u8

__u_short :: c.ushort

__u_int :: c.uint

__u_long :: c.ulong

__int8_t :: i8

__uint8_t :: u8

__int16_t :: c.short

__uint16_t :: c.ushort

__int32_t :: c.int

__uint32_t :: c.uint

__int64_t :: c.long

__uint64_t :: c.ulong

__int_least8_t :: i8

__uint_least8_t :: u8

__int_least16_t :: c.short

__uint_least16_t :: c.ushort

__int_least32_t :: c.int

__uint_least32_t :: c.uint

__int_least64_t :: c.long

__uint_least64_t :: c.ulong

__quad_t :: c.long

__u_quad_t :: c.ulong

__intmax_t :: c.long

__uintmax_t :: c.ulong

__dev_t :: c.ulong

__uid_t :: c.uint

__gid_t :: c.uint

__ino_t :: c.ulong

__ino64_t :: c.ulong

__mode_t :: c.uint

__nlink_t :: c.ulong

__off_t :: c.long

__off64_t :: c.long

__pid_t :: c.int

__fsid_t :: struct {
	__val: [2]c.int,
}

__clock_t :: c.long

__rlim_t :: c.ulong

__rlim64_t :: c.ulong

__id_t :: c.uint

__time_t :: c.long

__useconds_t :: c.uint

__suseconds_t :: c.long

__suseconds64_t :: c.long

__daddr_t :: c.int

__key_t :: c.int

__clockid_t :: c.int

__timer_t :: rawptr

__blksize_t :: c.long

__blkcnt_t :: c.long

__blkcnt64_t :: c.long

__fsblkcnt_t :: c.ulong

__fsblkcnt64_t :: c.ulong

__fsfilcnt_t :: c.ulong

__fsfilcnt64_t :: c.ulong

__fsword_t :: c.long

__ssize_t :: c.long

__syscall_slong_t :: c.long

__syscall_ulong_t :: c.ulong

__loff_t :: c.long

__caddr_t :: cstring

__intptr_t :: c.long

__socklen_t :: c.uint

__sig_atomic_t :: c.int

TaskCallback :: rawptr  /* ? void (void *) */

EnqueueTaskCallback :: rawptr  /* ? void *(b3TaskCallback *, void *, void *, const char *) */

FinishTaskCallback :: rawptr  /* ? void (void *, void *) */

// This is sent to the user for debug shape creation. The user should know the type in case they have
// custom sphere or capsule rendering.
DebugShape :: struct {
}

CreateDebugShapeCallback :: rawptr  /* ? void *(const b3DebugShape *, void *) */

DestroyDebugShapeCallback :: rawptr  /* ? void (void *, void *) */

FrictionCallback :: rawptr  /* ? float (float, uint64_t, float, uint64_t) */

RestitutionCallback :: rawptr  /* ? float (float, uint64_t, float, uint64_t) */

CustomFilterFcn :: rawptr  /* ? _Bool (b3ShapeId, b3ShapeId, void *) */

PreSolveFcn :: rawptr  /* ? _Bool (b3ShapeId, b3ShapeId, b3Pos, b3Vec3, void *) */

OverlapResultFcn :: rawptr  /* ? _Bool (b3ShapeId, void *) */

CastResultFcn :: rawptr  /* ? float (b3ShapeId, b3Pos, b3Vec3, float, uint64_t, int, int, void *) */

// Optional world capacities that can be use to avoid run-time allocations
// @ingroup world
Capacity :: struct {
	staticShapeCount: c.int,
	dynamicShapeCount: c.int,
	staticBodyCount: c.int,
	dynamicBodyCount: c.int,
	contactCount: c.int,
}

// World definition used to create a simulation world. Must be initialized using b3DefaultWorldDef.
// @ingroup world
WorldDef :: struct {
	gravity: Vec3,
	restitutionThreshold: f32,
	hitEventThreshold: f32,
	contactHertz: f32,
	contactDampingRatio: f32,
	contactSpeed: f32,
	maximumLinearSpeed: f32,
	frictionCallback: FrictionCallback,
	restitutionCallback: RestitutionCallback,
	enableSleep: bool,
	enableContinuous: bool,
	workerCount: c.uint,
	enqueueTask: EnqueueTaskCallback,
	finishTask: FinishTaskCallback,
	userTaskContext: rawptr,
	userData: rawptr,
	createDebugShape: CreateDebugShapeCallback,
	destroyDebugShape: DestroyDebugShapeCallback,
	userDebugShapeContext: rawptr,
	capacity: Capacity,
	internalValue: c.int,
}

// The body simulation type.
// Each body is one of these three types. The type determines how the body behaves in the simulation.
// @ingroup body
BodyType :: enum c.int {
	staticBody = 0,
	kinematicBody = 1,
	dynamicBody = 2,
	bodyTypeCount = 3,
}

// Motion locks to restrict the body movement
// @ingroup body
MotionLocks :: struct {
	linearX: bool,
	linearY: bool,
	linearZ: bool,
	angularX: bool,
	angularY: bool,
	angularZ: bool,
}

// A body definition holds all the data needed to construct a rigid body.
// You can safely re-use body definitions. Shapes are added to a body after construction.
// Body definitions are temporary objects used to bundle creation parameters.
// Must be initialized using b3DefaultBodyDef().
// @ingroup body
BodyDef :: struct {
	type: BodyType,
	position: Vec3,
	rotation: Quat,
	linearVelocity: Vec3,
	angularVelocity: Vec3,
	linearDamping: f32,
	angularDamping: f32,
	gravityScale: f32,
	sleepThreshold: f32,
	name: cstring,
	userData: rawptr,
	motionLocks: MotionLocks,
	enableSleep: bool,
	isAwake: bool,
	isBullet: bool,
	isEnabled: bool,
	allowFastRotation: bool,
	enableContactRecycling: bool,
	internalValue: c.int,
}

// This is used to filter collision on shapes. It affects shape-vs-shape collision
// and shape-versus-query collision (such as b3World_CastRay).
// @ingroup shape
Filter :: struct {
	categoryBits: c.ulong,
	maskBits: c.ulong,
	groupIndex: c.int,
}

// Material properties supported per triangle on meshes and height fields
// @ingroup shape
SurfaceMaterial :: struct {
	friction: f32,
	restitution: f32,
	rollingResistance: f32,
	tangentVelocity: Vec3,
	userMaterialId: c.ulong,
	customColor: c.uint,
}

// Shape type
// @ingroup shape
ShapeType :: enum c.int {
	capsuleShape = 0,
	compoundShape = 1,
	heightShape = 2,
	hullShape = 3,
	meshShape = 4,
	sphereShape = 5,
	shapeTypeCount = 6,
}

// Used to create a shape
// @ingroup shape
ShapeDef :: struct {
	userData: rawptr,
	materials: ^SurfaceMaterial,
	materialCount: c.int,
	baseMaterial: SurfaceMaterial,
	density: f32,
	explosionScale: f32,
	filter: Filter,
	enableCustomFiltering: bool,
	isSensor: bool,
	enableSensorEvents: bool,
	enableContactEvents: bool,
	enableHitEvents: bool,
	enablePreSolveEvents: bool,
	invokeContactCreation: bool,
	updateBodyMass: bool,
	internalValue: c.int,
}

// ! @cond
// Profiling data. Times are in milliseconds.
// @ingroup world
Profile :: struct {
	step: f32,
	pairs: f32,
	collide: f32,
	solve: f32,
	solverSetup: f32,
	constraints: f32,
	prepareConstraints: f32,
	integrateVelocities: f32,
	warmStart: f32,
	solveImpulses: f32,
	integratePositions: f32,
	relaxImpulses: f32,
	applyRestitution: f32,
	storeImpulses: f32,
	splitIslands: f32,
	transforms: f32,
	sensorHits: f32,
	jointEvents: f32,
	hitEvents: f32,
	refit: f32,
	bullets: f32,
	sleepIslands: f32,
	sensors: f32,
}

// Counters that give details of the simulation size.
// @ingroup world
Counters :: struct {
	bodyCount: c.int,
	shapeCount: c.int,
	contactCount: c.int,
	jointCount: c.int,
	islandCount: c.int,
	stackUsed: c.int,
	arenaCapacity: c.int,
	staticTreeHeight: c.int,
	treeHeight: c.int,
	satCallCount: c.int,
	satCacheHitCount: c.int,
	byteCount: c.int,
	taskCount: c.int,
	colorCounts: [24]c.int,
	manifoldCounts: [8]c.int,
	awakeContactCount: c.int,
	recycledContactCount: c.int,
	distanceIterations: c.int,
	pushBackIterations: c.int,
	rootIterations: c.int,
}

// Joint type enumeration. This is useful because all joint types use b3JointId and sometimes you
// want to get the type of a joint.
// @ingroup joint
JointType :: enum c.int {
	parallelJoint = 0,
	distanceJoint = 1,
	filterJoint = 2,
	motorJoint = 3,
	prismaticJoint = 4,
	revoluteJoint = 5,
	sphericalJoint = 6,
	weldJoint = 7,
	wheelJoint = 8,
}

// Base joint definition used by all joint types. The local frames are measured from the
// body's origin rather than the center of mass because:
// 1. You might not know where the center of mass will be.
// 2. If you add/remove shapes from a body and recompute the mass, the joints will be broken.
// @ingroup joint
JointDef :: struct {
	userData: rawptr,
	bodyIdA: BodyId,
	bodyIdB: BodyId,
	localFrameA: Transform,
	localFrameB: Transform,
	forceThreshold: f32,
	torqueThreshold: f32,
	constraintHertz: f32,
	constraintDampingRatio: f32,
	drawScale: f32,
	collideConnected: bool,
	internalValue: c.int,
}

// Distance joint definition.
// Connects a point on body A with a point on body B by a segment.
// Useful for ropes and springs.
// @ingroup distance_joint
DistanceJointDef :: struct {
	base: JointDef,
	length: f32,
	enableSpring: bool,
	lowerSpringForce: f32,
	upperSpringForce: f32,
	hertz: f32,
	dampingRatio: f32,
	enableLimit: bool,
	minLength: f32,
	maxLength: f32,
	enableMotor: bool,
	maxMotorForce: f32,
	motorSpeed: f32,
}

// A motor joint is used to control the relative position and velocity between two bodies.
// @ingroup motor_joint
MotorJointDef :: struct {
	base: JointDef,
	linearVelocity: Vec3,
	maxVelocityForce: f32,
	angularVelocity: Vec3,
	maxVelocityTorque: f32,
	linearHertz: f32,
	linearDampingRatio: f32,
	maxSpringForce: f32,
	angularHertz: f32,
	angularDampingRatio: f32,
	maxSpringTorque: f32,
}

// A filter joint is used to disable collision between two specific bodies.
// @ingroup filter_joint
FilterJointDef :: struct {
	base: JointDef,
}

// Parallel joint definition. Constrains the angle between axis z in body A and axis z in body B
// using a spring. Useful to keep a body upright.
// @ingroup parallel_joint
ParallelJointDef :: struct {
	base: JointDef,
	hertz: f32,
	dampingRatio: f32,
	maxTorque: f32,
}

// Prismatic joint definition. Body B may slide along the x-axis in local frame A.
// Body B cannot rotate relative to body A. The joint translation is zero when the
// local frame origins coincide in world space.
// @ingroup prismatic_joint
PrismaticJointDef :: struct {
	base: JointDef,
	enableSpring: bool,
	hertz: f32,
	dampingRatio: f32,
	targetTranslation: f32,
	enableLimit: bool,
	lowerTranslation: f32,
	upperTranslation: f32,
	enableMotor: bool,
	maxMotorForce: f32,
	motorSpeed: f32,
}

// Revolute joint definition. A point on body B is fixed to a point on body A.
// Allows relative rotation about the z-axis.
// @ingroup revolute_joint
RevoluteJointDef :: struct {
	base: JointDef,
	targetAngle: f32,
	enableSpring: bool,
	hertz: f32,
	dampingRatio: f32,
	enableLimit: bool,
	lowerAngle: f32,
	upperAngle: f32,
	enableMotor: bool,
	maxMotorTorque: f32,
	motorSpeed: f32,
}

// Spherical joint definition. A point on body B is fixed to a point on body A.
// Allows rotation about the shared point.
// @ingroup spherical_joint
SphericalJointDef :: struct {
	base: JointDef,
	enableSpring: bool,
	hertz: f32,
	dampingRatio: f32,
	targetRotation: Quat,
	enableConeLimit: bool,
	coneAngle: f32,
	enableTwistLimit: bool,
	lowerTwistAngle: f32,
	upperTwistAngle: f32,
	enableMotor: bool,
	maxMotorTorque: f32,
	motorVelocity: Vec3,
}

// Weld joint definition
// Connects two bodies together rigidly. This constraint provides springs to mimic
// soft-body simulation.
// @note The approximate solver in Box3D cannot hold many bodies together rigidly
// @ingroup weld_joint
WeldJointDef :: struct {
	base: JointDef,
	linearHertz: f32,
	angularHertz: f32,
	linearDampingRatio: f32,
	angularDampingRatio: f32,
}

// Wheel joint definition
// Body A is the chassis and body B is the wheel.
// The wheel rotates around the local z-axis in frame B.
// The wheel translates along the local x-axis in frame A.
// The wheel can optionally steer along the x-axis in frame A.
// @ingroup wheel_joint
WheelJointDef :: struct {
	base: JointDef,
	enableSuspensionSpring: bool,
	suspensionHertz: f32,
	suspensionDampingRatio: f32,
	enableSuspensionLimit: bool,
	lowerSuspensionLimit: f32,
	upperSuspensionLimit: f32,
	enableSpinMotor: bool,
	maxSpinTorque: f32,
	spinSpeed: f32,
	enableSteering: bool,
	steeringHertz: f32,
	steeringDampingRatio: f32,
	targetSteeringAngle: f32,
	maxSteeringTorque: f32,
	enableSteeringLimit: bool,
	lowerSteeringLimit: f32,
	upperSteeringLimit: f32,
}

// The explosion definition is used to configure options for explosions. Explosions
// consider shape geometry when computing the impulse.
// @ingroup world
ExplosionDef :: struct {
	maskBits: c.ulong,
	position: Vec3,
	radius: f32,
	falloff: f32,
	impulsePerArea: f32,
}

// A begin-touch event is generated when a shape starts to overlap a sensor shape.
SensorBeginTouchEvent :: struct {
	sensorShapeId: ShapeId,
	visitorShapeId: ShapeId,
}

// An end touch event is generated when a shape stops overlapping a sensor shape.
// These include things like setting the transform, destroying a body or shape, or changing
// a filter. You will also get an end event if the sensor or visitor are destroyed.
// Therefore you should always confirm the shape id is valid using b3Shape_IsValid.
SensorEndTouchEvent :: struct {
	sensorShapeId: ShapeId,
	visitorShapeId: ShapeId,
}

// Sensor events are buffered in the world and are available
// as begin/end overlap event arrays after the time step is complete.
// Note: these may become invalid if bodies and/or shapes are destroyed
SensorEvents :: struct {
	beginEvents: ^SensorBeginTouchEvent,
	endEvents: ^SensorEndTouchEvent,
	beginCount: c.int,
	endCount: c.int,
}

// A begin-touch event is generated when two shapes begin touching.
ContactBeginTouchEvent :: struct {
	shapeIdA: ShapeId,
	shapeIdB: ShapeId,
	contactId: ContactId,
}

// An end touch event is generated when two shapes stop touching.
// You will get an end event if you do anything that destroys contacts previous to the last
// world step. These include things like setting the transform, destroying a body
// or shape, or changing a filter or body type.
ContactEndTouchEvent :: struct {
	shapeIdA: ShapeId,
	shapeIdB: ShapeId,
	contactId: ContactId,
}

// A hit touch event is generated when two shapes collide with a speed faster than the hit speed threshold.
// This may be reported for speculative contacts that have a confirmed impulse.
ContactHitEvent :: struct {
	shapeIdA: ShapeId,
	shapeIdB: ShapeId,
	contactId: ContactId,
	point: Vec3,
	normal: Vec3,
	approachSpeed: f32,
	userMaterialIdA: c.ulong,
	userMaterialIdB: c.ulong,
}

// Contact events are buffered in the world and are available
// as event arrays after the time step is complete.
// Note: these may become invalid if bodies and/or shapes are destroyed
ContactEvents :: struct {
	beginEvents: ^ContactBeginTouchEvent,
	endEvents: ^ContactEndTouchEvent,
	hitEvents: ^ContactHitEvent,
	beginCount: c.int,
	endCount: c.int,
	hitCount: c.int,
}

// Body move events triggered when a body moves.
// Triggered when a body moves due to simulation. Not reported for bodies moved by the user.
// This also has a flag to indicate that the body went to sleep so the application can also
// sleep that actor/entity/object associated with the body.
// On the other hand if the flag does not indicate the body went to sleep then the application
// can treat the actor/entity/object associated with the body as awake.
// This is an efficient way for an application to update game object transforms rather than
// calling functions such as b3Body_GetTransform() because this data is delivered as a contiguous array
// and it is only populated with bodies that have moved.
// @note If sleeping is disabled all dynamic and kinematic bodies will trigger move events.
BodyMoveEvent :: struct {
	userData: rawptr,
	transform: Transform,
	bodyId: BodyId,
	fellAsleep: bool,
}

// Body events are buffered in the world and are available
// as event arrays after the time step is complete.
// Note: this data becomes invalid if bodies are destroyed
BodyEvents :: struct {
	moveEvents: ^BodyMoveEvent,
	moveCount: c.int,
}

// Joint events report joints that are awake and have a force and/or torque exceeding the threshold
// The observed forces and torques are not returned for efficiency reasons.
JointEvent :: struct {
	jointId: JointId,
	userData: rawptr,
}

// Joint events are buffered in the world and are available
// as event arrays after the time step is complete.
// Note: this data becomes invalid if joints are destroyed
JointEvents :: struct {
	jointEvents: ^JointEvent,
	count: c.int,
}

// The contact data for two shapes. By convention the manifold normal points
// from shape A to shape B.
// @see b3Shape_GetContactData() and b3Body_GetContactData()
ContactData :: struct {
	contactId: ContactId,
	shapeIdA: ShapeId,
	shapeIdB: ShapeId,
	manifolds: ^Manifold,
	manifoldCount: c.int,
}

// The query filter is used to filter collisions between queries and shapes. For example,
// you may want a ray-cast representing a projectile to hit players and the static environment
// but not debris.
QueryFilter :: struct {
	categoryBits: c.ulong,
	maskBits: c.ulong,
	id: c.ulong,
	name: cstring,
}

// Low level ray cast input data.
RayCastInput :: struct {
	origin: Vec3,
	translation: Vec3,
	maxFraction: f32,
}

// Result from b3World_RayCastClosest.
RayResult :: struct {
	shapeId: ShapeId,
	point: Vec3,
	normal: Vec3,
	userMaterialId: c.ulong,
	fraction: f32,
	triangleIndex: c.int,
	childIndex: c.int,
	nodeVisits: c.int,
	leafVisits: c.int,
	hit: bool,
}

// A shape proxy is used by the GJK algorithm. It can represent a convex shape.
ShapeProxy :: struct {
	points: ^Vec3,
	count: c.int,
	radius: f32,
}

// Low level shape cast input in generic form. This allows casting an arbitrary point
// cloud wrap with a radius. For example, a sphere is a single point with a non-zero radius.
// A capsule is two points with a non-zero radius. A box is four points with a zero radius.
ShapeCastInput :: struct {
	proxy: ShapeProxy,
	translation: Vec3,
	maxFraction: f32,
	canEncroach: bool,
}

// Input for sweeping an AABB through a dynamic tree. The box is in the tree's world float frame.
// The caller folds the cast shape radius and any world origin into the box, so the tree traversal
// stays a conservative box sweep and the precise narrow phase happens per shape in the callback.
BoxCastInput :: struct {
	box: AABB,
	translation: Vec3,
	maxFraction: f32,
}

// Low level ray cast or shape-cast output data.
CastOutput :: struct {
	normal: Vec3,
	point: Vec3,
	fraction: f32,
	iterations: c.int,
	triangleIndex: c.int,
	childIndex: c.int,
	materialIndex: c.int,
	hit: bool,
}

// Body cast result for ray and shape casts.
BodyCastResult :: struct {
	shapeId: ShapeId,
	point: Vec3,
	normal: Vec3,
	fraction: f32,
	triangleIndex: c.int,
	userMaterialId: c.ulong,
	iterations: c.int,
	hit: bool,
}

// Used to warm start the GJK simplex. If you call this function multiple times with nearby
// transforms this might improve performance. Otherwise you can zero initialize this.
// The distance cache must be initialized to zero on the first call.
// Users should generally just zero initialize this structure for each call.
SimplexCache :: struct {
	metric: f32,
	count: c.ushort,
	indexA: [4]u8,
	indexB: [4]u8,
}

// Input parameters for b3ShapeCast
ShapeCastPairInput :: struct {
	proxyA: ShapeProxy,
	proxyB: ShapeProxy,
	transform: Transform,
	translationB: Vec3,
	maxFraction: f32,
	canEncroach: bool,
}

// Input for b3ShapeDistance
DistanceInput :: struct {
	proxyA: ShapeProxy,
	proxyB: ShapeProxy,
	transform: Transform,
	useRadii: bool,
}

// Output for b3ShapeDistance
DistanceOutput :: struct {
	pointA: Vec3,
	pointB: Vec3,
	normal: Vec3,
	distance: f32,
	iterations: c.int,
	simplexCount: c.int,
}

// Simplex vertex for debugging the GJK algorithm
SimplexVertex :: struct {
	wA: Vec3,
	wB: Vec3,
	w: Vec3,
	a: f32,
	indexA: c.int,
	indexB: c.int,
}

// Simplex from the GJK algorithm
Simplex :: struct {
	vertices: [4]SimplexVertex,
	count: c.int,
}

// This describes the motion of a body/shape for TOI computation. Shapes are defined with respect to the body origin,
// which may not coincide with the center of mass. However, to support dynamics we must interpolate the center of mass
// position.
Sweep :: struct {
	localCenter: Vec3,
	c1: Vec3,
	c2: Vec3,
	q1: Quat,
	q2: Quat,
}

// Time of impact input
TOIInput :: struct {
	proxyA: ShapeProxy,
	proxyB: ShapeProxy,
	sweepA: Sweep,
	sweepB: Sweep,
	maxFraction: f32,
}

// Describes the TOI output
TOIState :: enum c.int {
	toiStateUnknown = 0,
	toiStateFailed = 1,
	toiStateOverlapped = 2,
	toiStateHit = 3,
	toiStateSeparated = 4,
}

// Time of impact output
TOIOutput :: struct {
	state: TOIState,
	point: Vec3,
	normal: Vec3,
	fraction: f32,
	distance: f32,
	distanceIterations: c.int,
	pushBackIterations: c.int,
	rootIterations: c.int,
	usedFallback: bool,
}

// Flags for tree nodes. For internal usage.
TreeNodeFlags :: enum c.int {
	allocatedNode = 1,
	enlargedNode = 2,
	leafNode = 4,
}

// Tree node child indices. For internal usage.
TreeNodeChildren :: struct {
	child1: c.int,
	child2: c.int,
}

// A node in the dynamic tree. This is private data placed here for performance reasons.
// todo test padding to 64 bytes to avoid straddling cache lines
TreeNode :: struct #align(8) { _: [48]u8 } // opaque (bitfields/anon union)

// The dynamic tree structure. This should be considered private data.
// It is placed here for performance reasons.
DynamicTree :: struct {
	version: c.ulong,
	nodes: ^TreeNode,
	root: c.int,
	nodeCount: c.int,
	nodeCapacity: c.int,
	proxyCount: c.int,
	freeList: c.int,
	leafIndices: ^c.int,
	leafBoxes: ^AABB,
	leafCenters: ^Vec3,
	binIndices: ^c.int,
	rebuildCapacity: c.int,
}

// These are performance results returned by dynamic tree queries.
TreeStats :: struct {
	nodeVisits: c.int,
	leafVisits: c.int,
}

TreeQueryCallbackFcn :: rawptr  /* ? _Bool (int, uint64_t, void *) */

TreeQueryClosestCallbackFcn :: rawptr  /* ? float (float, int, uint64_t, void *) */

TreeBoxCastCallbackFcn :: rawptr  /* ? float (const b3BoxCastInput *, int, uint64_t, void *) */

TreeRayCastCallbackFcn :: rawptr  /* ? float (const b3RayCastInput *, int, uint64_t, void *) */

// The plane between a character mover and a shape
PlaneResult :: struct {
	plane: Plane,
	point: Vec3,
}

// These are collision planes that can be fed to b3SolvePlanes. Normally
// this is assembled by the user from plane results in b3PlaneResult.
CollisionPlane :: struct {
	plane: Plane,
	pushLimit: f32,
	push: f32,
	clipVelocity: bool,
}

// Result returned by b3SolvePlanes.
PlaneSolverResult :: struct {
	delta: Vec3,
	iterationCount: c.int,
}

// Body plane result for movers.
BodyPlaneResult :: struct {
	shapeId: ShapeId,
	result: PlaneResult,
}

PlaneResultFcn :: rawptr  /* ? _Bool (b3ShapeId, const b3PlaneResult *, int, void *) */

MoverFilterFcn :: rawptr  /* ? _Bool (b3ShapeId, void *) */

// This holds the mass data computed for a shape.
MassData :: struct {
	mass: f32,
	center: Vec3,
	inertia: Matrix3,
}

// A solid sphere
Sphere :: struct {
	center: Vec3,
	radius: f32,
}

// A solid capsule can be viewed as two hemispheres connected
// by a rectangle.
Capsule :: struct {
	center1: Vec3,
	center2: Vec3,
	radius: f32,
}

// A hull vertex. Identified by a half-edge with this
// vertex as its tail.
HullVertex :: struct {
	edge: u8,
}

// Half-edge for hull data structure
HullHalfEdge :: struct {
	next: u8,
	twin: u8,
	origin: u8,
	face: u8,
}

// A hull face. Hulls use a half-edge data structure, so a face
// can be determined from a single half-edge index.
HullFace :: struct {
	edge: u8,
}

// A convex hull.
// @note This data structure has data hanging off the end and cannot be directly copied.
HullData :: struct {
	version: c.ulong,
	byteCount: c.int,
	hash: c.uint,
	aabb: AABB,
	surfaceArea: f32,
	volume: f32,
	innerRadius: f32,
	center: Vec3,
	centralInertia: Matrix3,
	vertexCount: c.int,
	vertexOffset: c.int,
	pointOffset: c.int,
	edgeCount: c.int,
	edgeOffset: c.int,
	faceCount: c.int,
	faceOffset: c.int,
	planeOffset: c.int,
	padding: c.int,
}

// Efficient box hull
BoxHull :: struct {
	base: HullData,
	boxVertices: [8]HullVertex,
	boxPoints: [8]Vec3,
	boxEdges: [24]HullHalfEdge,
	boxFaces: [6]HullFace,
	padding: [2]u8,
	boxPlanes: [6]Plane,
}

// This is used to create a re-usable collision mesh
MeshDef :: struct {
	vertices: ^Vec3,
	indices: ^c.int,
	materialIndices: ^u8,
	weldTolerance: f32,
	vertexCount: c.int,
	triangleCount: c.int,
	weldVertices: bool,
	useMedianSplit: bool,
	identifyEdges: bool,
}

// Triangle mesh edge flags.
MeshEdgeFlags :: enum c.int {
	concaveEdge1 = 1,
	concaveEdge2 = 2,
	concaveEdge3 = 4,
	inverseConcaveEdge1 = 16,
	inverseConcaveEdge2 = 32,
	inverseConcaveEdge3 = 64,
	allConcaveEdges = 7,
	flatEdge1 = 17,
	flatEdge2 = 34,
	flatEdge3 = 68,
	allFlatEdges = 119,
}

// A mesh triangle.
MeshTriangle :: struct {
	index1: c.int,
	index2: c.int,
	index3: c.int,
}

// A mesh BVH node.
MeshNode :: struct #align(4) { _: [32]u8 } // opaque (bitfields/anon union)

// This is a sorted triangle collision bounding volume hierarchy.
// @note This struct has data hanging off the end and cannot be directly copied.
MeshData :: struct {
	version: c.ulong,
	byteCount: c.int,
	hash: c.uint,
	bounds: AABB,
	surfaceArea: f32,
	treeHeight: c.int,
	degenerateCount: c.int,
	nodeOffset: c.int,
	nodeCount: c.int,
	vertexOffset: c.int,
	vertexCount: c.int,
	triangleOffset: c.int,
	triangleCount: c.int,
	materialOffset: c.int,
	materialCount: c.int,
	flagsOffset: c.int,
}

// This allows mesh data to be re-used with different scales.
Mesh :: struct {
	data: ^MeshData,
	scale: Vec3,
}

// Data used to create a height field
HeightFieldDef :: struct {
	heights: ^f32,
	materialIndices: ^u8,
	scale: Vec3,
	countX: c.int,
	countZ: c.int,
	globalMinimumHeight: f32,
	globalMaximumHeight: f32,
	clockwiseWinding: bool,
}

// A height field with compressed storage.
// @note This data structure has data hanging off the end and cannot be directly copied.
HeightFieldData :: struct {
	version: c.ulong,
	byteCount: c.int,
	hash: c.uint,
	aabb: AABB,
	minHeight: f32,
	maxHeight: f32,
	heightScale: f32,
	scale: Vec3,
	columnCount: c.int,
	rowCount: c.int,
	heightsOffset: c.int,
	materialOffset: c.int,
	flagsOffset: c.int,
	clockwise: bool,
	padding: [3]u8,
}

// Definition for a capsule in a compound shape.
CompoundCapsuleDef :: struct {
	capsule: Capsule,
	material: SurfaceMaterial,
}

// Definition for a convex hull in a compound shape.
CompoundHullDef :: struct {
	hull: ^HullData,
	transform: Transform,
	material: SurfaceMaterial,
}

// Definition for a triangle mesh in a compound shape.
CompoundMeshDef :: struct {
	meshData: ^MeshData,
	transform: Transform,
	scale: Vec3,
	materials: ^SurfaceMaterial,
	materialCount: c.int,
}

// Definition for a sphere in a compound shape.
CompoundSphereDef :: struct {
	sphere: Sphere,
	material: SurfaceMaterial,
}

// Definition for creating a compound shape. All this data is fully cloned
// into the run-time compound shape.
CompoundDef :: struct {
	capsules: ^CompoundCapsuleDef,
	capsuleCount: c.int,
	hulls: ^CompoundHullDef,
	hullCount: c.int,
	meshes: ^CompoundMeshDef,
	meshCount: c.int,
	spheres: ^CompoundSphereDef,
	sphereCount: c.int,
}

// The runtime data for a compound shape. This is a potentially large yet highly optimized
// data structure. It can contain thousands of child shapes, yet at runtime it populates
// into the world as a single shape in the runtime broad-phase.
// This data structure has data living off the end and must be accessed using offsets.
// Accessors are provided for user relevant data.
CompoundData :: struct {
	version: c.ulong,
	byteCount: c.int,
	nodeOffset: c.int,
	tree: DynamicTree,
	materialOffset: c.int,
	materialCount: c.int,
	capsuleOffset: c.int,
	capsuleCount: c.int,
	hullOffset: c.int,
	hullCount: c.int,
	sharedHullCount: c.int,
	meshOffset: c.int,
	meshCount: c.int,
	sharedMeshCount: c.int,
	sphereOffset: c.int,
	sphereCount: c.int,
}

// A capsule that lives in a compound.
CompoundCapsule :: struct {
	capsule: Capsule,
	materialIndex: c.int,
}

// A hull that lives in a compound.
CompoundHull :: struct {
	hull: ^HullData,
	transform: Transform,
	materialIndex: c.int,
}

// A mesh with non-uniform scale that lives in a compound.
CompoundMesh :: struct {
	meshData: ^MeshData,
	transform: Transform,
	scale: Vec3,
	materialIndices: [4]c.int,
}

// A sphere that lives in a compound.
CompoundSphere :: struct {
	sphere: Sphere,
	materialIndex: c.int,
}

// Child shape of a compound
ChildShape :: struct #align(8) { _: [80]u8 } // opaque (bitfields/anon union)

CompoundQueryFcn :: rawptr  /* ? _Bool (const b3CompoundData *, int, void *) */

// A manifold point is a contact point belonging to a contact manifold.
// It holds details related to the geometry and dynamics of the contact points.
// Box3D uses speculative collision so some contact points may be separated.
// You may use the maxNormalImpulse to determine if there was an interaction during
// the time step.
ManifoldPoint :: struct {
	anchorA: Vec3,
	anchorB: Vec3,
	separation: f32,
	baseSeparation: f32,
	normalImpulse: f32,
	totalNormalImpulse: f32,
	normalVelocity: f32,
	featureId: c.uint,
	triangleIndex: c.int,
	persisted: bool,
}

// A contact manifold describes the contact points between colliding shapes.
// @note Box3D uses speculative collision so some contact points may be separated.
Manifold :: struct {
	points: [4]ManifoldPoint,
	normal: Vec3,
	twistImpulse: f32,
	frictionImpulse: Vec3,
	rollingImpulse: Vec3,
	pointCount: c.int,
}

// Cached separating axis feature.
SeparatingFeature :: enum c.int {
	invalidAxis = 0,
	backsideAxis = 1,
	faceAxisA = 2,
	faceAxisB = 3,
	edgePairAxis = 4,
	closestPointsAxis = 5,
	manualFaceAxisA = 6,
	manualFaceAxisB = 7,
	manualEdgePairAxis = 8,
}

// Cached triangle feature.
TriangleFeature :: enum c.int {
	featureNone = 0,
	featureTriangleFace = 1,
	featureHullFace = 2,
	featureEdge1 = 3,
	featureEdge2 = 4,
	featureEdge3 = 5,
	featureVertex1 = 6,
	featureVertex2 = 7,
	featureVertex3 = 8,
}

// Separating axis test cache. Provides temporal acceleration of collision routines.
SATCache :: struct {
	separation: f32,
	type: u8,
	indexA: u8,
	indexB: u8,
	hit: u8,
}

// Contact points are always the result of two edges intersecting.
// It can be two edges of the same shape, which is just a shape vertex.
// Or a contact point can be the result of two edges crossing from different shapes.
// This is designed to support hull versus hull, but it is adapted to work
// with all shape types. The feature pair is used to identify contact points
// for temporal coherence and warm starting.
FeaturePair :: struct {
	owner1: u8,
	index1: u8,
	owner2: u8,
	index2: u8,
}

// A local manifold point and normal in frame A.
LocalManifoldPoint :: struct {
	point: Vec3,
	separation: f32,
	pair: FeaturePair,
	triangleIndex: c.int,
}

// A local manifold with no dynamic information. Used by b3Collide functions.
LocalManifold :: struct {
	normal: Vec3,
	triangleNormal: Vec3,
	points: ^LocalManifoldPoint,
	pointCount: c.int,
	triangleIndex: c.int,
	i1: c.int,
	i2: c.int,
	i3: c.int,
	squaredDistance: f32,
	feature: TriangleFeature,
	triangleFlags: c.int,
}

// These colors are used for debug draw and mostly match the named SVG colors.
// See https://www.rapidtables.com/web/color/index.html
// https://johndecember.com/html/spec/colorsvg.html
// https://upload.wikimedia.org/wikipedia/commons/2/2b/SVG_Recognized_color_keyword_names.svg
HexColor :: enum c.int {
	colorAliceBlue = 15792383,
	colorAntiqueWhite = 16444375,
	colorAqua = 65535,
	colorAquamarine = 8388564,
	colorAzure = 15794175,
	colorBeige = 16119260,
	colorBisque = 16770244,
	colorBlack = 0,
	colorBlanchedAlmond = 16772045,
	colorBlue = 255,
	colorBlueViolet = 9055202,
	colorBrown = 10824234,
	colorBurlywood = 14596231,
	colorCadetBlue = 6266528,
	colorChartreuse = 8388352,
	colorChocolate = 13789470,
	colorCoral = 16744272,
	colorCornflowerBlue = 6591981,
	colorCornsilk = 16775388,
	colorCrimson = 14423100,
	colorCyan = 65535,
	colorDarkBlue = 139,
	colorDarkCyan = 35723,
	colorDarkGoldenRod = 12092939,
	colorDarkGray = 11119017,
	colorDarkGreen = 25600,
	colorDarkKhaki = 12433259,
	colorDarkMagenta = 9109643,
	colorDarkOliveGreen = 5597999,
	colorDarkOrange = 16747520,
	colorDarkOrchid = 10040012,
	colorDarkRed = 9109504,
	colorDarkSalmon = 15308410,
	colorDarkSeaGreen = 9419919,
	colorDarkSlateBlue = 4734347,
	colorDarkSlateGray = 3100495,
	colorDarkTurquoise = 52945,
	colorDarkViolet = 9699539,
	colorDeepPink = 16716947,
	colorDeepSkyBlue = 49151,
	colorDimGray = 6908265,
	colorDodgerBlue = 2003199,
	colorFireBrick = 11674146,
	colorFloralWhite = 16775920,
	colorForestGreen = 2263842,
	colorFuchsia = 16711935,
	colorGainsboro = 14474460,
	colorGhostWhite = 16316671,
	colorGold = 16766720,
	colorGoldenRod = 14329120,
	colorGray = 8421504,
	colorGreen = 32768,
	colorGreenYellow = 11403055,
	colorHoneyDew = 15794160,
	colorHotPink = 16738740,
	colorIndianRed = 13458524,
	colorIndigo = 4915330,
	colorIvory = 16777200,
	colorKhaki = 15787660,
	colorLavender = 15132410,
	colorLavenderBlush = 16773365,
	colorLawnGreen = 8190976,
	colorLemonChiffon = 16775885,
	colorLightBlue = 11393254,
	colorLightCoral = 15761536,
	colorLightCyan = 14745599,
	colorLightGoldenRodYellow = 16448210,
	colorLightGray = 13882323,
	colorLightGreen = 9498256,
	colorLightPink = 16758465,
	colorLightSalmon = 16752762,
	colorLightSeaGreen = 2142890,
	colorLightSkyBlue = 8900346,
	colorLightSlateGray = 7833753,
	colorLightSteelBlue = 11584734,
	colorLightYellow = 16777184,
	colorLime = 65280,
	colorLimeGreen = 3329330,
	colorLinen = 16445670,
	colorMagenta = 16711935,
	colorMaroon = 8388608,
	colorMediumAquaMarine = 6737322,
	colorMediumBlue = 205,
	colorMediumOrchid = 12211667,
	colorMediumPurple = 9662683,
	colorMediumSeaGreen = 3978097,
	colorMediumSlateBlue = 8087790,
	colorMediumSpringGreen = 64154,
	colorMediumTurquoise = 4772300,
	colorMediumVioletRed = 13047173,
	colorMidnightBlue = 1644912,
	colorMintCream = 16121850,
	colorMistyRose = 16770273,
	colorMoccasin = 16770229,
	colorNavajoWhite = 16768685,
	colorNavy = 128,
	colorOldLace = 16643558,
	colorOlive = 8421376,
	colorOliveDrab = 7048739,
	colorOrange = 16753920,
	colorOrangeRed = 16729344,
	colorOrchid = 14315734,
	colorPaleGoldenRod = 15657130,
	colorPaleGreen = 10025880,
	colorPaleTurquoise = 11529966,
	colorPaleVioletRed = 14381203,
	colorPapayaWhip = 16773077,
	colorPeachPuff = 16767673,
	colorPeru = 13468991,
	colorPink = 16761035,
	colorPlum = 14524637,
	colorPowderBlue = 11591910,
	colorPurple = 8388736,
	colorRebeccaPurple = 6697881,
	colorRed = 16711680,
	colorRosyBrown = 12357519,
	colorRoyalBlue = 4286945,
	colorSaddleBrown = 9127187,
	colorSalmon = 16416882,
	colorSandyBrown = 16032864,
	colorSeaGreen = 3050327,
	colorSeaShell = 16774638,
	colorSienna = 10506797,
	colorSilver = 12632256,
	colorSkyBlue = 8900331,
	colorSlateBlue = 6970061,
	colorSlateGray = 7372944,
	colorSnow = 16775930,
	colorSpringGreen = 65407,
	colorSteelBlue = 4620980,
	colorTan = 13808780,
	colorTeal = 32896,
	colorThistle = 14204888,
	colorTomato = 16737095,
	colorTurquoise = 4251856,
	colorViolet = 15631086,
	colorWheat = 16113331,
	colorWhite = 16777215,
	colorWhiteSmoke = 16119285,
	colorYellow = 16776960,
	colorYellowGreen = 10145074,
	colorBox2DRed = 14430514,
	colorBox2DBlue = 3190463,
	colorBox2DGreen = 9226532,
	colorBox2DYellow = 16772748,
}

// Debug draw material preset. Optionally packed into the unused high byte of a
// b3HexColor (or b3SurfaceMaterial::customColor) to drive the renderer's PBR
// roughness and metalness. The low 24 bits stay RGB, so a plain 0xRRGGBB color
// reads as b3_debugMaterialDefault and keeps the renderer's per-body-type look.
DebugMaterial :: enum c.int {
	debugMaterialDefault = 0,
	debugMaterialMatte = 1,
	debugMaterialSoft = 2,
	debugMaterialDead = 3,
	debugMaterialGlossy = 4,
	debugMaterialMetallic = 5,
}

// This struct is passed to b3World_Draw to draw a debug view of the simulation world.
// Callbacks receive world coordinates. In large world mode the translation is double precision so
// it stays accurate far from the origin. Shift into your own camera frame inside the callbacks.
DebugDraw :: struct {
	DrawShapeFcn: proc "c" (rawptr, Transform, HexColor, rawptr) -> bool,
	DrawSegmentFcn: proc "c" (Vec3, Vec3, HexColor, rawptr),
	DrawTransformFcn: proc "c" (Transform, rawptr),
	DrawPointFcn: proc "c" (Vec3, f32, HexColor, rawptr),
	DrawSphereFcn: proc "c" (Vec3, f32, HexColor, f32, rawptr),
	DrawCapsuleFcn: proc "c" (Vec3, Vec3, f32, HexColor, f32, rawptr),
	DrawBoundsFcn: proc "c" (AABB, HexColor, rawptr),
	DrawBoxFcn: proc "c" (Vec3, Transform, HexColor, rawptr),
	DrawStringFcn: proc "c" (Vec3, cstring, HexColor, rawptr),
	drawingBounds: AABB,
	forceScale: f32,
	jointScale: f32,
	drawShapes: bool,
	drawJoints: bool,
	drawJointExtras: bool,
	drawBounds: bool,
	drawMass: bool,
	drawBodyNames: bool,
	drawContacts: bool,
	drawAnchorA: c.int,
	drawGraphColors: bool,
	drawContactFeatures: bool,
	drawContactNormals: bool,
	drawContactForces: bool,
	drawFrictionForces: bool,
	drawIslands: bool,
	context_: rawptr,
}

foreign import lib { LIB_PATH }

@(link_prefix="b3", default_calling_convention="c")
foreign lib {
	// Use this to initialize your world definition
	// @ingroup world
	DefaultWorldDef :: proc() -> WorldDef ---
	// Use this to initialize your body definition
	// @ingroup body
	DefaultBodyDef :: proc() -> BodyDef ---
	// Use this to initialize your filter
	// @ingroup shape
	DefaultFilter :: proc() -> Filter ---
	// Use this to initialize your surface material
	// @ingroup shape
	DefaultSurfaceMaterial :: proc() -> SurfaceMaterial ---
	// Use this to initialize your shape definition
	// @ingroup shape
	DefaultShapeDef :: proc() -> ShapeDef ---
	// Use this to initialize your joint definition
	// @ingroup distance_joint
	DefaultDistanceJointDef :: proc() -> DistanceJointDef ---
	// Use this to initialize your joint definition
	// @ingroup motor_joint
	DefaultMotorJointDef :: proc() -> MotorJointDef ---
	// Use this to initialize your joint definition
	// @ingroup filter_joint
	DefaultFilterJointDef :: proc() -> FilterJointDef ---
	// Use this to initialize your joint definition
	// @ingroup parallel_joint
	DefaultParallelJointDef :: proc() -> ParallelJointDef ---
	// Use this to initialize your joint definition
	// @ingroup prismatic_joint
	DefaultPrismaticJointDef :: proc() -> PrismaticJointDef ---
	// Use this to initialize your joint definition.
	// @ingroup revolute_joint
	DefaultRevoluteJointDef :: proc() -> RevoluteJointDef ---
	// Use this to initialize your joint definition.
	// @ingroup spherical_joint
	DefaultSphericalJointDef :: proc() -> SphericalJointDef ---
	// Use this to initialize your joint definition
	// @ingroup weld_joint
	DefaultWeldJointDef :: proc() -> WeldJointDef ---
	// Use this to initialize your joint definition
	// @ingroup wheel_joint
	DefaultWheelJointDef :: proc() -> WheelJointDef ---
	// Use this to initialize your explosion definition
	// @ingroup world
	DefaultExplosionDef :: proc() -> ExplosionDef ---
	// Use this to initialize your query filter
	DefaultQueryFilter :: proc() -> QueryFilter ---
	// Get the visualization color assigned to a constraint graph color slot. The last index
	// (B3_GRAPH_COLOR_COUNT - 1) is the overflow color.
	GetGraphColor :: proc(index: c.int) -> HexColor ---
	// Create a debug draw struct with default values.
	DefaultDebugDraw :: proc() -> DebugDraw ---
}
