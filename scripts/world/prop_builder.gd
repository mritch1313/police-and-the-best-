extends RefCounted
class_name PropBuilder
## Builds every piece of street furniture and clutter in the city.
##
## The props are what turn an empty road network into a place: lamp posts with arms,
## benches, hydrants, bins, bollards, jersey barriers, traffic lights with lenses, bus
## stops with glass, dumpsters, planters, containers, crates, cones, barrels, fountains,
## statues, trees and market tents.
##
## Every prop is assembled from primitives into the shared GeometryBuilder of its chunk
## (so props cost no extra draw calls) and reports whether it needs a collision box. Only
## the props a car can realistically hit get a collider: a phone cannot afford thousands of
## physics shapes for lamp posts nobody ever touches.

## Radii (metres) used when a prop is placed inside a MultiMesh or a collision box.
var materials: MaterialLibrary


func _init(p_materials: MaterialLibrary = null) -> void:
	materials = p_materials if p_materials != null else MaterialLibrary.new()


## Adds one prop to the builder.
##
## `data` is an entry from DistrictLayout ({"kind", "position", "rotation", "scale"...}).
## `collision_boxes` receives one dictionary per solid part of the prop, ready for
## GeometryBuilder.build_collision_body.
func add_prop(
	builder: GeometryBuilder,
	data: Dictionary,
	collision_boxes: Array[Dictionary] = [],
	detail: int = CarMeshFactory.DETAIL_MEDIUM
) -> void:
	var kind: StringName = data.get("kind", &"")
	var position: Vector3 = data.get("position", Vector3.ZERO)
	var rotation: float = float(data.get("rotation", 0.0))
	var scale: float = float(data.get("scale", 1.0))
	var origin := Transform3D(Basis(Vector3.UP, rotation).scaled(Vector3(scale, scale, scale)), position)
	match kind:
		DistrictLayout.PROP_LAMP:
			_build_lamp(builder, origin, collision_boxes)
		DistrictLayout.PROP_TREE:
			_build_tree(builder, origin, collision_boxes)
		DistrictLayout.PROP_BUSH:
			_build_bush(builder, origin)
		DistrictLayout.PROP_BENCH:
			_build_bench(builder, origin, collision_boxes)
		DistrictLayout.PROP_BIN:
			_build_bin(builder, origin, collision_boxes)
		DistrictLayout.PROP_HYDRANT:
			_build_hydrant(builder, origin)
		DistrictLayout.PROP_BOLLARD:
			_build_bollard(builder, origin)
		DistrictLayout.PROP_BARRIER:
			_build_barrier(builder, origin, collision_boxes)
		DistrictLayout.PROP_TRAFFIC_LIGHT:
			_build_traffic_light(builder, origin, collision_boxes)
		DistrictLayout.PROP_SIGN:
			_build_sign(builder, origin)
		DistrictLayout.PROP_BUS_STOP:
			_build_bus_stop(builder, origin, collision_boxes)
		DistrictLayout.PROP_FENCE:
			_build_fence(builder, origin, collision_boxes)
		DistrictLayout.PROP_DUMPSTER:
			_build_dumpster(builder, origin, collision_boxes)
		DistrictLayout.PROP_PLANTER:
			_build_planter(builder, origin, collision_boxes)
		DistrictLayout.PROP_CONTAINER:
			_build_container(builder, origin, collision_boxes)
		DistrictLayout.PROP_CRATE:
			_build_crate(builder, origin, collision_boxes)
		DistrictLayout.PROP_CONE:
			_build_cone(builder, origin)
		DistrictLayout.PROP_BARREL:
			_build_barrel(builder, origin, collision_boxes)
		DistrictLayout.PROP_FOUNTAIN:
			_build_fountain(builder, origin, collision_boxes)
		DistrictLayout.PROP_STATUE:
			_build_statue(builder, origin, collision_boxes)
		DistrictLayout.PROP_PARKED_CAR:
			_build_parked_car(builder, data, collision_boxes, detail)
		DistrictLayout.PROP_TENT:
			_build_market_tent(builder, origin, collision_boxes)


