extends RefCounted
class_name CarMeshFactory
## Procedural car models.
##
## The game ships without imported models, so the cars are built from the same primitives
## the city uses - but they are built with care: tapered cabins, sloped hoods, real
## windows, bumpers, mirrors, head and tail lights, exhausts, wheel arches and a separate
## wheel mesh with a tyre and a rim. Nine shapes cover the whole cast (sedan, hatchback,
## SUV, van, pickup, sports car, police cruiser, truck, bus).
##
## Because the models are described by data (see MODELS), replacing them later is a local
## change: either swap the numbers here, or hand the visual layer a real .glb model - the
## rest of the game only ever asks for "the body meshes" and "the wheel mesh".

## Wheel geometry per model: front axle offset, rear axle offset, radius, width, track.
const MODELS := {
	0: {  # sedan
		"name": "sedan", "length": 4.45, "width": 1.86, "height": 0.74, "ride": 0.16,
		"wheel_radius": 0.33, "wheel_width": 0.23, "axle_front": 1.42, "axle_rear": -1.44,
		"track": 0.80, "cabin": Vector2(0.42, 0.62), "hood": 0.28, "trunk": 0.22,
	},
	1: {  # hatchback
		"name": "hatchback", "length": 3.72, "width": 1.70, "height": 0.76, "ride": 0.15,
		"wheel_radius": 0.30, "wheel_width": 0.21, "axle_front": 1.18, "axle_rear": -1.22,
		"track": 0.73, "cabin": Vector2(0.46, 0.6), "hood": 0.2, "trunk": 0.08,
	},
	2: {  # SUV
		"name": "suv", "length": 4.72, "width": 1.96, "height": 0.98, "ride": 0.22,
		"wheel_radius": 0.37, "wheel_width": 0.26, "axle_front": 1.48, "axle_rear": -1.5,
		"track": 0.84, "cabin": Vector2(0.44, 0.66), "hood": 0.24, "trunk": 0.14,
	},
	3: {  # van
		"name": "van", "length": 5.40, "width": 2.02, "height": 1.42, "ride": 0.18,
		"wheel_radius": 0.36, "wheel_width": 0.24, "axle_front": 1.72, "axle_rear": -1.72,
		"track": 0.86, "cabin": Vector2(0.46, 0.5), "hood": 0.12, "trunk": 0.0,
	},
	4: {  # pickup
		"name": "pickup", "length": 5.20, "width": 1.98, "height": 0.92, "ride": 0.22,
		"wheel_radius": 0.38, "wheel_width": 0.27, "axle_front": 1.62, "axle_rear": -1.66,
		"track": 0.84, "cabin": Vector2(0.34, 0.62), "hood": 0.26, "trunk": 0.0,
	},
	5: {  # sports
		"name": "sports", "length": 4.32, "width": 1.92, "height": 0.62, "ride": 0.12,
		"wheel_radius": 0.34, "wheel_width": 0.28, "axle_front": 1.36, "axle_rear": -1.38,
		"track": 0.86, "cabin": Vector2(0.34, 0.42), "hood": 0.34, "trunk": 0.18,
	},
	6: {  # police cruiser
		"name": "cruiser", "length": 4.78, "width": 1.94, "height": 0.78, "ride": 0.17,
		"wheel_radius": 0.35, "wheel_width": 0.26, "axle_front": 1.5, "axle_rear": -1.52,
		"track": 0.82, "cabin": Vector2(0.42, 0.62), "hood": 0.26, "trunk": 0.22,
	},
	7: {  # truck
		"name": "truck", "length": 7.70, "width": 2.36, "height": 1.60, "ride": 0.30,
		"wheel_radius": 0.48, "wheel_width": 0.30, "axle_front": 2.5, "axle_rear": -2.2,
		"track": 1.0, "cabin": Vector2(0.3, 0.5), "hood": 0.2, "trunk": 0.0,
	},
	8: {  # bus
		"name": "bus", "length": 11.4, "width": 2.5, "height": 2.72, "ride": 0.24,
		"wheel_radius": 0.5, "wheel_width": 0.32, "axle_front": 3.6, "axle_rear": -3.2,
		"track": 1.06, "cabin": Vector2(0.82, 0.9), "hood": 0.0, "trunk": 0.0,
	},
}

const MODEL_SEDAN := 0
const MODEL_HATCHBACK := 1
const MODEL_SUV := 2
const MODEL_VAN := 3
const MODEL_PICKUP := 4
const MODEL_SPORTS := 5
const MODEL_POLICE := 6
const MODEL_TRUCK := 7
const MODEL_BUS := 8

