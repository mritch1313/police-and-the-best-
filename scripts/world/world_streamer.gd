extends Node3D
class_name WorldStreamer
## Streams the city in and out around the player.
##
## Design constraints that shaped this class:
##
##   * a phone must never stutter while driving, so chunk builds are *budgeted*: at most
##     `build_budget_per_frame` chunks are generated per frame, nearest first, and the
##     streamer works through a queue instead of a loop over the whole world
##   * the world is 8x8 chunks in the shipping configuration, so a full residency list is
##     small enough to keep in memory; the streamer still frees chunks that have been
##     outside the stream radius for a while (and always keeps the memory cap)
##   * chunks are pooled: freeing and rebuilding a chunk is much more expensive than
##     re-levelling one, so a chunk that is still inside the "keep alive" radius is only
##     downgraded, never destroyed
##   * everything is deterministic and inspectable, because this is also the code the
##     automated streaming test drives (see tests/integration/test_world_streaming.gd)

signal chunk_built(coords: Vector2i, lod: int, milliseconds: float)
signal residency_changed(active_chunks: int)

## How long a chunk may stay queued before it is considered stale (seconds).
const QUEUE_TIMEOUT := 12.0

var world_config: WorldConfig
var layout: DistrictLayout
var materials: MaterialLibrary
var lod_manager: LODManager

## Chunks currently alive, keyed by their coordinates.
var chunks: Dictionary = {}
## Chunks waiting to be built, nearest first: [{coords, lod, distance, stamp}]
var _queue: Array[Dictionary] = []
var _keep_alive: Dictionary = {}
var _last_center := Vector3(INF, INF, INF)
var _roof: Node3D = null
var _builder: ChunkBuilder = null
var _stats := {"built": 0, "freed": 0, "releveled": 0, "collisions": 0}

## Set by the PerformanceManager every frame.
var prop_density: float = 1.0
var build_budget: int = 2
var max_resident: int = 160

## Set to false by the tests to build everything at once.
var streaming_enabled: bool = true
## When true, chunk builds happen in the same frame they are requested (used by the
## headless smoke test and by the world generation test so results are deterministic).
var force_immediate: bool = false


func setup(
	p_layout: DistrictLayout,
	p_materials: MaterialLibrary,
	p_config: WorldConfig = null
) -> void:
	layout = p_layout
	materials = p_materials
	world_config = p_config if p_config != null else (p_layout.config if p_layout != null else WorldConfig.new())
	lod_manager = LODManager.new(world_config)
	_builder = ChunkBuilder.new(layout, materials, world_config)
	build_budget = world_config.build_budget_per_frame
	max_resident = world_config.max_resident_chunks


## Adds the distant skyline (built once, never streamed: it is cheap and it must always be
## visible to hide the end of the streamed city).
func build_skyline() -> int:
	if layout == null or materials == null:
		return 0
	_builder = ChunkBuilder.new(layout, materials, world_config)
	var count := 0
	for ring in range(1, maxi(world_config.skyline_rings, 0) + 1):
		count += _builder.build_skyline(self, ring)
	return count


## Called every frame by the game world with the current player position.
func update_streaming(center: Vector3, delta: float) -> void:
	if not streaming_enabled or layout == null:
		return
	var moved := center.distance_to(_last_center) > 1.0
	# Which chunks *should* be resident?
	var radius := world_config.stream_radius * maxf(lod_manager.lod_bias, 0.4)
	var chunk_size := world_config.chunk_size
	var chunk_count := world_config.chunk_count()
	var half := float(chunk_count) * 0.5
	var center_cx := int(floor(center.x / chunk_size + half))
	var center_cz := int(floor(center.z / chunk_size + half))
	var span := int(ceil(radius / chunk_size)) + 1
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var coords := Vector2i(center_cx + dx, center_cz + dz)
			if not world_config.is_inside_world(coords):
				continue
			var origin := world_config.chunk_origin(coords)
			var distance := lod_manager.distance_to_chunk(origin, center)
			if distance > radius:
				continue
			_keep_alive[coords] = 0.0
			var chunk: WorldChunk = chunks.get(coords)
			var wanted_lod := lod_manager.level_for_distance(distance, chunk.lod if chunk != null else -1)
			if chunk == null:
				if not _queued(coords):
					_queue.append({
						"coords": coords,
						"lod": wanted_lod,
						"distance": distance,
						"stamp": Time.get_ticks_msec(),
					})
			else:
				if wanted_lod != chunk.lod:
					_apply_lod(chunk, wanted_lod)
				var want_collision := lod_manager.collision_for_distance(distance)
				if want_collision != chunk.has_collision():
					chunk.set_collision_enabled(want_collision)
					if want_collision:
						_stats["collisions"] = int(_stats["collisions"]) + 1
	# Sort the queue nearest first so the player always sees what they are driving into.
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	_build_from_queue()
	_update_keep_alive(delta, moved)
	if moved:
		_last_center = center


## True when the chunk is already waiting in the queue.
func _queued(coords: Vector2i) -> bool:
	for entry: Dictionary in _queue:
		if entry["coords"] == coords:
			return true
	return false


