class_name ChaseManager
extends Node
## Мозг погони: уровень розыска, «тепло», потеря/возврат цели, засады и арест.
##
## ЗНАЧЕНИЯ (только из ChaseConfig/PoliceConfig, магических чисел нет):
##  * wanted растёт, пока игрок быстрый И рядом с патрулями; остывает, если он медленный
##    или ушёл далеко (`wanted_cool_distance_m`);
##  * «цель потеряна» = нет линии видимости дольше `PoliceConfig.lose_time_s` ИЛИ дистанция
##    больше `lose_distance_m` ИЛИ маршрута до игрока нет (тупик/забор) — тогда патрули
##    уходят в патрулирование, а не «магически телепортируются» к игроку;
##  * блокпост запрашивается не чаще, чем раз в `roadblock_lifetime_s`, и только впереди
##    по направлению движения игрока (иначе «стена из ниоткуда»);
##  * статистика сессии пишется в SaveManager пачкой раз в `session_flush_interval_s` —
##    записи на каждый кадр убивают флеш-память телефона.

signal wanted_changed(level: int, previous: int)
signal chase_started
signal chase_ended
signal target_lost
signal target_reacquired
signal roadblock_requested(position: Vector3, lifetime_s: float)
signal unit_rammed(unit: Node, impact_speed_ms: float)
signal arrest_progress(ratio: float)
signal arrested

var chase_config: ChaseConfig = null
var police_config: PoliceConfig = null
var world_config: WorldConfig = null
var arrest: ArrestSystem = null
var target: VehicleRig = null
var units: Array[Node] = []
var wanted: float = 0.0
var wanted_int: int = 0
var heat: float = 0.0
var lost_time_s: float = 0.0
var distance_m: float = INF
var target_speed_kmh: float = 0.0
var engaged: bool = false
var roadblock_cooldown: float = 0.0
var roadblock_active_until: float = 0.0
var roadblock_position: Vector3 = Vector3.ZERO
var ramming_speed_kmh: float = 35.0
var collisions: int = 0
var session_time: float = 0.0
var top_speed_kmh: float = 0.0
var _flush_timer: float = 0.0
var _stats_timer: float = 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	chase_config = GameSetup.get_config("chase") as ChaseConfig
	police_config = GameSetup.get_config("police") as PoliceConfig
	world_config = GameSetup.get_config("world") as WorldConfig
	arrest = ArrestSystem.new()
	arrest.configure(chase_config)
	arrest.arrested.connect(_on_arrested)
	_rng.seed = Time.get_ticks_msec() ^ 0xC45E
	set_physics_process(chase_config == null or chase_config.police_enabled)

func attach_target(rig: VehicleRig) -> void:
	target = rig
	wanted = chase_config.initial_wanted_level if chase_config != null else 1.0
	_refresh_wanted(true)
	distance_m = INF

func detach_target() -> void:
	target = null
	engaged = false
	lost_time_s = 0.0

func register_unit(unit: Node) -> void:
	if not units.has(unit):
		units.append(unit)
	unit.add_to_group("police_units")
	if not unit.crashed.is_connected(_on_unit_crashed):
		unit.crashed.connect(_on_unit_crashed)

func unregister_unit(unit: Node) -> void:
	units.erase(unit)
	if is_instance_valid(unit) and unit.crashed.is_connected(_on_unit_crashed):
		unit.crashed.disconnect(_on_unit_crashed)

func clear_units() -> void:
	for unit in units.duplicate():
		unregister_unit(unit)
	units.clear()
	if arrest != null:
		arrest.reset(&"cleared")

func _physics_process(delta: float) -> void:
	if chase_config == null:
		return
	session_time += delta
	var alive := target != null and is_instance_valid(target)
	var player_speed := absf(target.ground_speed_kmh()) if alive else 0.0
	target_speed_kmh = player_speed
	top_speed_kmh = maxf(top_speed_kmh, player_speed)
	distance_m = _nearest_unit_distance() if alive else INF
	var contact := _units_in_arrest_range()
	var closest := _closest_unit_distance()
	var arrested_now := arrest.update(delta, closest if closest < INF else 9999.0, player_speed, contact)
	if arrested_now:
		# Сцену «задержания» включает игра (она реагирует на фазу), здесь — только сигнал.
		AppState.set_phase(AppState.Phase.ARRESTED)
	arrest_progress.emit(arrest.progress())
	_update_wanted(delta, player_speed, alive)
	_update_engagement(delta, alive)
	_update_roadblock(delta)
	_flush_timer -= delta
	if _flush_timer <= 0.0:
		_flush_timer = chase_config.session_flush_interval_s
		_flush_session()
	_stats_timer -= delta
	if _stats_timer <= 0.0:
		_stats_timer = 0.25
		AppState.update_speed_record(player_speed / 3.6)
		if alive and target != null:
			AppState.add_distance(target.travelled_m_reset())

