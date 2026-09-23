extends TestCase
## The city recipe. `DistrictLayout` is the single source of truth for the geometry, the
## collision boxes, the road graph and the traffic spawner, so it has to be deterministic
## (two runs with the same seed produce the same city) and it has to produce a *varied* city:
## several block kinds, a wide range of building heights and many kinds of street props.


func _suite_name() -> String:
	return "unit/district_layout"

const SEED_A := 20240923
const SEED_B := 777001


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(config, "world_config.tres must load")
	if config == null:
		return
	var layout := DistrictLayout.new(SEED_A, config)
	var other := DistrictLayout.new(SEED_B, config)

	# --- determinism ---------------------------------------------------------------
	var first_count := 0
	var first_positions := PackedVector3Array()
	var second_count := 0
	var second_positions := PackedVector3Array()
	for bz in range(-4, 5):
		for bx in range(-4, 5):
			var block := layout.buildings(bx, bz)
			first_count += block.size()
			for building: Dictionary in block:
				first_positions.append(building["position"])
	for bz in range(-4, 5):
		for bx in range(-4, 5):
			var block := layout.buildings(bx, bz)
			second_count += block.size()
			for building: Dictionary in block:
				second_positions.append(building["position"])
	check(first_count > 100, "the sampled area contains a city, not a handful of boxes")
	check(first_count == second_count, "the same seed produces the same number of buildings")
	check(first_positions == second_positions, "the same seed produces the same city")

	# A different seed must produce a different city (otherwise "new run" means nothing).
	var differs := false
	for i in mini(60, mini(first_positions.size(), second_positions.size())):
		if first_positions[i] != second_positions[i]:
			differs = true
			break
	check(differs, "a different seed produces a different city")

	# --- variety of block kinds ----------------------------------------------------
	var kinds := {}
	var prop_kinds := {}
	var styles := {}
	var heights := PackedFloat32Array()
	var floors_min := 999
	var floors_max := 0
	var shops := 0
	var max_buildings_in_block := 0
	for bz in range(-6, 7):
		for bx in range(-6, 7):
			var kind := layout.block_kind(bx, bz)
			kinds[kind] = int(kinds.get(kind, 0)) + 1
			var block := layout.buildings(bx, bz)
			max_buildings_in_block = maxi(max_buildings_in_block, block.size())
			for building: Dictionary in block:
				styles[building["style"]] = true
				heights.append(float(building["size"].y))
				floors_min = mini(floors_min, int(building["floors"]))
				floors_max = maxi(floors_max, int(building["floors"]))
				if bool(building.get("shop", false)):
					shops += 1
			for prop: Dictionary in layout.street_props(bx, bz):
				prop_kinds[prop["kind"]] = true
			for prop: Dictionary in layout.block_props(bx, bz):
				prop_kinds[prop["kind"]] = true
	check(kinds.size() >= 2, "the city contains more than one kind of block")
	check(int(kinds.get(DistrictLayout.KIND_BUILDINGS, 0)) > 20, "most blocks are built up")
	check(int(kinds.get(DistrictLayout.KIND_PARK, 0)) > 0, "the city has parks")
	check(int(kinds.get(DistrictLayout.KIND_YARD, 0)) > 0, "the city has industrial yards")
	check(styles.size() >= 4, "there are at least four façade styles in use")
	check(prop_kinds.size() >= 8, "the streets carry at least eight kinds of props")
	check_greater(float(shops), 5.0, "shop fronts are placed on the ground floors")
	check_greater(float(floors_max - floors_min), 4.0, "buildings have varied heights")
	note("blocks: %s" % str(kinds))
	note("props kinds: %d, façade styles: %d, floors %d..%d" % [prop_kinds.size(), styles.size(), floors_min, floors_max])

	# --- buildings are on their block, not on the road -----------------------------
	var pitch := config.block_pitch
	var margin := pitch * 0.5 - config.road_width * 0.5 - config.sidewalk_width
	var inside := true
	for bz in range(-3, 4):
		for bx in range(-3, 4):
			var centre := layout.block_center(bx, bz)
			for building: Dictionary in layout.buildings(bx, bz):
				var position: Vector3 = building["position"]
				var size: Vector3 = building["size"]
				if absf(position.x - centre.x) + size.x * 0.5 > margin + 0.5:
					inside = false
				if absf(position.z - centre.z) + size.z * 0.5 > margin + 0.5:
					inside = false
				check_greater(size.y, config.floor_height, "a building is at least one floor tall")
				check_less(size.x, pitch, "a building fits inside its block")
	check(inside, "buildings stay inside their block and never sit on the road")

	# --- no building overlaps another in the same block ----------------------------
	var overlapping := false
	for bz in range(-3, 4):
		for bx in range(-3, 4):
			var block := layout.buildings(bx, bz)
			for i in block.size():
				for j in range(i + 1, block.size()):
					var a: Dictionary = block[i]
					var b: Dictionary = block[j]
					var overlap_x: float = absf((a["position"] as Vector3).x - (b["position"] as Vector3).x) - ((a["size"] as Vector3).x + (b["size"] as Vector3).x) * 0.5
					var overlap_z: float = absf((a["position"] as Vector3).z - (b["position"] as Vector3).z) - ((a["size"] as Vector3).z + (b["size"] as Vector3).z) * 0.5
					if overlap_x < -0.5 and overlap_z < -0.5:
						overlapping = true
	check(not overlapping, "buildings inside a block do not intersect each other")

	# --- parked cars are on the street, not inside a wall --------------------------
	var parked_checked := 0
	var parked_inside_building := false
	for bz in range(-3, 4):
		for bx in range(-3, 4):
			var building_boxes: Array[Dictionary] = layout.buildings(bx, bz)
			for car: Dictionary in layout.parked_cars(bx, bz):
				parked_checked += 1
				var car_position: Vector3 = car["position"]
				for building: Dictionary in building_boxes:
					var building_position: Vector3 = building["position"]
					var building_size: Vector3 = building["size"]
					if (
						absf(car_position.x - building_position.x) < building_size.x * 0.5
						and absf(car_position.z - building_position.z) < building_size.z * 0.5
					):
						parked_inside_building = true
	check_greater(float(parked_checked), 4.0, "parked cars are generated")
	check(not parked_inside_building, "parked cars never stand inside a building")
	check_greater(float(max_buildings_in_block), 1.0, "a block holds several buildings")

	# --- the spawn point -----------------------------------------------------------
	var spawn := layout.spawn_position()
	check_less(spawn.length(), config.concrete_radius, "the player spawns on the concrete")
	check_almost(spawn.y, config.ground_height, 0.4, "the spawn is at ground level")
	var spawn_block := layout.block_coords(spawn)
	var spawn_buildings := layout.buildings(spawn_block.x, spawn_block.y)
	var spawn_inside := false
	for building: Dictionary in spawn_buildings:
		var building_position: Vector3 = building["position"]
		var building_size: Vector3 = building["size"]
		if (
			absf(spawn.x - building_position.x) < building_size.x * 0.5 + 1.0
			and absf(spawn.z - building_position.z) < building_size.z * 0.5 + 1.0
		):
			spawn_inside = true
	check(not spawn_inside, "the player never spawns inside a building")

	# --- the triangle budget the builder is expected to spend ----------------------
	check_greater(float(layout.expected_budget(DistrictLayout.KIND_BUILDINGS)), 500.0, "a built block has a budget")
	check_greater(float(layout.expected_budget(DistrictLayout.KIND_PARK)), 100.0, "a park has a budget")
	check_greater(float(other.expected_budget(DistrictLayout.KIND_BUILDINGS)), 500.0, "the budget is seed independent")
