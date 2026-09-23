extends TestCase
## The world: generation, streaming, level of detail and the density of the city.
##
## This is the test that proves the project is not "grey cubes on a plane": it builds the real
## chunks through the real chunk builder and inspects what came out - how many triangles, how
## many materials, how many collision boxes, how many chunks are resident, how the LOD levels
## follow the player - and it also checks the two performance promises: a chunk is merged per
## material (a handful of draw calls, not hundreds) and the world covers 500 metres of concrete
## in every direction from the spawn.


func _suite_name() -> String:
	return "integration/world_streaming"

const SEED := 20240923


func run(tree: SceneTree) -> void:
	var config := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(config, "world_config.tres must load")
	if config == null:
		return

	var world := WorldGenerator.new()
	world.name = "TestWorld"
	world.world_config = config
	tree.root.add_child(world)
	var statistics := world.generate(SEED)
	check_not_null(world.streamer, "the world created a streamer")
	check_not_null(world.road_graph, "the world created a road graph")
	check(world.road_graph.is_valid(), "the road graph is usable")
	check_not_null(world.sun, "the world has a sun")
	check_not_null(world.environment_node, "the world has an environment")
	note("world: %s" % str(statistics))

	# --- the skyline -----------------------------------------------------------------
	var skyline_meshes := world.streamer.build_skyline()
	check_greater(float(skyline_meshes), 0.0, "the distant skyline is built (a horizon, not an empty void)")

	# --- streaming around the player -------------------------------------------------
	var spawn := world.spawn_transform().origin
	world.streamer.force_immediate = true
	world.streamer.update_streaming(spawn, 1.0 / 60.0)
	var stats := world.streamer.statistics()
	check_greater(float(stats["resident"]), 8.0, "chunks are streamed in around the player")
	check_greater(float(stats["meshes"]), 20.0, "the resident chunks contain meshes")
	check_greater(float(stats["triangles"]), 20000.0, "the resident chunks contain a real amount of geometry")
	check_less(float(stats["triangles"]), 4000000.0, "the resident geometry stays inside a mobile budget")
	check_greater(float(stats["collisions"]), 0.0, "the chunks near the player have collision")
	note("streaming: %s" % world.streamer.debug_string())

	# Residency must be a disc around the player, not the whole world.
	var resident := stats["resident"]
	check_less(float(resident), float(config.chunk_count()), "not every chunk of the world is resident at once")

	# --- level of detail -------------------------------------------------------------
	var near_chunk := _chunk_at(world, spawn)
	check_not_null(near_chunk, "the chunk under the player exists")
	if near_chunk != null:
		check(near_chunk.lod == ChunkBuilder.LOD_NEAR, "the chunk under the player is the detailed one")
		check(near_chunk.has_collision(), "the chunk under the player has collision")
		var materials_in_chunk := _material_count(near_chunk)
		check_greater(float(materials_in_chunk), 4.0, "a chunk is built from several materials (asphalt, concrete, façades, ...)")
		var triangles := near_chunk.triangle_count()
		check_greater(float(triangles), 2000.0, "a city chunk is dense, not a handful of boxes")
		check_less(float(near_chunk.mesh_count()), 24.0, "a chunk is merged per material: a few draw calls, not hundreds")
		check_greater(float(near_chunk.collision_boxes.size()), 5.0, "buildings and props provide collision boxes")
		note("chunk(0,0): %s, %d materials" % [near_chunk.describe(), materials_in_chunk])
	var far_chunk: WorldChunk = null
	for chunk: WorldChunk in world.streamer.chunks.values():
		if chunk.lod == ChunkBuilder.LOD_FAR:
			far_chunk = chunk
			break
	check_not_null(far_chunk, "distant chunks are downgraded to a cheaper level")
	if far_chunk != null and near_chunk != null:
		check(far_chunk.lod > near_chunk.lod, "the far chunk is less detailed than the near one")
		check_less(
			float(far_chunk.triangle_count()), float(near_chunk.triangle_count()),
			"the far chunk costs fewer triangles than the near one"
		)

	# --- the player drives: chunks follow and are re-levelled ------------------------
	var before := world.streamer.chunks.keys().duplicate()
	var moved_to := spawn + Vector3(config.chunk_size * 2.5, 0.0, config.chunk_size * 1.5)
	world.streamer.update_streaming(moved_to, 1.0 / 60.0)
	var after := world.streamer.chunks.keys().duplicate()
	var new_chunks := 0
	for coords: Vector2i in after:
		if not before.has(coords):
			new_chunks += 1
	check_greater(float(new_chunks), 0.0, "driving into new territory streams new chunks in")
	check_less(
		float(world.streamer.chunks.size()), float(config.max_resident_chunks) + 1.0,
		"the resident chunk budget is respected"
	)
	var moved_chunk := _chunk_at(world, moved_to)
	check_not_null(moved_chunk, "the new position is covered by a chunk")
	if moved_chunk != null:
		check(moved_chunk.lod == ChunkBuilder.LOD_NEAR, "the new chunk is detailed immediately")

	# --- chunks are deterministic -----------------------------------------------------
	var builder := ChunkBuilder.new(world.layout, world.materials, config)
	var holder := Node3D.new()
	tree.root.add_child(holder)
	var first := builder.build(holder, Vector2i(0, 0), ChunkBuilder.LOD_NEAR, 1.0)
	var holder_two := Node3D.new()
	tree.root.add_child(holder_two)
	var second := builder.build(holder_two, Vector2i(0, 0), ChunkBuilder.LOD_NEAR, 1.0)
	check_almost(
		float(first["triangles"]), float(second["triangles"]), 0.5, "the same chunk always has the same geometry"
	)
	check_greater(
		float(first["triangles"]), 2000.0, "the chunk builder spends the triangle budget it is expected to"
	)
	check_almost(
		float(first["collision_boxes"]), float(second["collision_boxes"]), 0.5, "collision is deterministic too"
	)
	# The whole point of leaving out small props: the far LOD must be much cheaper.
	var holder_three := Node3D.new()
	tree.root.add_child(holder_three)
	var far := builder.build(holder_three, Vector2i(0, 0), ChunkBuilder.LOD_FAR, 1.0)
	check_less(
		float(far["triangles"]), float(first["triangles"]) * 0.95, "the far LOD of a chunk is cheaper than the near one"
	)
	check_less(
		float(far["collision_boxes"]), float(first["collision_boxes"]) + 0.5,
		"the far LOD does not add collision"
	)
	holder.queue_free()
	holder_two.queue_free()
	holder_three.queue_free()

	# --- the concrete slab the player drives on --------------------------------------
	var ground_area := PI * config.concrete_radius * config.concrete_radius
	check_greater(ground_area, 700000.0, "the concrete covers ~500 m in every direction")
	check(config.contains_position(spawn + Vector3(450.0, 0.0, 0.0)), "the world contains a point 450 m east of the spawn")
	check(config.contains_position(spawn + Vector3(-450.0, 0.0, 0.0)), "the world contains a point 450 m west of the spawn")
	check(config.contains_position(spawn + Vector3(0.0, 0.0, 450.0)), "the world contains a point 450 m north of the spawn")
	check(config.contains_position(spawn + Vector3(0.0, 0.0, -450.0)), "the world contains a point 450 m south of the spawn")
	check(not config.contains_position(Vector3(9000.0, 0.0, 0.0)), "the world does not pretend to be infinite")

	# --- traffic and police can be placed on the streets -----------------------------
	var generator := RandomNumberGenerator.new()
	generator.seed = SEED
	var on_road := 0
	var attempts := 12
	for _i in attempts:
		var point := world.road_graph.point_on_road_near(spawn, 40.0, 260.0, generator)
		if point != Vector3.INF and world.layout.is_on_road(point):
			on_road += 1
	check_greater(float(on_road), 4.0, "cars can be placed on real streets near the spawn")

	world.queue_free()
	await tree.process_frame


func _chunk_at(world: WorldGenerator, position: Vector3) -> WorldChunk:
	var coords := world.world_config.chunk_coords(position)
	return world.streamer.chunks.get(coords)


## Counts how many different materials a chunk uses by looking at the names of the merged
## meshes the chunk builder created ("chunk_<material_key>").
func _material_count(chunk: WorldChunk) -> int:
	var keys := {}
	for child in chunk.get_children():
		if child is MeshInstance3D:
			var instance := child as MeshInstance3D
			var parts := instance.name.split("_", false, 1)
			if parts.size() > 1:
				keys[parts[1]] = true
			elif instance.material_override != null:
				keys[instance.material_override.get_instance_id()] = true
		elif child is Node3D:
			for grandchild in child.get_children():
				if grandchild is MeshInstance3D:
					var mesh_instance := grandchild as MeshInstance3D
					var parts2 := mesh_instance.name.split("_", false, 1)
					keys[parts2[0] if parts2.size() > 1 else mesh_instance.name] = true
	return keys.size()
