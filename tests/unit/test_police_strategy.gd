extends TestCase
## The police decision making. `PoliceStrategy.choose()` is a pure function of a situation, so
## every branch of the AI can be checked here without a scene: what happens when the player is
## seen, when the player is lost, when a unit is blocked and when the fleet is big enough to
## box the player in.


func _suite_name() -> String:
	return "unit/police_strategy"


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/police_config.tres") as PoliceConfig
	check_not_null(config, "police_config.tres must load")
	if config == null:
		return

	# --- a unit with no heat patrols ------------------------------------------------
	var calm := _situation()
	calm.heat_level = 0
	calm.sees_player = true
	calm.has_line_of_sight = true
	calm.distance_to_player = 10.0
	check(
		PoliceStrategy.choose(calm, config, PoliceStrategy.Strategy.SPAWN, 99.0)
		== PoliceStrategy.Strategy.PATROL,
		"no heat means no chase"
	)

	# --- lost contact: search, then give up ----------------------------------------
	var lost := _situation()
	lost.heat_level = 2
	lost.sees_player = false
	lost.has_line_of_sight = false
	lost.time_since_seen = 10.0
	check(
		PoliceStrategy.choose(lost, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.SEARCH,
		"a unit that lost the player searches the last known position"
	)
	lost.time_since_seen = 0.5
	check(
		PoliceStrategy.choose(lost, config, PoliceStrategy.Strategy.RAM, 99.0)
		== PoliceStrategy.Strategy.PURSUE,
		"a unit that just lost sight keeps chasing"
	)
	lost.time_since_seen = 120.0
	check(
		PoliceStrategy.choose(lost, config, PoliceStrategy.Strategy.SEARCH, 99.0)
		== PoliceStrategy.Strategy.PATROL,
		"a cold trail ends the search"
	)

	# --- close range: ram ----------------------------------------------------------
	var close := _situation()
	close.heat_level = 2
	close.sees_player = true
	close.has_line_of_sight = true
	close.distance_to_player = config.ram_distance - 1.0
	check(
		PoliceStrategy.choose(close, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.RAM,
		"a unit right behind the player rams"
	)

	# --- mid range: pursue ---------------------------------------------------------
	close.distance_to_player = config.pursue_distance - 5.0
	check(
		PoliceStrategy.choose(close, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.PURSUE,
		"a unit at pursuit range follows"
	)

	# --- a second unit boxes the player in ----------------------------------------
	close.distance_to_player = config.box_in_distance - 2.0
	close.active_units = 3
	close.unit_index = 1
	check(
		PoliceStrategy.choose(close, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.BOX_IN,
		"a supporting unit pulls alongside"
	)

	# --- far away with heat: intercept --------------------------------------------
	var far := _situation()
	far.heat_level = 3
	far.sees_player = true
	far.has_line_of_sight = true
	far.distance_to_player = config.pursue_distance + 40.0
	far.unit_index = 1
	check(
		PoliceStrategy.choose(far, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.INTERCEPT,
		"a far unit cuts ahead instead of following"
	)
	far.unit_index = 0
	check(
		PoliceStrategy.choose(far, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.PURSUE,
		"the first unit always stays on the player's tail"
	)

	# --- a blocked unit repositions ------------------------------------------------
	var blocked := _situation()
	blocked.blocked = true
	blocked.heat_level = 3
	check(
		PoliceStrategy.choose(blocked, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.INTERCEPT,
		"a blocked unit with backup repositions"
	)
	blocked.heat_level = 1
	check(
		PoliceStrategy.choose(blocked, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.SEARCH,
		"a blocked unit without backup searches"
	)

	# --- the strategy is held for a moment, not re-chosen every frame --------------
	var flicker := _situation()
	flicker.heat_level = 2
	flicker.sees_player = true
	flicker.has_line_of_sight = true
	flicker.distance_to_player = config.ram_distance - 1.0
	check(
		PoliceStrategy.choose(flicker, config, PoliceStrategy.Strategy.PURSUE, 0.1)
		== PoliceStrategy.Strategy.PURSUE,
		"a strategy is held for strategy_hold_time"
	)

	# --- the player stopped --------------------------------------------------------
	var parked := _situation()
	parked.heat_level = 2
	parked.sees_player = true
	parked.has_line_of_sight = true
	parked.distance_to_player = config.ram_distance - 1.0
	parked.player_speed = 0.0
	parked.unit_index = 0
	check(
		PoliceStrategy.choose(parked, config, PoliceStrategy.Strategy.PURSUE, 99.0)
		== PoliceStrategy.Strategy.PURSUE,
		"a stopped player is closed in on, not rammed"
	)

	# --- the helper tables --------------------------------------------------------
	check_greater(PoliceStrategy.throttle_for(PoliceStrategy.Strategy.PURSUE), 0.9, "pursuit is flat out")
	check_less(PoliceStrategy.throttle_for(PoliceStrategy.Strategy.BLOCK_ROAD), 0.6, "a blocking unit drives slowly")
	check_greater(
		PoliceStrategy.target_speed(PoliceStrategy.Strategy.PURSUE, config, 200.0),
		PoliceStrategy.target_speed(PoliceStrategy.Strategy.SEARCH, config, 200.0),
		"pursuit is faster than a search"
	)
	check(PoliceStrategy.is_hunting(PoliceStrategy.Strategy.RAM), "ramming counts as hunting")
	check(not PoliceStrategy.is_hunting(PoliceStrategy.Strategy.PATROL), "patrolling is not hunting")
	check(PoliceStrategy.name_of(PoliceStrategy.Strategy.INTERCEPT) == "intercept", "strategy names are stable")
	check_between(
		PoliceStrategy.arrival_radius(PoliceStrategy.Strategy.RAM), 0.5, 3.0, "a ram ends very close"
	)


func _situation() -> PoliceStrategy.Situation:
	var situation := PoliceStrategy.Situation.new()
	situation.unit_index = 0
	situation.active_units = 3
	return situation
