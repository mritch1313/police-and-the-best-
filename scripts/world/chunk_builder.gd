extends RefCounted
class_name ChunkBuilder
## Builds the geometry of one world chunk: ground, streets, pavements, buildings,
## street furniture, props and parked cars.
##
## Everything a chunk contains is merged per material, so a 125 m city chunk becomes
## between five and ten draw calls no matter how much detail it holds. The builder also
## collects the collision boxes (one per building, kerb run and solid prop) so the physics
## body can be a cheap StaticBody3D with box shapes instead of a mesh collider.
##
## The three LOD levels are the reason the city can be dense *and* cheap:
##   LOD 0 (near)   - everything: façade details, shop fronts, small props, parked cars
##   LOD 1 (medium) - buildings, pavements, lamps and trees, no small clutter
##   LOD 2 (far)    - building silhouettes only, no shadows, no props at all

const LOD_NEAR := 0
const LOD_MEDIUM := 1
const LOD_FAR := 2

## How many texture repeats per metre a façade uses (roughly one tile every four floors).
const FACADE_UV_PER_METER := Vector2(0.075, 0.055)
const ROOF_UV_PER_METER := 0.12
const ROAD_UV_PER_METER := 0.09
const PAVEMENT_UV_PER_METER := 0.16

var config: WorldConfig
var layout: DistrictLayout
var materials: MaterialLibrary
var props: PropBuilder


func _init(
	p_layout: DistrictLayout,
	p_materials: MaterialLibrary,
	p_config: WorldConfig = null
) -> void:
	layout = p_layout
	config = p_config if p_config != null else (p_layout.config if p_layout != null else WorldConfig.new())
	materials = p_materials if p_materials != null else MaterialLibrary.new()
	props = PropBuilder.new(materials)


## Builds a chunk into `chunk_root` and returns its statistics.
##
## `lod` selects the detail level, `chunk_coords` the chunk, and `prop_density` allows the
## performance manager to thin out the clutter on a weak device without changing the layout.
func build(chunk_root: Node3D, chunk_coords: Vector2i, lod: int, prop_density: float = 1.0) -> Dictionary:
	var builder := GeometryBuilder.new(materials)
	var collision_boxes: Array[Dictionary] = []
	var half_chunk := config.chunk_size * 0.5
	var origin_x := float(chunk_coords.x) * config.chunk_size
	var origin_z := float(chunk_coords.y) * config.chunk_size
	# Chunk coordinates are centred on the world origin, so the chunk covers
	# [origin - half, origin + half].
	var area := Rect2(
		Vector2(origin_x - half_chunk, origin_z - half_chunk),
		Vector2(config.chunk_size, config.chunk_size)
	)

	_build_ground(chunk_root, area, lod, prop_density)
	_build_streets(builder, area, lod, collision_boxes)
	if lod <= LOD_MEDIUM:
		_build_blocks(builder, area, lod, prop_density, collision_boxes)

	var created := builder.commit(chunk_root, "chunk")
	var shadow_mode := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if lod == LOD_NEAR
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	for instance: MeshInstance3D in created:
		instance.cast_shadow = shadow_mode
	var stats := {
		"triangles": builder.triangle_count,
		"primitives": builder.primitive_count,
		"meshes": created.size(),
		"collision_boxes": collision_boxes.size(),
		"lod": lod,
		"content_meshes": created,
	}
	chunk_root.set_meta("stats", stats)
	chunk_root.set_meta("collision_boxes", collision_boxes)
	return stats


