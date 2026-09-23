extends RefCounted
class_name TestArena
## A flat, empty piece of ground for the tests that have to *drive* a car.
##
## The arena is deliberately trivial (one static box, no city) so that a physics test measures
## the car and nothing else: when a test says "the car reached 46 m/s on a straight", the only
## thing that could have changed it is the vehicle code.

## Big enough that a car at 58 m/s can accelerate for ten seconds without leaving the arena.
const DEFAULT_SIZE := 4000.0


static func create(tree: SceneTree, size: float = DEFAULT_SIZE, name: String = "TestArena") -> Node3D:
	var arena := Node3D.new()
	arena.name = name
	tree.root.add_child(arena)
	add_ground(arena, size)
	return arena


## One box as the ground: the top surface sits exactly at y = 0, which is the convention the
## city uses as well (`WorldConfig.ground_height`).
static func add_ground(arena: Node3D, size: float = DEFAULT_SIZE) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = CollisionLayers.GROUND
	body.collision_mask = 0
	body.set_meta("surface_grip", 1.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 2.0, size)
	shape.shape = box
	shape.position = Vector3(0.0, -1.0, 0.0)
	body.add_child(shape)
	arena.add_child(body)
	return body


## A solid wall (used by the collision and blocked-state tests).
static func add_wall(
	arena: Node3D,
	position: Vector3,
	size: Vector3,
	layer: int = CollisionLayers.BUILDING
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Wall"
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = position
	body.add_child(shape)
	arena.add_child(body)
	return body


## Creates a car in the arena at a given position and heading.
static func add_car(
	arena: Node3D,
	config_path: String,
	position: Vector3,
	heading: float = 0.0,
	police: bool = false
) -> CarBody:
	var car: CarBody = PoliceCar.new() if police else CarBody.new()
	car.name = "TestCar"
	car.config_path = config_path
	car.detail_level = CarMeshFactory.DETAIL_MEDIUM
	arena.add_child(car)
	car.reset_to(Transform3D(Basis(Vector3.UP, heading), position + Vector3.UP * 0.6))
	return car


## Runs `frames` physics frames, calling `on_frame` for every one of them.
##
## This is the single place where the tests advance time, so a test can be read as
## "press the throttle for 3 seconds" instead of as a loop.
static func simulate(tree: SceneTree, frames: int, on_frame: Callable = Callable()) -> void:
	for _i in frames:
		if on_frame.is_valid():
			on_frame.call()
		await tree.physics_frame


## Releases every node created by the arena.
static func destroy(arena: Node3D) -> void:
	if is_instance_valid(arena):
		arena.queue_free()