func _box(origin: Transform3D, position: Vector3, size: Vector3) -> Dictionary:
	return {
		"position": origin * position,
		"size": size,
		"basis": origin.basis,
	}


# --------------------------------------------------------------------------------------
# props
# --------------------------------------------------------------------------------------
func _build_lamp(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var metal := MaterialLibrary.METAL
	var height := 6.4
	builder.add_cylinder(metal, origin * Transform3D(Basis(), Vector3(0, height * 0.5, 0)), 0.09, height, 8, 1.0, Color(0.36, 0.37, 0.4), true, 0.07)
	builder.add_cylinder(metal, origin * Transform3D(Basis(), Vector3(0, 0.25, 0)), 0.16, 0.5, 8, 1.2, Color(0.3, 0.31, 0.33))
	# Arm bending over the road and the lamp head.
	var arm_rotation := Basis(Vector3.RIGHT, PI * 0.5) * Basis(Vector3.UP, 0.0)
	builder.add_cylinder(
		metal, origin * Transform3D(arm_rotation, Vector3(0.55, height - 0.15, 0.0)),
		0.055, 1.1, 6, 1.4, Color(0.36, 0.37, 0.4)
	)
	builder.add_frustum(
		MaterialLibrary.PLASTIC,
		origin * Transform3D(Basis(), Vector3(1.05, height - 0.28, 0.0)),
		Vector2(0.44, 0.28), Vector2(0.3, 0.2), 0.16, 1.6, Color(0.22, 0.23, 0.25)
	)
	builder.add_box(
		MaterialLibrary.LIGHT_HEAD,
		origin * Transform3D(Basis(), Vector3(1.05, height - 0.38, 0.0)),
		Vector3(0.34, 0.04, 0.2), 2.0, Color(0.95, 0.94, 0.86)
	)
	collision_boxes.append(_box(origin, Vector3(0, height * 0.5, 0), Vector3(0.28, height, 0.28)))


func _build_tree(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var trunk_height := 2.2
	builder.add_cylinder(MaterialLibrary.WOOD, origin * Transform3D(Basis(), Vector3(0, trunk_height * 0.5, 0)), 0.17, trunk_height, 8, 1.0, Color(0.34, 0.26, 0.19))
	var foliage_colour := Color(0.24, 0.42, 0.2).lerp(Color(0.38, 0.56, 0.24), fmod(absf(origin.origin.x + origin.origin.z), 1.0))
	builder.add_sphere(MaterialLibrary.GRASS, origin * Transform3D(Basis(), Vector3(0, trunk_height + 0.9, 0)), 1.5, 5, 6, 0.5, foliage_colour, 0.9)
	builder.add_sphere(
		MaterialLibrary.GRASS,
		origin * Transform3D(Basis(Basis(Vector3.UP, 1.1), Vector3(0.7, trunk_height + 1.5, -0.4))),
		1.05, 4, 6, 0.6, foliage_colour.lightened(0.12), 0.9
	)
	builder.add_sphere(
		MaterialLibrary.GRASS,
		origin * Transform3D(Basis(Basis(Vector3.UP, 2.4), Vector3(-0.75, trunk_height + 1.25, 0.5))),
		0.95, 4, 6, 0.6, foliage_colour.darkened(0.12), 0.9
	)
	collision_boxes.append(_box(origin, Vector3(0, 1.2, 0), Vector3(0.42, 2.4, 0.42)))


func _build_bush(builder: GeometryBuilder, origin: Transform3D) -> void:
	builder.add_sphere(MaterialLibrary.GRASS, origin * Transform3D(Basis(), Vector3(0, 0.42, 0)), 0.62, 4, 6, 0.8, Color(0.26, 0.44, 0.21), 0.85)
	builder.add_sphere(
		MaterialLibrary.GRASS, origin * Transform3D(Basis(Basis(Vector3.UP, 1.7), Vector3(0.45, 0.36, 0.2))),
		0.42, 3, 5, 0.9, Color(0.32, 0.5, 0.24), 0.85
	)


func _build_bench(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var wood := MaterialLibrary.WOOD
	var metal := MaterialLibrary.METAL
	builder.add_box(wood, origin * Transform3D(Basis(), Vector3(0, 0.45, 0)), Vector3(1.8, 0.07, 0.44), 1.2, Color(0.62, 0.45, 0.28))
	builder.add_box(wood, origin * Transform3D(Basis(), Vector3(0, 0.72, -0.2)), Vector3(1.8, 0.34, 0.06), 1.2, Color(0.6, 0.44, 0.27))
	for side in [-0.75, 0.75]:
		builder.add_box(metal, origin * Transform3D(Basis(), Vector3(side, 0.22, 0)), Vector3(0.07, 0.44, 0.4), 1.6, Color(0.32, 0.33, 0.35))
	collision_boxes.append(_box(origin, Vector3(0, 0.4, 0), Vector3(1.85, 0.8, 0.5)))


func _build_bin(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 0.38, 0)), 0.28, 0.76, 10, 1.4, Color(0.3, 0.33, 0.3))
	builder.add_cylinder(MaterialLibrary.PLASTIC, origin * Transform3D(Basis(), Vector3(0, 0.78, 0)), 0.3, 0.06, 10, 1.6, Color(0.18, 0.2, 0.19))
	collision_boxes.append(_box(origin, Vector3(0, 0.4, 0), Vector3(0.6, 0.8, 0.6)))


func _build_hydrant(builder: GeometryBuilder, origin: Transform3D) -> void:
	var red := Color(0.62, 0.13, 0.1)
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 0.3, 0)), 0.11, 0.6, 8, 1.8, red)
	builder.add_sphere(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 0.62, 0)), 0.13, 3, 8, 2.0, red)
	builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0.16, 0.42, 0)), Vector3(0.16, 0.1, 0.1), 2.0, red.darkened(0.2))


