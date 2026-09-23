extends RefCounted
class_name VehiclePhysics
## The force model of a car on a RigidBody3D.
##
## Model: a raycast vehicle. Every wheel casts a suspension ray, the spring and damper
## push the chassis up, and two tyre forces (longitudinal and lateral) act at the contact
## patch. The wheels have their own rotational speed, so wheelspin, locked wheels under
## braking, handbrake drifts and burnouts all emerge from the model instead of being
## faked with animations.
##
## Everything here works on the *body* the caller hands over; nothing is applied through
## `global_transform`, so the physics engine stays in charge of the movement (a hard rule
## of this project: no teleporting a car by writing to its transform).

## Sub-steps used for the wheel rotational integration. The wheel inertia is small, so a
## single 1/60 s step would oscillate; four sub-steps are cheap and rock solid.
const WHEEL_SUBSTEPS := 4
## Absolute limit for a wheel's rotation speed (rad/s). Beyond this the tyre is burning.
const MAX_WHEEL_OMEGA := 260.0
## Vertical speed (m/s) of a landing that counts as an impact.
const LANDING_IMPACT_SPEED := 4.5

var config: VehicleConfig
var wheels: WheelSystem
var body: RigidBody3D

## Surface grip of the ground under each wheel (1 = dry asphalt). Filled by the raycasts
## from the collider metadata, so grass or construction dirt can be slippery later.
var surface_grip: PackedFloat32Array = PackedFloat32Array()

## Diagnostics (read by the debug overlay and by the automated tests).
var last_speed: float = 0.0
var last_forward_speed: float = 0.0
var last_lateral_speed: float = 0.0
var last_acceleration: float = 0.0
var air_time: float = 0.0
var grounded: bool = false
var impact_speed: float = 0.0
var last_grip_usage: float = 0.0
var lateral_slip: float = 0.0

var _previous_speed: float = 0.0
var _was_airborne: bool = false
var _impact_timer: float = 0.0
var _centre_of_mass_world := Vector3.ZERO
var _time_since_contact := 0.0


func setup(p_body: RigidBody3D, p_config: VehicleConfig, p_wheels: WheelSystem) -> void:
	body = p_body
	config = p_config
	wheels = p_wheels
	surface_grip.resize(WheelSystem.WHEEL_COUNT)
	surface_grip.fill(1.0)
	_apply_body_settings()


## Applies mass, damping, centre of mass and collision behaviour to the rigid body.
func _apply_body_settings() -> void:
	if body == null:
		return
	body.mass = config.mass
	# The centre of mass is given as a height above the ground in the configuration and
	# converted into the body's local space here. A low centre of mass is what keeps the
	# car from tipping over in fast corners.
	var ground_offset := WheelSystem.RIDE_HEIGHT + config.body_size.y * 0.5
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.0, config.center_of_mass_height - ground_offset, 0.0)
	body.linear_damp = config.linear_damping
	body.angular_damp = config.angular_damping
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.can_sleep = false


## Casts the suspension rays and updates the spring/damper forces.
##
## Called once per physics tick from the car script, *before* the forces are applied, so
## the force step always works on fresh wheel data.
func update_wheels(space: PhysicsDirectSpaceState3D, delta: float, collision_mask: int = 0xFFFFFFFF) -> void:
	if wheels == null:
		return
	var exclude: Array[RID] = [body.get_rid()]
	wheels.update_rays(space, body.global_transform, delta, collision_mask, exclude)
	_read_surface_grip(space)
	wheels.update_suspension_loads(config)


