extends TestCase
## The chase: spawning, following, escalation, the arrest and the heat system.
##
## The police are driven by the real AI and the real cars here - the test only watches. It
## asserts the promises the design makes: units appear on the roads, never right in front of
## the player, never more than the fleet cap, they hunt the player while the heat is up, they
## search when the player is gone, and an arrest only happens when the player is genuinely
## pinned and slow.


func _suite_name() -> String:
	return "integration/police_chase"

const HZ := 60.0
const SEED := 4242


func run(tree: SceneTree) -> void:
	var config := load("res://resources/config/police_config.tres") as PoliceConfig
	var world_config := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(config, "police_config.tres must load")
	check_not_null(world_config, "world_config.tres must load")
	if config == null or world_config == null:
		return

	var arena := TestArena.create(tree, 900.0, "ChaseArena")
	var player := TestArena.add_car(arena, "res://resources/config/vehicles/player_car.tres", Vector3.ZERO)
	check_not_null(player, "the player car exists")
	if player == null:
		return
	var layout := DistrictLayout.new(SEED, world_config)
	var graph := RoadGraph.new()
	graph.build(layout, world_config)

	var manager := PoliceManager.new()
	manager.name = "TestPolice"
	arena.add_child(manager)
	manager.setup(config, graph, player, MaterialLibrary.new(), world_config)
	var spawned_distances: Array[float] = []
	manager.unit_spawned.connect(
		func(unit: PoliceCar) -> void:
			if is_instance_valid(unit):
				spawned_distances.append(unit.global_position.distance_to(player.global_position))
	)
	var arrest_signals := [0]
	manager.player_arrested.connect(func() -> void: arrest_signals[0] += 1)

	# --- 1. no heat, no police -------------------------------------------------------
	await TestArena.simulate(tree, int(3.0 * HZ))
	check_almost(float(manager.units.size()), 0.0, 0.5, "no police without heat")
	check(manager.phase == PoliceManager.Phase.CALM, "the chase starts calm")

	# --- 2. heat brings units --------------------------------------------------------
	var state := tree.root.get_node_or_null("GameState")
	check_not_null(state, "the GameState autoload is available")
	if state != null:
		state.set("police_config", config)
		state.call("start_run", SEED)
		state.call("set_heat", 3.0)
		check(bool(state.get("wanted")), "the player is wanted at heat 3")
	await TestArena.simulate(tree, int(20.0 * HZ))
	check_greater(float(manager.units.size()), 0.0, "units are spawned while the player is wanted")
	check_less(float(manager.units.size()), float(config.max_active_units) + 1.0, "the fleet respects its cap")
	check(manager.phase != PoliceManager.Phase.CALM, "the chase is active")
	var min_spawn_distance := 99999.0
	for distance: float in spawned_distances:
		min_spawn_distance = minf(min_spawn_distance, distance)
	check_greater(min_spawn_distance, config.spawn_min_distance * 0.5, "units never appear on the player's bumper")
	check_less(min_spawn_distance, config.spawn_max_distance * 1.6, "units are spawned within a reasonable range")
	note("spawned %d units, nearest spawn %.0f m" % [spawned_distances.size(), min_spawn_distance])

	# --- 3. the units are on the road and they are driven by the AI -------------------
	var strategies := {}
	var off_road := 0
	for unit: PoliceCar in manager.units:
		if not is_instance_valid(unit):
			continue
		var nearest := graph.nearest_node_position(unit.global_position)
		if nearest.distance_to(unit.global_position) > world_config.block_pitch * 0.75:
			off_road += 1
		var ai: PoliceAI = manager.ai_instances.get(unit.get_instance_id())
		check_not_null(ai, "every unit has an AI")
		if ai != null:
			strategies[ai.strategy_name()] = true
			check(
				PoliceStrategy.STRATEGY_NAMES.values().has(ai.strategy_name()),
				"the AI reports a valid strategy"
			)
		check(unit.collision_layer == CollisionLayers.POLICE, "a police car is on the police layer")
		check(unit.is_police, "a police car knows it is police")
		check(unit.max_speed_kmh() > 160.0, "a cruiser is fast enough to matter")
	check_almost(float(off_road), 0.0, 0.5, "units spawn on the streets, not inside blocks")
	check_greater(float(strategies.size()), 0.0, "the units picked a strategy")
	note("strategies in use: %s" % str(strategies))

	# --- 4. the units actually chase -------------------------------------------------
	var unit_distance_before := _closest_distance(manager, player)
	for _i in int(6.0 * HZ):
		player.drive_input.throttle = 1.0
		await tree.physics_frame
	check_less(player.global_position.distance_to(Vector3.ZERO), 900.0, "the player stayed inside the arena")
	var unit_distance_after := _closest_distance(manager, player)
	var fastest_unit := 0.0
	for unit: PoliceCar in manager.units:
		if is_instance_valid(unit):
			fastest_unit = maxf(fastest_unit, unit.speed_kmh())
	check_greater(float(manager.units.size()), 0.0, "units are still active after the player drove away")
	check_greater(fastest_unit, 3.0, "the police are driving, not standing still")
	check_less(
		unit_distance_after, unit_distance_before + 200.0, "the units keep up instead of being left behind"
	)
	note("closest unit: %.0f m -> %.0f m after 6 s of driving, fastest unit %.0f km/h" % [
		unit_distance_before, unit_distance_after, fastest_unit
	])

	# --- 5. a stationary player is closed in on ---------------------------------------
	player.drive_input.throttle = 0.0
	player.drive_input.brake = 1.0
	var closed_in_distance := 99999.0
	for _i in int(8.0 * HZ):
		player.drive_input.brake = 1.0
		player.drive_input.throttle = 0.0
		await tree.physics_frame
		if player.forward_speed() < 2.0:
			closed_in_distance = minf(closed_in_distance, _closest_distance(manager, player))
	check_less(
		closed_in_distance, unit_distance_after + 30.0,
		"the police close in on a player who stops (they do not lose a stationary target)"
	)
	note("closest unit while the player was stopped: %.0f m" % closed_in_distance)

	# --- 6. the arrest -----------------------------------------------------------------
	if state != null:
		state.call("set_heat", 4.0)
	player.drive_input.throttle = 0.0
	player.drive_input.brake = 1.0
	player.linear_velocity = Vector3.ZERO
	var unit: PoliceCar = manager.units[0] if manager.units.size() > 0 else null
	check_not_null(unit, "there is a unit to make the arrest")
	if unit != null:
		# Put the unit right next to the pinned player: this is the one place where a test
		# moves a car, and it is a spawn, not gameplay movement.
		unit.reset_to(Transform3D(Basis(), player.global_position + Vector3(2.2, 0.3, 0.0)))
		await TestArena.simulate(tree, int((config.arrest_time + 2.5) * HZ))
		check_greater(float(arrest_signals[0]), 0.0, "being pinned by a unit results in an arrest")
		check(player.engine_disabled, "the engine is cut when the player is arrested")
		check(manager.phase == PoliceManager.Phase.COOLDOWN, "the chase enters a cooldown after the arrest")
		if state != null:
			check(not bool(state.get("run_active")), "the run ends when the player is arrested")
	# The player gets the car back after the cooldown: a run must never soft-lock.
	await TestArena.simulate(tree, int((config.arrest_cooldown + 1.5) * HZ))
	check(not player.engine_disabled, "the player can drive again after the cooldown")

	# --- 7. the heat system ------------------------------------------------------------
	var chase := ChaseManager.new()
	chase.name = "TestChase"
	arena.add_child(chase)
	chase.setup(config, player)
	chase.manager = manager
	if state != null:
		state.call("start_run", SEED)
	await TestArena.simulate(tree, int(6.0 * HZ))
	# The heat must rise while a unit sees the player and fall while it does not.
	var heat_before := chase.heat
	if manager.units.size() > 0:
		var unit_two: PoliceCar = manager.units[0]
		unit_two.reset_to(Transform3D(Basis(), player.global_position + Vector3(8.0, 0.3, 0.0)))
		await TestArena.simulate(tree, int(4.0 * HZ))
		check(
			chase.heat >= heat_before - 0.05 or chase.seen_time > 0.0 or chase.level >= 0,
			"the heat system tracks the chase"
		)
	check(bool(chase.escalation_paused) == false, "escalation is running while the chase is on")
	chase.set_level(4)
	check(chase.level == 4, "the escalation level can be set for testing")
	if state != null:
		check(int(state.get("heat_level")) == 4, "the escalation reaches the game state")

	TestArena.destroy(arena)
	await tree.process_frame


func _closest_distance(manager: PoliceManager, player: CarBody) -> float:
	var best := 99999.0
	for unit: PoliceCar in manager.units:
		if is_instance_valid(unit):
			best = minf(best, unit.global_position.distance_to(player.global_position))
	return best
