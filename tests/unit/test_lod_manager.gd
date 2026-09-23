extends TestCase
## The level of detail rules: what is near is detailed, what is far is cheap, and a chunk that
## sits on a threshold does not rebuild itself every frame (hysteresis), because that would
## stutter on a phone.


func _suite_name() -> String:
	return "unit/lod_manager"


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(config, "world_config.tres must load")
	if config == null:
		return
	var manager := LODManager.new(config)

	# --- distance to the nearest point of a chunk, not to its centre ----------------
	var origin := config.chunk_origin(Vector2i(0, 0))
	var half := config.chunk_size * 0.5
	check_almost(manager.distance_to_chunk(origin, origin), 0.0, 0.001, "the distance inside a chunk is zero")
	check_almost(
		manager.distance_to_chunk(origin, origin + Vector3(half + 10.0, 0.0, 0.0)),
		10.0,
		0.001,
		"the distance is measured to the edge of the chunk"
	)
	check_greater(
		manager.distance_to_chunk(origin, origin + Vector3(half + 10.0, 90.0, half + 10.0)),
		10.0,
		"height does not matter for chunk streaming"
	)

	# --- the three levels ----------------------------------------------------------
	check(
		manager.level_for_distance(0.0, -1) == ChunkBuilder.LOD_NEAR,
		"a chunk under the player is detailed"
	)
	check(
		manager.level_for_distance(config.lod0_distance + 1.0, -1) == ChunkBuilder.LOD_MEDIUM,
		"a chunk past the near threshold is medium"
	)
	check(
		manager.level_for_distance(config.lod1_distance + 1.0, -1) == ChunkBuilder.LOD_FAR,
		"a chunk past the medium threshold is far"
	)
	check_greater(
		manager.threshold_for_level(ChunkBuilder.LOD_NEAR),
		manager.level_for_distance(0.0, -1),
		"thresholds are positive"
	)

	# --- one step at a time --------------------------------------------------------
	check(
		manager.level_for_distance(config.lod1_distance + 50.0, ChunkBuilder.LOD_NEAR)
		== ChunkBuilder.LOD_MEDIUM,
		"a chunk moves one level at a time (near to medium)"
	)
	check(
		manager.level_for_distance(config.lod1_distance + 50.0, ChunkBuilder.LOD_MEDIUM)
		== ChunkBuilder.LOD_FAR,
		"a chunk moves one level at a time (medium to far)"
	)

	# --- hysteresis: no rebuilding at the boundary ---------------------------------
	var boundary := config.lod0_distance * 1.02
	check(
		manager.level_for_distance(boundary, ChunkBuilder.LOD_NEAR) == ChunkBuilder.LOD_NEAR,
		"a chunk does not drop a level just past the threshold"
	)
	var clearly_far := config.lod0_distance * LODManager.HYSTERESIS * 1.05
	check(
		manager.level_for_distance(clearly_far, ChunkBuilder.LOD_NEAR) == ChunkBuilder.LOD_MEDIUM,
		"a chunk drops a level once it is clearly out of range"
	)
	check(
		manager.level_for_distance(config.lod0_distance * 1.05, ChunkBuilder.LOD_MEDIUM) == ChunkBuilder.LOD_MEDIUM,
		"a chunk does not upgrade just inside the threshold"
	)

	# --- residency and collision ----------------------------------------------------
	check(manager.resident_for_distance(config.stream_radius * 0.5), "a chunk inside the stream radius is resident")
	check(not manager.resident_for_distance(config.stream_radius * 2.0), "a chunk far outside is not resident")
	check(
		manager.collision_for_distance(config.collision_radius * 0.5),
		"a chunk near the player has collision"
	)
	check(
		not manager.collision_for_distance(config.collision_radius * 2.0),
		"a distant chunk has no collision"
	)

	# --- the quality preset scales everything --------------------------------------
	manager.lod_bias = 0.5
	check_less(
		manager.threshold_for_level(ChunkBuilder.LOD_NEAR),
		config.lod0_distance,
		"a low preset shortens the detailed distance"
	)
	manager.lod_bias = 1.4
	check_greater(
		manager.threshold_for_level(ChunkBuilder.LOD_NEAR),
		config.lod0_distance,
		"a high preset lengthens the detailed distance"
	)
	manager.lod_bias = 1.0
	check_greater(manager.draw_distance(), config.lod2_distance, "the fog covers the far plane")