# --------------------------------------------------------------------------------------
# ground
# --------------------------------------------------------------------------------------
## The concrete slab the whole district stands on. It is built once per chunk as a small
## grid of quads (not one giant plane) so that the lighting and the vertex colour variation
## stay smooth and so a chunk never stretches a single texture over 125 metres.
func _build_ground(chunk_root: Node3D, area: Rect2, lod: int, prop_density: float) -> void:
	var builder := GeometryBuilder.new(materials)
	var step := maxf(config.chunk_size / 6.0, 8.0)
	var x := area.position.x
	var gen := RandomNumberGenerator.new()
	gen.seed = layout.block_hash(int(area.position.x), int(area.position.y))
	while x < area.position.x + area.size.x - 0.01:
		var z := area.position.y
		while z < area.position.y + area.size.y - 0.01:
			var size := Vector2(minf(step, area.position.x + area.size.x - x), minf(step, area.position.y + area.size.y - z))
			var centre := Vector3(x + size.x * 0.5, config.ground_height, z + size.y * 0.5)
			var tint := 0.94 + gen.randf() * 0.1
			var colour := Color(tint, tint, tint * (0.99 + gen.randf() * 0.02))
			var key := MaterialLibrary.DIRT
			# A subtle mix of concrete and worn asphalt patches keeps the slab from looking
			# like one flat plate, exactly like the reference art for this project.
			var value := layout.block_value(int(floor(x / config.block_pitch)), int(floor(z / config.block_pitch)))
			if value > 0.72:
				key = MaterialLibrary.DIRT
				colour = Color(0.5, 0.44, 0.36) * tint
			elif value > 0.5:
				key = MaterialLibrary.ASPHALT_WORN
				colour = Color(0.86, 0.86, 0.88) * tint
			else:
				key = MaterialLibrary.CONCRETE
			builder.add_plane(
				key,
				Transform3D(Basis(), centre),
				size, PAVEMENT_UV_PER_METER, colour
			)
			z += step
		x += step
	var node := Node3D.new()
	node.name = "Ground"
	chunk_root.add_child(node)
	var meshes := builder.commit(node, "ground", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	for mesh: MeshInstance3D in meshes:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ground of a chunk is also the collision floor of that chunk.
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta("surface_grip", 1.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(area.size.x, 0.6, area.size.y)
	shape.shape = box
	shape.position = Vector3(area.position.x + area.size.x * 0.5, config.ground_height - 0.3, area.position.y + area.size.y * 0.5)
	body.add_child(shape)
	node.add_child(body)
	if prop_density < 0.0:
		pass


# --------------------------------------------------------------------------------------
# streets
# --------------------------------------------------------------------------------------
func _build_streets(builder: GeometryBuilder, area: Rect2, lod: int, collision_boxes: Array[Dictionary]) -> void:
	var pitch := config.block_pitch
	var road_half := config.road_width * 0.5
	var pavement := config.sidewalk_width
	var kerb_height := config.kerb_height
	var first_bx := int(floor(area.position.x / pitch)) - 1
	var last_bx := int(ceil((area.position.x + area.size.x) / pitch)) + 1
	var first_bz := int(floor(area.position.y / pitch)) - 1
	var last_bz := int(ceil((area.position.y + area.size.y) / pitch)) + 1
	for bx in range(first_bx, last_bx + 1):
		for bz in range(first_bz, last_bz + 1):
			var centre := layout.block_center(bx, bz)
			if not _rect_overlaps(area, centre, pitch * 0.5 + config.road_width):
				continue
			# Roads run along the north and west edge of every block, so each block owns a
			# corner and the grid closes without overlapping geometry.
			var road_x := centre.x - pitch * 0.5
			var road_z := centre.z - pitch * 0.5
			builder.add_plane(
				MaterialLibrary.ASPHALT,
				Transform3D(Basis(), Vector3(road_x, config.ground_height + 0.02, centre.z)),
				Vector2(config.road_width, pitch), ROAD_UV_PER_METER, Color(0.98, 0.98, 1.0)
			)
			builder.add_plane(
				MaterialLibrary.ASPHALT,
				Transform3D(Basis(), Vector3(centre.x, config.ground_height + 0.02, road_z)),
				Vector2(pitch, config.road_width), ROAD_UV_PER_METER, Color(0.98, 0.98, 1.0)
			)
			# Intersection patch keeps the crossing seamless.
			builder.add_plane(
				MaterialLibrary.ASPHALT,
				Transform3D(Basis(), Vector3(road_x, config.ground_height + 0.021, road_z)),
				Vector2(config.road_width, config.road_width), ROAD_UV_PER_METER, Color(0.95, 0.95, 0.97)
			)
			if lod == LOD_NEAR:
				_build_markings(builder, centre, pitch)
			# Pavements: a ring around the block, raised by the kerb height. Only blocks
			# that belong to this chunk contribute collision, otherwise two neighbouring
			# chunks would both collide with the same kerb.
			var owns_block := _point_in_rect(area, centre)
			var target: Array[Dictionary] = collision_boxes if owns_block else []
			_build_pavement_ring(builder, centre, pitch, road_half, pavement, kerb_height, target)
			# Kerb stones along the pavement edge.
			var inner := pitch * 0.5 - road_half
			for side in 4:
				var kerb_centre := Vector3.ZERO
				var kerb_size := Vector3.ZERO
				match side:
					0:
						kerb_centre = Vector3(centre.x, config.ground_height + kerb_height * 0.5, centre.z - inner + 0.06)
						kerb_size = Vector3(pitch - config.road_width, kerb_height, 0.12)
					1:
						kerb_centre = Vector3(centre.x, config.ground_height + kerb_height * 0.5, centre.z + inner - 0.06)
						kerb_size = Vector3(pitch - config.road_width, kerb_height, 0.12)
					2:
						kerb_centre = Vector3(centre.x - inner + 0.06, config.ground_height + kerb_height * 0.5, centre.z)
						kerb_size = Vector3(0.12, kerb_height, pitch - config.road_width)
					_:
						kerb_centre = Vector3(centre.x + inner - 0.06, config.ground_height + kerb_height * 0.5, centre.z)
						kerb_size = Vector3(0.12, kerb_height, pitch - config.road_width)
				builder.add_box(
					MaterialLibrary.KERB, Transform3D(Basis(), kerb_centre), kerb_size, 2.0, Color(0.86, 0.85, 0.82)
				)


func _build_pavement_ring(
	builder: GeometryBuilder,
	centre: Vector3,
	pitch: float,
	road_half: float,
	pavement_width: float,
	kerb_height: float,
	collision_boxes: Array[Dictionary]
) -> void:
	var outer := pitch * 0.5 - road_half
	var inner := outer - pavement_width
	var y := config.ground_height + kerb_height
	var width := pitch - config.road_width
	var colour := Color(0.9, 0.9, 0.88)
	builder.add_plane(
		MaterialLibrary.SIDEWALK,
		Transform3D(Basis(), Vector3(centre.x, y, centre.z - (outer + inner) * 0.5)),
		Vector2(width, pavement_width), PAVEMENT_UV_PER_METER, colour
	)
	builder.add_plane(
		MaterialLibrary.SIDEWALK,
		Transform3D(Basis(), Vector3(centre.x, y, centre.z + (outer + inner) * 0.5)),
		Vector2(width, pavement_width), PAVEMENT_UV_PER_METER, colour.darkened(0.02)
	)
	builder.add_plane(
		MaterialLibrary.SIDEWALK,
		Transform3D(Basis(), Vector3(centre.x - (outer + inner) * 0.5, y, centre.z)),
		Vector2(pavement_width, inner * 2.0), PAVEMENT_UV_PER_METER, colour
	)
	builder.add_plane(
		MaterialLibrary.SIDEWALK,
		Transform3D(Basis(), Vector3(centre.x + (outer + inner) * 0.5, y, centre.z)),
		Vector2(pavement_width, inner * 2.0), PAVEMENT_UV_PER_METER, colour
	)
	# The pavement is solid enough to be hit: a low box per side keeps cars on the road
	# without making the kerb a wall.
	var side_length := pitch - config.road_width
	for side in 4:
		var position := Vector3.ZERO
		var size := Vector3.ZERO
		match side:
			0:
				position = Vector3(centre.x, y - 0.06, centre.z - (outer + inner) * 0.5)
				size = Vector3(side_length, 0.12, pavement_width)
			1:
				position = Vector3(centre.x, y - 0.06, centre.z + (outer + inner) * 0.5)
				size = Vector3(side_length, 0.12, pavement_width)
			2:
				position = Vector3(centre.x - (outer + inner) * 0.5, y - 0.06, centre.z)
				size = Vector3(pavement_width, 0.12, inner * 2.0)
			_:
				position = Vector3(centre.x + (outer + inner) * 0.5, y - 0.06, centre.z)
				size = Vector3(pavement_width, 0.12, inner * 2.0)
		collision_boxes.append({"position": position, "size": size})


## Lane markings, dashes and crosswalks. These are painted as thin quads slightly above the
## asphalt, which is far cheaper than a second material with an alpha texture.
func _build_markings(builder: GeometryBuilder, centre: Vector3, pitch: float) -> void:
	var paint := MaterialLibrary.ROAD_PAINT
	var white := Color(0.9, 0.9, 0.86, 1.0)
	var yellow := Color(0.86, 0.76, 0.32, 1.0)
	var y := config.ground_height + 0.03
	var road_x := centre.x - pitch * 0.5
	var road_z := centre.z - pitch * 0.5
	# Centre line of the north/south avenue.
	var dash_length := 2.6
	var gap := 3.4
	var z := centre.z - pitch * 0.5 + gap
	while z < centre.z + pitch * 0.5 - gap:
		if not (z > road_z - config.road_width * 0.9 and z < road_z + config.road_width * 0.9):
			builder.add_plane(
				paint, Transform3D(Basis(), Vector3(road_x, y, z)), Vector2(0.16, dash_length), 1.0, white
			)
		z += dash_length + gap
	var x := centre.x - pitch * 0.5 + gap
	while x < centre.x + pitch * 0.5 - gap:
		if not (x > road_x - config.road_width * 0.9 and x < road_x + config.road_width * 0.9):
			builder.add_plane(paint, Transform3D(Basis(), Vector3(x, y, road_z)), Vector2(dash_length, 0.16), 1.0, white)
		x += dash_length + gap
	# Crosswalk stripes on the two approaches of the intersection.
	var stripe := 0.5
	var stripe_gap := 0.42
	var crossing_width := config.road_width * 0.85
	var offset := 2.2
	for i in int(crossing_width / (stripe + stripe_gap)):
		var t := -crossing_width * 0.5 + float(i) * (stripe + stripe_gap)
		builder.add_plane(
			paint,
			Transform3D(Basis(), Vector3(road_x + t, y, road_z + offset + stripe * 0.5)),
			Vector2(stripe, 2.4), 1.0, white
		)
		builder.add_plane(
			paint,
			Transform3D(Basis(), Vector3(road_x + offset + stripe * 0.5, y, road_z + t)),
			Vector2(2.4, stripe), 1.0, white
		)
	# Stop line + a painted bus bay for colour.
	builder.add_plane(paint, Transform3D(Basis(), Vector3(road_x, y, road_z - offset - 1.0)), Vector2(config.road_width * 0.8, 0.35), 1.0, yellow)


# --------------------------------------------------------------------------------------
# blocks: buildings and props
# --------------------------------------------------------------------------------------
func _build_blocks(
	builder: GeometryBuilder,
	area: Rect2,
	lod: int,
	prop_density: float,
	collision_boxes: Array[Dictionary]
) -> void:
	var pitch := config.block_pitch
	var first_bx := int(floor(area.position.x / pitch)) - 1
	var last_bx := int(ceil((area.position.x + area.size.x) / pitch)) + 1
	var first_bz := int(floor(area.position.y / pitch)) - 1
	var last_bz := int(ceil((area.position.y + area.size.y) / pitch)) + 1
	for bx in range(first_bx, last_bx + 1):
		for bz in range(first_bz, last_bz + 1):
			var centre := layout.block_center(bx, bz)
			if not _rect_overlaps(area, centre, pitch * 0.5):
				continue
			var owns_block := _point_in_rect(area, centre)
			var target: Array[Dictionary] = collision_boxes if owns_block else []
			for building: Dictionary in layout.buildings(bx, bz):
				_build_building(builder, building, lod, target)
			if lod > LOD_NEAR:
				continue
			# Street furniture, props and parked cars (near chunks only).
			for prop: Dictionary in layout.street_props(bx, bz):
				if prop_density < 1.0 and _thin_out(prop, prop_density):
					continue
				props.add_prop(builder, prop, target, CarMeshFactory.DETAIL_LOW)
			for prop: Dictionary in layout.block_props(bx, bz):
				if prop_density < 1.0 and _thin_out(prop, prop_density):
					continue
				props.add_prop(builder, prop, target, CarMeshFactory.DETAIL_LOW)
			if prop_density > 0.2:
				for car: Dictionary in layout.parked_cars(bx, bz):
					props.add_prop(builder, car, target, CarMeshFactory.DETAIL_LOW)


## Deterministic thinning of the prop list, so the same device always sees the same city.
func _thin_out(prop: Dictionary, density: float) -> bool:
	var position: Vector3 = prop.get("position", Vector3.ZERO)
	var value := layout.block_value(int(position.x), int(position.z))
	return value > density


## Builds one building: façade walls, a parapet, a roof slab and (near) a shop front,
## roof clutter and an entrance.
func _build_building(
	builder: GeometryBuilder,
	building: Dictionary,
	lod: int,
	collision_boxes: Array[Dictionary]
) -> void:
	var position: Vector3 = building["position"]
	var size: Vector3 = building["size"]
	var style: StringName = building["style"]
	var floors := int(building["floors"])
	var base_y := config.ground_height + config.kerb_height
	var height := size.y
	var tint := 0.86 + float(layout.block_value(int(position.x), int(position.z))) * 0.28
	var facade_colour := Color(tint, tint * 0.995, tint * 0.99)
	var half := Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	var uv := FACADE_UV_PER_METER
	# Four façade walls. Each wall is one quad with correct per-axis UVs.
	var wall_variants: Array[Dictionary] = [
		{"basis": Basis(), "offset": Vector3(0.0, 0.0, half.z), "size": Vector2(size.x, height)},
		{"basis": Basis(Vector3.UP, PI), "offset": Vector3(0.0, 0.0, -half.z), "size": Vector2(size.x, height)},
		{"basis": Basis(Vector3.UP, PI * 0.5), "offset": Vector3(half.x, 0.0, 0.0), "size": Vector2(size.z, height)},
		{"basis": Basis(Vector3.UP, -PI * 0.5), "offset": Vector3(-half.x, 0.0, 0.0), "size": Vector2(size.z, height)},
	]
	for wall: Dictionary in wall_variants:
		var wall_basis: Basis = wall["basis"]
		var offset: Vector3 = wall["offset"]
		var wall_size: Vector2 = wall["size"]
		var origin := Transform3D(
			wall_basis * Basis(Vector3.RIGHT, 0.0),
			position + Vector3(offset.x, base_y + height * 0.5, offset.z)
		)
		builder.add_wall(style, origin, wall_size, uv, facade_colour)
		if lod <= LOD_MEDIUM:
			# Windows sills: a thin band that reads as a floor division from a distance.
			var bands := int(float(floors))
			for floor_index in range(1, bands):
				var y := base_y + float(floor_index) * (height / float(maxi(floors, 1)))
				if y > base_y + height - 0.6:
					break
				builder.add_box(
					style,
					Transform3D(
						wall_basis,
						position + Vector3(offset.x * 1.01, y, offset.z * 1.01)
					),
					Vector3(wall_size.x, 0.22, 0.16), 1.2, facade_colour.darkened(0.12)
				)
	# Ground floor treatment: a taller shop band with an awning and a sign.
	if bool(building.get("shop", false)) and lod <= LOD_MEDIUM:
		var shop_height := 3.4
		var shop_origin := Transform3D(Basis(), position + Vector3(0.0, base_y + shop_height * 0.5, half.z + 0.06))
		builder.add_wall(MaterialLibrary.FACADE_SHOP, shop_origin, Vector2(size.x, shop_height), Vector2(0.1, 0.1), Color(0.95, 0.93, 0.9))
		builder.add_box(
			MaterialLibrary.PLASTIC,
			Transform3D(Basis(), position + Vector3(0.0, base_y + shop_height + 0.1, half.z + 0.5)),
			Vector3(size.x * 0.9, 0.12, 1.0), 1.2, Color(0.42, 0.16, 0.14)
		)
		var sign_key := MaterialLibrary.SIGN_CAFE if floors % 2 == 0 else MaterialLibrary.SIGN_SHOP
		builder.add_box(
			sign_key,
			Transform3D(Basis(), position + Vector3(0.0, base_y + shop_height + 0.55, half.z + 0.52)),
			Vector3(size.x * 0.55, 0.7, 0.08), 1.0, Color(0.95, 0.95, 0.95)
		)
		builder.add_stairs(
			MaterialLibrary.CONCRETE,
			Transform3D(Basis(), position + Vector3(0.0, base_y, half.z + 0.55)),
			size.x * 0.28, config.kerb_height * 1.4, 1.1, 3, 1.0, Color(0.78, 0.77, 0.74)
		)
	# Roof slab, parapet and clutter.
	builder.add_plane(
		MaterialLibrary.ROOF,
		Transform3D(Basis(), position + Vector3(0.0, base_y + height + 0.02, 0.0)),
		Vector2(size.x, size.z), ROOF_UV_PER_METER, Color(0.7, 0.7, 0.68)
	)
	var parapet := 0.9
	var parapet_colour := facade_colour.darkened(0.08)
	for side in 4:
		var offset := Vector3.ZERO
		var wall_size := Vector2.ZERO
		var basis := Basis()
		match side:
			0:
				offset = Vector3(0.0, 0.0, half.z - 0.1)
				wall_size = Vector2(size.x, parapet)
			1:
				offset = Vector3(0.0, 0.0, -half.z + 0.1)
				wall_size = Vector2(size.x, parapet)
				basis = Basis(Vector3.UP, PI)
			2:
				offset = Vector3(half.x - 0.1, 0.0, 0.0)
				wall_size = Vector2(size.z, parapet)
				basis = Basis(Vector3.UP, PI * 0.5)
			_:
				offset = Vector3(-half.x + 0.1, 0.0, 0.0)
				wall_size = Vector2(size.z, parapet)
				basis = Basis(Vector3.UP, -PI * 0.5)
		builder.add_wall(
			style,
			Transform3D(basis, position + Vector3(offset.x, base_y + height + parapet * 0.5, offset.z)),
			wall_size, uv, parapet_colour
		)
	if lod <= LOD_MEDIUM:
		_build_roof_clutter(builder, position, size, base_y + height, floors)
	# Collision: one box for the whole building. A car cannot tell the difference and the
	# physics is dramatically cheaper than a mesh collider.
	collision_boxes.append(
		{
			"position": position + Vector3(0.0, base_y + height * 0.5, 0.0),
			"size": Vector3(size.x, height, size.z),
			"basis": Basis(),
		}
	)


func _build_roof_clutter(builder: GeometryBuilder, position: Vector3, size: Vector3, roof_y: float, floors: int) -> void:
	var gen := layout.block_rng(int(position.x), int(position.z) + floors)
	var count := 2 + (floors % 3)
	for i in count:
		var offset := Vector3(
			gen.randf_range(-size.x * 0.3, size.x * 0.3),
			0.0,
			gen.randf_range(-size.z * 0.3, size.z * 0.3)
		)
		var unit_size := Vector3(gen.randf_range(1.0, 2.2), gen.randf_range(0.7, 1.4), gen.randf_range(1.0, 2.0))
		builder.add_box(
			MaterialLibrary.METAL,
			Transform3D(Basis(Vector3.UP, gen.randf_range(0.0, TAU)), position + offset + Vector3(0.0, roof_y + unit_size.y * 0.5 + 0.9, 0.0)),
			unit_size, 0.8, Color(0.72, 0.73, 0.75)
		)
	if floors > 6 and gen.randf() < 0.6:
		# Rooftop water tank or lift machine room.
		var room := Vector3(size.x * 0.28, 2.6, size.z * 0.28)
		builder.add_frustum(
			MaterialLibrary.CONCRETE,
			Transform3D(Basis(), position + Vector3(size.x * 0.18, roof_y + 0.9 + room.y * 0.5, -size.z * 0.18)),
			Vector2(room.x, room.z), Vector2(room.x * 0.92, room.z * 0.92), room.y, 1.2, Color(0.74, 0.72, 0.68)
		)
	# Antenna masts make the skyline read as a city.
	if floors > 9:
		builder.add_cylinder(
			MaterialLibrary.METAL,
			Transform3D(Basis(), position + Vector3(0.0, roof_y + 0.9 + 4.0, 0.0)),
			0.08, 8.0, 6, 1.0, Color(0.6, 0.61, 0.63)
		)


# --------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------
## True when a point (a block centre) is inside the chunk area.
func _point_in_rect(area: Rect2, point: Vector3) -> bool:
	return (
		point.x >= area.position.x
		and point.x <= area.position.x + area.size.x
		and point.z >= area.position.y
		and point.z <= area.position.y + area.size.y
	)


## True when a chunk area touches the block that is centred on `centre`.
func _rect_overlaps(area: Rect2, centre: Vector3, radius: float) -> bool:
	return not (
		centre.x + radius < area.position.x
		or centre.x - radius > area.position.x + area.size.x
		or centre.z + radius < area.position.y
		or centre.z - radius > area.position.y + area.size.y
	)


## Builds the distant skyline impostors: a ring of simple, unlit (but textured) blocks that
## keep the horizon believable for a fraction of the cost of real buildings.
func build_skyline(parent: Node3D, ring: int = 1) -> int:
	var builder := GeometryBuilder.new(materials)
	var gen := RandomNumberGenerator.new()
	gen.seed = layout.seed_value + ring * 7919
	var radius := config.skyline_distance + float(ring - 1) * 420.0
	var count := 46 + ring * 14
	for i in count:
		var angle := TAU * float(i) / float(count) + gen.randf_range(-0.02, 0.02)
		var distance := radius * gen.randf_range(0.92, 1.12)
		var position := Vector3(cos(angle) * distance, config.ground_height, sin(angle) * distance)
		var size := Vector3(
			gen.randf_range(24.0, 52.0),
			gen.randf_range(28.0, 120.0),
			gen.randf_range(24.0, 52.0)
		)
		var style := layout._pick_style(gen, true) if gen.randf() < 0.5 else MaterialLibrary.FACADE_PANEL
		var tint := 0.78 + gen.randf() * 0.2
		# Slight blue haze keeps the skyline in the background, which also hides the LOD
		# transition from the streamed city.
		var colour := Color(tint * 0.94, tint * 0.97, tint)
		builder.add_frustum(
			style,
			Transform3D(Basis(Vector3.UP, gen.randf_range(0.0, TAU)), position + Vector3(0.0, size.y * 0.5, 0.0)),
			Vector2(size.x, size.z), Vector2(size.x * 0.9, size.z * 0.9), size.y, FACADE_UV_PER_METER, colour
		)
		if gen.randf() < 0.35:
			builder.add_box(
				MaterialLibrary.FACADE_GLASS,
				Transform3D(Basis(), position + Vector3(0.0, size.y + 4.0, 0.0)),
				Vector3(size.x * 0.4, 8.0, size.z * 0.4), FACADE_UV_PER_METER, colour.lightened(0.1)
			)
	var node := Node3D.new()
	node.name = "Skyline"
	parent.add_child(node)
	var meshes := builder.commit(node, "skyline", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	for mesh: MeshInstance3D in meshes:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return meshes.size()
