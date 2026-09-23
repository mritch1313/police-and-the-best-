extends RefCounted
class_name DistrictLayout
## The recipe of the city: what stands where, decided deterministically from a seed.
##
## The layout is the single source of truth for the world. The mesh builder, the collision
## builder, the road graph, the traffic spawner, the police spawner and the map thumbnail
## all read the same specification, so the city that is drawn, the city that is collided
## with and the city the AI drives through are guaranteed to be the same city.
##
## Everything is derived from (seed, block index), which means:
##   * the same seed always produces the same district (useful for tests and bug reports),
##   * a block can be rebuilt in isolation (chunk streaming),
##   * nothing needs to be stored in the save file.

const KIND_BUILDINGS := "buildings"
const KIND_PARK := "park"
const KIND_YARD := "yard"

## Kinds of props the chunk builder understands.
const PROP_LAMP := &"lamp"
const PROP_TREE := &"tree"
const PROP_BUSH := &"bush"
const PROP_BENCH := &"bench"
const PROP_BIN := &"bin"
const PROP_HYDRANT := &"hydrant"
const PROP_BOLLARD := &"bollard"
const PROP_BARRIER := &"barrier"
const PROP_TRAFFIC_LIGHT := &"traffic_light"
const PROP_SIGN := &"sign"
const PROP_BUS_STOP := &"bus_stop"
const PROP_FENCE := &"fence"
const PROP_DUMPSTER := &"dumpster"
const PROP_PLANTER := &"planter"
const PROP_CONTAINER := &"container"
const PROP_CRATE := &"crate"
const PROP_CONE := &"cone"
const PROP_BARREL := &"barrel"
const PROP_FOUNTAIN := &"fountain"
const PROP_STATUE := &"statue"
const PROP_PARKED_CAR := &"parked_car"
const PROP_TENT := &"market_tent"

var seed_value: int = 1
var config: WorldConfig


func _init(p_seed: int = 1, p_config: WorldConfig = null) -> void:
	seed_value = p_seed
	config = p_config if p_config != null else WorldConfig.new()


# --------------------------------------------------------------------------------------
# deterministic hashing (must stay identical to tools/assets/generate_textures.py)
# --------------------------------------------------------------------------------------
## Stable 32 bit hash of two block coordinates and the seed.
func block_hash(bx: int, bz: int) -> int:
	var h := (bx * 73856093) ^ (bz * 19349663) ^ (seed_value & 0xFFFF)
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return h


## A value in 0..1 derived from the block coordinates.
func block_value(bx: int, bz: int) -> float:
	return float(block_hash(bx, bz) % 1000) / 1000.0


## A deterministic random generator for a block (same seed -> same buildings).
func block_rng(bx: int, bz: int) -> RandomNumberGenerator:
	var generator := RandomNumberGenerator.new()
	generator.seed = block_hash(bx, bz)
	return generator


# --------------------------------------------------------------------------------------
# geometry queries
# --------------------------------------------------------------------------------------
func block_count() -> int:
	return config.block_count()


## Grid coordinates of the block that contains a world position.
func block_coords(world_position: Vector3) -> Vector2i:
	var pitch := config.block_pitch
	var half := float(block_count()) * 0.5
	return Vector2i(
		int(floor(world_position.x / pitch + half)),
		int(floor(world_position.z / pitch + half))
	)


## Centre of a block in world space.
func block_center(bx: int, bz: int) -> Vector3:
	var pitch := config.block_pitch
	var half := float(block_count()) * 0.5
	return Vector3(
		(float(bx) - half + 0.5) * pitch,
		config.ground_height,
		(float(bz) - half + 0.5) * pitch
	)


## Classification of a block: buildings, park or yard.
func block_kind(bx: int, bz: int) -> String:
	var value := block_value(bx, bz)
	var park_chance := config.park_chance
	var yard_chance := config.yard_chance
	# Blocks close to the spawn point are kept as buildings so the player always starts
	# inside a real city instead of on an empty field.
	var distance := Vector2(float(bx) - float(block_count() - 1) * 0.5, float(bz) - float(block_count() - 1) * 0.5).length()
	if distance < 1.2:
		return KIND_BUILDINGS
	if value < park_chance:
		return KIND_PARK
	if value < park_chance + yard_chance:
		return KIND_YARD
	return KIND_BUILDINGS