func _build_bollard(builder: GeometryBuilder, origin: Transform3D) -> void:
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 0.42, 0)), 0.09, 0.84, 8, 1.6, Color(0.42, 0.43, 0.45))
	builder.add_box(MaterialLibrary.LIGHT_TAIL, origin * Transform3D(Basis(), Vector3(0, 0.78, 0)), Vector3(0.1, 0.06, 0.1), 2.0, Color(0.75, 0.2, 0.12))


func _build_barrier(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var concrete := Color(0.68, 0.66, 0.62)
	builder.add_frustum(
		MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.35, 0)),
		Vector2(0.62, 1.9), Vector2(0.26, 1.9), 0.7, 1.0, concrete
	)
	builder.add_box(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.78, 0)), Vector3(0.3, 0.16, 1.9), 1.2, concrete.lightened(0.06))
	collision_boxes.append(_box(origin, Vector3(0, 0.42, 0), Vector3(0.62, 0.84, 1.9)))


func _build_traffic_light(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var metal := MaterialLibrary.METAL
	var height := 5.6
	builder.add_cylinder(metal, origin * Transform3D(Basis(), Vector3(0, height * 0.5, 0)), 0.08, height, 8, 1.2, Color(0.34, 0.35, 0.37))
	builder.add_cylinder(
		metal, origin * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.7, height - 0.12, 0)),
		0.05, 1.4, 6, 1.6, Color(0.34, 0.35, 0.37)
	)
	var head_origin := origin * Transform3D(Basis(), Vector3(1.35, height - 0.45, 0))
	builder.add_frustum(MaterialLibrary.PLASTIC, head_origin, Vector2(0.32, 0.24), Vector2(0.32, 0.24), 0.9, 1.6, Color(0.14, 0.15, 0.16))
	builder.add_box(MaterialLibrary.LIGHT_TAIL, head_origin * Transform3D(Basis(), Vector3(0, 0.28, 0.14)), Vector3(0.2, 0.2, 0.06), 2.0, Color(0.8, 0.12, 0.1))
	builder.add_box(MaterialLibrary.PLASTIC, head_origin * Transform3D(Basis(), Vector3(0, 0.0, 0.14)), Vector3(0.2, 0.2, 0.06), 2.0, Color(0.85, 0.7, 0.15))
	builder.add_box(MaterialLibrary.LIGHT_HEAD, head_origin * Transform3D(Basis(), Vector3(0, -0.28, 0.14)), Vector3(0.2, 0.2, 0.06), 2.0, Color(0.2, 0.75, 0.35))
	collision_boxes.append(_box(origin, Vector3(0, height * 0.5, 0), Vector3(0.24, height, 0.24)))


