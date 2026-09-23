class_name PoliceAI
extends Node
## Исполнитель тактики патруля: руль, педали, ручник, заявка на нитро.
##
## СЛОИРОВАНИЕ (см. PoliceStrategy — там решения, здесь — руки): AI НЕ решает «какая
## тактика», он только превращает решение в DriveInput. Поэтому «переключение стратегий»
## тестируется без физики (PoliceStrategy.self_check), а «не влетает ли патруль в дома» —
## тестами руления (steer_towards).
##
## АВТОПИЛОТ: контроллер переведён в `override_input` (VehicleController.set_autopilot),
## т.е. ИИ пишет в тот же DriveInput, что и палец игрока в виртуальный стик. Никаких
## «прямых» apply_impulse для поворота — иначе поведение ИИ отличалось бы от поведения
## игрока, и баланс «полиция чуть быстрее игрока» ломался бы.
##
## ЧУВСТВА: цель обновляется раз в `sense_interval_s` (не каждый кадр) + шум + проверка
## видимости лучом. Реакция `PoliceConfig.reaction_time_s` вносит задержку, иначе патруль
## «читает» игрока насквозь и уворачивается идеально.

signal mode_changed(mode: StringName, reason: StringName)
signal unit_blocked(unit: Node)

@export var sense_interval_s: float = 0.14
@export var speed_gain: float = 0.055
@export var brake_gain: float = 0.075
@export var steer_deadzone: float = 0.045
@export var los_mask: int = 5

var rig: VehicleRig = null
var physics: VehiclePhysics = null
var controller: VehicleController = null
var chase: Node = null
var police_config: PoliceConfig = null
var chase_config: ChaseConfig = null
var world_config: WorldConfig = null
var graph: RoadGraph = null
var nav := NavigationManager.new()
var autopilot := DriveInput.new()
var mode: StringName = PoliceStrategy.PATROL
var mode_reason: StringName = &"init"
var unit_index: int = 0
var target_rig: VehicleRig = null
var target_position: Vector3 = Vector3.ZERO
var target_velocity: Vector3 = Vector3.ZERO
var distance_m: float = INF
var graph_distance_m: float = INF
var has_line_of_sight: bool = false
var lost_time_s: float = 0.0
var engaged_time_s: float = 0.0
var reaction_timer: float = 0.0
var desired_speed_kmh: float = 40.0
var nitro_wanted: bool = false
var reverse_time_s: float = 0.0
var _sense_timer: float = 0.0
var _enabled: bool = true
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var parent := get_parent()
	rig = parent as VehicleRig
	if rig == null:
		push_error("PoliceAI: родитель обязан быть VehicleRig (PoliceCar)")
		set_physics_process(false)
		return
	police_config = GameSetup.get_config("police") as PoliceConfig
	chase_config = GameSetup.get_config("chase") as ChaseConfig
	world_config = GameSetup.get_config("world") as WorldConfig
	physics = rig.physics
	controller = rig.controller
	graph = RoadGraph.for_config(world_config)
	_rng.seed = absi(hash(rig.get_instance_id())) ^ 0x51ED
	nav.setup(graph, police_config, chase_config)
	if controller != null:
		controller.set_autopilot(autopilot)

func configure(p_chase: Node, p_index: int) -> void:
	chase = p_chase
	unit_index = p_index

func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		clear_input()

func clear_input() -> void:
	autopilot.reset()
	autopilot.source = "police_ai_idle"
	nitro_wanted = false

func _physics_process(delta: float) -> void:
	if rig == null or physics == null or controller == null:
		return
	if not _enabled or not AppState.is_playing():
		clear_input()
		return
	_sense_timer -= delta
	if _sense_timer <= 0.0:
		_sense_timer = maxf(sense_interval_s, 0.02)
		_sense()
	reaction_timer = maxf(reaction_timer - delta, 0.0)
	_think(delta)
	_drive(delta)

# ------------------------------------------------------------------ чувства

func _sense() -> void:
	target_rig = null
	if chase != null and chase.has_method("target_rig"):
		target_rig = chase.call("target_rig") as VehicleRig
	if target_rig == null or not is_instance_valid(target_rig):
		lost_time_s += sense_interval_s
		has_line_of_sight = false
		distance_m = INF
		graph_distance_m = INF
		return
	var raw_position := target_rig.global_position
	# Шум сенсора: без него ИИ едет «по пикселю» и выглядит читером.
	var jitter := (_rng.randf() - 0.5) * 0.7
	target_position = raw_position + Vector3(jitter, 0.0, -jitter * 0.6)
	target_velocity = target_rig.linear_velocity
	distance_m = rig.global_position.distance_to(raw_position)
	graph_distance_m = RoutePlanner.graph_distance(graph, rig.global_position, raw_position) \
			if graph != null else distance_m
	has_line_of_sight = _check_line_of_sight(raw_position)
	if has_line_of_sight:
		lost_time_s = 0.0
		engaged_time_s += sense_interval_s
	else:
		lost_time_s += sense_interval_s
	reaction_timer = police_config.reaction_time_s if police_config != null else 0.2

