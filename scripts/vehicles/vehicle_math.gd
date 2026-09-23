extends RefCounted
class_name VehicleMath
## Pure mathematics of the car: engine, tyres, drag, braking.
##
## Everything in this file is a static function without any access to a body, a scene or
## an engine singleton. That is deliberate: it makes the driving model unit testable
## (see tests/unit/test_vehicle_math.gd) and it keeps the feel of the car in one place
## instead of spread over the force application code.

## Smallest speed (m/s) at which the tyre model uses the normal slip formulas. Below it
## the car is nearly standing and a velocity-proportional model is stable.
const LOW_SPEED_THRESHOLD := 1.6
## Smallest absolute number to avoid dividing by zero.
const EPSILON := 0.0001


## Torque of the engine at a given engine speed, as a fraction of `VehicleConfig.engine_torque`.
##
## The curve idles at 0.35, rises linearly to 1.0 at the peak torque engine speed and then
## falls towards 0.55 at the rev limiter. It is intentionally smooth: the arcade feel must
## not depend on a gearbox that shifts perfectly.
static func torque_curve(rpm: float, peak_rpm: float, max_rpm: float, idle_rpm: float) -> float:
	var safe_peak := maxf(peak_rpm, idle_rpm + 1.0)
	var safe_max := maxf(max_rpm, safe_peak + 1.0)
	if rpm <= idle_rpm:
		return 0.35
	if rpm >= safe_max:
		return 0.0
	if rpm <= safe_peak:
		var t := (rpm - idle_rpm) / (safe_peak - idle_rpm)
		return lerpf(0.35, 1.0, clampf(t, 0.0, 1.0))
	var t2 := (rpm - safe_peak) / (safe_max - safe_peak)
	return lerpf(1.0, 0.0, clampf(t2, 0.0, 1.0) * 0.45 + 0.0)


## Engine torque produced with a given throttle, in N*m.
static func engine_torque(
	config: VehicleConfig,
	rpm: float,
	throttle: float,
	boost_multiplier: float = 1.0
) -> float:
	var clamped_throttle := clampf(throttle, 0.0, 1.0)
	var curve := torque_curve(rpm, config.peak_torque_rpm, config.max_rpm, config.idle_rpm)
	return config.engine_torque * curve * clamped_throttle * maxf(boost_multiplier, 0.0)


## Drive force at the contact patch for a wheel torque (N).
static func force_from_torque(torque: float, wheel_radius: float) -> float:
	return torque / maxf(wheel_radius, 0.05)


## The tyre longitudinal force scale for a slip ratio (Pacejka shaped, but cheap).
##
## `slip_ratio` = (wheel surface speed - ground speed) / max(ground speed, 1).
## Positive values spin the wheel, negative values lock it.
static func slip_ratio_factor(slip_ratio: float, peak_slip: float = 0.12, slide_slip: float = 0.55) -> float:
	var magnitude := absf(slip_ratio)
	if magnitude <= peak_slip:
		return magnitude / maxf(peak_slip, EPSILON)
	if magnitude >= slide_slip:
		return 0.82
	var t := (magnitude - peak_slip) / maxf(slide_slip - peak_slip, EPSILON)
	return lerpf(1.0, 0.82, clampf(t, 0.0, 1.0))


## The tyre lateral force scale for a slip angle in radians.
##
## Grip rises to 1.0 at `peak_slip_angle`, then falls to `slide_grip_scale` at
## `slide_slip_angle` and stays there: that fall-off is exactly what makes the car drift
## instead of snapping back like a slot car.
static func slip_angle_factor(
	slip_angle: float,
	peak_slip_angle: float,
	slide_slip_angle: float,
	slide_grip_scale: float
) -> float:
	var magnitude := absf(slip_angle)
	if magnitude <= peak_slip_angle:
		return magnitude / maxf(peak_slip_angle, EPSILON)
	if magnitude >= slide_slip_angle:
		return slide_grip_scale
	var t := (magnitude - peak_slip_angle) / maxf(slide_slip_angle - peak_slip_angle, EPSILON)
	return lerpf(1.0, slide_grip_scale, clampf(t, 0.0, 1.0))


## Lateral force of one tyre in newtons, signed against the slip angle.
static func lateral_force(
	config: VehicleConfig,
	slip_angle: float,
	load: float,
	grip_scale: float = 1.0,
	grip_offset: float = 0.0
) -> float:
	if load <= 0.0:
		return 0.0
	var factor := slip_angle_factor(
		slip_angle, config.peak_slip_angle, config.slide_slip_angle, config.slide_grip_scale
	)
	var grip := maxf(config.tyre_grip * grip_scale - grip_offset, 0.0)
	var force := -signf(slip_angle) * factor * grip * load
	return force