func _build_sign(builder: GeometryBuilder, origin: Transform3D) -> void:
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 1.3, 0)), 0.05, 2.6, 6, 1.6, Color(0.45, 0.46, 0.48))
	builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 2.35, 0)), Vector3(0.72, 0.72, 0.04), 1.6, Color(0.82, 0.28, 0.16))
	builder.add_box(MaterialLibrary.ROAD_PAINT, origin * Transform3D(Basis(), Vector3(0, 2.35, 0.03)), Vector3(0.5, 0.16, 0.02), 2.0, Color(0.94, 0.94, 0.9))


func _build_bus_stop(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var metal := MaterialLibrary.METAL
	builder.add_box(metal, origin * Transform3D(Basis(), Vector3(0, 2.55, 0)), Vector3(3.4, 0.12, 1.5), 1.0, Color(0.3, 0.32, 0.35))
	for x in [-1.6, 1.6]:
		for z in [-0.65, 0.65]:
			builder.add_cylinder(metal, origin * Transform3D(Basis(), Vector3(x, 1.28, z)), 0.06, 2.55, 6, 1.6, Color(0.34, 0.35, 0.38))
	builder.add_box(MaterialLibrary.GLASS, origin * Transform3D(Basis(), Vector3(0, 1.3, -0.68)), Vector3(3.2, 2.4, 0.06), 0.8, Color(1, 1, 1, 0.7))
	builder.add_box(MaterialLibrary.WOOD, origin * Transform3D(Basis(), Vector3(0, 0.5, 0.3)), Vector3(2.6, 0.08, 0.42), 1.2, Color(0.55, 0.4, 0.26))
	builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(-1.5, 1.6, 0.6)), Vector3(0.06, 1.2, 0.9), 1.4, Color(0.3, 0.32, 0.34))
	builder.add_box(MaterialLibrary.SIGN_SHOP, origin * Transform3D(Basis(), Vector3(-1.5, 2.0, 0.62)), Vector3(0.5, 1.0, 0.04), 1.4, Color(0.85, 0.85, 0.85))
	collision_boxes.append(_box(origin, Vector3(0, 1.3, -0.68), Vector3(3.2, 2.6, 0.2)))
	collision_boxes.append(_box(origin, Vector3(-1.5, 1.6, 0.6), Vector3(0.2, 3.2, 0.9)))


func _build_fence(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	builder.add_railing(MaterialLibrary.METAL, origin, 6.0, 1.1, 1.4, Color(0.36, 0.37, 0.4))
	collision_boxes.append(_box(origin, Vector3(0, 0.55, 0), Vector3(6.0, 1.1, 0.14)))


func _build_dumpster(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var metal := MaterialLibrary.METAL
	builder.add_frustum(metal, origin * Transform3D(Basis(), Vector3(0, 0.62, 0)), Vector2(1.3, 2.0), Vector2(1.42, 2.1), 1.0, 1.0, Color(0.2, 0.42, 0.3))
	builder.add_frustum(metal, origin * Transform3D(Basis(), Vector3(0, 1.16, 0)), Vector2(1.44, 2.12), Vector2(1.3, 2.0), 0.1, 1.2, Color(0.17, 0.36, 0.26))
	for x in [-0.5, 0.5]:
		for z in [-0.85, 0.85]:
			builder.add_cylinder(MaterialLibrary.RUBBER, origin * Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(x, 0.09, z)), 0.09, 0.07, 6, 2.0, Color(0.1, 0.1, 0.1))
	collision_boxes.append(_box(origin, Vector3(0, 0.6, 0), Vector3(1.45, 1.2, 2.1)))


func _build_planter(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	builder.add_frustum(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.3, 0)), Vector2(1.2, 1.2), Vector2(1.3, 1.3), 0.6, 1.0, Color(0.7, 0.68, 0.64))
	builder.add_box(MaterialLibrary.DIRT, origin * Transform3D(Basis(), Vector3(0, 0.6, 0)), Vector3(1.1, 0.06, 1.1), 1.6, Color(0.34, 0.26, 0.18))
	builder.add_sphere(MaterialLibrary.GRASS, origin * Transform3D(Basis(), Vector3(0, 0.95, 0)), 0.55, 4, 6, 0.9, Color(0.27, 0.45, 0.22), 0.85)
	collision_boxes.append(_box(origin, Vector3(0, 0.32, 0), Vector3(1.3, 0.64, 1.3)))


