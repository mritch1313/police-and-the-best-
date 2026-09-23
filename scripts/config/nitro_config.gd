extends Resource
class_name NitroConfig
## Nitro (NOS) tuning. Nitro never moves the car directly: it only changes the torque
## available to the drivetrain and the speed cap the physics is allowed to reach.

@export_group("Boost")
## Engine torque multiplier while the boost is active.
@export_range(1.0, 5.0, 0.05) var torque_multiplier: float = 1.85
## Aerodynamic drag multiplier while boosting (lower drag = higher top speed).
@export_range(0.05, 1.0, 0.01) var drag_multiplier: float = 0.42
## Maximum speed in m/s while boosting. Set in the game config so that the boosted
## player is faster than the fastest police car (world balance rule).
@export_range(5.0, 200.0, 0.5) var boosted_max_speed: float = 58.0
## Extra downforce while boosting.
@export_range(0.0, 40.0, 0.1) var downforce_bonus: float = 8.0

@export_group("Tank")
## Seconds of continuous boost available with a full tank.
@export_range(0.5, 30.0, 0.1) var capacity_seconds: float = 4.0
## Seconds of boost regenerated per second while not boosting.
@export_range(0.05, 10.0, 0.05) var recharge_seconds_per_second: float = 0.42
## Delay before the tank starts refilling after the boost was released.
@export_range(0.0, 10.0, 0.1) var recharge_delay: float = 1.1
## Minimum amount of nitro needed to (re)start a boost.
@export_range(0.0, 2.0, 0.05) var minimum_to_start: float = 0.35
## Cooldown after the tank ran empty before it may be used again.
@export_range(0.0, 10.0, 0.1) var empty_cooldown: float = 0.8
## FOV boost added to the chase camera while boosting (visual feedback).
@export_range(0.0, 30.0, 0.5) var camera_fov_bonus: float = 9.0
## Visual flame scale while boosting.
@export_range(0.0, 4.0, 0.05) var flame_scale: float = 1.0


## Boosted top speed in km/h.
func boosted_max_speed_kmh() -> float:
	return boosted_max_speed * 3.6


## Average recharge rate needed to refill a full tank in `seconds`.
func recharge_rate_for_full_tank_in(seconds: float) -> float:
	if seconds <= 0.0:
		return recharge_seconds_per_second
	return capacity_seconds / seconds
