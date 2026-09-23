extends RefCounted
class_name VehicleController
## Turns a DriveInput into the torque, steering, braking and gear state of a car.
##
## The controller owns the *drivetrain*: pedals, steering angle, engine speed, gearbox and
## reverse logic. It writes its decisions into the VehicleWheel objects (drive torque,
## brake torque, steering angle) and publishes a DrivetrainOutput that the VehiclePhysics
## reads. It never touches the rigid body, so it can be tested without a scene.

## Steering angle below which the steering is considered centred.
const STEER_EPSILON := 0.0005

## Live values for the renderer and the HUD.
var steer_angle: float = 0.0
var engine_rpm: float = 800.0
var gear: int = 1
var shift_timer: float = 0.0
var wheelspin: float = 0.0
var last_output := DrivetrainOutput.new()

## Rolling state used to derive the engine speed when the car is standing still.
var _crank_torque: float = 0.0
var _air_brake: float = 0.0
var _steer_speed: float = 0.0


## Updates the whole drivetrain for one physics tick.
##
## `input` is the driver's request, `wheels` the wheel system of the car, `config` the
## tuning resource, `nitro` the nitro state (may be null), `speed` the current forward
## speed of the car in m/s (signed, positive = forward) and `delta` the physics step.
func update(
	input: DriveInput,
	wheels: WheelSystem,
	config: VehicleConfig,
	nitro: NitroSystem,
	speed: float,
	delta: float,
	output: DrivetrainOutput
) -> void:
	var safe_delta := maxf(delta, 0.0001)
	_update_steering(input, config, wheels, speed, safe_delta)
	_update_gearbox(input, wheels, config, speed, safe_delta)
	_update_engine(input, config, nitro, wheels, speed, output, safe_delta)
	_update_brakes(input, config, wheels, output)
	output.handbrake = input.handbrake
	last_output.copy_from(output)
	wheelspin = _measure_wheelspin(wheels)


## Steers the front wheels towards the requested angle with a speed limit, and reduces the
## available angle as the car goes faster.
func _update_steering(
	input: DriveInput,
	config: VehicleConfig,
	wheels: WheelSystem,
	speed: float,
	delta: float
) -> void:
	var max_angle := deg_to_rad(config.max_steer_angle_deg)
	var limited := VehicleMath.speed_limited_steer(max_angle, speed, config.max_speed, config.speed_steer_reduction)
	var target := clampf(input.steer, -1.0, 1.0) * limited
	# Counter-steer help: while the car is sliding, the player is allowed to steer more
	# than the physical limit, which is what makes a drift controllable with a thumb.
	if config.counter_steer_assist > 0.0 and absf(input.steer) > 0.01:
		var drift := _lateral_slip(wheels)
		target += signf(input.steer) * drift * config.counter_steer_assist * limited * 0.5
	var rate := deg_to_rad(config.steer_speed_deg)
	steer_angle = move_toward(steer_angle, clampf(target, -max_angle * 1.4, max_angle * 1.4), rate * delta)
	steer_angle = clampf(steer_angle, -max_angle * 1.4, max_angle * 1.4)
	_steer_speed = input.steer
	# Only the front wheels steer. A rear steer angle of ~0 keeps the wheel visuals clean.
	for wheel: VehicleWheel in wheels.wheels:
		wheel.steer_angle = steer_angle if wheel.is_front else 0.0


## Full lateral slip of the rear axle, in the range 0..1. Used for the drift assist and
## for the tyre smoke / skid marks.
func _lateral_slip(wheels: WheelSystem) -> float:
	var worst := 0.0
	for wheel: VehicleWheel in wheels.rear_wheels():
		if wheel.contact:
			worst = maxf(worst, clampf(absf(wheel.slip_angle) / 0.4, 0.0, 1.0))
	return worst


func alignment() -> float:
	return absf(_steer_speed) * 0.25


## Engine speed, gear changes and the resulting crank torque.
func _update_engine(
	input: DriveInput,
	config: VehicleConfig,
	nitro: NitroSystem,
	wheels: WheelSystem,
	speed: float,
	output: DrivetrainOutput,
	delta: float
) -> void:
	var boosting := nitro != null and nitro.is_boosting()
	var boost_multiplier := nitro.torque_multiplier() if nitro != null else 1.0
	var total_ratio := _gear_ratio(config, gear) * config.final_drive

	# The engine turns with the driven wheels; when the clutch is open (gear change) or the
	# car is rolling in neutral it falls back to idle.
	var target_rpm := VehicleMath.rpm_from_speed(speed, config.wheel_radius, total_ratio, 1.0, config.idle_rpm)
	var throttle := clampf(input.throttle, 0.0, 1.0)
	if input.reverse_requested or gear == 0:
		throttle = throttle
	target_rpm = maxf(target_rpm, config.idle_rpm + throttle * 900.0)
	engine_rpm = lerpf(engine_rpm, clampf(target_rpm, config.idle_rpm, config.max_rpm), VehicleMath.damping_alpha(config.rpm_response, delta))

	var torque := VehicleMath.engine_torque(config, engine_rpm, throttle, boost_multiplier)
	if gear == 0:
		torque = -VehicleMath.engine_torque(config, engine_rpm, throttle, boost_multiplier) * config.reverse_torque_scale
	elif throttle < 0.02:
		torque = -config.engine_braking_torque * clampf(absf(speed) / 6.0, 0.0, 1.0)
	if shift_timer > 0.0:
		shift_timer = maxf(0.0, shift_timer - delta)
		torque = 0.0

	_crank_torque = torque
	var axle_torque := torque * total_ratio * config.drivetrain_efficiency
	# Reverse gear has its own torque path (the reverse idler), handled by sign(torque).
	_distribute_drive(config, wheels, axle_torque)

	output.engine_rpm = engine_rpm
	output.gear = gear
	output.shifting = shift_timer > 0.0
	output.boosting = boosting
	output.effective_throttle = throttle
	output.crank_torque = torque
	output.max_speed = config.max_speed
	output.reverse_max_speed = config.reverse_max_speed()
	output.drag_multiplier = 1.0
	output.downforce_bonus = 0.0
	if nitro != null and boosting:
		output.max_speed = nitro.boosted_max_speed()
		output.drag_multiplier = nitro.drag_multiplier()
		output.downforce_bonus = nitro.downforce_bonus()
	# Blocked by the speed cap: torque is cut and the physics adds a gentle counter force.
	var cap := output.max_speed if speed >= 0.0 else output.reverse_max_speed
	if absf(speed) > cap:
		output.speed_limited = true
		_crank_torque = 0.0
		_distribute_drive(config, wheels, 0.0)
	else:
		output.speed_limited = false


