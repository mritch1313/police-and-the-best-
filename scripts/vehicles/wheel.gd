extends RefCounted
class_name VehicleWheel
## Runtime state of a single wheel.
##
## The wheel owns its geometry (where the hub sits in the car's local space), its
## suspension state (how far it is compressed) and its tyre state (slip angle, slip
## ratio, the forces the tyre currently produces). The controller writes the inputs
## (steering angle, drive torque, brake torque), the wheel system writes the geometry and
## the suspension, and the physics reads everything to build the force on the chassis.

enum Position {
	FRONT_LEFT,
	FRONT_RIGHT,
	REAR_LEFT,
	REAR_RIGHT,
}

## Which corner of the car this wheel is (see the Position enum).
var position: int = Position.FRONT_LEFT
## True for the two front wheels (they steer).
var is_front: bool = true
## True for the two left wheels (used by the steering sign and the anti-roll bar).
var is_left: bool = true

## Hub position in the car's local space, in metres. Includes the ride height.
var rest_position: Vector3 = Vector3.ZERO
## Hub position in world space for the current frame.
var world_position: Vector3 = Vector3.ZERO

@export_group("Suspension state")
## True while the wheel touches something.
var contact: bool = false
## Point where the wheel touches the ground (world space).
var contact_point: Vector3 = Vector3.ZERO
## Surface normal at the contact point.
var contact_normal: Vector3 = Vector3.UP
## Current length of the suspension (hub to wheel centre), in metres.
var suspension_length: float = 0.28
## Previous frame's suspension length, used for the damper.
var previous_suspension_length: float = 0.28
## Compression relative to the free spring length (positive = compressed).
var compression: float = 0.0
## Compression speed in m/s (positive = compressing).
var compression_velocity: float = 0.0
## Vertical load on the tyre in newtons.
var load: float = 0.0
## Load from the previous frame, for the anti-roll bar and for the debug overlay.
var previous_load: float = 0.0

@export_group("Tyre state")
## Steering angle of this wheel in radians (0 for the rear wheels).
var steer_angle: float = 0.0
## Drive torque delivered to this wheel in N*m (0 for the non-driven wheels).
var drive_torque: float = 0.0
## Braking torque applied by the service brakes in N*m.
var brake_torque: float = 0.0
## True while the handbrake locks this wheel.
var handbrake_locked: bool = false
## Rotation speed of the wheel in rad/s (integrated from the torque balance).
var angular_velocity: float = 0.0
## Slip ratio: (surface speed - ground speed) / max(ground speed, 1).
var slip_ratio: float = 0.0
## Slip angle in radians.
var slip_angle: float = 0.0
## Longitudinal force produced by this tyre in newtons (wheel space).
var longitudinal_force: float = 0.0
## Lateral force produced by this tyre in newtons (wheel space).
var lateral_force: float = 0.0
## Total force applied to the chassis by this wheel, in world space. Read by the debug
## overlay and by the tests to verify the force balance.
var applied_force: Vector3 = Vector3.ZERO
## Suspension force (spring + damper + anti-roll) in newtons along the contact normal.
var suspension_force: float = 0.0

@export_group("Visual state")
## Accumulated wheel spin in radians (visual only, never fed back into the physics).
var spin_angle: float = 0.0
## Local position of the wheel mesh for the current frame.
var visual_position: Vector3 = Vector3.ZERO
## Local rotation of the wheel mesh for the current frame.
var visual_basis: Basis = Basis()


## Resets the per-frame state. Called by the wheel system before every update.
func reset_frame_state() -> void:
	previous_load = load
	load = 0.0
	longitudinal_force = 0.0
	lateral_force = 0.0
	applied_force = Vector3.ZERO
	suspension_force = 0.0
	if not contact:
		compression_velocity = 0.0


## Height of the hub above the ground implied by the current suspension length.
func hub_height_above_ground(wheel_radius: float) -> float:
	return suspension_length + wheel_radius


## How much of the suspension travel is left before the bump stop (0..1).
func travel_usage(config: VehicleConfig) -> float:
	if config.suspension_travel <= 0.0:
		return 0.0
	return clampf(compression / config.suspension_travel, 0.0, 1.0)


## Surface speed of the tyre in m/s (how fast the tread moves over the ground).
func surface_speed(wheel_radius: float) -> float:
	return angular_velocity * wheel_radius


## Compact description of the wheel for the test report and the debug overlay.
func describe() -> String:
	return (
		"wheel%d contact=%s compression=%.3f load=%.0fN slipA=%.3f slipR=%.3f Fx=%.0f Fy=%.0f suspF=%.0f"
		% [
			position,
			str(contact),
			compression,
			load,
			slip_angle,
			slip_ratio,
			longitudinal_force,
			lateral_force,
			suspension_force,
		]
	)


## Serialises the wheel for the automated gameplay tests.
func to_dictionary() -> Dictionary:
	return {
		"position": position,
		"contact": contact,
		"compression": compression,
		"load": load,
		"slip_angle": slip_angle,
		"slip_ratio": slip_ratio,
		"longitudinal_force": longitudinal_force,
		"lateral_force": lateral_force,
		"angular_velocity": angular_velocity,
		"steer_angle": steer_angle,
		"handbrake_locked": handbrake_locked,
	}
