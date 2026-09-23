extends Resource
class_name PoliceConfig
## Everything about the police force: how many cars may exist, how fast they are, how
## they are allowed to behave and how the chase escalates. Kept as data so the chase can
## be re-balanced without touching a single AI script.

@export_group("Fleet")
## Maximum number of police cars alive at the same time. Mobile GPUs and the CPU cost of
## the AI scale directly with this number, so it is the main performance dial.
@export_range(0, 12, 1) var max_active_units: int = 5
## Units that start hunting the player at heat level 1 and grow per level.
@export_range(1, 12, 1) var units_at_level_one: int = 2
## Additional units per extra heat level.
@export_range(0, 4, 1) var units_per_heat_level: int = 1
## Seconds between two spawn attempts while the player is wanted.
@export_range(0.5, 60.0, 0.5) var spawn_interval: float = 11.0
## Minimum distance from the player at which a police car may appear.
@export_range(20.0, 600.0, 5.0) var spawn_min_distance: float = 110.0
## Maximum distance from the player at which a police car may appear (must stay inside
## the loaded world radius, otherwise the car is created off the streamed area).
@export_range(40.0, 900.0, 5.0) var spawn_max_distance: float = 260.0
## Distance at which a unit gives up, parks and is removed.
@export_range(100.0, 2000.0, 10.0) var despawn_distance: float = 480.0

@export_group("Performance envelope")
## Police top speed in m/s. The world balancing rule is player * 1.01, i.e. the police can
## slowly close in on a player who has no nitro, but never catch a boosting player.
@export_range(5.0, 150.0, 0.5) var max_speed: float = 46.46
## Acceleration multiplier applied to the police drivetrain (they are slightly better).
@export_range(0.5, 3.0, 0.05) var torque_scale: float = 1.06
## Grip bonus of the police tyres (they corner a little better than the player).
@export_range(0.5, 2.0, 0.02) var grip_scale: float = 1.03

@export_group("Behaviour")
## Distance from the player at which a unit switches from approach to pursuit.
@export_range(10.0, 200.0, 1.0) var pursue_distance: float = 55.0
## Distance considered "close enough" for a ramming attempt.
@export_range(2.0, 60.0, 0.5) var ram_distance: float = 9.0
## Distance for the boxing-in manoeuvre.
@export_range(10.0, 120.0, 1.0) var box_in_distance: float = 26.0
## Look-ahead time of the trajectory prediction (used for interception and ramming).
@export_range(0.2, 6.0, 0.1) var prediction_time: float = 1.35
## Seconds a unit keeps a strategy before re-evaluating.
@export_range(0.1, 10.0, 0.1) var strategy_hold_time: float = 1.6
## Reaction time before the spawn flash turns into an active unit.
@export_range(0.0, 5.0, 0.1) var spawn_warmup: float = 0.6
## How aggressively the AI steers (0..1).
@export_range(0.0, 1.0, 0.02) var steering_aggression: float = 0.92
## Braking distance kept from the player.
@export_range(2.0, 40.0, 0.5) var follow_distance: float = 11.0

@export_group("Arrest")
## Heat needed before the police consider an arrest.
@export_range(0, 10, 1) var min_heat_for_arrest: int = 1
## Distance under which an arrest can happen.
@export_range(1.0, 20.0, 0.1) var arrest_radius: float = 4.2
## Player speed (m/s) below which the arrest counts as "stopped".
@export_range(0.0, 20.0, 0.1) var arrest_max_player_speed: float = 2.6
## Seconds the player must stay pinned inside the arrest radius.
@export_range(0.5, 30.0, 0.1) var arrest_time: float = 3.2
## Seconds a unit is disabled after a heavy collision.
@export_range(0.0, 20.0, 0.5) var wrecked_recovery_time: float = 6.0
## Seconds the player is free after being arrested before the chase restarts.
@export_range(0.0, 30.0, 0.5) var arrest_cooldown: float = 6.0

@export_group("Heat")
## Heat gained per second while driving fast in view of a unit.
@export_range(0.0, 5.0, 0.01) var heat_gain_per_second: float = 0.045
## Heat lost per second while no unit can see the player.
@export_range(0.0, 5.0, 0.01) var heat_decay_per_second: float = 0.02
## Maximum heat level.
@export_range(1, 10, 1) var max_heat: int = 5
## Seconds without contact before heat drops by one level.
@export_range(1.0, 120.0, 0.5) var heat_decay_delay: float = 14.0


## Number of units that should be alive at a given heat level (clamped to the fleet cap).
func units_for_heat(heat: int) -> int:
	if heat <= 0:
		return 0
	var wanted := units_at_level_one + (heat - 1) * units_per_heat_level
	return clampi(wanted, 0, max_active_units)


## Spawn interval for a given heat level: the hotter the chase, the faster reinforcements.
func spawn_interval_for_heat(heat: int) -> float:
	var factor := clampf(1.0 - 0.12 * float(maxi(heat - 1, 0)), 0.35, 1.0)
	return spawn_interval * factor


## Top speed in km/h (UI).
func max_speed_kmh() -> float:
	return max_speed * 3.6
