extends Node3D
class_name PoliceManager
## Owns the police fleet: spawning, recycling, per-unit AI and the arrest conditions.
##
## The manager is deliberately the only place that decides *how many* police cars exist and
## *where* they come from. Everything else about a cruiser (how it drives, how it collides,
## how it looks) belongs to the car and its AI.
##
## Spawning rules that keep the chase fair on a phone:
##   * a unit appears on a road node 110..260 m away, behind or beside the player, never in
##     front of their bumper and never inside a building
##   * units beyond the despawn distance are recycled back into the pool instead of being
##     deleted, so a long chase does not allocate
##   * the fleet size is capped by `PoliceConfig.max_active_units` (5 by default: that is the
##     number of AIs a 720p phone can run while the player is drifting)

signal unit_spawned(unit: PoliceCar)
signal unit_despawned(unit: PoliceCar)
signal unit_wrecked(unit: PoliceCar)
signal arrest_progress(ratio: float)
signal player_arrested()
signal chase_escaped()

enum Phase {
	CALM,     ## no police, the player is free to drive
	ALERTED,  ## heat just started, units are driving in
	CHASE,    ## at least one unit has contact
	COOLDOWN, ## after an arrest or an escape
}

var config: PoliceConfig
var world_config: WorldConfig
var graph: RoadGraph
var player: Node3D = null
var materials: MaterialLibrary = null

var phase: int = Phase.CALM
var units: Array[PoliceCar] = []
var ai_instances: Dictionary = {}
var phase_timer: float = 0.0
var spawn_timer: float = 0.0
var arrest_timer: float = 0.0
var units_wrecked: int = 0
var units_spawned_total: int = 0

var _generator := RandomNumberGenerator.new()
var _space_state: PhysicsDirectSpaceState3D = null
var _last_player_position := Vector3.ZERO


func setup(
	p_config: PoliceConfig,
	p_graph: RoadGraph,
	p_player: Node3D,
	p_materials: MaterialLibrary,
	p_world_config: WorldConfig = null
) -> void:
	config = p_config
	graph = p_graph
	player = p_player
	materials = p_materials
	world_config = p_world_config if p_world_config != null else WorldConfig.new()
	_generator.seed = 4242
	_last_player_position = player.global_position if player != null else Vector3.ZERO


func _physics_process(delta: float) -> void:
	if config == null or player == null:
		return
	var world := get_world_3d()
	_space_state = world.direct_space_state if world != null else null
	phase_timer += delta
	_update_phase(delta)
	_update_fleet(delta)
	_update_arrest(delta)
	_last_player_position = player.global_position


## The chase phases. Heat comes from `GameState`, which the world raises while the player is
## seen by a unit and decays when they are not.
func _update_phase(delta: float) -> void:
	var state := _game_state()
	var wanted_units := 0
	if state != null and state.wanted:
		wanted_units = config.units_for_heat(state.heat_level)
	match phase:
		Phase.CALM:
			if wanted_units > 0:
				phase = Phase.ALERTED
				phase_timer = 0.0
				spawn_timer = 0.0
		Phase.ALERTED:
			if _active_count() >= wanted_units:
				phase = Phase.CHASE
				phase_timer = 0.0
			elif wanted_units == 0:
				phase = Phase.CALM
		Phase.CHASE:
			if wanted_units == 0 and _active_count() == 0:
				phase = Phase.COOLDOWN
				phase_timer = 0.0
				chase_escaped.emit()
			elif wanted_units == 0:
				# The player broke contact: the units give up one by one.
				_despawn_until(0)
		Phase.COOLDOWN:
			_despawn_until(0)
			if phase_timer > config.arrest_cooldown:
				phase = Phase.CALM
				phase_timer = 0.0
	# Spawning.
	if wanted_units > _active_count() and phase != Phase.COOLDOWN:
		spawn_timer -= delta
		if spawn_timer <= 0.0:
			spawn_timer = config.spawn_interval_for_heat(maxi(1, _heat_level()))
			_spawn_unit()


## Runs every unit's AI and recycles the ones that are too far away or wrecked for good.
func _update_fleet(delta: float) -> void:
	var to_remove: Array[PoliceCar] = []
	for unit: PoliceCar in units:
		if not is_instance_valid(unit):
			to_remove.append(unit)
			continue
		unit.set_meta("heat_level", _heat_level())
		unit.set_meta("active_units", _active_count())
		var ai: PoliceAI = ai_instances.get(unit.get_instance_id())
		if ai != null:
			ai.update(delta)
		if unit.state == PoliceCar.State.BLOCKED:
			# A blocked unit is recycled: the AI could keep pushing, but a cruiser stuck on a
			# fence is neither fun nor fair for the player.
			to_remove.append(unit)
			continue
		if unit.global_position.distance_to(player.global_position) > config.despawn_distance:
			to_remove.append(unit)
	for unit: PoliceCar in to_remove:
		_despawn(unit)


