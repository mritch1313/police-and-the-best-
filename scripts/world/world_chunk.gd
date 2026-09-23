extends Node3D
class_name WorldChunk
## One streamed piece of the city.
##
## A chunk knows three things: where it is, how detailed it currently is, and whether its
## collision is active. The streamer creates, re-levels and frees chunks; the chunk itself
## owns the geometry and the physics body that goes with it.
##
## Collision is the expensive half of a chunk (a StaticBody3D with dozens of box shapes and
## the broad phase entries that come with it), so it is only enabled while the player is
## close enough to actually drive into it.

const STATE_EMPTY := 0
const STATE_GEOMETRY := 1
const STATE_FULL := 2

var coords: Vector2i = Vector2i.ZERO
var state: int = STATE_EMPTY
var lod: int = ChunkBuilder.LOD_FAR
var statistics: Dictionary = {}
var collision_boxes: Array[Dictionary] = []
var collision_body: StaticBody3D = null
var ground_root: Node3D = null
var built_ms: float = 0.0

var _builder: ChunkBuilder = null


## Builds the geometry. Called by the streamer on the main thread with a per-frame budget,
## so a chunk build must stay in the low milliseconds.
func build(p_builder: ChunkBuilder, p_coords: Vector2i, p_lod: int, prop_density: float) -> void:
	_builder = p_builder
	coords = p_coords
	lod = p_lod
	name = "Chunk_%d_%d" % [coords.x, coords.y]
	var started := Time.get_ticks_usec()
	statistics = _builder.build(self, coords, lod, prop_density)
	built_ms = float(Time.get_ticks_usec() - started) / 1000.0
	collision_boxes = get_meta("collision_boxes", []) as Array[Dictionary]
	state = STATE_GEOMETRY
	set_meta("built_ms", built_ms)


## Switches the level of detail. Rebuilding is deliberately cheap: a chunk is a handful of
## merged meshes, and a rebuild only happens when the player crosses an LOD ring boundary.
func set_lod(p_lod: int, prop_density: float) -> void:
	if p_lod == lod or _builder == null or state == STATE_EMPTY:
		return
	clear_geometry()
	build(_builder, coords, p_lod, prop_density)


## Creates or removes the collision body according to how close the player is.
func set_collision_enabled(enabled: bool) -> void:
	if enabled and collision_body == null and not collision_boxes.is_empty():
		var holder := Node3D.new()
		holder.name = "Collision"
		add_child(holder)
		collision_body = _builder_commit_collision(holder)
		state = STATE_FULL
	elif not enabled and collision_body != null:
		collision_body.queue_free()
		collision_body = null
		state = STATE_GEOMETRY


func _builder_commit_collision(holder: Node3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "ChunkBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta("surface_grip", 1.0)
	holder.add_child(body)
	for box: Dictionary in collision_boxes:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = box.get("size", Vector3.ONE)
		shape.shape = box_shape
		shape.transform = Transform3D(box.get("basis", Basis()), box.get("position", Vector3.ZERO))
		body.add_child(shape)
	return body


func has_collision() -> bool:
	return collision_body != null


## Removes all geometry (used when a chunk is re-levelled).
func clear_geometry() -> void:
	if collision_body != null:
		collision_body.queue_free()
		collision_body = null
	for child in get_children():
		child.queue_free()
	collision_boxes.clear()
	state = STATE_EMPTY


## Number of triangles this chunk currently draws.
func triangle_count() -> int:
	return int(statistics.get("triangles", 0))


func mesh_count() -> int:
	return int(statistics.get("meshes", 0))


func describe() -> String:
	return "chunk(%d,%d) lod=%d state=%d meshes=%d tris=%d boxes=%d build=%.2fms" % [
		coords.x,
		coords.y,
		lod,
		state,
		mesh_count(),
		triangle_count(),
		collision_boxes.size(),
		built_ms,
	]
