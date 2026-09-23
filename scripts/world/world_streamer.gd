class_name WorldStreamer
extends Node3D
## Стриминг чанков вокруг игрока: очередь по важности, бюджет на кадр, LOD, выгрузка.
##
## ПРИНЦИПЫ (важно для «не лагает на Infinix»):
##  * Строим НЕ БОЛЕЕ `chunk_build_budget_ms` миллисекунд за кадр, приоритет — ближайшим
##    чанкам. Иначе первый выезд из меню = 800 мс фриза (и ANR на Android).
##  * Один чанк за кадр максимум: сборка чанка — это ~2-6 мс, а два «тяжёлых» подряд уже
##    дают просадку ниже 60 fps.
##  * LOD считается по расстоянию до БЛИЖАЙШЕЙ точки чанка (не до центра), поэтому чанк,
##    в который игрок въезжает, уже подробный.
##  * Выгрузка = снять children и оставить узел: меш-ресурсы малых форм общие, поэтому
##    повторный въезд в чанк стоит только пересборку геометрии, а не загрузку ассетов.
##  * Всё, что «за экраном», не перестраивается вовсе: `frustum`-отсечение делает рендер
##    (AABB + окклюдеры), стример отвечает только за наличие данных.

signal chunk_ready(index: Vector2i, chunk: WorldChunk)
signal chunk_unloaded(index: Vector2i)
signal stream_stats(stats: Dictionary)

const UNLOAD_EXTRA_CHUNKS := 1

var config: WorldConfig = null
var target: Node3D = null
var chunks: Dictionary = {}
var queue: Array[Vector2i] = []
var last_center: Vector2i = Vector2i(999999, 999999)
var built_total: int = 0
var freed_total: int = 0
var build_time_ms: float = 0.0
var _stats_timer: float = 0.0
var _lod_timer: float = 0.0
var ready_enough: bool = false

func _ready() -> void:
	if config == null:
		config = GameSetup.get_config("world") as WorldConfig
	set_process(true)

func set_target(node: Node3D) -> void:
	target = node
	last_center = Vector2i(999999, 999999)

func _process(delta: float) -> void:
	if config == null:
		return
	var center := desired_center()
	if center != last_center:
		rebuild_queue(center)
		last_center = center
	_build_within_budget(delta)
	_lod_timer -= delta
	if _lod_timer <= 0.0:
		_lod_timer = 0.25
		update_lods()
	_stats_timer -= delta
	if _stats_timer <= 0.0:
		_stats_timer = 1.0
		stream_stats.emit(stats())

func desired_center() -> Vector2i:
	if target == null:
		return WorldGenerator.chunk_index_for(Vector3.ZERO, config)
	return WorldGenerator.chunk_index_for(target.global_position, config)

## Кандидаты на загрузку: всё в радиусе загрузки, отсортированное по близости к цели.
func rebuild_queue(center: Vector2i) -> void:
	queue.clear()
	var radius := clampi(config.load_radius_chunks, 0, 4)
	var wanted := chunk_ring(center, radius)
	var anchor := target_center()
	var scored: Array = []
	for index in wanted:
		var existing = chunks.get(index)
		if existing != null and (existing as WorldChunk).is_built():
			continue
		if not inside_world(index):
			continue
		scored.append({"index": index, "dist": _chunk_center(index).distance_to(anchor)})
	scored.sort_custom(_by_distance)
	for entry in scored:
		queue.append(entry["index"])
	while queue.size() > max_active():
		queue.remove_at(queue.size() - 1)

static func _by_distance(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) < float(b["dist"])

func _build_within_budget(_delta: float) -> void:
	if queue.is_empty():
		return
	var budget := maxf(config.chunk_build_budget_ms, 0.5)
	var spent := 0.0
	while not queue.is_empty() and spent < budget:
		var index: Vector2i = queue[0]
		queue.remove_at(0)
		var started := Time.get_ticks_msec()
		_build_chunk(index)
		var took := float(Time.get_ticks_msec() - started)
		spent += took
		build_time_ms = build_time_ms * 0.7 + took * 0.3
	# Выгрузка лишних (далёких) — после построения, чтобы не «голодать».
	evict_far()
	if queue.is_empty() and not ready_enough:
		ready_enough = true