func _build_container(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var tint := Color.from_hsv(fmod(absf(origin.origin.x * 0.37 + origin.origin.z * 0.11), 1.0), 0.55, 0.7)
	builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 1.3, 0)), Vector3(2.44, 2.6, 6.05), 0.4, tint)
	for i in 6:
		var z := -2.6 + float(i) * 1.04
		builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(-1.23, 1.3, z)), Vector3(0.06, 2.5, 0.16), 0.9, tint.darkened(0.25))
		builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(1.23, 1.3, z)), Vector3(0.06, 2.5, 0.16), 0.9, tint.darkened(0.25))
	collision_boxes.append(_box(origin, Vector3(0, 1.3, 0), Vector3(2.44, 2.6, 6.05)))


func _build_crate(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var size := 0.9
	builder.add_box(MaterialLibrary.WOOD, origin * Transform3D(Basis(), Vector3(0, size * 0.5, 0)), Vector3(size, size, size), 1.4, Color(0.58, 0.42, 0.26))
	builder.add_box(MaterialLibrary.WOOD, origin * Transform3D(Basis(), Vector3(0, size * 0.5, size * 0.5)), Vector3(size * 1.02, 0.1, 0.04), 1.6, Color(0.48, 0.34, 0.2))
	collision_boxes.append(_box(origin, Vector3(0, size * 0.5, 0), Vector3(size, size, size)))


func _build_cone(builder: GeometryBuilder, origin: Transform3D) -> void:
	builder.add_box(MaterialLibrary.PLASTIC, origin * Transform3D(Basis(), Vector3(0, 0.03, 0)), Vector3(0.36, 0.06, 0.36), 2.0, Color(0.16, 0.16, 0.18))
	builder.add_cone(MaterialLibrary.PLASTIC, origin * Transform3D(Basis(), Vector3(0, 0.34, 0)), 0.16, 0.62, 8, 2.4, Color(0.86, 0.34, 0.12))
	builder.add_cylinder(MaterialLibrary.PLASTIC, origin * Transform3D(Basis(), Vector3(0, 0.42, 0)), 0.125, 0.12, 8, 3.0, Color(0.94, 0.94, 0.92))


func _build_barrel(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	var tint := Color.from_hsv(fmod(absf(origin.origin.z * 0.41), 1.0), 0.5, 0.62)
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 0.45, 0)), 0.3, 0.9, 10, 1.2, tint)
	for y in [0.2, 0.7]:
		builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, y, 0)), 0.315, 0.06, 10, 2.0, tint.darkened(0.2))
	collision_boxes.append(_box(origin, Vector3(0, 0.45, 0), Vector3(0.62, 0.9, 0.62)))


func _build_fountain(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	builder.add_cylinder(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.25, 0)), 2.6, 0.5, 16, 0.6, Color(0.72, 0.7, 0.66))
	builder.add_cylinder(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.55, 0)), 2.3, 0.14, 16, 0.8, Color(0.64, 0.62, 0.58))
	builder.add_cylinder(MaterialLibrary.GLASS, origin * Transform3D(Basis(), Vector3(0, 0.6, 0)), 2.2, 0.06, 16, 1.0, Color(0.35, 0.55, 0.62, 0.75))
	builder.add_cylinder(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 1.1, 0)), 0.35, 1.1, 10, 1.0, Color(0.68, 0.66, 0.62))
	builder.add_sphere(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 1.8, 0)), 0.45, 4, 10, 1.0, Color(0.7, 0.68, 0.64))
	collision_boxes.append(_box(origin, Vector3(0, 0.3, 0), Vector3(5.2, 0.6, 5.2)))