func _update_wanted(delta: float, player_speed: float, alive: bool) -> void:
	if not alive:
		return
	var gain := 0.0
	if player_speed >= chase_config.wanted_speed_threshold_kmh:
		gain += chase_config.wanted_gain_per_s
	# Преследование «вблизи» и тараны греют сильнее: это то, за что игрок получает 4-й уровень.
	if distance_m < 60.0:
		gain += chase_config.wanted_gain_per_s * 0.6
	wanted += gain * delta
	if player_speed < chase_config.wanted_speed_threshold_kmh * 0.55:
		wanted -= chase_config.wanted_cool_per_s * delta
	if distance_m > chase_config.wanted_cool_distance_m:
		wanted -= chase_config.wanted_cool_per_s * 1.6 * delta
	heat = clampf(heat + gain * delta * 0.35 - delta * 0.06, 0.0, 1.0)
	wanted = clampf(wanted, 0.0, 5.0)
	_refresh_wanted(false)

func _refresh_wanted(force: bool) -> void:
	var next := int(floorf(wanted))
	if next != wanted_int or force:
		var previous := wanted_int
		wanted_int = next
		AppState.update_wanted(next)
		wanted_changed.emit(next, previous)

func _update_engagement(delta: float, alive: bool) -> void:
	if not alive:
		if engaged:
			engaged = false
			chase_ended.emit()
		return
	var out_of_range := distance_m > (police_config.lose_distance_m if police_config != null else 430.0)
	var blind := lost_time_s > (police_config.lose_time_s if police_config != null else 9.0)
	var no_route := false
	if graph() != null and target != null:
		no_route = RoutePlanner.graph_distance(graph(), _any_unit_position(), target.global_position) >= INF * 0.5
	if out_of_range or blind:
		lost_time_s += delta
	if lost_time_s > (police_config.lose_time_s if police_config != null else 9.0) or out_of_range:
		if engaged:
			engaged = false
			target_lost.emit()
			chase_ended.emit()
			# Уровень розыска НЕ обнуляется: потеря цели = пауза погони, а не «простили».
			wanted = maxf(wanted - 0.5, 0.0)
			_refresh_wanted(false)
	else:
		if not engaged:
			engaged = true
			target_reacquired.emit()
			chase_started.emit()

func _update_roadblock(delta: float) -> void:
	roadblock_cooldown = maxf(roadblock_cooldown - delta, 0.0)
	if police_config == null or not engaged or wanted_int < 3:
		return
	var distance := distance_m
	if distance > police_config.roadblock_min_distance_m or roadblock_cooldown > 0.0:
		return
	if _rng.randf() > police_config.roadblock_chance * delta * 2.0:
		return
	var point := _point_ahead_of_target()
	if point == Vector3.ZERO:
		return
	roadblock_position = point
	roadblock_cooldown = police_config.roadblock_lifetime_s
	roadblock_active_until = session_time + police_config.roadblock_lifetime_s
	roadblock_requested.emit(point, police_config.roadblock_lifetime_s)

## Точка впереди игрока по дороге (для засады): ближайший узел графа на 1-2 квартала вперёд.
func _point_ahead_of_target() -> Vector3:
	if target == null or graph() == null:
		return Vector3.ZERO
	var velocity := target.linear_velocity
	if velocity.length_squared() < 1.0:
		return Vector3.ZERO
	var node := RoutePlanner.chase_target_node(graph(), target.global_position, velocity, 1.6, world_config)
	if node < 0:
		return Vector3.ZERO
	return graph().node_position(node)

# ------------------------------------------------------------------ запросы ИИ

func graph() -> RoadGraph:
	return RoadGraph.for_config(world_config)

func wanted_level() -> float:
	return wanted

func roadblock_ready(unit_position: Vector3) -> bool:
	if roadblock_position == Vector3.ZERO or session_time > roadblock_active_until:
		return false
	return unit_position.distance_to(roadblock_position) > 12.0

func roadblock_position_for_ai() -> Vector3:
	return roadblock_position

func target_rig() -> VehicleRig:
	return target

func pursuer_count() -> int:
	var count := 0
	for unit in units:
		if unit != null and unit.ai != null and unit.ai.mode != PoliceStrategy.PATROL:
			count += 1
	return maxi(count, 1)