## Trailers and details are the most expensive part of a car; parking lots use level 0.
const DETAIL_LOW := 0
const DETAIL_MEDIUM := 1
const DETAIL_HIGH := 2


static func model_count() -> int:
	return MODELS.size()


static func dimensions(model: int) -> Vector3:
	var data: Dictionary = MODELS.get(model, MODELS[MODEL_SEDAN])
	return Vector3(float(data["width"]), float(data["height"]), float(data["length"]))


static func wheel_radius(model: int) -> float:
	var data: Dictionary = MODELS.get(model, MODELS[MODEL_SEDAN])
	return float(data["wheel_radius"])


static func model_name(model: int) -> String:
	var data: Dictionary = MODELS.get(model, MODELS[MODEL_SEDAN])
	return String(data["name"])


## Builds the body of a car into a fresh GeometryBuilder.
##
## The body is returned as one mesh per material (paint, glass, chrome, rubber, lights),
## which the visual layer attaches as separate MeshInstance3D nodes so the head lights can
## be switched on and the brake lights can glow without touching the paint material.
static func build_body(model: int, colour: Color, materials: MaterialLibrary, detail: int = DETAIL_HIGH) -> Dictionary:
	var builder := GeometryBuilder.new(materials)
	append_body(builder, model, Transform3D(), colour, detail)
	return commit_grouped(builder, materials)


## Builds one wheel as a mesh with two surfaces: the tyre (index 0) and the rim (index 1).
static func build_wheel(model: int, materials: MaterialLibrary) -> ArrayMesh:
	var data: Dictionary = MODELS.get(model, MODELS[MODEL_SEDAN])
	var radius := float(data["wheel_radius"])
	var width := float(data["wheel_width"])
	var builder := GeometryBuilder.new(materials)
	# The tyre: a cylinder lying on its side (the primitive is built along +Y, so it is
	# rotated 90 degrees around Z to point along the car's X axis).
	var tyre_transform := Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO)
	builder.add_cylinder(MaterialLibrary.RUBBER, tyre_transform, radius, width, 14, 1.4, Color(0.06, 0.06, 0.07), true)
	var rim_transform := Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(0.0, 0.0, 0.0))
	builder.add_cylinder(
		MaterialLibrary.CHROME, rim_transform, radius * 0.62, width * 1.02, 12, 1.6, Color(0.78, 0.79, 0.82), true
	)
	# Spokes make the wheel readable while it spins.
	for i in 5:
		var angle := TAU * float(i) / 5.0
		var spoke := Transform3D(
			Basis(Vector3.FORWARD, PI * 0.5) * Basis(Vector3.RIGHT, angle),
			Vector3(0.0, 0.0, 0.0)
		)
		builder.add_box(MaterialLibrary.CHROME, spoke, Vector3(width * 0.9, 0.05, radius * 1.1), 2.0, Color(0.7, 0.71, 0.74))
	var meshes := commit_grouped(builder, materials)
	if meshes.is_empty():
		return null
	# Merge the groups into a single mesh with one surface per material.
	var merged := ArrayMesh.new()
	for key: StringName in meshes.keys():
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, (meshes[key] as ArrayMesh).surface_get_arrays(0))
	return merged


