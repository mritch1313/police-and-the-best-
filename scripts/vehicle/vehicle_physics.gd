class_name VehiclePhysics
extends Node
## Физика автомобиля: собственный силовой слой поверх [RigidBody3D].
##
## Почему не [VehicleBody3D]: нужны ручник с управляемым заносом, нитро как *тяга*
## (а не множитель скорости), раздельные Mu по осям, перенос массы, крены через
## стабилизаторы, предсказуемое поведение ИИ и единая математика с автотестами.
## Поэтому: RigidBody3D даёт массу, инерцию, коллизии, гравитацию и отклики
## (всё считает физический движок Godot), а здесь считаются силы.
##
## ГЛАВНОЕ ОГРАНИЧЕНИЕ АРХИТЕКТУРЫ: сюда запрещено писать позицию/трансформ.
## `state.transform` только читается. Перемещение — исключительно результат работы
## физического движка (включая нитро: оно меняет силу и потолок скорости, не координаты).
##
## Единицы: СИ. Масса RigidBody3D = масса машины в кг (GodotPhysics не привязан
## к «игровым» единицам массы; Jolt этого не любит — см. docs/GRAPHICS_AND_PERF.md).
##
## Порядок кадра:
##   1. `_physics_process` — лучи подвески и проба высоты (запросы в space state
##      вне интеграции);
##   2. `_integrate_forces` — силы: привод, тормоза, шина, подвеска, аэро,
##      стабилизаторы, демпфирование рыскания, удержание на уклоне.

signal grounded_changed(is_grounded: bool)
signal crashed(impact_speed_ms: float, other: Object)
signal config_applied

## Кто «сидит за рулём»: [DriveInput] заполняет [VehicleController] (игрок) или
## [PoliceAI] (патруль) — физике всё равно.
var input: DriveInput = DriveInput.new()
var wheels: WheelSystem = WheelSystem.new()
var config: VehicleConfig = null
var body: RigidBody3D = null
## [NitroSystem] игрока (может быть null). Физика спрашивает у него только множители.
var nitro: Node = null
## Внешний множитель сцепления (дождь/баланс ИИ).
var grip_multiplier: float = 1.0
## Потолок скорости извне (км/ч), 0 = использовать config.max_speed_kmh.
## Так ChaseManager «придерживает» патруль, не ломая физику.
var speed_cap_override_kmh: float = 0.0
var enabled: bool = true

## --- Телеметрия: обновляется каждый физический кадр, читается UI/ИИ/тестами ---
var speed_kms: float = 0.0
var forward_speed_kms: float = 0.0
var lateral_speed_kms: float = 0.0
var accel_long: float = 0.0
var accel_lat: float = 0.0
var yaw_rate: float = 0.0
var drift_ratio: float = 0.0
var tyre_saturation: float = 0.0
var slip_energy: float = 0.0
var grounded_count: int = 4
var is_grounded: bool = true
var airborne_time: float = 0.0
var engine_rpm: float = 0.0
var gear: int = 0
var steer_angle: float = 0.0
var contact_normal: Vector3 = Vector3.UP
var suspension_load: float = 0.0
var height_above_ground: float = 0.0
var blocked_time: float = 0.0
var drive_force_now: float = 0.0
var impact_speed_ms: float = 0.0

var yaw_rate_previous: float = 0.0
var _previous_velocity: Vector3 = Vector3.ZERO
var _had_previous: bool = false
var _was_grounded: bool = true
var _smooth_impulse: float = 0.0

func _ready() -> void:
	if config == null:
		config = _find_ancestor_config()
	if body == null:
		body = get_parent() as RigidBody3D
	if config == null:
		push_error("VehiclePhysics: не найден VehicleConfig (назначьте его в инспекторе)")
		set_physics_process(false)
		return
	if body == null:
		push_error("VehiclePhysics: родитель должен быть RigidBody3D")
		set_physics_process(false)
		return
	apply_config(config)

func _find_ancestor_config() -> VehicleConfig:
	var node: Node = get_parent()
	while node != null:
		if node.has_method("get_vehicle_config"):
			return node.call("get_vehicle_config") as VehicleConfig
		node = node.get_parent()
	return null