func _check_line_of_sight(towards: Vector3) -> bool:
	if distance_m > (police_config.engage_distance_m * 2.4 if police_config != null else 420.0):
		return false
	var space := rig.get_world_3d().direct_space_state
	var from := rig.global_position + Vector3(0.0, 0.9, 0.0)
	var to := towards + Vector3(0.0, 0.5, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, los_mask, [rig.get_rid()])
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return true
	return hit.get("collider", null) == target_rig

func _ctx() -> Dictionary:
	var wanted := 0.0
	if chase != null and chase.has_method("wanted_level"):
		wanted = float(chase.call("wanted_level"))
	var pursuers := 1
	if chase != null and chase.has_method("pursuer_count"):
		pursuers = maxi(int(chase.call("pursuer_count")), 1)
	return {
		"enabled": (chase_config == null or chase_config.police_enabled) and (police_config != null),
		"wanted": wanted,
		"distance_m": distance_m,
		"graph_distance_m": graph_distance_m,
		"speed_kmh": rig.ground_speed_kmh(),
		"target_speed_kmh": target_rig.ground_speed_kmh() if target_rig != null else 0.0,
		"lost_time_s": lost_time_s,
		"has_los": has_line_of_sight,
		"units_in_pursuit": pursuers,
		"unit_index": unit_index,
		"can_ram": _room_to_ram(),
		"nitro_allowed": police_config != null and police_config.ram_offset_m > 0.0,
		"roadblock_ready": chase != null and chase.has_method("roadblock_ready") \
				and bool(chase.call("roadblock_ready", rig.global_position)),
		"target_alive": target_rig != null and is_instance_valid(target_rig),
	}

## «Есть ли куда таранить»: если между нами и целью уже стоит другой патруль, таранить
## бессмысленно — они сложатся в кучу (классический баг погонь в аркадах).
func _room_to_ram() -> bool:
	if chase == null or not chase.has_method("nearest_other_unit_distance"):
		return true
	return float(chase.call("nearest_other_unit_distance", rig.global_position)) > 4.5

# ------------------------------------------------------------------ решения

func _think(delta: float) -> void:
	var decision := PoliceStrategy.decide(_ctx(), police_config, chase_config)
	var next_mode := decision["mode"] as StringName
	if next_mode != mode:
		mode = next_mode
		mode_reason = decision["reason"] as StringName
		mode_changed.emit(mode, mode_reason)
		nav.reset()
		if mode == PoliceStrategy.PURSUE or mode == PoliceStrategy.INTERCEPT:
			engaged_time_s = 0.0
	desired_speed_kmh = float(decision["speed_target_kmh"])
	nitro_wanted = bool(decision["allow_nitro"]) and distance_m > 55.0
	autopilot.source = "police_ai:%s" % String(mode)

	if mode == PoliceStrategy.IDLE:
		return
	var target_ok := target_rig != null and is_instance_valid(target_rig)
	var need_repath := not nav.has_path() or nav.update(delta, rig.global_position, rig.ground_speed_kmh())
	if need_repath:
		if target_ok:
			nav.retarget(target_position, target_velocity, rig.global_position, mode == PoliceStrategy.PATROL)
		else:
			_patrol_destination()
	if mode == PoliceStrategy.BLOCK or mode == PoliceStrategy.PINCER:
		desired_speed_kmh *= 0.95

func _patrol_destination() -> void:
	if graph == null or graph.node_count() == 0:
		return
	# Патруль = «уехать от того узла, откуда приехали»: цикл по кварталам без застреваний.
	var here := graph.nearest(rig.global_position, 0.0)
	if here < 0:
		return
	var neighbors := graph.neighbors(here)
	if neighbors.is_empty():
		return
	var pick := neighbors[_rng.randi_range(0, neighbors.size() - 1)]
	var found := RoutePlanner.find_path(graph, here, pick)
	if not found.is_empty():
		nav.path = found
		nav.index = 1 if found.size() > 1 else 0

# ------------------------------------------------------------------ руление