## Appends a complete car (body only, no wheels) to an existing builder. Used by the chunk
## builder for parked cars, so a parking lot costs no extra draw call at all.
static func append_body(
	builder: GeometryBuilder,
	model: int,
	origin: Transform3D,
	colour: Color,
	detail: int = DETAIL_MEDIUM
) -> void:
	var data: Dictionary = MODELS.get(model, MODELS[MODEL_SEDAN])
	var length := float(data["length"])
	var width := float(data["width"])
	var height := float(data["height"])
	var ride := float(data["ride"])
	var cabin: Vector2 = data["cabin"]
	var hood: float = float(data["hood"])
	var trunk: float = float(data["trunk"])
	var paint := MaterialLibrary.CAR_BODY
	var glass := MaterialLibrary.GLASS
	var body_y := ride + height * 0.5 - height * 0.5  # centre of the lower body

	if model == MODEL_BUS or model == MODEL_TRUCK:
		_append_utility_body(builder, model, origin, colour, data, detail)
		return

	# Lower body: a slightly tapered hull, which reads as a real car silhouette.
	var hull_height := height * 0.62
	builder.add_frustum(
		paint, origin * Transform3D(Basis(), Vector3(0.0, body_y, 0.0)),
		Vector2(width, length), Vector2(width * 0.99, length * 0.97), hull_height,
		0.8, colour
	)
	# Bonnet and boot.
	if hood > 0.05:
		builder.add_frustum(
			paint,
			origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.42, length * (0.5 - hood * 0.5))),
			Vector2(width * 0.96, length * hood), Vector2(width * 0.9, length * hood * 0.94),
			height * 0.2, 0.8, colour, Vector3(0.0, 0.0, -0.05)
		)
	if trunk > 0.05:
		builder.add_frustum(
			paint,
			origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.4, -length * (0.5 - trunk * 0.5))),
			Vector2(width * 0.96, length * trunk), Vector2(width * 0.92, length * trunk * 0.94),
			height * 0.18, 0.8, colour, Vector3(0.0, 0.0, 0.05)
		)
	# Cabin: tapered greenhouse with a glass band underneath the roof.
	var cabin_length := length * cabin.y
	var cabin_width := width * 0.94
	var cabin_height := height * 0.46
	var cabin_z := length * 0.02
	builder.add_frustum(
		paint,
		origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.5 + cabin_height * 0.5, cabin_z)),
		Vector2(cabin_width, cabin_length), Vector2(cabin_width * 0.86, cabin_length * 0.82),
		cabin_height * 0.62, 0.8, colour, Vector3(0.0, 0.0, 0.0)
	)
	# Windows: a glass band that sits slightly proud of the cabin so it is always visible.
	builder.add_frustum(
		glass,
		origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.5 + cabin_height * 0.36, cabin_z)),
		Vector2(cabin_width * 1.005, cabin_length * 0.98), Vector2(cabin_width * 0.87, cabin_length * 0.8),
		cabin_height * 0.34, 1.6, Color(1, 1, 1, 0.85)
	)
	# Roof.
	builder.add_frustum(
		paint,
		origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.5 + cabin_height * 0.86, cabin_z)),
		Vector2(cabin_width * 0.87, cabin_length * 0.83), Vector2(cabin_width * 0.8, cabin_length * 0.76),
		cabin_height * 0.2, 0.8, colour
	)
	# Bumpers, skirts and the grille.
	builder.add_box(
		MaterialLibrary.PLASTIC,
		origin * Transform3D(Basis(), Vector3(0.0, body_y - hull_height * 0.3, length * 0.5 - 0.06)),
		Vector3(width * 1.0, height * 0.26, 0.22), 1.2, Color(0.13, 0.13, 0.15)
	)
	builder.add_box(
		MaterialLibrary.PLASTIC,
		origin * Transform3D(Basis(), Vector3(0.0, body_y - hull_height * 0.3, -length * 0.5 + 0.06)),
		Vector3(width * 1.0, height * 0.26, 0.22), 1.2, Color(0.13, 0.13, 0.15)
	)
	builder.add_box(
		MaterialLibrary.PLASTIC,
		origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.16, length * 0.5 - 0.02)),
		Vector3(width * 0.62, height * 0.22, 0.08), 1.4, Color(0.09, 0.09, 0.1)
	)
	builder.add_box(
		MaterialLibrary.CHROME,
		origin * Transform3D(Basis(), Vector3(0.0, body_y + hull_height * 0.34, length * 0.5 - 0.02)),
		Vector3(width * 0.5, 0.05, 0.06), 2.0, Color(0.8, 0.81, 0.85)
	)
	# Side skirts give the body a visible bottom edge.
	for side in [-1.0, 1.0]:
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(side * width * 0.49, body_y - hull_height * 0.42, 0.0)),
			Vector3(0.08, height * 0.16, length * 0.82), 1.2, Color(0.11, 0.11, 0.12)
		)
	# Lights.
	_append_lights(builder, model, origin, width, height, length, body_y, hull_height)
	# Mirrors.
	for side in [-1.0, 1.0]:
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(side * (cabin_width * 0.5 + 0.11), body_y + hull_height * 0.6, cabin_z + cabin_length * 0.34)),
			Vector3(0.22, 0.09, 0.12), 2.0, colour.darkened(0.25)
		)
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(side * (cabin_width * 0.5 + 0.03), body_y + hull_height * 0.56, cabin_z + cabin_length * 0.34)),
			Vector3(0.14, 0.05, 0.1), 2.0, colour.darkened(0.35)
		)
	if detail == DETAIL_HIGH:
		_append_exhaust(builder, origin, width, length, body_y, hull_height, model)
		_append_wheel_arches(builder, origin, data, body_y, hull_height, colour)


