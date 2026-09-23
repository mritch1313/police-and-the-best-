extends TestCase
## The input snapshot: dead zones, sanitising and the neutral test used by the AI and by the
## "is the player actually driving" checks.


func _suite_name() -> String:
	return "unit/drive_input"


func run(_tree: SceneTree) -> void:
	var input := DriveInput.new()
	check(input.is_neutral(), "a fresh snapshot is neutral")

	input.throttle = 1.0
	check(not input.is_neutral(), "throttle breaks neutrality")

	input.reset()
	check(input.is_neutral(), "reset clears the snapshot")

	input.steer = 0.5
	input.brake = 0.4
	input.nitro = true
	input.handbrake = true
	var copy := input.copy()
	check_almost(copy.steer, 0.5, 0.0001, "copy keeps the steering")
	check(copy.nitro, "copy keeps nitro")
	check(copy.handbrake, "copy keeps the handbrake")

	var target := DriveInput.new()
	target.copy_from(copy)
	check_almost(target.steer, 0.5, 0.0001, "copy_from copies the steering")
	check_almost(target.brake, 0.4, 0.0001, "copy_from copies the brake")
	check(target.nitro, "copy_from copies nitro")

	# Dead zone: a worn thumb must not steer the car.
	var dead := DriveInput.new()
	dead.steer = 0.04
	dead.apply_dead_zone(0.12)
	check_almost(dead.steer, 0.0, 0.0001, "the dead zone kills a tiny steering input")
	var live := DriveInput.new()
	live.steer = 0.6
	live.apply_dead_zone(0.12)
	check_greater(live.steer, 0.4, "a real steering input survives the dead zone")

	# Sanitising: an AI or a broken device must never push a value out of range.
	var wild := DriveInput.new()
	wild.throttle = 4.0
	wild.brake = -3.0
	wild.steer = 9.0
	wild.look_delta = Vector2(9999.0, 9999.0)
	wild.sanitize()
	check_between(wild.throttle, 0.0, 1.0, "throttle is clamped")
	check_between(wild.brake, 0.0, 1.0, "brake is clamped")
	check_between(wild.steer, -1.0, 1.0, "steer is clamped")
	check_less(wild.look_delta.length(), 1000.0, "look delta is clamped")

	# Merging is what turns keyboard + touch + gamepad into one snapshot.
	var keyboard := DriveInput.new()
	keyboard.steer = 1.0
	var touch := DriveInput.new()
	touch.steer = -1.0
	keyboard.merge(touch, 1.0)
	check_almost(keyboard.steer, 0.0, 0.0001, "opposite inputs cancel out")
	var gas := DriveInput.new()
	gas.throttle = 0.5
	var pad := DriveInput.new()
	pad.throttle = 1.0
	gas.merge(pad, 1.0)
	check_greater(gas.throttle, 0.5, "the strongest throttle wins")