## Builds at most `build_budget` chunks this frame.
func _build_from_queue() -> void:
	var budget := maxi(build_budget, 1)
	if force_immediate:
		budget = maxi(_queue.size(), 1)
	var built_this_frame := 0
	while not _queue.is_empty() and built_this_frame < budget:
		var entry: Dictionary = _queue.pop_front()
		var coords: Vector2i = entry["coords"]
		if chunks.has(coords):
			continue
		var chunk := WorldChunk.new()
		add_child(chunk)
		chunk.build(_builder, coords, int(entry["lod"]), prop_density)
		chunk.set_collision_enabled(lod_manager.collision_for_distance(float(entry["distance"])))
		chunks[coords] = chunk
		built_this_frame += 1
		_stats["built"] = int(_stats["built"]) + 1
		chunk_built.emit(coords, chunk.lod, chunk.built_ms)
	_enforce_capacity()


func _apply_lod(chunk: WorldChunk, lod: int) -> void:
	chunk.set_lod(lod, prop_density)
	_stats["releveled"] = int(_stats["releveled"]) + 1


## Ages the keep-alive timer and frees chunks that have been out of range for long enough.
func _update_keep_alive(delta: float, moved: bool) -> void:
	if not moved and _keep_alive.size() > 0:
		return
	var expired: Array[Vector2i] = []
	for coords: Vector2i in _keep_alive.keys():
		if chunks.has(coords):
			_keep_alive[coords] = float(_keep_alive[coords]) + delta
			if float(_keep_alive[coords]) > world_config.chunk_keep_alive_time:
				expired.append(coords)
		else:
			_keep_alive.erase(coords)
	for coords: Vector2i in expired:
		if chunks.has(coords):
			_free_chunk(coords)


func _free_chunk(coords: Vector2i) -> void:
	var chunk: WorldChunk = chunks.get(coords)
	if chunk == null:
		return
	chunk.queue_free()
	chunks.erase(coords)
	_keep_alive.erase(coords)
	_stats["freed"] = int(_stats["freed"]) + 1
	residency_changed.emit(chunks.size())


## Keeps the resident chunk count inside the memory budget of the current preset by
## dropping the chunks that are furthest from the player.
func _enforce_capacity() -> void:
	var limit := mini(max_resident, maxi(world_config.max_resident_chunks, 16))
	if chunks.size() <= limit:
		return
	var centre := _last_center
	var sorted: Array[Vector2i] = []
	for coords: Vector2i in chunks.keys():
		sorted.append(coords)
	sorted.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return (
				world_config.chunk_origin(a).distance_to(centre)
				> world_config.chunk_origin(b).distance_to(centre)
			)
	)
	var to_free := chunks.size() - limit
	for i in to_free:
		_free_chunk(sorted[i])


## Rebuilds every resident chunk (used when the quality preset changes).
func reflow_all() -> void:
	_queue.clear()
	for coords: Vector2i in chunks.keys():
		var chunk: WorldChunk = chunks[coords]
		chunk.set_lod(lod_manager.level_for_distance(chunk.global_position.distance_to(_last_center), chunk.lod), prop_density)


## Total triangles of every resident chunk (the smoke test asserts this stays sane).
func total_triangles() -> int:
	var total := 0
	for chunk: WorldChunk in chunks.values():
		total += chunk.triangle_count()
	return total


func total_meshes() -> int:
	var total := 0
	for chunk: WorldChunk in chunks.values():
		total += chunk.mesh_count()
	return total


func collision_body_count() -> int:
	var total := 0
	for chunk: WorldChunk in chunks.values():
		if chunk.has_collision():
			total += 1
	return total


## Loads the whole world at once. Used by the headless world test and by the map preview,
## never in a running game.
func build_everything(lod: int = ChunkBuilder.LOD_FAR, with_collision: bool = false) -> int:
	var chunk_count := world_config.chunk_count()
	var built := 0
	for cz in chunk_count:
		for cx in chunk_count:
			var coords := Vector2i(cx, cz)
			if chunks.has(coords):
				continue
			var chunk := WorldChunk.new()
			add_child(chunk)
			chunk.build(_builder, coords, lod, prop_density)
			if with_collision:
				chunk.set_collision_enabled(true)
			chunks[coords] = chunk
			built += 1
	return built


func statistics() -> Dictionary:
	var data := _stats.duplicate()
	data["resident"] = chunks.size()
	data["queued"] = _queue.size()
	data["triangles"] = total_triangles()
	data["meshes"] = total_meshes()
	data["collisions"] = collision_body_count()
	return data


func debug_string() -> String:
	return "chunks=%d queued=%d tris=%d meshes=%d bodies=%d built=%d freed=%d" % [
		chunks.size(),
		_queue.size(),
		total_triangles(),
		total_meshes(),
		collision_body_count(),
		int(_stats["built"]),
		int(_stats["freed"]),
	]


## Frees every chunk and clears the bookkeeping (used when a run ends).
func clear_all() -> void:
	_queue.clear()
	_keep_alive.clear()
	for coords: Vector2i in chunks.keys():
		var chunk: WorldChunk = chunks[coords]
		chunk.queue_free()
	chunks.clear()
	_stats = {"built": 0, "freed": 0, "releveled": 0, "collisions": 0}