## World position of a road intersection (traffic nodes and AI navigation use this).
func intersection_position(ix: int, iz: int) -> Vector3:
	var pitch := config.block_pitch
	var half := float(block_count()) * 0.5
	return Vector3(
		(float(ix) - half) * pitch,
		config.ground_height,
		(float(iz) - half) * pitch
	)


## Number of intersections per axis (one more than the number of blocks).
func intersection_count() -> int:
	return block_count() + 1


## True when a position is on the roadway (used by the traffic spawner and by the tests).
func is_on_road(position: Vector3) -> bool:
	var half_road := config.road_width * 0.5
	var pitch := config.block_pitch
	var local_x := fposmod(position.x + pitch * 0.5, pitch) - pitch * 0.5
	var local_z := fposmod(position.z + pitch * 0.5, pitch) - pitch * 0.5
	return absf(local_x) <= half_road or absf(local_z) <= half_road


# --------------------------------------------------------------------------------------
# content of one block
# --------------------------------------------------------------------------------------
## Buildings of a block. Each entry: centre, size, floors, style, rotation, shop front.
func buildings(bx: int, bz: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var kind := block_kind(bx, bz)
	if kind != KIND_BUILDINGS:
		return result
	var gen := block_rng(bx, bz)
	var centre := block_center(bx, bz)
	var usable := config.block_pitch - config.road_width - config.sidewalk_width * 2.0 - config.building_margin * 2.0
	# A block is split into a 2x2 arrangement of plots; some plots stay empty (courtyards)
	# and a few blocks get a single tall tower instead of four small houses.
	var tower_block := gen.randf() < 0.16
	if tower_block:
		var floors := gen.randi_range(config.max_floors - 3, config.max_floors + 6)
		var width := usable * gen.randf_range(0.42, 0.6)
		var depth := usable * gen.randf_range(0.42, 0.6)
		result.append(
			{
				"position": centre + Vector3(gen.randf_range(-4.0, 4.0), 0.0, gen.randf_range(-4.0, 4.0)),
				"size": Vector3(width, float(floors) * config.floor_height, depth),
				"floors": floors,
				"style": _pick_style(gen, true),
				"rotation": 0.0,
				"shop": gen.randf() < config.shop_chance,
				"roof": true,
			}
		)
		_add_small_annex(result, gen, centre, usable)
		return result
	for plot_x in 2:
		for plot_z in 2:
			if gen.randf() < 0.14:
				continue
			var plot_size := usable * 0.46
			var offset := Vector3(
				(-0.25 + 0.5 * float(plot_x)) * usable,
				0.0,
				(-0.25 + 0.5 * float(plot_z)) * usable
			)
			var width := plot_size * gen.randf_range(0.72, 1.0)
			var depth := plot_size * gen.randf_range(0.72, 1.0)
			var floors := gen.randi_range(config.min_floors, maxi(config.min_floors + 1, config.max_floors - 4))
			result.append(
				{
					"position": centre + offset + Vector3(gen.randf_range(-1.5, 1.5), 0.0, gen.randf_range(-1.5, 1.5)),
					"size": Vector3(width, float(floors) * config.floor_height, depth),
					"floors": floors,
					"style": _pick_style(gen, false),
					"rotation": 0.0,
					"shop": gen.randf() < config.shop_chance,
					"roof": true,
				}
			)
	return result


func _add_small_annex(result: Array[Dictionary], gen: RandomNumberGenerator, centre: Vector3, usable: float) -> void:
	if gen.randf() > 0.7:
		return
	var annex_size := usable * gen.randf_range(0.2, 0.3)
	var floors := gen.randi_range(1, 3)
	result.append(
		{
			"position": centre + Vector3(usable * 0.42, 0.0, -usable * 0.38),
			"size": Vector3(annex_size, float(floors) * config.floor_height, annex_size),
			"floors": floors,
			"style": MaterialLibrary.FACADE_PANEL,
			"rotation": 0.0,
			"shop": false,
			"roof": false,
		}
	)


func _pick_style(gen: RandomNumberGenerator, tall: bool) -> StringName:
	if tall:
		return MaterialLibrary.FACADE_GLASS if gen.randf() < 0.6 else MaterialLibrary.FACADE_OFFICE
	var roll := gen.randf()
	if roll < 0.34:
		return MaterialLibrary.FACADE_OFFICE
	if roll < 0.6:
		return MaterialLibrary.FACADE_PANEL
	if roll < 0.82:
		return MaterialLibrary.FACADE_BRICK
	return MaterialLibrary.FACADE_GLASS


## Road side props around a block: lamps, hydrants, bins, signs, traffic lights.
func street_props(bx: int, bz: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var gen := block_rng(bx, bz)
	var centre := block_center(bx, bz)
	var pitch := config.block_pitch
	var edge := pitch * 0.5 - config.road_width * 0.5 - config.sidewalk_width * 0.5
	var density := config.prop_density * clampf(gen.randf_range(0.85, 1.15), 0.5, 1.5)
	for side in 4:
		var along := -pitch * 0.5 + 4.0
		while along < pitch * 0.5 - 4.0:
			var spacing := config.lamp_spacing * gen.randf_range(0.7, 1.3) / density
			along += spacing
			if along > pitch * 0.5 - 2.0:
				break
			var position := Vector3.ZERO
			var rotation := 0.0
			match side:
				0:
					position = centre + Vector3(along, 0.0, -edge)
					rotation = 0.0
				1:
					position = centre + Vector3(along, 0.0, edge)
					rotation = PI
				2:
					position = centre + Vector3(-edge, 0.0, along)
					rotation = PI * 0.5
				_:
					position = centre + Vector3(edge, 0.0, along)
					rotation = -PI * 0.5
			result.append({"kind": PROP_LAMP, "position": position, "rotation": rotation})
			if gen.randf() < 0.22 * density:
				result.append(
					{
						"kind": PROP_HYDRANT,
						"position": position + Vector3(0.0, 0.0, 1.6),
						"rotation": gen.randf_range(0.0, TAU),
					}
				)
			if gen.randf() < 0.18 * density:
				result.append(
					{
						"kind": PROP_BIN,
						"position": position + Vector3(1.4, 0.0, 0.0),
						"rotation": gen.randf_range(0.0, TAU),
					}
				)
	return result


## Props inside a block: trees, benches, planters, dumpsters, containers, cones.
func block_props(bx: int, bz: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var gen := block_rng(bx + 977, bz - 313)
	var centre := block_center(bx, bz)
	var kind := block_kind(bx, bz)
	var inner := (config.block_pitch - config.road_width) * 0.5 - config.sidewalk_width - 1.0
	var density := config.prop_density
	match kind:
		KIND_PARK:
			# trees in a rough grid with jitter, plus benches along the paths
			var tree_count := int(14.0 * density)
			for i in tree_count:
				var x := gen.randf_range(-inner, inner)
				var z := gen.randf_range(-inner, inner)
				result.append(
					{
						"kind": PROP_TREE,
						"position": centre + Vector3(x, 0.0, z),
						"rotation": gen.randf_range(0.0, TAU),
						"scale": gen.randf_range(0.85, 1.45),
					}
				)
			for i in 4:
				var t := float(i) / 4.0 * TAU
				result.append(
					{
						"kind": PROP_BENCH,
						"position": centre + Vector3(cos(t) * inner * 0.6, 0.0, sin(t) * inner * 0.6),
						"rotation": t + PI * 0.5,
					}
				)
			result.append({"kind": PROP_FOUNTAIN, "position": centre, "rotation": 0.0})
			if gen.randf() < 0.4:
				result.append(
					{
						"kind": PROP_STATUE,
						"position": centre + Vector3(inner * 0.7, 0.0, inner * 0.7),
						"rotation": gen.randf_range(0.0, TAU),
					}
				)
		KIND_YARD:
			var containers := int(5.0 * density)
			for i in containers:
				var x := gen.randf_range(-inner, inner)
				var z := gen.randf_range(-inner, inner)
				result.append(
					{
						"kind": PROP_CONTAINER,
						"position": centre + Vector3(x, 0.0, z),
						"rotation": (PI * 0.5 if gen.randf() < 0.5 else 0.0) + gen.randf_range(-0.1, 0.1),
					}
				)
			for i in int(6.0 * density):
				result.append(
					{
						"kind": PROP_CRATE,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": gen.randf_range(0.0, TAU),
						"scale": gen.randf_range(0.8, 1.3),
					}
				)
			for i in int(3.0 * density):
				result.append(
					{
						"kind": PROP_BARREL,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": 0.0,
					}
				)
			for i in int(4.0 * density):
				result.append(
					{
						"kind": PROP_CONE,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": 0.0,
					}
				)
		_:
			for i in int(4.0 * density):
				result.append(
					{
						"kind": PROP_TREE,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": gen.randf_range(0.0, TAU),
						"scale": gen.randf_range(0.8, 1.2),
					}
				)
			for i in int(2.0 * density):
				result.append(
					{
						"kind": PROP_DUMPSTER,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": gen.randf_range(0.0, TAU),
					}
				)
			for i in int(2.0 * density):
				result.append(
					{
						"kind": PROP_PLANTER,
						"position": centre + Vector3(gen.randf_range(-inner, inner), 0.0, gen.randf_range(-inner, inner)),
						"rotation": gen.randf_range(0.0, TAU),
					}
				)
			if gen.randf() < 0.5:
				result.append({"kind": PROP_BUS_STOP, "position": centre + Vector3(-inner, 0.0, inner * 0.5), "rotation": PI})
	return result


## Parked cars along the kerb of a block. They are baked into the chunk geometry as solid
## scenery (a real rigid body per parked car would waste the physics budget of a phone).
func parked_cars(bx: int, bz: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var gen := block_rng(bx - 555, bz + 777)
	var centre := block_center(bx, bz)
	var pitch := config.block_pitch
	var offset := pitch * 0.5 - config.road_width * 0.5 - 1.4
	var count := int(float(config.parked_cars_per_block) * config.prop_density)
	for i in count:
		var along := -pitch * 0.5 + 8.0 + gen.randf_range(0.0, pitch - 16.0)
		var side := gen.randi_range(0, 3)
		var position := Vector3.ZERO
		var rotation := 0.0
		match side:
			0:
				position = centre + Vector3(along, 0.0, -offset)
				rotation = 0.0
			1:
				position = centre + Vector3(along, 0.0, offset)
				rotation = PI
			2:
				position = centre + Vector3(-offset, 0.0, along)
				rotation = PI * 0.5
			_:
				position = centre + Vector3(offset, 0.0, along)
				rotation = -PI * 0.5
		result.append(
			{
				"kind": PROP_PARKED_CAR,
				"position": position,
				"rotation": rotation + gen.randf_range(-0.05, 0.05),
				"model": gen.randi_range(0, 5),
				"colour": Color.from_hsv(gen.randf(), gen.randf_range(0.15, 0.75), gen.randf_range(0.4, 0.95)),
			}
		)
	return result


## Everything a chunk has to build, in one call.
func block_content(bx: int, bz: int) -> Dictionary:
	return {
		"kind": block_kind(bx, bz),
		"buildings": buildings(bx, bz),
		"street_props": street_props(bx, bz),
		"props": block_props(bx, bz),
		"parked_cars": parked_cars(bx, bz),
	}


## The player spawns in the middle of the world, on the concrete, in the middle of a
## crossroads, facing along +X so the first thing the player sees is an avenue.
func spawn_position() -> Vector3:
	return Vector3(0.0, config.ground_height + 0.6, 0.0)


func spawn_rotation() -> float:
	return -PI * 0.5


## Rough triangle budget per block kind, used by the tests to catch a runaway generator.
func expected_budget(kind: String) -> int:
	match kind:
		KIND_PARK:
			return 9000
		KIND_YARD:
			return 8000
		_:
			return 14000