static func _append_utility_body(
	builder: GeometryBuilder,
	model: int,
	origin: Transform3D,
	colour: Color,
	data: Dictionary,
	detail: int
) -> void:
	var length := float(data["length"])
	var width := float(data["width"])
	var height := float(data["height"])
	var ride := float(data["ride"])
	var paint := MaterialLibrary.CAR_BODY
	if model == MODEL_BUS:
		# Bus: one long box with a windscreen, side windows and door glass.
		builder.add_box(
			paint, origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.5, 0.0)),
			Vector3(width, height, length), 0.7, colour
		)
		builder.add_box(
			MaterialLibrary.GLASS,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.72, length * 0.5 + 0.02)),
			Vector3(width * 0.92, height * 0.34, 0.1), 1.4, Color(1, 1, 1, 0.8)
		)
		var window_count := 6
		for i in window_count:
			var z := length * 0.5 - 1.2 - float(i) * 1.55
			for side in [-1.0, 1.0]:
				builder.add_box(
					MaterialLibrary.GLASS,
					origin * Transform3D(Basis(), Vector3(side * (width * 0.5 + 0.02), ride + height * 0.66, z)),
					Vector3(0.08, height * 0.3, 1.15), 1.4, Color(1, 1, 1, 0.8)
				)
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.06, 0.0)),
			Vector3(width * 1.02, height * 0.12, length * 0.98), 1.0, Color(0.14, 0.14, 0.16)
		)
		builder.add_box(
			MaterialLibrary.ROOF,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height + 0.03, 0.0)),
			Vector3(width * 0.96, 0.06, length * 0.96), 0.8, Color(0.72, 0.72, 0.7)
		)
	elif model == MODEL_TRUCK:
		# Truck: a tractor unit with a cab and a box trailer.
		builder.add_box(
			paint, origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.62, length * 0.22)),
			Vector3(width, height, length * 0.3), 0.7, colour
		)
		builder.add_box(
			MaterialLibrary.GLASS,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.86, length * 0.37)),
			Vector3(width * 0.9, height * 0.34, 0.1), 1.4, Color(1, 1, 1, 0.8)
		)
		builder.add_box(
			MaterialLibrary.METAL,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.72, -length * 0.26)),
			Vector3(width * 1.02, height * 0.82, length * 0.46), 0.5, Color(0.82, 0.84, 0.86)
		)
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.1, -length * 0.26)),
			Vector3(width * 1.04, height * 0.16, length * 0.46), 0.8, Color(0.15, 0.15, 0.17)
		)
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.3, length * 0.22)),
			Vector3(width * 1.02, height * 0.2, length * 0.3), 0.9, Color(0.16, 0.16, 0.18)
		)
	if detail >= DETAIL_MEDIUM:
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(0.0, ride + height * 0.1, length * 0.5 - 0.08)),
			Vector3(width * 1.0, 0.24, 0.16), 1.2, Color(0.13, 0.13, 0.15)
		)
	_append_lights(builder, model, origin, width, height, length, ride, height * 0.6)


static func _append_lights(
	builder: GeometryBuilder,
	model: int,
	origin: Transform3D,
	width: float,
	height: float,
	length: float,
	body_y: float,
	hull_height: float
) -> void:
	var light_y := body_y + hull_height * 0.32
	var light_z := length * 0.5 - 0.04
	var head_size := Vector3(width * 0.2, height * 0.16, 0.1)
	for side in [-1.0, 1.0]:
		builder.add_box(
			MaterialLibrary.LIGHT_HEAD,
			origin * Transform3D(Basis(), Vector3(side * width * 0.32, light_y, light_z)),
			head_size, 2.0, Color(0.95, 0.96, 1.0)
		)
		builder.add_box(
			MaterialLibrary.LIGHT_TAIL,
			origin * Transform3D(Basis(), Vector3(side * width * 0.32, light_y, -light_z)),
			Vector3(width * 0.22, height * 0.16, 0.08), 2.0, Color(0.85, 0.12, 0.1)
		)
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(side * width * 0.3, body_y - hull_height * 0.34, light_z - 0.02)),
			Vector3(width * 0.16, height * 0.1, 0.06), 2.0, Color(0.2, 0.2, 0.22)
		)
	if model == MODEL_POLICE:
		_append_police_equipment(builder, origin, width, height, length, body_y, hull_height)