## Longitudinal force of one tyre in newtons, signed along the wheel's rolling direction.
static func longitudinal_force(
	slip_ratio: float,
	load: float,
	grip: float,
	peak_slip: float = 0.12,
	slide_slip: float = 0.55
) -> float:
	if load <= 0.0:
		return 0.0
	var factor := slip_ratio_factor(slip_ratio, peak_slip, slide_slip)
	return signf(slip_ratio) * factor * maxf(grip, 0.0) * load


## Scales a tyre force pair down so that the combined force stays inside the friction
## circle of the tyre. Returns the corrected (longitudinal, lateral) pair.
static func apply_friction_circle(
	long_force: float,
	lat_force: float,
	max_force: float
) -> Vector2:
	var combined := sqrt(long_force * long_force + lat_force * lat_force)
	if combined <= max_force or combined <= EPSILON:
		return Vector2(long_force, lat_force)
	var scale := max_force / combined
	return Vector2(long_force * scale, lat_force * scale)


## Aerodynamic drag force magnitude for a speed (N).
static func drag_force(drag_coefficient: float, speed: float, multiplier: float = 1.0) -> float:
	return drag_coefficient * multiplier * speed * speed


## Rolling resistance force magnitude (N).
static func rolling_resistance_force(rolling_coefficient: float, mass: float, gravity: float) -> float:
	return rolling_coefficient * mass * gravity


## Downforce (N) for a speed.
static func downforce_force(downforce_coefficient: float, speed: float) -> float:
	return downforce_coefficient * speed * speed * 0.5


## Braking force available at a wheel (N) for a brake torque.
static func braking_force(
	brake_torque: float,
	wheel_radius: float,
	wheel_angular_velocity: float,
	apply_scale: float = 1.0
) -> float:
	if is_zero_approx(wheel_angular_velocity):
		# A stationary wheel has no rotation direction of its own; the caller resolves the
		# direction from the vehicle velocity.
		return 0.0
	return -signf(wheel_angular_velocity) * force_from_torque(brake_torque * apply_scale, wheel_radius)


## Engine speed (rpm) implied by a wheel speed on the driven axle, for the given gear ratio.
static func rpm_from_speed(
	speed: float,
	wheel_radius: float,
	gear_ratio: float,
	final_drive: float,
	idle_rpm: float
) -> float:
	var wheel_circumference := TAU * maxf(wheel_radius, 0.05)
	var wheel_rps := absf(speed) / wheel_circumference
	return maxf(idle_rpm, wheel_rps * gear_ratio * final_drive * 60.0)


## Wheel angular velocity (rad/s) for a linear speed, assuming the wheel rolls freely.
static func wheel_angular_velocity_for_speed(speed: float, wheel_radius: float) -> float:
	return speed / maxf(wheel_radius, 0.05)


## Slip ratio of a wheel: (surface speed - ground speed) / max(ground speed, 1).
static func slip_ratio(surface_speed: float, ground_speed: float) -> float:
	var reference := maxf(absf(ground_speed), 1.0)
	return (surface_speed - ground_speed) / reference


## Slip angle (radians) of a wheel from the lateral and longitudinal velocity at the
## contact patch.
static func slip_angle(lateral_speed: float, longitudinal_speed: float) -> float:
	if absf(longitudinal_speed) < LOW_SPEED_THRESHOLD:
		# Standing start: keep the tyre model continuous, otherwise the car twitches.
		var blended := maxf(absf(longitudinal_speed), 0.35)
		return atan2(lateral_speed, blended)
	return atan2(lateral_speed, maxf(absf(longitudinal_speed), EPSILON))


## Steering angle actually available at a given speed: the faster the car, the smaller the
## maximum angle, which is what makes a heavy car feel heavy instead of twitchy.
static func speed_limited_steer(
	max_steer_radians: float,
	speed: float,
	max_speed: float,
	reduction: float
) -> float:
	var t := clampf(absf(speed) / maxf(max_speed, 1.0), 0.0, 1.0)
	var scale := 1.0 - reduction * t
	return max_steer_radians * maxf(scale, 0.15)


## How much of the tyre grip is left on the rear axle while the handbrake is held.
static func handbrake_grip_scale(config: VehicleConfig, handbrake: bool) -> float:
	if not handbrake:
		return 1.0
	return clampf(1.0 - config.handbrake_grip_loss, 0.0, 1.0)


## A safe interpolation step for damping, frame rate independent.
static func damping_alpha(rate: float, delta: float) -> float:
	return clampf(1.0 - exp(-maxf(rate, 0.0) * delta), 0.0, 1.0)


## Distance needed to stop from `speed` with a constant deceleration, in metres.
static func braking_distance(speed: float, deceleration: float) -> float:
	if deceleration <= 0.0:
		return INF
	return (speed * speed) / (2.0 * deceleration)


## Terminal speed for a given drive force and drag coefficient (used by the tests to
## verify that `max_speed` is actually reachable).
static func terminal_speed(drive_force: float, drag_coefficient: float) -> float:
	if drag_coefficient <= 0.0:
		return INF
	return sqrt(maxf(drive_force, 0.0) / drag_coefficient)
