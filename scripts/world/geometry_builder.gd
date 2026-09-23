extends RefCounted
class_name GeometryBuilder
## Collects primitives and merges them into one mesh per material.
##
## This is the reason a dense city block can be a handful of draw calls: every wall, kerb,
## lamp, bench and bin is appended into a per-material SurfaceTool and committed once.
## A chunk therefore contains as many MeshInstance3D nodes as the block has *materials*
## (typically 5 to 9), not hundreds of individual objects.
##
## The builder also counts triangles, so the world generator can report and enforce a
## budget per chunk (mobile GPUs die from geometry, not from clever shaders).

var materials: MaterialLibrary
var triangle_count: int = 0
var primitive_count: int = 0

var _tools: Dictionary = {}
var _counts: Dictionary = {}


func _init(p_materials: MaterialLibrary = null) -> void:
	materials = p_materials if p_materials != null else MaterialLibrary.new()


func _tool(key: StringName) -> SurfaceTool:
	if _tools.has(key):
		return _tools[key]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tools[key] = tool
	_counts[key] = 0
	return tool


func _count(key: StringName, triangles: int) -> void:
	triangle_count += triangles
	primitive_count += 1
	_counts[key] = int(_counts.get(key, 0)) + triangles


func triangles_for(key: StringName) -> int:
	return int(_counts.get(key, 0))


## True when nothing was added for this material.
func is_empty() -> bool:
	return _tools.is_empty()


# --------------------------------------------------------------------------------------
# primitives
# --------------------------------------------------------------------------------------
func add_box(key: StringName, origin: Transform3D, size: Vector3, uv_scale: float = MeshFactory.DEFAULT_UV_SCALE, colour: Color = Color.WHITE) -> void:
	MeshFactory.append_box(_tool(key), origin, size, uv_scale, colour)
	_count(key, 12)


func add_plane(key: StringName, origin: Transform3D, size: Vector2, uv_scale: float = MeshFactory.DEFAULT_UV_SCALE, colour: Color = Color.WHITE, flip: bool = false) -> void:
	MeshFactory.append_plane(_tool(key), origin, size, uv_scale, colour, flip)
	_count(key, 2)


func add_quad(
	key: StringName,
	origin: Transform3D,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3,
	uv_scale: float = MeshFactory.DEFAULT_UV_SCALE,
	colour: Color = Color.WHITE,
	flip: bool = false
) -> void:
	MeshFactory.append_quad(_tool(key), origin, a, b, c, d, normal, uv_scale, colour, flip)
	_count(key, 2)


func add_wall(
	key: StringName,
	origin: Transform3D,
	size: Vector2,
	uv_per_meter: Vector2,
	colour: Color = Color.WHITE
) -> void:
	MeshFactory.append_wall(_tool(key), origin, size, uv_per_meter, colour)
	_count(key, 2)


func add_wall_quad(key: StringName, origin: Transform3D, size: Vector2, uv_scale: float, colour: Color) -> void:
	MeshFactory.append_wall_quad(_tool(key), origin, size, uv_scale, colour)
	_count(key, 2)


func add_frustum(
	key: StringName,
	origin: Transform3D,
	bottom_size: Vector2,
	top_size: Vector2,
	height: float,
	uv_scale: float = MeshFactory.DEFAULT_UV_SCALE,
	colour: Color = Color.WHITE,
	top_offset: Vector3 = Vector3.ZERO,
	caps: bool = true
) -> void:
	MeshFactory.append_frustum(_tool(key), origin, bottom_size, top_size, height, uv_scale, colour, top_offset, caps)
	_count(key, 12)


func add_cylinder(
	key: StringName,
	origin: Transform3D,
	radius: float,
	height: float,
	segments: int = 8,
	uv_scale: float = MeshFactory.DEFAULT_UV_SCALE,
	colour: Color = Color.WHITE,
	caps: bool = true,
	top_radius: float = -1.0
) -> void:
	MeshFactory.append_cylinder(_tool(key), origin, radius, height, segments, uv_scale, colour, caps, top_radius)
	_count(key, segments * 2 + (2 if caps else 0))


func add_cone(key: StringName, origin: Transform3D, radius: float, height: float, segments: int = 6, uv_scale: float = MeshFactory.DEFAULT_UV_SCALE, colour: Color = Color.WHITE) -> void:
	MeshFactory.append_cone(_tool(key), origin, radius, height, segments, uv_scale, colour)
	_count(key, segments * 2)


func add_sphere(
	key: StringName,
	origin: Transform3D,
	radius: float,
	rings: int = 5,
	segments: int = 8,
	uv_scale: float = MeshFactory.DEFAULT_UV_SCALE,
	colour: Color = Color.WHITE,
	flatten: float = 1.0
) -> void:
	MeshFactory.append_sphere(_tool(key), origin, radius, rings, segments, uv_scale, colour, flatten)
	_count(key, rings * segments * 2)


func add_stairs(key: StringName, origin: Transform3D, width: float, height: float, depth: float, steps: int, uv_scale: float, colour: Color) -> void:
	MeshFactory.append_stairs(_tool(key), origin, width, height, depth, steps, uv_scale, colour)
	_count(key, 12 * maxi(steps, 1))


func add_railing(key: StringName, origin: Transform3D, length: float, height: float, uv_scale: float, colour: Color) -> void:
	MeshFactory.append_railing(_tool(key), origin, length, height, uv_scale, colour)
	_count(key, 12 * (maxi(int(length / 2.4), 2) + 1))


# --------------------------------------------------------------------------------------
# commit
# --------------------------------------------------------------------------------------
## Turns every accumulated material group into a MeshInstance3D under `parent`.
##
## `shadow_mode` is applied to every created instance so that the caller can decide
## whether a chunk casts shadows (near chunks do, distant chunks do not: the shadow atlas
## is the most expensive resource on a mobile GPU).
func commit(parent: Node3D, name_prefix: String, shadow_mode: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON) -> Array[MeshInstance3D]:
	var created: Array[MeshInstance3D] = []
	for key: StringName in _tools.keys():
		var tool: SurfaceTool = _tools[key]
		tool.index()
		var mesh := tool.commit()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "%s_%s" % [name_prefix, key]
		instance.mesh = mesh
		var material := materials.get_material(key)
		if material != null:
			instance.material_override = material
		instance.cast_shadow = shadow_mode
		parent.add_child(instance)
		created.append(instance)
	_tools.clear()
	return created


## A static body holding one box collision shape per added collider. Chunks use this for
## buildings, kerbs and solid props; a box per building is dramatically cheaper than a
## triangle mesh and behaves better when a car hits a wall at 160 km/h.
func build_collision_body(parent: Node3D, name: String, boxes: Array[Dictionary], collision_layer: int = 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = name
	body.collision_layer = collision_layer
	body.collision_mask = 0
	parent.add_child(body)
	for box: Dictionary in boxes:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = box.get("size", Vector3.ONE)
		shape.shape = box_shape
		shape.transform = Transform3D(box.get("basis", Basis()), box.get("position", Vector3.ZERO))
		body.add_child(shape)
	return body