## Сменить конфигурацию на лету (другая машина, тест, отладка).
func apply_config(p_config: VehicleConfig, p_gravity: float = -1.0) -> void:
	if p_config == null or body == null:
		return
	config = p_config
	var g := p_gravity
	if g <= 0.0:
		g = absf(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	wheels.setup(config, g)
	body.mass = maxf(config.mass_kg, 50.0)
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_OVERRIDE
	body.center_of_mass = Vector3(0.0, -config.center_of_mass_drop_m, 0.0)
	body.contact_monitor = true
	body.max_contacts_reported = 6
	body.custom_integrator = false
	# Сон запрещён принципиально: спящее тело не вызывает `_integrate_forces`, а в 4.7
	# у RigidBody3D нет `wake_up()` — «постоял на светофоре, и машина не едет» было бы
	# неуловимым багом. Полиция/игрок всегда активны (см. docs/PHYSICS.md).
	body.can_sleep = false
	body.collision_layer = config.collision_layer
	body.collision_mask = config.collision_mask
	config_applied.emit()

func _physics_process(delta: float) -> void:
	if not _can_run():
		return
	var space := body.get_world_3d().direct_space_state
	wheels.cast_rays(space, body.global_transform, [body.get_rid()], config.wheel_ray_mask, delta)
	height_above_ground = _probe_height(space, body.global_transform.origin)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if config == null or state == null or not enabled:
		return
	var dt := maxf(state.step, 0.0005)
	var xf := state.transform
	var basis := xf.basis
	var velocity := state.linear_velocity
	var angular := state.angular_velocity
	var origin := xf.origin

	# Локальные оси кузова: X вправо, Y вверх, -Z вперёд.
	var v_local := basis.xform_inv(velocity)
	var w_local := basis.xform_inv(angular)
	var forward_speed := -v_local.z
	var right_speed := v_local.x
	var speed := velocity.length()
	var planar := Vector3(velocity.x, 0.0, velocity.z)

	# Ускорение кузова (для переноса массы) — из разницы скоростей соседних кадров.
	if _had_previous:
		var delta_local := basis.xform_inv(velocity - _previous_velocity) / dt
		accel_long = lerpf(accel_long, -delta_local.z, 0.5)
		accel_lat = lerpf(accel_lat, delta_local.x, 0.5)
	_had_previous = true
	_previous_velocity = velocity

	var grip := grip_multiplier
	var nitro_speed_mult := 1.0
	var nitro_thrust := 1.0
	if nitro != null and nitro.has_method("physics_multipliers"):
		var mult: Dictionary = nitro.call("physics_multipliers")
		nitro_speed_mult = float(mult.get("speed", 1.0))
		nitro_thrust = float(mult.get("thrust", 1.0))
		grip *= float(mult.get("grip", 1.0))

	var limit_kms := VehicleMath.speed_limit_kms(config, nitro_speed_mult)
	if speed_cap_override_kmh > 0.0:
		limit_kms = minf(limit_kms, speed_cap_override_kmh / 3.6)

	var handbrake := clampf(input.handbrake, 0.0, 1.0)
	var brake_strength := clampf(input.brake, 0.0, 1.0)
	var throttle := clampf(input.throttle, -1.0, 1.0)

	steer_angle = input.steer if input.steer_absolute else _steer_from_input(forward_speed, dt)

	var downforce := VehicleMath.downforce(config, absf(forward_speed))
	var loads := VehicleMath.weight_transfer(config, accel_long, accel_lat, downforce)
	wheels.compute_suspension_forces(loads)

	var drive_total := _drive_force(forward_speed, throttle, limit_kms, nitro_thrust)
	drive_force_now = drive_total
	var aero_drag := VehicleMath.resistance_force(config, speed, nitro_speed_mult)
	var engine_brake := VehicleMath.engine_brake_torque(config, engine_rpm)

	grounded_count = wheels.grounded_count()
	var now_grounded := grounded_count > 0
	if now_grounded != _was_grounded:
		grounded_changed.emit(now_grounded)
		_was_grounded = now_grounded
	if now_grounded:
		airborne_time = 0.0
	else:
		airborne_time += dt
	is_grounded = now_grounded

	var load_on_driven := 0.0
	for w in wheels.wheels:
		if w.is_driven and w.grounded:
			load_on_driven += w.load
	var applied_force := Vector3.ZERO
	var applied_torque := Vector3.ZERO
	suspension_load = 0.0

	for w in wheels.wheels:
		if not w.grounded:
			w.tyre_force_local = Vector2.ZERO
			w.force_world = Vector3.ZERO
			w.spin = lerpf(w.spin, forward_speed / maxf(config.wheel_radius_m, 0.05), minf(dt * 1.5, 1.0))
			w.slip_ratio = 0.0
			w.slip_angle = 0.0
			w.locked = false
			continue
		var wheel_basis := basis.rotated(Vector3.UP, -w.steer_angle)
		var fwd := -wheel_basis.z
		var rgt := wheel_basis.x
		var arm := w.contact_global - origin
		var v_contact := velocity + angular.cross(arm)
		var long_v := v_contact.dot(fwd)
		var lat_v := v_contact.dot(rgt)

		var mu := w.mu * grip
		if handbrake > 0.01 and w.is_rear():
			mu = lerpf(mu, config.grip_handbrake_mu * grip, handbrake)
		var force_limit := maxf(mu * w.load, 1.0)

		var wheel_drive_force := 0.0
		if w.is_driven and load_on_driven > 1.0 and absf(drive_total) > 0.01:
			# Тяга распределяется по загрузке: вывешенное колесо не «разгоняет» машину.
			wheel_drive_force = drive_total * w.load / load_on_driven
		wheel_drive_force = clampf(wheel_drive_force, -force_limit, force_limit)
		var drive_torque := wheel_drive_force * config.wheel_radius_m
		if absf(throttle) < 0.005:
			drive_torque = -signf(long_v) * engine_brake * (1.0 if w.is_driven else 0.35)

		var brake_share := 0.58 if w.is_front else 0.42
		var brake_effort := clampf(brake_strength * brake_share + handbrake * (0.0 if w.is_front else 0.85), 0.0, 1.0)
		var brake_torque := VehicleMath.brake_torque(
			config, w.load, mu / maxf(grip, 0.01), brake_effort, handbrake > 0.01 and w.is_rear()
		)

		wheels.update_wheel_spin(w, drive_torque, brake_torque, long_v, force_limit, dt)
		if w.locked:
			mu *= config.wheel_lock_grip_factor
			force_limit = maxf(mu * w.load, 1.0)

		w.slip_angle = VehicleMath.slip_angle(lat_v, long_v)
		var tyre := VehicleMath.tyre_force(w.load, mu, w.slip_ratio, w.slip_angle, config)
		# Физический потолок: сила не может за один кадр обратить компоненту скорости кузова.
		var max_long_step := config.mass_kg * 0.25 * absf(long_v) / dt
		var max_lat_step := config.mass_kg * 0.25 * absf(lat_v) / dt
		tyre.x = clampf(tyre.x, -max(max_long_step, force_limit), max(max_long_step, force_limit))
		tyre.y = clampf(tyre.y, -max(max_lat_step, force_limit), max(max_lat_step, force_limit))
		w.tyre_force_local = tyre

		var force := fwd * tyre.x + rgt * tyre.y + w.normal_global * w.suspension_force
		suspension_load += w.suspension_force
		w.force_world = force
		applied_force += force
		applied_torque += arm.cross(force)

	if planar.length_squared() > 0.0004:
		applied_force += -planar.normalized() * aero_drag

	applied_torque += basis.y * VehicleMath.yaw_damping_torque(config, w_local.y, config.yaw_damping)
	if not now_grounded and config.air_control_torque_n > 0.0:
		applied_torque += basis.y * (-input.steer) * config.air_control_torque_n * 0.5
		applied_torque += basis.x * clampf(-throttle, -1.0, 1.0) * config.air_control_torque_n * 0.22

	# Держим машину на месте/на уклоне, пока игрок не дал газ.
	if now_grounded and speed < 1.4 and absf(throttle) < 0.02:
		var hold := -planar * config.mass_kg * 6.0
		var hold_cap := config.hold_force_n * 4.0 * maxf(float(grounded_count) / 4.0, 0.25)
		if hold.length() > hold_cap:
			hold = hold.normalized() * hold_cap
		applied_force += hold

	state.apply_central_force(applied_force)
	if applied_torque.length_squared() > 0.000001:
		state.apply_torque(applied_torque)

	_process_contacts(state, dt)

	speed_kms = speed * 3.6
	forward_speed_kms = forward_speed * 3.6
	lateral_speed_kms = right_speed * 3.6
	yaw_rate = w_local.y
	drift_ratio = VehicleMath.drift_magnitude(lateral_speed_kms, forward_speed_kms)
	tyre_saturation = wheels.max_saturation()
	slip_energy = wheels.total_slip_energy() * 0.0002
	contact_normal = wheels.average_normal()
	yaw_rate_previous = w_local.y
	gear = VehicleMath.gear_for_speed(config, forward_speed)
	engine_rpm = VehicleMath.engine_rpm(config, forward_speed, gear)
	blocked_time = _update_blocked(dt, speed)

func _can_run() -> bool:
	return enabled and body != null and config != null

func _probe_height(space: PhysicsDirectSpaceState3D, from: Vector3) -> float:
	if space == null or config == null:
		return 0.0
	var probe := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -8.0, 0.0), config.wheel_ray_mask, [])
	)
	if probe.is_empty():
		return 0.0
	return from.y - float(probe.get("position", from)).y

