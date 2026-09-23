extends RefCounted
class_name PoliceStrategy
## Chooses what a police unit does this second.
##
## The AI is a small set of clearly named strategies instead of one big "chase" behaviour,
## because that is what makes a chase feel alive: two units behind the player, one cutting
## ahead through a side street, one waiting at the next junction. It is also what makes the
## AI testable - the chooser is a pure function of a few numbers, so the unit tests can
## assert "a unit that cannot see the player switches to SEARCH" without a scene.
##
## Every strategy maps to a target point and a driving style that `police_ai.gd` turns into
## pedals and steering.

enum Strategy {
	SPAWN,       ## driving in from a distance, not yet part of the chase
	PURSUE,      ## directly behind the player, matching their line
	RAM,         ## close range, aiming at the player's bumper
	BOX_IN,      ## a second unit pulling alongside to trap the player
	INTERCEPT,   ## predicting where the player is going and cutting them off
	BLOCK_ROAD,  ## stopping across the road ahead of the player
	SEARCH,      ## the player is out of sight: driving to their last known position
	PATROL,      ## no chase: cruising the grid
}

const STRATEGY_NAMES := {
	Strategy.SPAWN: "spawn",
	Strategy.PURSUE: "pursue",
	Strategy.RAM: "ram",
	Strategy.BOX_IN: "box_in",
	Strategy.INTERCEPT: "intercept",
	Strategy.BLOCK_ROAD: "block_road",
	Strategy.SEARCH: "search",
	Strategy.PATROL: "patrol",
}

## How long a unit keeps chasing after it lost sight of the player (seconds).
const SEARCH_DELAY := 1.5
## How long a unit searches the last known position before going back to patrol (seconds).
const SEARCH_GIVE_UP_TIME := 25.0

## Everything the chooser needs to know. A plain data object, so the tests can build it by
## hand and the AI does not have to reach into the scene tree.
class Situation:
	extends RefCounted
	var distance_to_player: float = 999.0
	var player_speed: float = 0.0
	var own_speed: float = 0.0
	var has_line_of_sight: bool = false
	var sees_player: bool = false
	var heat_level: int = 0
	var unit_index: int = 0
	var active_units: int = 0
	var time_since_seen: float = 999.0
	var player_on_road: bool = true
	var blocked: bool = false
	var near_intersection: bool = false


## Chooses a strategy. Pure function: same situation, same result, no randomness and no
## side effects (the caller adds a little noise to the *target*, not to the decision).
static func choose(
	situation: Situation,
	config: PoliceConfig,
	current: int,
	time_in_strategy: float
) -> int:
	if situation.blocked:
		# A unit that cannot move must not keep pushing into the wall: it repositions.
		return Strategy.INTERCEPT if situation.heat_level >= 2 else Strategy.SEARCH
	if situation.heat_level <= 0:
		# Nothing is happening: the unit patrols the grid and can become a witness later.
		return Strategy.PATROL
	if not situation.sees_player and not situation.has_line_of_sight:
		if situation.time_since_seen > SEARCH_GIVE_UP_TIME:
			# The trail is cold: back to patrolling instead of hunting an old position forever.
			return Strategy.PATROL
		# Lost the player: search the last known position before giving up.
		return Strategy.SEARCH if situation.time_since_seen > SEARCH_DELAY else Strategy.PURSUE
	if situation.player_speed < 2.0 and situation.distance_to_player < config.arrest_radius * 4.0:
		# The player stopped: close in for the arrest instead of ramming a stationary car.
		return Strategy.BOX_IN if situation.unit_index > 0 else Strategy.PURSUE
	# Hold the current decision for a moment so the AI does not flicker between strategies.
	if time_in_strategy < config.strategy_hold_time and current != Strategy.SPAWN:
		return current
	if situation.distance_to_player <= config.ram_distance and situation.has_line_of_sight:
		return Strategy.RAM
	if situation.distance_to_player <= config.box_in_distance and situation.active_units > 1 and situation.unit_index > 0:
		return Strategy.BOX_IN
	if situation.distance_to_player <= config.pursue_distance:
		return Strategy.PURSUE
	# Far away: some units cut ahead (intercept), some block a junction, the rest just chase.
	if situation.heat_level >= 2 and situation.unit_index % 2 == 1:
		return Strategy.INTERCEPT
	if situation.heat_level >= 3 and situation.unit_index % 3 == 2 and situation.near_intersection:
		return Strategy.BLOCK_ROAD
	return Strategy.PURSUE


## Throttle and brake cap a strategy allows. A blocking unit drives slowly, a chasing unit
## drives flat out - the physical car still decides what is possible.
static func throttle_for(strategy: int) -> float:
	match strategy:
		Strategy.SPAWN:
			return 0.55
		Strategy.PURSUE:
			return 1.0
		Strategy.RAM:
			return 1.0
		Strategy.BOX_IN:
			return 0.72
		Strategy.INTERCEPT:
			return 0.95
		Strategy.BLOCK_ROAD:
			return 0.45
		Strategy.SEARCH:
			return 0.7
		_:
			return 0.4


## How close the unit wants to be to its target point (metres).
static func arrival_radius(strategy: int) -> float:
	match strategy:
		Strategy.RAM:
			return 1.0
		Strategy.BOX_IN:
			return 3.0
		Strategy.BLOCK_ROAD:
			return 4.0
		Strategy.SEARCH:
			return 6.0
		Strategy.PATROL:
			return 8.0
		_:
			return 2.0


## Speed the unit tries to hold (m/s). Cars still obey their own physics and tyres.
static func target_speed(strategy: int, config: PoliceConfig, distance: float) -> float:
	var base := config.max_speed
	match strategy:
		Strategy.SPAWN:
			return base * 0.5
		Strategy.PURSUE:
			return base * clampf(distance / 25.0 + 0.45, 0.5, 1.0)
		Strategy.RAM:
			return base * 0.95
		Strategy.BOX_IN:
			return base * 0.7
		Strategy.INTERCEPT:
			return base
		Strategy.BLOCK_ROAD:
			return base * 0.4
		Strategy.SEARCH:
			return base * 0.65
		_:
			return base * 0.45


static func name_of(strategy: int) -> String:
	return STRATEGY_NAMES.get(strategy, "unknown")


## True when the strategy means "actively hunting the player".
static func is_hunting(strategy: int) -> bool:
	return strategy in [Strategy.PURSUE, Strategy.RAM, Strategy.BOX_IN, Strategy.INTERCEPT, Strategy.BLOCK_ROAD]


## True when the strategy means "looking for the player".
static func is_searching(strategy: int) -> bool:
	return strategy == Strategy.SEARCH
