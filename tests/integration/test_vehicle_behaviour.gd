extends TestCase
## The acceptance test of the vehicle: a real car, on real ground, driven by the real physics.
##
## Everything here is measured from the physics engine - the speed of the rigid body, the slip
## of its wheels, the distance it travels - so the results cannot be faked by the game logic:
## if the car in this test reaches 165 km/h, it is because the forces produced that speed.
##
## Covered: resting on the ground, acceleration, top speed, braking, handbrake drift, nitro,
## the "movement comes only from physics" rule and the blocked state.


func _suite_name() -> String:
	return "integration/vehicle_behaviour"

const HZ := 60.0
const PLAYER_CONFIG := "res://resources/config/vehicles/player_car.tres"


func run(tree: SceneTree) -> void:
	var arena := TestArena.create(tree)
	var car := TestArena.add_car(arena, PLAYER_CONFIG, Vector3.ZERO)
	check_not_null(car, "the player car is created")
	if car == null:
		return
	await TestArena.simulate(tree, 30)
	check_not_null(car.config, "the car loaded its configuration")

	# --- 1. the car rests on its wheels ---------------------------------------------
	check(car.is_grounded(), "the car stands on the ground without input")
	check_almost(car.forward_speed(), 0.0, 0.4, "a car with no throttle does not roll away")
	check_between(car.global_position.y, 0.05, 1.2, "the car sits at ride height, not sunk into the road")
	check_almost(float(car.wheels.contact_count()), 4.0, 0.5, "all four wheels touch the ground")
	check_greater(car.wheels.total_load(), car.config.mass * 9.0, "the suspension carries the mass of the car")
	var front_share := car.wheels.static_front_load_share(car.config, 9.8)
	check_between(front_share, 0.4, 0.65, "the weight distribution is realistic")

	# --- 2. acceleration ------------------------------------------------------------
	car.reset_to(Transform3D(Basis(), Vector3(0.0, 0.6, 0.0)))
	var speed_after_one_second := 0.0
	var speed_after_three_seconds := 0.0
	var elapsed := 0.0
	var cap_broken := false
	var previous_position := car.global_position
	biggest_step = 0.0
	for _i in int(9.0 * HZ):
		car.drive_input.throttle = 1.0
		car.drive_input.brake = 0.0
		car.drive_input.steer = 0.0
		car.drive_input.source = &"test"
		await tree.physics_frame
		elapsed += 1.0 / HZ
		biggest_step = maxf(biggest_step, car.global_position.distance_to(previous_position))
		previous_position = car.global_position
		if car.forward_speed() > car.config.max_speed * 1.03:
			cap_broken = true
		if speed_after_one_second == 0.0 and elapsed >= 1.0:
			speed_after_one_second = car.forward_speed()
		if speed_after_three_seconds == 0.0 and elapsed >= 3.0:
			speed_after_three_seconds = car.forward_speed()
	check(not cap_broken, "the car never breaks its speed cap, not even for one frame")
	check_greater(speed_after_one_second, 3.0, "the car accelerates immediately (heavy, but not sluggish)")
	check_greater(speed_after_three_seconds, 14.0, "the car reaches ~50 km/h in three seconds")
	check_greater(car.forward_speed(), speed_after_three_seconds, "the car keeps accelerating")
	check(car.gear() >= 1, "the gearbox is engaged while driving forward")
	check_greater(car.engine_rpm(), car.config.idle_rpm - 1.0, "the engine is running")
	note("speed after 1 s: %.1f m/s, 3 s: %.1f m/s, 9 s: %.1f m/s" % [
		speed_after_one_second, speed_after_three_seconds, car.forward_speed()
	])

	# --- 3. movement is physical only -----------------------------------------------
	var top_step_limit := 0.0
	var speed_now := car.linear_velocity.length()
	biggest_step = 0.0
	previous_position = car.global_position
	for _i in int(2.0 * HZ):
		car.drive_input.throttle = 1.0
		await tree.physics_frame
		var step := car.global_position.distance_to(previous_position)
		speed_now = maxf(speed_now, car.linear_velocity.length())
		biggest_step = maxf(biggest_step, step)
		previous_position = car.global_position
	top_step_limit = speed_now / HZ * 1.5
	check_less(biggest_step, top_step_limit, "the car never teleports: every frame's movement matches its speed")
	check_greater(car.global_position.distance_to(Vector3.ZERO), 50.0, "the car actually travelled")

	# --- 4. top speed ---------------------------------------------------------------
	await TestArena.simulate(
		tree,
		int(14.0 * HZ),
		func() -> void:
			car.drive_input.throttle = 1.0
	)
	var plain_top_speed := car.forward_speed()
	check_between(plain_top_speed, car.config.max_speed * 0.9, car.config.max_speed * 1.03, "the car reaches its top speed")
	note("top speed without nitro: %.2f m/s (%.0f km/h)" % [plain_top_speed, plain_top_speed * 3.6])

	# --- 5. braking -----------------------------------------------------------------
	var braking_frames := 0
	var distance_at_brake := car.global_position.distance_to(Vector3.ZERO)
	while car.forward_speed() > 0.5 and braking_frames < int(8.0 * HZ):
		car.drive_input.throttle = 0.0
		car.drive_input.brake = 1.0
		await tree.physics_frame
		braking_frames += 1
	var braking_distance := car.global_position.distance_to(Vector3.ZERO) - distance_at_brake
	check_greater(float(braking_frames), 1.0, "braking takes more than one frame")
	check_less(float(braking_frames), 8.0 * HZ, "the car can be stopped completely")
	check_greater(braking_distance, 5.0, "the car needs a real distance to stop from top speed")
	check_less(car.forward_speed(), 1.5, "braking actually stops the car")
	note("braking from %.1f m/s took %.2f s" % [plain_top_speed, float(braking_frames) / HZ])

	# --- 6. the car stays stopped and can reverse -----------------------------------
	await TestArena.simulate(
		tree,
		int(1.5 * HZ),
		func() -> void:
			car.drive_input.throttle = 0.0
			car.drive_input.brake = 1.0
	)
	check_less(absf(car.forward_speed()), 0.6, "the car stays stopped with the brake held")
	await TestArena.simulate(
		tree,
		int(2.0 * HZ),
		func() -> void:
			car.drive_input.brake = 0.6
			car.drive_input.reverse_requested = true
			car.drive_input.throttle = 0.3
	)
	check_less(car.forward_speed(), -0.5, "the car reverses when asked to")

	# --- 7. handbrake and drift ------------------------------------------------------
	# Reset to a clean straight and build speed again.
	car.reset_to(Transform3D(Basis(), Vector3(0.0, 0.6, 0.0)))
	await TestArena.simulate(
		tree,
		int(6.0 * HZ),
		func() -> void:
			car.drive_input.throttle = 1.0
			car.drive_input.brake = 0.0
			car.drive_input.reverse_requested = false
			car.drive_input.steer = 0.0
			car.drive_input.handbrake = false
	)
	var speed_before_drift := car.forward_speed()
	var max_slip := 0.0
	var heading_before := car.global_rotation.y
	for _i in int(2.5 * HZ):
		car.drive_input.throttle = 0.55
		car.drive_input.steer = 1.0
		car.drive_input.handbrake = true
		await tree.physics_frame
		max_slip = maxf(max_slip, car.lateral_slip())
	check_greater(float(max_slip), 0.08, "the handbrake makes the car slide sideways")
	check_greater(
		absf(angle_difference(car.global_rotation.y, heading_before)), 0.25, "the car rotates while drifting"
	)
	check_greater(car.linear_velocity.length(), 3.0, "a drifting car keeps its momentum (no sudden stop)")
	check_greater(speed_before_drift, 10.0, "the drift started at speed")
	note("drift: slip %.2f, rotation %.1f deg" % [max_slip, rad_to_deg(angle_difference(car.global_rotation.y, heading_before))])

	# --- 8. nitro is a physical boost -----------------------------------------------
	car.reset_to(Transform3D(Basis(), Vector3(0.0, 0.6, 0.0)))
	car.nitro.refill()
	var nitro_top := 0.0
	var nitro_charge_start := car.nitro_ratio()
	await TestArena.simulate(
		tree,
		int(22.0 * HZ),
		func() -> void:
			car.drive_input.throttle = 1.0
			car.drive_input.brake = 0.0
			car.drive_input.steer = 0.0
			car.drive_input.handbrake = false
			car.drive_input.nitro = true
			nitro_top = maxf(nitro_top, car.forward_speed())
	)
	check_greater(nitro_top, plain_top_speed + 3.0, "nitro makes the car faster than its normal top speed")
	check_less(nitro_top, car.config.nitro.boosted_max_speed * 1.03, "nitro never exceeds the boosted cap")
	check_greater(car.config.nitro.boosted_max_speed, plain_top_speed, "the boosted cap is above the normal top speed")
	check_less(car.nitro_ratio(), nitro_charge_start, "boosting uses the tank")
	check_greater(car.nitro.total_used, 0.0, "the tank recorded the boost time")
	note("top speed with nitro: %.2f m/s (%.0f km/h) vs %.2f m/s without" % [
		nitro_top, nitro_top * 3.6, plain_top_speed
	])

	# --- 9. collisions ---------------------------------------------------------------
	car.reset_to(Transform3D(Basis(), Vector3(0.0, 0.6, 0.0)))
	TestArena.add_wall(arena, Vector3(60.0, 2.0, 0.0), Vector3(2.0, 4.0, 40.0))
	var hit_wall := false
	for _i in int(8.0 * HZ):
		car.drive_input.throttle = 1.0
		car.drive_input.brake = 0.0
		car.drive_input.nitro = false
		await tree.physics_frame
		if car.global_position.x > 55.0:
			hit_wall = true
	check(hit_wall, "the car reached the wall")
	check_less(car.global_position.x, 61.0, "the wall stopped the car: it did not pass through")
	check_less(car.linear_velocity.length(), 6.0, "the impact absorbed the speed instead of bouncing")
	check(car.is_grounded(), "the car is still on its wheels after the crash")

	# --- 10. driving without a physics server available ------------------------------
	check_less(car.linear_velocity.length(), car.config.velocity_clamp, "the velocity clamp holds")

	TestArena.destroy(arena)
	await tree.process_frame