func _build_chunk(index: Vector2i) -> void:
	# Малые формы нужны только «ближнему» кольцу: дальше они всё равно скрыты LOD,
	# а память и вершины уже потрачены.
	var anchor := target_center()
	var include_props := _chunk_center(index).distance_to(anchor) <= config.lod1_distance_m * 1.2
	var data := ChunkBuilder.build(index, config, include_props)
	var chunk := WorldChunk.new()
	chunk.name = "Chunk_%d_%d" % [index.x, index.y]
	add_child(chunk)
	var started := Time.get_ticks_usec()
	chunk.apply_data(data, config)
	chunk.built_ms = float(Time.get_ticks_usec() - started) / 1000.0
	chunks[index] = chunk
	built_total += 1
	DebugConsole.bump("chunks_built")
	DebugConsole.log_line("world", chunk.status_line())
	chunk_ready.emit(index, chunk)

## Радиус, за которым чанк можно выгружать: радиус загрузки + запас `unload_margin_chunks`.
## Запас держат в долях чанка, чтобы выгрузка не «дышала» на границе (игрок стоит на
## границе -> чанк выгружен -> шаг назад -> снова нужен).
static func keep_radius_m(cfg: WorldConfig) -> float:
	var radius := clampi(cfg.load_radius_chunks, 0, 4)
	var margin := clampf(cfg.unload_margin_chunks, 0.0, 4.0)
	return (float(radius) + margin) * chunk_size(cfg)


static func chunk_size(cfg: WorldConfig) -> float:
	return WorldGenerator.chunk_size(cfg)


func evict_far() -> void:
	var max_active := max_active()
	var anchor := target_center()
	var keep_r := keep_radius_m(config)
	# 1) Всё, что дальше радиуса, выгружаем независимо от количества: иначе игрок,
	#    уехавший по проспекту, тащил за собой «лишние» чанки в памяти.
	if chunks.size() > max_active:
		for index in chunks.keys():
			var far_dist := _chunk_center(index as Vector2i).distance_to(anchor)
			if far_dist <= keep_r:
				continue
			var far_chunk = chunks.get(index)
			if far_chunk == null:
				continue
			(far_chunk as WorldChunk).unload()
			far_chunk.queue_free()
			chunks.erase(index)
			freed_total += 1
			chunk_unloaded.emit(index)
	# 2) Осталось «много» — режем по близости до budget-размера.
	if chunks.size() <= max_active + 2:
		return
	var keep: Array = []
	for index in chunks.keys():
		var dist := _chunk_center(index as Vector2i).distance_to(anchor)
		keep.append({"index": index, "dist": dist})
	keep.sort_custom(_by_distance_evict)
	var limit := maxi(max_active, 1)
	for i in range(limit, keep.size()):
		var index: Vector2i = keep[i]["index"]
		var chunk = chunks.get(index)
		if chunk == null:
			continue
		(chunk as WorldChunk).unload()
		chunk.queue_free()
		chunks.erase(index)
		freed_total += 1
		chunk_unloaded.emit(index)

static func _by_distance_evict(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) > float(b["dist"])

## LOD по дистанции до ближайшей точки чанка + гистерезис через таймер обновления.
func update_lods() -> void:
	if config == null:
		return
	var anchor := target_center()
	var bias := PerformanceManager.lod_bias()
	var cull := maxf(config.cull_distance_m * bias, 200.0)
	for index in chunks.keys():
		var chunk := chunks[index] as WorldChunk
		if chunk == null:
			continue
		var dist := chunk.distance_to_point(anchor)
		var lod := lod_for_distance(dist, config, bias)
		if lod == WorldChunk.LOD_HIDDEN and dist > cull:
			# Дальше радиуса отсечения геометрию можно отпустить совсем.
			chunk.unload()
			chunks.erase(index)
			freed_total += 1
			chunk.queue_free()
			continue
		chunk.set_lod(lod)

static func lod_for_distance(dist: float, cfg: WorldConfig, bias: float = 1.0) -> int:
	var detail := cfg.detail_distance_m * bias
	var lod1 := cfg.lod1_distance_m * bias
	var lod2 := cfg.lod2_distance_m * bias
	if dist <= detail:
		return WorldChunk.LOD_NEAR
	if dist <= lod1:
		return WorldChunk.LOD_MID
	if dist <= lod2:
		return WorldChunk.LOD_FAR
	return WorldChunk.LOD_HIDDEN

## Кольцо чанков вокруг центра (включая сам центр), квадратом — быстрее и «покрывает» углы.
static func chunk_ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			out.append(center + Vector2i(dx, dz))
	return out

func max_active() -> int:
	var from_radius := int(pow(float(2 * clampi(config.load_radius_chunks, 0, 4) + 1), 2))
	# Пресет качества может только сократить число живых чанков (low: 6 вместо 12), но не
	# должен урезать кольцо загрузки: иначе чанк под ногами не соберётся.
	var configured := config.max_active_chunks
	if PerformanceManager.tier() != null:
		configured = mini(configured, PerformanceManager.max_chunks())
	return clampi(maxi(configured, from_radius), 1, 64)

