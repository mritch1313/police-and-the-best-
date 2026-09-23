extends RefCounted
class_name DriveInput
## One immutable-per-frame snapshot of everything the driver asks the car to do.
##
## Every input source (touch controls, keyboard, gamepad, an AI driver or a test) writes
## into this structure and the vehicle only ever reads it. That single seam is what makes
## the car testable: a unit test can build a DriveInput by hand and check what the physics
## does with it, without any device or scene involved.

## -1 = full left, +1 = full right.
var steer: float = 0.0
## 0..1 accelerator pedal.
var throttle: float = 0.0
## 0..1 service brake pedal.
var brake: float = 0.0
## Handbrake: locks the rear wheels and removes rear lateral grip.
var handbrake: bool = false
## Nitro requested by the driver (the NitroSystem decides whether it is available).
var nitro: bool = false
## True while the driver explicitly asks for reverse (some input layouts use a button).
var reverse_requested: bool = false
## Optional camera look delta for this frame, in "pixels".
var look_delta: Vector2 = Vector2.ZERO
## Optional camera zoom delta for this frame.
var zoom_delta: float = 0.0
## True when the player asked for the camera to be reset behind the car.
var camera_reset: bool = false
## Source of this snapshot, used by the UI and by the tests.
var source: StringName = &"none"


## Clears every field back to neutral.
func reset() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	nitro = false
	reverse_requested = false
	look_delta = Vector2.ZERO
	zoom_delta = 0.0
	camera_reset = false
	source = &"none"


## Returns a copy of this snapshot.
## Copies the state of another snapshot into this one (used by the player car, which reads
## the merged input manager snapshot into its own frame state).
func copy_from(other: DriveInput) -> void:
	if other == null:
		reset()
		return
	steer = other.steer
	throttle = other.throttle
	brake = other.brake
	handbrake = other.handbrake
	nitro = other.nitro
	reverse_requested = other.reverse_requested
	look_delta = other.look_delta
	zoom_delta = other.zoom_delta
	camera_reset = other.camera_reset
	source = other.source


func copy() -> DriveInput:
	var other := DriveInput.new()
	other.steer = steer
	other.throttle = throttle
	other.brake = brake
	other.handbrake = handbrake
	other.nitro = nitro
	other.reverse_requested = reverse_requested
	other.look_delta = look_delta
	other.zoom_delta = zoom_delta
	other.camera_reset = camera_reset
	other.source = source
	return other


## True when the driver is not asking for anything at all.
func is_neutral() -> bool:
	return (
		is_zero_approx(steer)
		and is_zero_approx(throttle)
		and is_zero_approx(brake)
		and not handbrake
		and not nitro
		and not reverse_requested
	)


## Clamps every field into its legal range. Called by the sources, and by the tests to
## prove that a hostile input cannot push the physics outside its envelope.
func sanitize() -> void:
	steer = clampf(steer, -1.0, 1.0)
	throttle = clampf(throttle, 0.0, 1.0)
	brake = clampf(brake, 0.0, 1.0)
	if not is_finite(steer):
		steer = 0.0
	if not is_finite(throttle):
		throttle = 0.0
	if not is_finite(brake):
		brake = 0.0


## Applies a dead zone and rescales the remaining range, so a worn analogue stick or a
## fat thumb does not leave the car creeping.
func apply_dead_zone(dead_zone: float) -> void:
	if absf(steer) < dead_zone:
		steer = 0.0
	else:
		steer = signf(steer) * (absf(steer) - dead_zone) / maxf(0.0001, 1.0 - dead_zone)
	if throttle < dead_zone and throttle > 0.0:
		throttle = 0.0
	if brake < dead_zone and brake > 0.0:
		brake = 0.0


## Blends another snapshot on top of this one (used to merge keyboard and touch).
func merge(other: DriveInput, weight: float = 1.0) -> void:
	if absf(other.steer) > absf(steer):
		steer = clampf(steer + other.steer * weight, -1.0, 1.0)
	throttle = clampf(throttle + other.throttle * weight, 0.0, 1.0)
	brake = clampf(brake + other.brake * weight, 0.0, 1.0)
	handbrake = handbrake or other.handbrake
	nitro = nitro or other.nitro
	reverse_requested = reverse_requested or other.reverse_requested
	look_delta += other.look_delta
	zoom_delta += other.zoom_delta
	camera_reset = camera_reset or other.camera_reset
	if other.source != &"none":
		source = other.source


## Text form used by the smoke test report and by the on-screen debug overlay.
func to_string() -> String:
	return (
		"DriveInput(steer=%.3f throttle=%.3f brake=%.3f handbrake=%s nitro=%s reverse=%s src=%s)"
		% [steer, throttle, brake, str(handbrake), str(nitro), str(reverse_requested), str(source)]
	)
