extends TestCase
## Nitro: the tank, the drain, the recharge and the physical bonuses. The rule of the game is
## that nitro never moves the car - it only scales torque, drag, downforce and the speed cap.


func _suite_name() -> String:
	return "unit/nitro_system"


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/nitro_config.tres") as NitroConfig
	check_not_null(config, "nitro_config.tres must load")
	if config == null:
		return
	var nitro := NitroSystem.new(config)
	check_almost(nitro.charge_ratio(), 1.0, 0.0001, "a fresh tank is full")
	check(nitro.can_activate(), "a full tank can be used")
	check(not nitro.is_boosting(), "the tank is closed until it is asked for")

	# Holding the button drains the tank at exactly one second of charge per second.
	var dt := 1.0 / 60.0
	var drained := 0.0
	for _i in 60:
		nitro.update(dt, true)
		drained += dt
	check_almost(nitro.charge, config.capacity_seconds - drained, 0.02, "one second of boost drains one second of tank")
	check(nitro.is_boosting(), "the tank is open while the button is held")
	check_greater(nitro.torque_multiplier(), 1.0, "boost multiplies the torque")
	check_less(nitro.drag_multiplier(), 1.0, "boost reduces the drag")
	check_greater(
		nitro.boosted_max_speed(), 0.0, "boost raises the speed cap"
	)
	check_almost(
		nitro.boosted_max_speed(),
		config.boosted_max_speed,
		0.001,
		"the boosted speed cap comes from the configuration"
	)

	# The tank empties, the boost stops and the recharge is delayed.
	var empty_frames := 0
	while nitro.charge > 0.001 and empty_frames < 1000:
		nitro.update(dt, true)
		empty_frames += 1
	check_less(nitro.charge, 0.001, "the tank can be drained completely")
	check(not nitro.is_boosting(), "an empty tank stops boosting")
	check(not nitro.can_activate(), "an empty tank cannot be used again immediately")
	var charge_before := nitro.charge
	nitro.update(dt, false)
	check_almost(nitro.charge, charge_before, 0.001, "the recharge starts with a delay")
	for _i in 120:
		nitro.update(dt, false)
	check_greater(nitro.charge, charge_before, "the tank recharges while unused")

	# A refill (new run, reset button) restores the tank.
	nitro.refill()
	check_almost(nitro.charge, config.capacity_seconds, 0.0001, "refill restores the tank")
	check_almost(nitro.charge_ratio(), 1.0, 0.0001, "refill restores the ratio")

	# The whole point of nitro: it adds speed on top of the police's top speed.
	var player := load("res://resources/config/vehicles/player_car.tres") as VehicleConfig
	var cruiser := load("res://resources/config/vehicles/police_cruiser.tres") as VehicleConfig
	check_not_null(player, "player_car.tres must load")
	check_not_null(cruiser, "police_cruiser.tres must load")
	if player != null and cruiser != null and player.nitro != null:
		var boosted_cap := player.nitro.boosted_max_speed
		check_greater(boosted_cap, cruiser.max_speed, "boosted player is faster than the police")
		check_almost(
			boosted_cap / cruiser.max_speed, 1.25, 0.03, "boosted player is ~1.25x the police top speed"
		)
		check_almost(
			cruiser.max_speed / player.max_speed, 1.01, 0.005, "the police top speed is ~1.01x the player"
		)
		note(
			"speeds: player %.2f m/s, police %.2f m/s, player+nitro %.2f m/s"
			% [player.max_speed, cruiser.max_speed, boosted_cap]
		)