## Distributes an axle torque over the driven wheels according to the drive layout.
func _distribute_drive(config: VehicleConfig, wheels: WheelSystem, axle_torque: float) -> void:
	var front_share := 0.0
	var rear_share := 0.0
	match config.drive_layout:
		1:
			front_share = 1.0
		2:
			front_share = clampf(config.awd_front_split, 0.0, 1.0)
			rear_share = 1.0 - front_share
		_:
			rear_share = 1.0
	for wheel: VehicleWheel in wheels.wheels:
		if wheel.is_front:
			wheel.drive_torque = axle_torque * front_share * 0.5
		else:
			wheel.drive_torque = axle_torque * rear_share * 0.5


## Service brakes with a front/rear bias, plus the handbrake on the rear wheels.
func _update_brakes(
	input: DriveInput,
	config: VehicleConfig,
	wheels: WheelSystem,
	output: DrivetrainOutput
) -> void:
	var brake_input := clampf(input.brake, 0.0, 1.0)
	for wheel: VehicleWheel in wheels.wheels:
		var bias := config.brake_bias if wheel.is_front else (1.0 - config.brake_bias)
		var torque := config.brake_torque * bias * 2.0 * brake_input
		wheel.brake_torque = torque
		wheel.handbrake_locked = false
		if input.handbrake and not wheel.is_front:
			wheel.brake_torque += config.handbrake_torque * config.brake_bias * 2.0
			wheel.handbrake_locked = true
	output.handbrake = input.handbrake


## Automatic gearbox: shifts up when the engine revs out and down when it bogs.
func _update_gearbox(
	input: DriveInput,
	wheels: WheelSystem,
	config: VehicleConfig,
	speed: float,
	delta: float
) -> void:
	var want_reverse := input.reverse_requested or (input.brake > 0.5 and speed < -0.2)
	if gear == 0 and not want_reverse and speed > -0.2 and (input.throttle > 0.05 or speed > 0.5):
		# Rolling forward again: back into first gear.
		gear = 1
	elif gear != 0 and input.reverse_requested and speed < 1.2:
		gear = 0
	if gear == 0:
		if speed > 0.6:
			gear = 1
		return
	var up_rpm := config.max_rpm * config.shift_up_fraction
	var down_rpm := config.max_rpm * config.shift_down_fraction
	if engine_rpm > up_rpm and gear < config.gear_count and shift_timer <= 0.0:
		gear += 1
		shift_timer = config.shift_time
	elif engine_rpm < down_rpm and gear > 1 and shift_timer <= 0.0:
		gear -= 1
		shift_timer = config.shift_time


## Ratio of a given gear. Gear 0 is reverse, gears 1..gear_count are forward.
func _gear_ratio(config: VehicleConfig, gear_index: int) -> float:
	if gear_index <= 0:
		return -config.first_gear_ratio * 0.7
	if config.gear_count <= 1:
		return config.first_gear_ratio
	var t := float(gear_index - 1) / float(config.gear_count - 1)
	return lerpf(config.first_gear_ratio, config.top_gear_ratio, t)


## Highest speed the car is allowed to reach in the current state (m/s).
func current_max_speed() -> float:
	return last_output.max_speed


## How much the wheels are slipping (0..1). Drives the tyre smoke and the audio.
func _measure_wheelspin(wheels: WheelSystem) -> float:
	var worst := 0.0
	for wheel: VehicleWheel in wheels.wheels:
		if wheel.contact:
			worst = maxf(worst, clampf(absf(wheel.slip_ratio), 0.0, 1.0))
	return worst


## Resets the controller to a clean state (respawn, tests).
func reset(config: VehicleConfig) -> void:
	steer_angle = 0.0
	engine_rpm = config.idle_rpm
	gear = 1
	shift_timer = 0.0
	wheelspin = 0.0
	_crank_torque = 0.0
	last_output = DrivetrainOutput.new()


## Snapshot for the smoke test report.
func to_dictionary() -> Dictionary:
	var data := last_output.to_dictionary()
	data["steer_angle"] = steer_angle
	data["wheelspin"] = wheelspin
	return data