func _drive_force(forward_speed: float, throttle: float, limit_kms: float, nitro_thrust: float) -> float:
	return VehicleMath.drive_force_limited(config, forward_speed, throttle, limit_kms, nitro_thrust)

## Угол руля: скорость поворота зависит от скорости машины (на месте — полный угол).
func _steer_from_input(forward_speed: float, dt: float) -> float:
	var limit := VehicleMath.steer_limit_rad(config, absf(forward_speed))
	var target := clampf(input.steer, -1.0, 1.0) * limit
	var going_out := absf(target) > absf(steer_angle)
	var rate_deg := config.steer_speed_in_deg_s if going_out else config.steer_speed_out_deg_s
	var rate := deg_to_rad(rate_deg) * limit / maxf(deg_to_rad(config.max_steer_deg), 0.01)
	if absf(input.steer) < 0.02 and absf(forward_speed) < config.steer_return_deadzone_kmh / 3.6:
		rate = deg_to_rad(config.steer_speed_out_deg_s) * 0.5
	return move_toward(steer_angle, target, rate * dt)

func _process_contacts(state: PhysicsDirectBodyState3D, dt: float) -> void:
	var count := state.get_contact_count()
	var strongest := 0.0
	var other: Object = null
	for i in range(count):
		var impulse := absf(state.get_contact_impulse(i))
		if impulse > strongest:
			strongest = impulse
			other = state.get_contact_collider_object(i)
	# Импульс (кг*м/с) -> условная скорость удара (м/с).
	var impact := strongest / maxf(config.mass_kg, 1.0)
	_smooth_impulse = lerpf(_smooth_impulse, impact, clampf(dt * 14.0, 0.0, 1.0))
	impact_speed_ms = _smooth_impulse
	if impact > 1.1 and _smooth_impulse < impact * 0.85:
		crashed.emit(impact, other)