func nearest_other_unit_distance(from: Vector3) -> float:
	var best := INF
	for unit in units:
		if unit == null or unit.global_position == from:
			continue
		best = minf(best, unit.global_position.distance_to(from))
	return best

func _nearest_unit_distance() -> float:
	return nearest_other_unit_distance(target.global_position) if target != null else INF

func _closest_unit_distance() -> float:
	return _nearest_unit_distance()

func _units_in_arrest_range() -> int:
	if target == null or chase_config == null:
		return 0
	var count := 0
	for unit in units:
		if unit != null and unit.global_position.distance_to(target.global_position) <= chase_config.arrest_distance_m:
			count += 1
	return count

func _any_unit_position() -> Vector3:
	for unit in units:
		if unit != null:
			return unit.global_position
	return target.global_position if target != null else Vector3.ZERO

func report_lost_time(seconds: float) -> void:
	## Патрули сообщают, что «видели цель недавно»: берём минимум, чтобы один
	## патруль, потерявший цель, не ронял погоню, пока остальные ещё видят игрока.
	lost_time_s = minf(lost_time_s, seconds)

func _on_unit_crashed(impact_speed_ms: float, rig: VehicleRig) -> void:
	if chase_config == null or police_config == null or rig == null:
		return
	if impact_speed_ms < ramming_speed_kmh / 3.6:
		return
	collisions += 1
	if target != null and rig != target:
		wanted += 0.08
		heat = clampf(heat + 0.12, 0.0, 1.0)
		_refresh_wanted(false)
		unit_rammed.emit(rig, impact_speed_ms)

func _on_arrested() -> void:
	arrested.emit()
	# После задержания «тепло» сбрасывается: игрок получает паузу и новый заезд, а не
	# вечно живущий 5-й уровень.
	heat = 0.0
	wanted = maxf(wanted - 1.0, 0.0)
	lost_time_s = 0.0
	_refresh_wanted(false)

func _flush_session() -> void:
	var data := snapshot()
	if data.is_empty():
		return
	var save := get_node_or_null("/root/SaveManager")
	if save != null and save.has_method("record_session"):
		save.call("record_session", data)

func snapshot() -> Dictionary:
	return {
		"session_time_s": session_time,
		"top_speed_kmh": top_speed_kmh,
		"max_wanted_level": wanted_int,
		"collisions_with_police": collisions,
		"arrests": arrest.arrests if arrest != null else 0,
		"engaged": engaged,
		"distance_to_nearest_unit_m": distance_m,
		"heat": heat,
		"lost_time_s": lost_time_s,
	}

func status_text() -> String:
	var level := "уровень %d" % wanted_int
	if wanted - float(wanted_int) > 0.05:
		level += " (+%.0f%%)" % ((wanted - float(wanted_int)) * 100.0)
	var tail := ""
	if not engaged:
		tail = " | цель потеряна %.1f с" % lost_time_s
	else:
		tail = " | цель %.0f м, скорость %.0f км/ч" % [distance_m, target_speed_kmh]
	return "%s, патрулей %d%s" % [level, units.size(), tail]

func state() -> Dictionary:
	return {
		"wanted": wanted,
		"wanted_int": wanted_int,
		"heat": heat,
		"engaged": engaged,
		"units": units.size(),
		"distance_m": distance_m,
		"lost_time_s": lost_time_s,
		"roadblock_cooldown": roadblock_cooldown,
		"arrest": arrest.state() if arrest != null else {},
	}

## Автотест-хук: «потеря цели» и «переключение режима» должны работать без физики.
static func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	var chase := ChaseConfig.new()
	var police := PoliceConfig.new()
	# wanted -> число патрулей обязано расти с уровнем розыска.
	var previous := -1
	for level in range(1, 6):
		var units := PoliceStrategy.wanted_units(float(level), police)
		if units < previous:
			problems.append("chase: на уровне %d патрулей %d (было %d) — не монотонно" % [level, units, previous])
		previous = units
	if PoliceStrategy.wanted_units(0.0, police) != 0:
		problems.append("chase: при wanted=0 патрули должны сходить на нет")
	if police.max_units > 0 and PoliceStrategy.wanted_units(5.0, police) > police.max_units:
		problems.append("chase: units_per_wanted_level[5]=%d больше max_units=%d" % [
			PoliceStrategy.wanted_units(5.0, police), police.max_units])
	problems.append_array(ArrestSystem.self_check())
	return problems