static func _append_police_equipment(
	builder: GeometryBuilder,
	origin: Transform3D,
	width: float,
	height: float,
	length: float,
	_index: float,
	_hull: float
) -> void:
	var roof_y := height * 1.02
	# Light bar: two coloured lenses on a black base.
	builder.add_box(
		MaterialLibrary.PLASTIC,
		origin * Transform3D(Basis(), Vector3(0.0, roof_y, -0.1)),
		Vector3(width * 0.72, 0.09, 0.3), 1.4, Color(0.08, 0.08, 0.09)
	)
	builder.add_box(
		MaterialLibrary.LIGHT_EMERGENCY,
		origin * Transform3D(Basis(), Vector3(-width * 0.2, roof_y + 0.08, -0.1)),
		Vector3(width * 0.3, 0.1, 0.26), 2.0, Color(0.25, 0.4, 1.0)
	)
	builder.add_box(
		MaterialLibrary.LIGHT_EMERGENCY,
		origin * Transform3D(Basis(), Vector3(width * 0.2, roof_y + 0.08, -0.1)),
		Vector3(width * 0.3, 0.1, 0.26), 2.0, Color(1.0, 0.2, 0.2)
	)
	# Push bar at the front.
	builder.add_box(
		MaterialLibrary.CHROME,
		origin * Transform3D(Basis(), Vector3(0.0, 0.35, length * 0.5 + 0.08)),
		Vector3(width * 0.92, 0.1, 0.08), 1.6, Color(0.7, 0.71, 0.75)
	)
	for side in [-1.0, 1.0]:
		builder.add_box(
			MaterialLibrary.CHROME,
			origin * Transform3D(Basis(), Vector3(side * width * 0.36, 0.2, length * 0.5 + 0.08)),
			Vector3(0.08, 0.4, 0.08), 1.6, Color(0.7, 0.71, 0.75)
		)
	# Livery stripe along the sides.
	for side in [-1.0, 1.0]:
		builder.add_box(
			MaterialLibrary.PLASTIC,
			origin * Transform3D(Basis(), Vector3(side * width * 0.5, 0.28, 0.0)),
			Vector3(0.04, 0.22, length * 0.7), 1.6, Color(0.06, 0.08, 0.2)
		)


static func _append_exhaust(
	builder: GeometryBuilder,
	origin: Transform3D,
	width: float,
	length: float,
	body_y: float,
	hull_height: float,
	model: int
) -> void:
	var pipes := 2 if model == MODEL_SPORTS or model == MODEL_POLICE else 1
	for i in pipes:
		var x := (float(i) - float(pipes - 1) * 0.5) * width * 0.32
		builder.add_cylinder(
			MaterialLibrary.CHROME,
			origin * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(x, body_y - hull_height * 0.36, -length * 0.5 + 0.02)),
			0.055, 0.16, 8, 2.0, Color(0.62, 0.63, 0.66)
		)


static func _append_wheel_arches(
	builder: GeometryBuilder,
	origin: Transform3D,
	data: Dictionary,
	body_y: float,
	hull_height: float,
	colour: Color
) -> void:
	var radius := float(data["wheel_radius"])
	var width := float(data["width"])
	var track := float(data["track"])
	for axle: float in [float(data["axle_front"]), float(data["axle_rear"])]:
		for side in [-1.0, 1.0]:
			# A dark plastic lip around the wheel opening reads as an arch without cutting
			# a hole in the body (which a procedural box model cannot do cheaply).
			builder.add_box(
				MaterialLibrary.PLASTIC,
				origin * Transform3D(Basis(), Vector3(side * track, body_y - hull_height * 0.34, axle)),
				Vector3(width * 0.12, radius * 0.6, radius * 2.4), 1.6, colour.darkened(0.55)
			)


## Merges the accumulated primitives into a dictionary of "material key -> ArrayMesh".
## A throw-away Node3D is used as the commit target and is released immediately; the meshes
## themselves stay alive because the returned dictionary references them.
static func commit_grouped(builder: GeometryBuilder, materials: MaterialLibrary) -> Dictionary:
	var holder := Node3D.new()
	var nodes := builder.commit(holder, "part")
	var result := {}
	for node: MeshInstance3D in nodes:
		var key := StringName(node.name.trim_prefix("part_"))
		result[key] = node.mesh
		node.mesh = null
	holder.free()
	return result