func inside_world(index: Vector2i) -> bool:
	var center := _chunk_center(index)
	var limit := config.world_radius_m + config.chunk_size_m * 0.5
	return absf(center.x) <= limit and absf(center.z) <= limit

func _chunk_center(index: Vector2i) -> Vector3:
	var size := WorldGenerator.chunk_size(config)
	return Vector3((float(index.x) + 0.5) * size, 0.0, (float(index.y) + 0.5) * size)

func target_center() -> Vector3:
	if target == null:
		return Vector3.ZERO
	# Y игнорируется: LOD/стриминг — плоская задача в XZ (мир не многоуровневый).
	return Vector3(target.global_position.x, 0.0, target.global_position.z)

## Синхронная сборка ВСЕХ чанков в радиусе: нужно для автотестов, скриншотов CI
## и «мировая карта» обязана быть готова до первого кадра, иначе скриншот пустой.
func build_all_immediately(max_chunks: int = 64) -> int:
	if config == null:
		config = GameSetup.get_config("world") as WorldConfig
	var center := desired_center()
	var built := 0
	for index in chunk_ring(center, clampi(config.load_radius_chunks + UNLOAD_EXTRA_CHUNKS, 0, 4)):
		if built >= max_chunks:
			break
		if not inside_world(index):
			continue
		var existing = chunks.get(index)
		if existing != null and (existing as WorldChunk).is_built():
			continue
		_build_chunk(index)
		built += 1
	queue.clear()
	update_lods()
	ready_enough = true
	return built

## Готовность для «загрузочного» экрана: все чанки в радиусе построены.
func is_ready() -> bool:
	return queue.is_empty()

func progress() -> float:
	var wanted := chunks.size() + queue.size()
	if wanted <= 0:
		return 1.0
	return float(chunks.size()) / float(wanted)

func stats() -> Dictionary:
	var near := 0
	var mid := 0
	var far := 0
	var hidden := 0
	var tris := 0
	var instances := 0
	for index in chunks.keys():
		var chunk := chunks[index] as WorldChunk
		if chunk == null:
			continue
		if chunk.lod == WorldChunk.LOD_NEAR:
			near += 1
		elif chunk.lod == WorldChunk.LOD_MID:
			mid += 1
		elif chunk.lod == WorldChunk.LOD_FAR:
			far += 1
		else:
			hidden += 1
		tris += chunk.triangle_count
		instances += chunk.instance_count
	return {
		"loaded": chunks.size(),
		"pending": queue.size(),
		"built_total": built_total,
		"freed_total": freed_total,
		"lod_near": near,
		"lod_mid": mid,
		"lod_far": far,
		"lod_hidden": hidden,
		"triangles": tris,
		"prop_instances": instances,
		"build_ms": build_time_ms,
		"progress": progress(),
	}

## Построен ли чанк под точкой (нужно полиции: не спавниться «в доме, которого ещё нет»).
func is_chunk_built(position: Vector3, cfg: WorldConfig = null) -> bool:
	var effective := cfg if cfg != null else config
	if effective == null:
		return true
	var index := WorldGenerator.chunk_index_for(position, effective)
	var chunk = chunks.get(index)
	return chunk != null and (chunk as WorldChunk).is_built()

func loaded_chunk_count() -> int:
	return chunks.size()

func status_text() -> String:
	var s := stats()
	return "Чанки: %d (рядом %d / средне %d / далеко %d), треугольников %d, инстансов %d, сборка %.1f мс" % [
		int(s["loaded"]), int(s["lod_near"]), int(s["lod_mid"]), int(s["lod_far"]),
		int(s["triangles"]), int(s["prop_instances"]), float(s["build_ms"]),
	]

## Самопроверка для автотестов: детерминированность и непустота ближнего чанка.
func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	if config == null:
		return PackedStringArray(["WorldStreamer: нет WorldConfig"])
	var center := desired_center()
	var first := ChunkBuilder.build(center, config, true)
	var again := ChunkBuilder.build(center, config, true)
	if (first["stats"] as Dictionary).get("buildings") != (again["stats"] as Dictionary).get("buildings"):
		problems.append("стример: пересборка чанка дала другое число зданий — детерминизм сломан")
	problems.append_array(WorldGenerator.validate_layout(center, config))
	problems.append_array(ChunkBuilder.self_check(center, config))
	return problems
