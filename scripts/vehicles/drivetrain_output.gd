extends RefCounted
class_name DrivetrainOutput
## What the drivetrain asks the physics to do this frame.
##
## The VehicleController produces this structure every physics tick and the VehiclePhysics
## consumes it. Keeping it a plain data object means the drivetrain can be unit tested on
## its own (does the gearbox shift up at the right engine speed? does nitro raise the
## speed cap?) and the physics can be tested with a hand written output, without any of
## them requiring the other.

## Highest forward speed the car is allowed to reach this frame, in m/s. Depends on
## whether nitro is active and on the car's configuration.
var max_speed: float = 46.0
## Highest reverse speed, in m/s (positive number).
var reverse_max_speed: float = 12.0
## Multiplier applied to the aerodynamic drag (nitro lowers it, which raises top speed).
var drag_multiplier: float = 1.0
## Extra downforce (N per (m/s)^2, halved) while boosting.
var downforce_bonus: float = 0.0
## Engine speed in rpm, for the tachometer, the audio and the gearbox.
var engine_rpm: float = 800.0
## Current gear: 0 = reverse, 1..gear_count = forward gears.
var gear: int = 1
## True while a gear change is in progress (torque is cut).
var shifting: bool = false
## True while nitro is burning.
var boosting: bool = false
## Throttle actually delivered to the engine (after traction/gearbox logic), 0..1.
var effective_throttle: float = 0.0
## Total drive torque at the crankshaft this frame, in N*m (signed: negative = reverse).
var crank_torque: float = 0.0
## True while the driver holds the handbrake.
var handbrake: bool = false
## True when the car is limited by its speed cap rather than by the engine.
var speed_limited: bool = false


## Copies every field of another output (used by the controller to publish its state).
func copy_from(other: DrivetrainOutput) -> void:
	max_speed = other.max_speed
	reverse_max_speed = other.reverse_max_speed
	drag_multiplier = other.drag_multiplier
	downforce_bonus = other.downforce_bonus
	engine_rpm = other.engine_rpm
	gear = other.gear
	shifting = other.shifting
	boosting = other.boosting
	effective_throttle = other.effective_throttle
	crank_torque = other.crank_torque
	handbrake = other.handbrake
	speed_limited = other.speed_limited


func to_dictionary() -> Dictionary:
	return {
		"max_speed": max_speed,
		"drag_multiplier": drag_multiplier,
		"rpm": engine_rpm,
		"gear": gear,
		"shifting": shifting,
		"boosting": boosting,
		"throttle": effective_throttle,
		"crank_torque": crank_torque,
		"speed_limited": speed_limited,
	}


func describe() -> String:
	return (
		"gear=%d rpm=%.0f throttle=%.2f torque=%.0fNm max=%.1fm/s shift=%s boost=%s limited=%s"
		% [
			gear,
			engine_rpm,
			effective_throttle,
			crank_torque,
			max_speed,
			str(shifting),
			str(boosting),
			str(speed_limited),
		]
	)
