extends TestCase
## The vehicle maths layer: the tyre model, the torque curve and the helpers the tests and the
## physics both rely on. These are pure functions, so they are checked against their
## documented behaviour (and against the physical expectations of the game).


func _suite_name() -> String:
	return "unit/vehicle_math"


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/vehicles/player_car.tres") as VehicleConfig
	check_not_null(config, "player_car.tres must load as a VehicleConfig")
	if config == null:
		return

	# --- torque curve ---------------------------------------------------------------
	check_almost(VehicleMath.torque_curve(0.0, 4200.0, 6800.0, 800.0), 0.35, 0.001, "idle torque")
	check_almost(VehicleMath.torque_curve(4200.0, 4200.0, 6800.0, 800.0), 1.0, 0.001, "peak torque at peak rpm")
	check_almost(VehicleMath.torque_curve(6800.0, 4200.0, 6800.0, 800.0), 0.0, 0.001, "no torque at the limiter")
	check_between(VehicleMath.torque_curve(5500.0, 4200.0, 6800.0, 800.0), 0.5, 1.0, "mid range torque")
	check_greater(
		VehicleMath.engine_torque(config, 4200.0, 1.0, 1.0),
		VehicleMath.engine_torque(config, 6800.0, 1.0, 1.0),
		"torque falls after the peak"
	)
	check_almost(
		VehicleMath.engine_torque(config, 4200.0, 1.0, 2.0),
		VehicleMath.engine_torque(config, 4200.0, 1.0, 1.0) * 2.0,
		0.01,
		"boost multiplies the torque"
	)

	# --- tyres ---------------------------------------------------------------------
	check_almost(VehicleMath.slip_ratio_factor(0.0), 0.0, 0.0001, "no slip, no force")
	check_almost(VehicleMath.slip_ratio_factor(0.12), 1.0, 0.0001, "peak slip ratio gives full force")
	check_almost(VehicleMath.slip_ratio_factor(0.55), 0.82, 0.0001, "sliding tyre keeps 82 percent")
	check_almost(VehicleMath.slip_angle_factor(0.0, 0.14, 0.42, 0.86), 0.0, 0.0001, "no slip angle, no force")
	check_almost(VehicleMath.slip_angle_factor(0.14, 0.14, 0.42, 0.86), 1.0, 0.0001, "peak slip angle")
	check_almost(VehicleMath.slip_angle_factor(10.0, 0.14, 0.42, 0.86), 0.86, 0.0001, "sliding cornering grip")
	# The lateral force must oppose the slip, otherwise the car would steer itself.
	check_less(VehicleMath.lateral_force(config, 0.2, 4000.0), 0.0, "lateral force opposes a positive slip angle")
	check_greater(VehicleMath.lateral_force(config, -0.2, 4000.0), 0.0, "lateral force opposes a negative slip angle")
	check_greater(VehicleMath.lateral_force(config, 0.2, 4000.0), VehicleMath.lateral_force(config, 0.2, 2000.0), "more load, more force")
	check_almost(VehicleMath.lateral_force(config, 0.2, 0.0), 0.0, 0.0001, "an airborne tyre makes no force")
	check_almost(VehicleMath.longitudinal_force(0.2, 4000.0, 1.0), VehicleMath.longitudinal_force(0.2, 4000.0, 1.0), 0.0001, "longitudinal force is deterministic")
	check_greater(VehicleMath.longitudinal_force(0.2, 4000.0, 1.0), 0.0, "positive slip drives forward")

	# --- friction circle -----------------------------------------------------------
	var capped := VehicleMath.apply_friction_circle(6000.0, 6000.0, 4000.0)
	check_less(capped.length(), 4000.01, "the friction circle caps the combined force")
	check_between(capped.x, 2000.0, 3600.0, "longitudinal part of the capped force")
	var uncapped := VehicleMath.apply_friction_circle(100.0, 100.0, 4000.0)
	check_almost(uncapped.x, 100.0, 0.0001, "small forces pass through the friction circle unchanged")

	# --- envelope ------------------------------------------------------------------
	check_almost(VehicleMath.drag_force(0.42, 46.0), 0.42 * 46.0 * 46.0, 0.01, "drag grows with the square of speed")
	check_greater(VehicleMath.drag_force(0.42, 46.0, 2.0), VehicleMath.drag_force(0.42, 46.0), "the drag multiplier used by nitro lowers drag")
	check_almost(
		VehicleMath.terminal_speed(VehicleMath.drag_force(0.42, 46.0), 0.42), 46.0, 0.01,
		"the drag coefficient is tuned so that the terminal speed is max_speed"
	)
	check_almost(
		VehicleMath.wheel_angular_velocity_for_speed(13.0, 0.34),
		13.0 / 0.34,
		0.0001,
		"wheel angular velocity"
	)
	check_almost(VehicleMath.slip_ratio(0.0, 0.0), 0.0, 0.0001, "a standing wheel has no slip ratio")
	check_greater(VehicleMath.slip_ratio(20.0, 10.0), 0.0, "spinning wheel has a positive slip ratio")
	check_less(VehicleMath.slip_ratio(0.0, 10.0), 0.0, "locked wheel has a negative slip ratio")

	# --- steering and braking ------------------------------------------------------
	check_almost(VehicleMath.speed_limited_steer(0.6, 0.0, 46.0, 0.62), 0.6, 0.0001, "full lock when stationary")
	check_less(VehicleMath.speed_limited_steer(0.6, 46.0, 46.0, 0.62), 0.6, "less lock at top speed")
	check_greater(VehicleMath.speed_limited_steer(0.6, 46.0, 46.0, 0.62), 0.0, "some lock always remains")
	check_almost(VehicleMath.handbrake_grip_scale(config, false), 1.0, 0.0001, "no grip loss without the handbrake")
	check_less(VehicleMath.handbrake_grip_scale(config, true), 0.5, "the handbrake takes away rear grip")
	var stop_distance := VehicleMath.braking_distance(27.8, 9.0)
	check_between(stop_distance, 30.0, 60.0, "braking distance from 100 km/h is realistic")
	check_almost(VehicleMath.damping_alpha(1.0, 0.016), 1.0 - exp(-0.016), 0.0001, "frame independent damping")
	check_almost(
		VehicleMath.rpm_from_speed(0.0, 0.34, 3.2, 3.6, 800.0), 800.0, 0.01, "engine idles when stopped"
	)
	check_greater(
		VehicleMath.rpm_from_speed(30.0, 0.34, 1.0, 3.6, 800.0),
		VehicleMath.rpm_from_speed(15.0, 0.34, 1.0, 3.6, 800.0),
		"rpm rises with speed"
	)