func _spawn_unit() -> void:
	if units.size() >= config.max_active_units:
		return
	var position := _find_spawn_position()
	if position == Vector3.INF:
		return
	var cruiser := PoliceCar.new()
	cruiser.name = "PoliceUnit%d" % units_spawned_total
	cruiser.unit_index = units.size()
	cruiser.detail_level = CarMeshFactory.DETAIL_HIGH
	add_child(cruiser)
	var forward := player.global_position - position
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		forward = Vector3.FORWARD
	var spawn_transform := Transform3D(Basis().looking_at(-forward.normalized(), Vector3.UP), position + Vector3.UP * 0.6)
	cruiser.reset_to(spawn_transform)
	var ai := PoliceAI.new()
	ai.setup(cruiser, config, graph, player, units.size())
	ai_instances[cruiser.get_instance_id()] = ai
	units.append(cruiser)
	units_spawned_total += 1
	unit_spawned.emit(cruiser)


## Looks for a point on a road that is far enough away from the player and not occluded.
func _find_spawn_position() -> Vector3:
	if graph == null or not graph.is_valid():
		return Vector3.INF
	for attempt in 12:
		var candidate := graph.point_on_road_near(
			player.global_position,
			config.spawn_min_distance,
			config.spawn_max_distance,
			_generator
		)
		if candidate == Vector3.INF:
			continue
		# Never spawn a unit where the player can see it appear from thin air: require the
		# line of sight to be blocked, exactly like a real spawn behind a building.
		var visible := TrajectoryPrediction.has_line_of_sight(
			_space_state, player.global_position, candidate, CollisionLayers.AI_VISION_BLOCKERS
		)
		if visible and attempt < 8:
			continue
		return candidate + Vector3.UP * 0.5
	return Vector3.INF


## Counts down to an arrest while the player is pinned. An arrest is not a fail state that
## happens instantly: the player has a few seconds to escape by accelerating out of the trap.
func _update_arrest(delta: float) -> void:
	if config == null or player == null or phase == Phase.COOLDOWN:
		return
	var player_car := player as CarBody
	var speed := absf(player_car.forward_speed()) if player_car != null else 0.0
	var close_units := 0
	for unit: PoliceCar in units:
		if not is_instance_valid(unit) or unit.is_wrecked():
			continue
		if unit.global_position.distance_to(player.global_position) <= config.arrest_radius:
			close_units += 1
	var pinnable := close_units >= maxi(1, config.min_heat_for_arrest) and speed <= config.arrest_max_player_speed
	if pinnable:
		arrest_timer += delta
		arrest_progress.emit(clampf(arrest_timer / maxf(config.arrest_time, 0.1), 0.0, 1.0))
		if arrest_timer >= config.arrest_time:
			arrest_timer = 0.0
			_complete_arrest()
	else:
		arrest_timer = maxf(0.0, arrest_timer - delta * 1.5)
		if arrest_timer <= 0.0:
			arrest_progress.emit(0.0)


func _complete_arrest() -> void:
	phase = Phase.COOLDOWN
	phase_timer = 0.0
	if player is CarBody:
		(player as CarBody).set_engine_disabled(true)
	_despawn_until(0)
	player_arrested.emit()
	var state := _game_state()
	if state != null:
		state.notify_arrested()
	# The player gets their car back after the cooldown so a run never soft-locks.
	var timer := get_tree().create_timer(config.arrest_cooldown)
	timer.timeout.connect(func() -> void:
		if player is CarBody:
			(player as CarBody).set_engine_disabled(false)
	)


func _despawn_until(count: int) -> void:
	while units.size() > count:
		_despawn(units[units.size() - 1])


func _despawn(unit: PoliceCar) -> void:
	if unit == null:
		return
	var key := unit.get_instance_id()
	if ai_instances.has(key):
		ai_instances.erase(key)
	units.erase(unit)
	unit_despawned.emit(unit)
	if is_instance_valid(unit):
		unit.queue_free()


## Called by the units themselves (a heavy impact wrecks a cruiser for a while).
func notify_unit_wrecked(unit: PoliceCar) -> void:
	units_wrecked += 1
	unit_wrecked.emit(unit)


func _active_count() -> int:
	var total := 0
	for unit: PoliceCar in units:
		if is_instance_valid(unit) and not unit.is_wrecked():
			total += 1
	return total


func _heat_level() -> int:
	var state := _game_state()
	return state.heat_level if state != null else 0


func _game_state() -> Node:
	return get_node_or_null("/root/GameState")


## Highest speed any unit is currently doing (used by the balance test).
func fleet_top_speed() -> float:
	var top := 0.0
	for unit: PoliceCar in units:
		if is_instance_valid(unit):
			top = maxf(top, absf(unit.forward_speed()))
	return top


func statistics() -> Dictionary:
	var by_strategy := {}
	for unit: PoliceCar in units:
		if not is_instance_valid(unit):
			continue
		var ai: PoliceAI = ai_instances.get(unit.get_instance_id())
		if ai == null:
			continue
		var key := ai.strategy_name()
		by_strategy[key] = int(by_strategy.get(key, 0)) + 1
	return {
		"phase": phase,
		"active": _active_count(),
		"total": units.size(),
		"spawned": units_spawned_total,
		"wrecked": units_wrecked,
		"arrest_timer": arrest_timer,
		"strategies": by_strategy,
		"fleet_top_speed": fleet_top_speed(),
	}


func debug_string() -> String:
	var stats := statistics()
	return "police(phase=%d active=%d spawned=%d wrecked=%d arrest=%.1f)" % [
		stats["phase"],
		stats["active"],
		stats["spawned"],
		stats["wrecked"],
		stats["arrest_timer"],
	]