func _build_statue(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	builder.add_box(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 0.35, 0)), Vector3(1.6, 0.7, 1.6), 1.0, Color(0.66, 0.64, 0.6))
	builder.add_box(MaterialLibrary.CONCRETE, origin * Transform3D(Basis(), Vector3(0, 1.05, 0)), Vector3(1.0, 0.7, 1.0), 1.2, Color(0.6, 0.58, 0.55))
	builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 2.0, 0)), 0.34, 1.2, 10, 1.0, Color(0.42, 0.4, 0.36))
	builder.add_sphere(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(0, 2.75, 0)), 0.26, 4, 10, 1.0, Color(0.45, 0.43, 0.38))
	builder.add_box(MaterialLibrary.METAL, origin * Transform3D(Basis(Basis(Vector3.UP, 0.4), Vector3(0.45, 2.1, 0))), Vector3(0.9, 0.16, 0.16), 1.4, Color(0.45, 0.43, 0.38))
	collision_boxes.append(_box(origin, Vector3(0, 0.7, 0), Vector3(1.6, 1.4, 1.6)))


func _build_market_tent(builder: GeometryBuilder, origin: Transform3D, collision_boxes: Array[Dictionary]) -> void:
	for x in [-1.4, 1.4]:
		for z in [-1.4, 1.4]:
			builder.add_cylinder(MaterialLibrary.METAL, origin * Transform3D(Basis(), Vector3(x, 1.2, z)), 0.05, 2.4, 6, 1.6, Color(0.5, 0.5, 0.52))
	builder.add_frustum(MaterialLibrary.FABRIC_TENT, origin * Transform3D(Basis(), Vector3(0, 2.6, 0)), Vector2(3.2, 3.2), Vector2(0.2, 0.2), 0.9, 1.0, Color(0.78, 0.3, 0.26))
	builder.add_box(MaterialLibrary.WOOD, origin * Transform3D(Basis(), Vector3(0, 0.85, 0)), Vector3(2.6, 0.1, 1.0), 1.2, Color(0.55, 0.4, 0.26))
	collision_boxes.append(_box(origin, Vector3(0, 0.9, 0), Vector3(2.8, 0.2, 1.2)))


func _build_parked_car(
	builder: GeometryBuilder,
	data: Dictionary,
	collision_boxes: Array[Dictionary],
	detail: int
) -> void:
	var model := int(data.get("model", 0))
	var colour: Color = data.get("colour", Color(0.7, 0.2, 0.2))
	var position: Vector3 = data.get("position", Vector3.ZERO)
	var rotation: float = float(data.get("rotation", 0.0))
	var origin := Transform3D(Basis(Vector3.UP, rotation), position)
	CarMeshFactory.append_body(builder, model, origin, colour, detail)
	var size := CarMeshFactory.dimensions(model)
	collision_boxes.append(
		{
			"position": position + Vector3(0.0, 0.72, 0.0),
			"size": Vector3(size.x * 1.02, 1.0, size.z * 0.98),
			"basis": Basis(Vector3.UP, rotation),
		}
	)
	# Wheels of the parked car: two cylinders per side, cheap and invisible from far away.
	var wheel_radius := CarMeshFactory.wheel_radius(model)
	var axle_front := float(CarMeshFactory.MODELS[model]["axle_front"])
	var axle_rear := float(CarMeshFactory.MODELS[model]["axle_rear"])
	var track := float(CarMeshFactory.MODELS[model]["track"])
	for axle: float in [axle_front, axle_rear]:
		for side in [-1.0, 1.0]:
			var wheel_origin := origin * Transform3D(
				Basis(Vector3.FORWARD, PI * 0.5),
				Vector3(side * track, wheel_radius, -axle)
			)
			builder.add_cylinder(
				MaterialLibrary.RUBBER, wheel_origin, wheel_radius, wheel_radius * 0.65, 10, 1.6, Color(0.07, 0.07, 0.08)
			)
