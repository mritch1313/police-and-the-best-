extends TestCase
## The balance rules of the game, checked against the resources that ship with it.
##
## These are the numbers the design depends on: the police must be slightly faster than the
## player, the nitro must make the player clearly faster than the police, traffic must be
## slower than the player, and the world must be big enough to give the player 500 metres in
## every direction.


func _suite_name() -> String:
	return "unit/config_balance"

const VEHICLES := [
	"player_car",
	"police_cruiser",
	"traffic_sedan",
	"traffic_hatchback",
	"traffic_suv",
	"traffic_van",
	"traffic_truck",
	"traffic_bus",
]


func run(_tree: SceneTree) -> void:
	var loaded := {}
	for name: String in VEHICLES:
		var path := "res://resources/config/vehicles/%s.tres" % name
		var vehicle := load(path) as VehicleConfig
		check_not_null(vehicle, "%s must load" % path)
		if vehicle == null:
			continue
		loaded[name] = vehicle
		# Every car must be physically plausible, otherwise the physics produces nonsense.
		check_greater(vehicle.mass, 300.0, "%s has a real mass" % name)
		check_greater(vehicle.max_speed, 5.0, "%s can move" % name)
		check_between(vehicle.wheel_radius, 0.2, 0.7, "%s has a sane wheel radius" % name)
		check_between(vehicle.center_of_mass_height, 0.05, 1.2, "%s has a sane centre of mass" % name)
		check_greater(vehicle.engine_torque, 20.0, "%s has an engine" % name)
		check_between(vehicle.drive_layout, 0, 2, "%s uses a valid drivetrain layout" % name)
		check_greater(vehicle.body_size.x, 1.0, "%s has a body" % name)
		check_greater(vehicle.brake_torque, 500.0, "%s can stop" % name)
		check_between(vehicle.tyre_grip, 0.5, 2.0, "%s has believable grip" % name)
		check(vehicle.gear_count >= 1, "%s has at least one gear" % name)
		check_greater(vehicle.first_gear_ratio, vehicle.top_gear_ratio, "%s gears go from short to long" % name)

	var player: VehicleConfig = loaded.get("player_car")
	var police: VehicleConfig = loaded.get("police_cruiser")
	if player != null and police != null:
		check_greater(player.max_speed, 30.0, "the player car is a proper get-away car")
		check_almost(police.max_speed / player.max_speed, 1.01, 0.005, "police top speed is 1.01x the player")
		check_greater(police.mass, player.mass, "a cruiser is heavier than the player's car")
		check_greater(police.tyre_grip, player.tyre_grip - 0.05, "the police car grips as well as the player")
		check_not_null(player.nitro, "the player car has a nitro tank")
		if player.nitro != null:
			check_greater(player.nitro.torque_multiplier, 1.2, "nitro adds real torque")
			check_greater(player.nitro.boosted_max_speed, player.max_speed, "nitro raises the speed cap")
			check_almost(
				player.nitro.boosted_max_speed / police.max_speed,
				1.25,
				0.03,
				"a boosting player is 1.25x the police top speed"
			)
			check_greater(player.nitro.capacity_seconds, 1.0, "the tank lasts more than a second")
			check_less(player.nitro.capacity_seconds, 12.0, "the tank is a burst, not a permanent boost")

	# Traffic must never outrun the player, otherwise the city cannot be driven.
	for name: String in ["traffic_sedan", "traffic_hatchback", "traffic_suv", "traffic_van"]:
		var traffic: VehicleConfig = loaded.get(name)
		if traffic != null and player != null:
			check_less(traffic.max_speed, player.max_speed, "%s is slower than the player" % name)
	# Heavy vehicles are slower and heavier, which is what makes a truck an obstacle.
	var truck: VehicleConfig = loaded.get("traffic_truck")
	var bus: VehicleConfig = loaded.get("traffic_bus")
	var sedan: VehicleConfig = loaded.get("traffic_sedan")
	if truck != null and sedan != null:
		check_greater(truck.mass, sedan.mass, "the truck is heavier than the sedan")
		check_less(truck.max_speed, sedan.max_speed, "the truck is slower than the sedan")
	if bus != null and sedan != null:
		check_greater(bus.mass, sedan.mass, "the bus is heavier than the sedan")
		check_greater(bus.body_size.z, sedan.body_size.z, "the bus is longer than the sedan")

	# --- world --------------------------------------------------------------------
	var world := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(world, "world_config.tres must load")
	if world != null:
		check_greater(world.concrete_radius, 499.0, "the concrete covers 500 m in every direction")
		check_greater(world.stream_radius, world.concrete_radius, "the streaming radius covers the concrete")
		check_less(world.collision_radius, world.stream_radius, "collision costs less than streaming")
		check_less(world.lod0_distance, world.lod1_distance, "LOD thresholds are ordered")
		check_less(world.lod1_distance, world.lod2_distance, "LOD thresholds are ordered")
		check_greater(float(world.chunk_count()), 3.0, "the world is bigger than one chunk")
		check_between(world.chunk_size, 40.0, 300.0, "a chunk is a sensible size")
		check_greater(world.block_pitch, world.road_width * 2.0, "a block is bigger than the roads around it")
		check_greater(world.max_traffic_cars, 0.0, "there is traffic")
		check_between(world.min_floors, 1.0, float(world.max_floors), "floor range is valid")
		check_between(world.park_chance + world.yard_chance, 0.0, 0.4, "the city stays a city, not a park")
		check_greater(world.prop_density, 0.2, "the streets are furnished")
		var chunk_origin := world.chunk_origin(Vector2i(0, 0))
		check_almost(
			world.chunk_origin(Vector2i(1, 0)).x - chunk_origin.x, world.chunk_size, 0.01,
			"chunks tile the world exactly"
		)
		note("world: %.0f m across, %d chunks of %.0f m" % [world.world_size, world.chunk_count(), world.chunk_size])

	# --- police -------------------------------------------------------------------
	var police_config := load("res://resources/config/police_config.tres") as PoliceConfig
	check_not_null(police_config, "police_config.tres must load")
	if police_config != null:
		check_between(police_config.max_active_units, 1, 12, "the fleet has a sane cap")
		check_greater(police_config.despawn_distance, police_config.spawn_max_distance, "units despawn further away than they spawn")
		check_greater(police_config.arrest_time, 0.5, "an arrest takes time")
		check_greater(police_config.arrest_radius, 1.0, "an arrest needs the police to be close")
		check_greater(police_config.spawn_interval_for_heat(5), 0.0, "reinforcements keep coming")
		check_greater(
			float(police_config.units_for_heat(5)), float(police_config.units_for_heat(1)),
			"more heat means more units"
		)
		check(police_config.units_for_heat(5) <= police_config.max_active_units, "heat never exceeds the fleet cap")

	# --- graphics -----------------------------------------------------------------
	var graphics := load("res://resources/config/graphics_config.tres") as GraphicsConfig
	check_not_null(graphics, "graphics_config.tres must load")
	if graphics != null:
		check_between(graphics.preset, 0, 2, "the default preset is valid")
		check_greater(graphics.ambient_energy, 0.0, "the world is lit")
		check_less(graphics.fog_density, 0.02, "the fog does not swallow the city")
		check_greater(graphics.lod_bias_for_preset(), 0.0, "the LOD bias is positive")

	# --- gameplay / camera ---------------------------------------------------------
	var camera := load("res://resources/config/gameplay_config.tres") as CameraConfig
	check_not_null(camera, "gameplay_config.tres must hold the camera config")
	if camera != null:
		check_greater(camera.distance, 3.0, "the camera sits behind the car")
		check_less(camera.distance, 20.0, "the camera is not a fly-over")
		check_between(camera.fov, 45.0, 95.0, "the field of view is mobile friendly")
		check_greater(camera.touch_sensitivity, 0.0, "the camera can be rotated by touch")
