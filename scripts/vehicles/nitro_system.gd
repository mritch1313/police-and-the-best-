extends RefCounted
class_name NitroSystem
## Nitro (NOS) tank of a car.
##
## Hard rules of this project: nitro NEVER moves the car. It does not touch the transform,
## it does not add impulses and it does not teleport anything. It only raises the torque
## the drivetrain is allowed to produce, lowers the aerodynamic drag and raises the speed
## cap the physics enforces - all of which still travel through the tyre model, so a
## boosting car can still spin its wheels, lose grip and crash.
##
## The tank is modelled in seconds of boost, which is what the HUD shows and what the
## balance of the game is expressed in (a full tank = `capacity_seconds` of boost).

## Remaining boost in seconds.
var charge: float = 0.0
## True while the tank is delivering boost.
var active: bool = false
## Blocking cooldown after the tank ran dry.
var cooldown: float = 0.0
## Time left before the tank starts refilling after a release.
var recharge_delay_timer: float = 0.0
## Set for one frame when the boost starts (drives the flame effect and the sound).
var just_activated: bool = false
## Set for one frame when the tank runs dry.
var just_depleted: bool = false
## Total seconds of boost burnt since the last reset (statistics).
var total_used: float = 0.0

var config: NitroConfig


func _init(p_config: NitroConfig = null) -> void:
	config = p_config if p_config != null else NitroConfig.new()
	charge = config.capacity_seconds


## Advances the tank by one physics tick. `requested` is the driver's nitro button.
## Returns true while the boost is active.
func update(delta: float, requested: bool) -> bool:
	just_activated = false
	just_depleted = false
	var safe_delta := maxf(delta, 0.0)
	if active:
		if not requested:
			active = false
			recharge_delay_timer = config.recharge_delay
		else:
			charge -= safe_delta
			total_used += safe_delta
			if charge <= 0.0:
				charge = 0.0
				active = false
				just_depleted = true
				cooldown = config.empty_cooldown
				recharge_delay_timer = config.recharge_delay
	if not active:
		if cooldown > 0.0:
			cooldown = maxf(0.0, cooldown - safe_delta)
		if recharge_delay_timer > 0.0:
			recharge_delay_timer = maxf(0.0, recharge_delay_timer - safe_delta)
		else:
			charge = minf(config.capacity_seconds, charge + config.recharge_seconds_per_second * safe_delta)
		if requested and can_activate():
			active = true
			just_activated = true
	return active


## True when the driver may start (or restart) a boost right now.
func can_activate() -> bool:
	return charge >= config.minimum_to_start and cooldown <= 0.0


func is_boosting() -> bool:
	return active


## Fraction of the tank that is full, for the HUD bar (0..1).
func charge_ratio() -> float:
	if config.capacity_seconds <= 0.0:
		return 0.0
	return clampf(charge / config.capacity_seconds, 0.0, 1.0)


## Seconds until the tank is full again, used by the HUD hint.
func seconds_until_full() -> float:
	var missing := config.capacity_seconds - charge
	if missing <= 0.0:
		return 0.0
	return missing / maxf(config.recharge_seconds_per_second, 0.0001) + recharge_delay_timer


func torque_multiplier() -> float:
	return config.torque_multiplier if active else 1.0


func drag_multiplier() -> float:
	return config.drag_multiplier if active else 1.0


func downforce_bonus() -> float:
	return config.downforce_bonus if active else 0.0


func boosted_max_speed() -> float:
	return config.boosted_max_speed


## Refills the tank (a fresh run, a repair pickup or a test).
func refill() -> void:
	charge = config.capacity_seconds
	active = false
	cooldown = 0.0
	recharge_delay_timer = 0.0


func to_dictionary() -> Dictionary:
	return {
		"charge": charge,
		"ratio": charge_ratio(),
		"active": active,
		"cooldown": cooldown,
		"total_used": total_used,
	}