func _update_blocked(dt: float, speed: float) -> float:
	var wants_to_move := absf(input.throttle) > 0.15 and input.brake < 0.1 and input.handbrake < 0.5
	if wants_to_move and speed < 1.2:
		return blocked_time + dt
	return maxf(blocked_time - dt * 3.0, 0.0)

# ---------------------------------------------------------------- API для UI / ИИ / тестов

func snapshot() -> Dictionary:
	return {
		"speed_kms": speed_kms,
		"forward_kms": forward_speed_kms,
		"lateral_kms": lateral_speed_kms,
		"accel_long": accel_long,
		"accel_lat": accel_lat,
		"yaw_rate": yaw_rate,
		"drift": drift_ratio,
		"saturation": tyre_saturation,
		"slip_energy": slip_energy,
		"grounded": grounded_count,
		"airborne_time": airborne_time,
		"rpm": engine_rpm,
		"gear": gear,
		"steer": steer_angle,
		"blocked_time": blocked_time,
		"height": height_above_ground,
		"impact": impact_speed_ms,
		"drive_force": drive_force_now,
		"wheels": _wheels_snapshot(),
		"input": input.to_dict(),
	}

func _wheels_snapshot() -> Array:
	var out: Array = []
	for w in wheels.wheels:
		out.append({
			"index": w.index,
			"grounded": w.grounded,
			"compression": w.compression,
			"load": w.load,
			"slip_ratio": w.slip_ratio,
			"slip_angle": w.slip_angle,
			"spin": w.spin,
			"locked": w.locked,
			"force": w.tyre_force_local,
			"saturation": w.saturation(),
		})
	return out

## Скорость, которую ИИ может безопасно держать на текущем радиусе поворота.
func grip_limited_speed_kms(curvature: float) -> float:
	var mu := (config.grip_front_mu + config.grip_rear_mu) * 0.5 * grip_multiplier
	var radius := 1.0 / maxf(absf(curvature), 0.0008)
	var v := sqrtf(maxf(mu * 9.8 * radius, 0.0))
	return minf(v * 3.6, config.max_speed_kmh)

func set_enabled(p_enabled: bool) -> void:
	enabled = p_enabled
	if body != null:
		body.freeze = not p_enabled
		if p_enabled:
			# В 4.7 у RigidBody3D нет wake_up(); пробуждение обеспечивается `can_sleep = false`.
			pass