func _drive(_delta: float) -> void:
	if rig == null:
		return
	var speed := absf(rig.ground_speed_kmh())
	var want_point := _aim_point(speed)
	if want_point == Vector3.INF:
		clear_input()
		return
	var error := _lateral_error(want_point)
	var ahead := _forward_distance(want_point)
	# 1) Руль: пропорционально углу до точки прицела, нормирован на полный угол руля.
	var limit := deg_to_rad(police_config.steering_sharpness * 12.0) if police_config != null else 0.6
	var steer := clampf(atan2(error, maxf(ahead, 1.2)) / maxf(limit, 0.08), -1.0, 1.0)
	if absf(steer) < steer_deadzone:
		steer = 0.0
	# разворот через ручник, если цель сзади и мы почти встали
	var need_u_turn := ahead < -3.0 and speed < 22.0
	# 2) Скорость: вход в поворот ограничен сцеплением, иначе «полиция в стенах».
	var corner := _corner_limit(speed)
	var target_speed := minf(desired_speed_kmh, corner)
	var diff := target_speed - speed
	var throttle := clampf(diff * speed_gain, 0.0, 1.0)
	var brake := clampf(-diff * brake_gain, 0.0, 1.0)
	var handbrake := 0.0
	if need_u_turn:
		handbrake = 1.0
		brake = 1.0
	elif absf(steer) > 0.8 and speed > 70.0 and mode != PoliceStrategy.PATROL:
		handbrake = 0.35
	if controller != null and controller.is_blocked:
		throttle = 0.0
		brake = 0.0
		_reverse_out(speed)
	if rig.physics != null and rig.physics.airborne_time > 0.35:
		# В воздухе руль и газ только ухудшают приземление (момент инерции + тяга).
		throttle = 0.0
		brake = 0.0
		steer *= 0.25
		handbrake = 0.0
	autopilot.steer = steer
	autopilot.throttle = throttle
	autopilot.brake = brake
	autopilot.handbrake = handbrake
	autopilot.steer_absolute = false
	if rig.nitro != null:
		rig.nitro.set_requested(nitro_wanted and throttle > 0.5 and speed > 40.0)

func _aim_point(speed: float) -> Vector3:
	var point := nav.waypoint()
	if point == Vector3.ZERO and target_rig != null and is_instance_valid(target_rig) and mode != PoliceStrategy.PATROL:
		point = target_position
	if point == Vector3.ZERO:
		return Vector3.INF
	# «Взгляд вперёд» зависит от скорости: на 150 км/ч целимся дальше, иначе ИИ режет
	# перекрёстики по диагонали и влетает в углы.
	var lookahead := VehicleMath.lookahead_point(rig.global_position, (point - rig.global_position), speed / 3.6, 7.0)
	return point.lerp(lookahead, 0.35) if speed > 25.0 else point

func _lateral_error(point: Vector3) -> float:
	if rig == null:
		return 0.0
	var local := rig.global_transform.affine_inverse() * point
	return local.x

func _forward_distance(point: Vector3) -> float:
	if rig == null:
		return 0.0
	var local := rig.global_transform.affine_inverse() * point
	return -local.z

func _corner_limit(speed: float) -> float:
	if physics == null:
		return INF
	var point := nav.waypoint()
	if point == Vector3.ZERO:
		return INF
	var to := point - rig.global_position
	to.y = 0.0
	var distance := maxf(to.length(), 2.0)
	var heading := rig.forward_direction()
	var cross := absf(heading.x * to.normalized().z - heading.z * to.normalized().x)
	var radius := maxf(distance / maxf(cross, 0.05), 8.0)
	var limit := physics.grip_limited_speed_kms(1.0 / radius)
	return maxf(limit, 18.0) if speed > 18.0 else limit

func _reverse_out(_speed: float) -> void:
	# Разворот «из тупика»: сдаём назад ровно `police_config.stuck_time_s * 0.5` секунд.
	var limit := (police_config.stuck_time_s if police_config != null else 2.6) * 0.5
	reverse_time_s = limit
	autopilot.throttle = -0.75
	autopilot.brake = 0.0
	autopilot.steer = -signf(autopilot.steer)
	# Возврат в «построение маршрута» — после отката навигация перестроится сама.
	nav.retarget(target_position, target_velocity, rig.global_position, true)

func debug_line() -> String:
	return "%s (цель %.0f м, по графу %.0f м, LOS %s, %s)" % [
		PoliceStrategy.mode_name(mode), distance_m, graph_distance_m,
		"есть" if has_line_of_sight else "нет", nav.debug_line(),
	]

func state() -> Dictionary:
	return {
		"mode": String(mode),
		"mode_name": PoliceStrategy.mode_name(mode),
		"reason": String(mode_reason),
		"distance_m": distance_m,
		"graph_distance_m": graph_distance_m,
		"has_los": has_line_of_sight,
		"lost_time_s": lost_time_s,
		"engaged_time_s": engaged_time_s,
		"desired_speed_kmh": desired_speed_kmh,
		"speed_kmh": rig.ground_speed_kmh() if rig != null else 0.0,
		"nitro_wanted": nitro_wanted,
		"nav": nav.state(),
		"autopilot": autopilot.to_dict(),
	}