## Reads the grip multiplier from the collider under each wheel.
func _read_surface_grip(space: PhysicsDirectSpaceState3D) -> void:
	for i in wheels.wheels.size():
		var wheel := wheels.wheels[i]
		surface_grip[i] = 1.0
		if not wheel.contact:
			continue
		var query := PhysicsRayQueryParameters3D.create(wheel.contact_point + Vector3.UP * 0.05, wheel.contact_point - Vector3.UP * 0.05)
		query.exclude = [body.get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider: Object = hit.get("collider")
		if collider is Node and (collider as Node).has_meta("surface_grip"):
			surface_grip[i] = float((collider as Node).get_meta("surface_grip"))


## Applies every force for this physics tick.
##
## `delta` is the physics step and `output` the drivetrain state for this frame
## (torque, speed cap, drag multiplier, nitro bonus).
func apply_forces(delta: float, output: DrivetrainOutput) -> void:
	if body == null or config == null:
		return
	var safe_delta := maxf(delta, 0.0001)
	var basis := body.global_transform.basis
	var forward := -basis.z
	var right := basis.x
	var up := basis.y
	var velocity := body.linear_velocity
	var angular := body.angular_velocity
	_centre_of_mass_world = body.global_position + basis * body.center_of_mass

	var speed := velocity.length()
	last_speed = speed
	last_forward_speed = velocity.dot(forward)
	last_lateral_speed = velocity.dot(right)
	var longitudinal_accel := (last_forward_speed - _previous_speed) / safe_delta
	last_acceleration = longitudinal_accel
	_previous_speed = last_forward_speed

	_update_wheel_forces(safe_delta, output, velocity, angular)

	_apply_body_forces(safe_delta, output, forward, right, up, velocity)

	_update_air_state(safe_delta, output)


## Computes the tyre forces of every wheel and applies them at the contact patches.
func _update_wheel_forces(
	delta: float,
	output: DrivetrainOutput,
	velocity: Vector3,
	angular: Vector3
) -> void:
	var basis := body.global_transform.basis
	var total_lateral := 0.0
	for index in wheels.wheels.size():
		var wheel := wheels.wheels[index]
		if not wheel.contact:
			# In the air the wheel keeps spinning: the drive torque still acts on it, which
			# is what produces the wheelspin when the car lands again.
			_integrate_free_wheel(wheel, delta, output)
			wheel.steer_angle = wheel.steer_angle
			continue
		var normal := wheel.contact_normal
		var steer_basis := Basis(Vector3.UP, wheel.steer_angle)
		var wheel_forward := (basis * steer_basis) * Vector3.FORWARD
		wheel_forward = (wheel_forward - normal * wheel_forward.dot(normal))
		if wheel_forward.length_squared() < 0.0001:
			wheel_forward = (basis * Vector3.FORWARD).normalized()
		else:
			wheel_forward = wheel_forward.normalized()
		var wheel_right := wheel_forward.cross(normal).normalized()

		var contact_velocity := velocity + angular.cross(wheel.contact_point - _centre_of_mass_world)
		var v_forward := contact_velocity.dot(wheel_forward)
		var v_lateral := contact_velocity.dot(wheel_right)
		var slip_angle := VehicleMath.slip_angle(v_lateral, v_forward)
		var grip := surface_grip[index] if index < surface_grip.size() else 1.0
		var grip_scale := grip
		if wheel.handbrake_locked:
			grip_scale *= VehicleMath.handbrake_grip_scale(config, true)
		var load := wheel.suspension_force
		var lateral := VehicleMath.lateral_force(config, slip_angle, load, grip_scale)
		var long_force := _integrate_wheel_rotation(wheel, delta, v_forward, load, grip, output)
		# Friction circle: a tyre cannot produce full longitudinal and full lateral force at
		# the same time. This is what makes the car slide when the player brakes hard and
		# steers at the same time.
		var max_force := config.tyre_grip * grip * load
		var corrected := VehicleMath.apply_friction_circle(long_force, lateral, max_force)
		long_force = corrected.x
		lateral = corrected.y
		wheel.longitudinal_force = long_force
		wheel.lateral_force = lateral
		wheel.slip_angle = slip_angle
		wheel.load = load
		total_lateral += absf(lateral)

		var force := wheel_forward * long_force + wheel_right * lateral + normal * wheel.suspension_force
		wheel.applied_force = force
		body.apply_force(force, wheel.contact_point - body.global_position)
	lateral_slip = clampf(total_lateral / maxf(config.mass * 9.0, 1.0), 0.0, 2.0)


## Integrates the rotation of a wheel that is touching the ground and returns the
## longitudinal tyre force in newtons.
func _integrate_wheel_rotation(
	wheel: VehicleWheel,
	delta: float,
	ground_speed: float,
	load: float,
	grip: float,
	output: DrivetrainOutput
) -> float:
	var sub_delta := delta / float(WHEEL_SUBSTEPS)
	var long_force := 0.0
	var radius := config.wheel_radius
	var grip_circle := config.tyre_grip * grip * load
	for _step in WHEEL_SUBSTEPS:
		var surface := wheel.angular_velocity * radius
		var slip := VehicleMath.slip_ratio(surface, ground_speed)
		long_force = VehicleMath.longitudinal_force(
			slip, load, config.tyre_grip * grip, config.peak_slip_ratio, config.slide_slip_ratio
		)
		long_force = clampf(long_force, -grip_circle, grip_circle)
		var brake_torque := wheel.brake_torque
		var brake_sign := signf(wheel.angular_velocity)
		if is_zero_approx(brake_sign):
			brake_sign = signf(ground_speed)
		var net_torque := wheel.drive_torque - brake_torque * brake_sign - long_force * radius
		var inertia := maxf(config.wheel_inertia, 0.05)
		var new_omega := wheel.angular_velocity + net_torque / inertia * sub_delta
		# A braking wheel must be able to lock completely but never spin backwards because
		# of the brake torque alone.
		if brake_torque > 0.0 and signf(new_omega) != signf(wheel.angular_velocity) and absf(new_omega) < 4.0:
			new_omega = 0.0
		wheel.angular_velocity = clampf(new_omega, -MAX_WHEEL_OMEGA, MAX_WHEEL_OMEGA)
	wheel.slip_ratio = VehicleMath.slip_ratio(wheel.angular_velocity * radius, ground_speed)
	wheel.drive_torque = wheel.drive_torque
	return long_force


## Integrates a wheel that is not touching the ground (free spinning).
func _integrate_free_wheel(wheel: VehicleWheel, delta: float, _output: DrivetrainOutput) -> void:
	var inertia := maxf(config.wheel_inertia, 0.05)
	var damping := wheel.angular_velocity * 0.4
	wheel.angular_velocity += (wheel.drive_torque - damping) / inertia * delta
	wheel.angular_velocity = clampf(wheel.angular_velocity, -MAX_WHEEL_OMEGA, MAX_WHEEL_OMEGA)
	wheel.slip_ratio = 0.0
	wheel.longitudinal_force = 0.0
	wheel.lateral_force = 0.0
	wheel.load = 0.0


## Aerodynamic drag, rolling resistance, downforce, the speed cap and the air stability.
func _apply_body_forces(
	delta: float,
	output: DrivetrainOutput,
	forward: Vector3,
	right: Vector3,
	up: Vector3,
	velocity: Vector3
) -> void:
	var speed := velocity.length()
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var flat_speed := flat_velocity.length()
	var grounded_fraction := float(wheels.contact_count()) / float(WheelSystem.WHEEL_COUNT)

	# Drag: 0.5 * rho * Cd * A * v^2 is folded into the single drag coefficient.
	if flat_speed > 0.01:
		var drag := VehicleMath.drag_force(config.drag_coefficient, flat_speed, output.drag_multiplier)
		body.apply_central_force(-flat_velocity.normalized() * drag)
	# Rolling resistance only acts through the tyres, so it scales with the number of
	# wheels on the ground.
	if flat_speed > 0.05 and grounded_fraction > 0.0:
		var rolling := VehicleMath.rolling_resistance_force(config.rolling_resistance, config.mass, 12.0)
		body.apply_central_force(-flat_velocity.normalized() * rolling * grounded_fraction)
	# Downforce keeps the car planted at high speed and makes it feel heavy.
	if speed > 1.0:
		var down := VehicleMath.downforce_force(config.downforce + output.downforce_bonus, speed)
		body.apply_central_force(-up * down * grounded_fraction)
	# Speed cap. The engine torque is already cut by the controller; this only removes the
	# remaining momentum, and it is a force, never a teleport or a velocity reset.
	if output.speed_limited and absf(last_forward_speed) > output.max_speed:
		var excess := absf(last_forward_speed) - output.max_speed
		var direction := forward if last_forward_speed > 0.0 else -forward
		body.apply_central_force(-direction * excess * config.mass * 2.2)

	# Air stability: while no wheel touches the ground, a small torque rotates the car
	# towards level flight instead of letting it tumble.
	if wheels.is_airborne():
		var correction := up.cross(Vector3.UP)
		if correction.length_squared() > 0.0001:
			body.apply_torque(correction * config.air_stability * config.mass * 0.02)

	# Safety net: nothing in a street racing game needs to move faster than this, and a
	# clamp prevents a single bad contact from launching the car into orbit.
	var linear := body.linear_velocity
	if linear.length() > config.velocity_clamp:
		body.linear_velocity = linear.normalized() * config.velocity_clamp
	var angular := body.angular_velocity
	var angular_limit := 12.0
	if angular.length() > angular_limit:
		body.angular_velocity = angular.normalized() * angular_limit


## Tracks grounding, air time and landing impacts.
func _update_air_state(delta: float, _output: DrivetrainOutput) -> void:
	var touching := wheels.contact_count() > 0
	grounded = touching
	if touching:
		if _was_airborne and air_time > 0.25:
			impact_speed = absf(body.linear_velocity.dot(Vector3.UP)) + air_time * 2.0
			if impact_speed < LANDING_IMPACT_SPEED:
				impact_speed = 0.0
			_impact_timer = 0.3
		_was_airborne = false
		air_time = 0.0
		_time_since_contact = 0.0
	else:
		_was_airborne = true
		air_time += delta
		_time_since_contact += delta
	if _impact_timer > 0.0:
		_impact_timer = maxf(0.0, _impact_timer - delta)
		if _impact_timer <= 0.0:
			impact_speed = 0.0


## True when the car has been lying without contact for a while (rolled over).
func is_stuck(timeout: float = 3.0) -> bool:
	return _time_since_contact > timeout and body.linear_velocity.length() < 1.5


## Current grip usage (0 = cruising, 1 = at the limit of the tyres). Drives the HUD and
## the tyre marks.
func grip_usage() -> float:
	var load := 0.0
	for wheel: VehicleWheel in wheels.wheels:
		load += wheel.load
	if load <= 1.0:
		return 0.0
	var force := 0.0
	for wheel: VehicleWheel in wheels.wheels:
		force += sqrt(wheel.longitudinal_force * wheel.longitudinal_force + wheel.lateral_force * wheel.lateral_force)
	last_grip_usage = clampf(force / (config.tyre_grip * load), 0.0, 1.5)
	return last_grip_usage


## Snapshot used by the smoke test to assert that the car behaves as intended.
func to_dictionary() -> Dictionary:
	return {
		"speed": last_speed,
		"forward_speed": last_forward_speed,
		"lateral_speed": last_lateral_speed,
		"acceleration": last_acceleration,
		"air_time": air_time,
		"grounded": grounded,
		"impact_speed": impact_speed,
		"lateral_slip": lateral_slip,
		"wheels": wheels.to_dictionary(),
	}
