extends Resource
class_name CameraConfig
## Third person chase camera tuning. The camera is always free: the player can rotate it
## at any time (even while the car is standing still) and it never locks to the car's
## heading. Collision avoidance and automatic distance recovery keep it out of walls.

@export_group("Placement")
## Base distance behind the car in metres.
@export_range(2.0, 20.0, 0.1) var distance: float = 7.4
## Camera height above the chassis origin.
@export_range(0.5, 8.0, 0.05) var height: float = 2.55
## Extra height added when looking straight down.
@export_range(0.0, 10.0, 0.05) var height_at_top: float = 1.6
## Camera pitch in degrees (negative looks down).
@export_range(-80.0, 40.0, 0.5) var pitch_deg: float = -12.5
## Minimum pitch the player may reach.
@export_range(-89.0, 0.0, 0.5) var min_pitch_deg: float = -62.0
## Maximum pitch the player may reach.
@export_range(-10.0, 60.0, 0.5) var max_pitch_deg: float = 22.0
## Field of view in degrees.
@export_range(45.0, 110.0, 0.5) var fov: float = 68.0
## FOV added with speed (gives a sense of speed without a heavy post effect).
@export_range(0.0, 30.0, 0.5) var fov_speed_bonus: float = 10.0
## Speed (m/s) at which the speed FOV bonus is fully applied.
@export_range(5.0, 120.0, 1.0) var fov_speed_reference: float = 46.0

@export_group("Smoothing")
## Position smoothing time (seconds). Higher = softer, more "cinematic" camera.
@export_range(0.0, 1.0, 0.01) var position_smoothing: float = 0.11
## Rotation smoothing time. 0 = the camera follows the stick exactly.
@export_range(0.0, 1.0, 0.01) var rotation_smoothing: float = 0.06
## Seconds after the last look input before the camera starts drifting behind the car.
@export_range(0.0, 10.0, 0.1) var auto_recenter_delay: float = 1.6
## Auto recenter speed (radians/s). 0 disables automatic recentring entirely.
@export_range(0.0, 3.0, 0.01) var auto_recenter_speed: float = 0.55
## Whether the camera recenters while reversing (should be false: the player sees where
## they are reversing into).
@export var recenter_when_reversing: bool = false

@export_group("Collision")
## Enable wall avoidance.
@export var collision_enabled: bool = true
## Radius of the camera probe sphere.
@export_range(0.05, 2.0, 0.05) var collision_radius: float = 0.42
## Extra margin kept from the surface.
@export_range(0.0, 2.0, 0.05) var collision_margin: float = 0.35
## Minimum distance from the car the camera can be pushed to.
@export_range(0.5, 8.0, 0.1) var min_collision_distance: float = 1.6
## How fast the camera returns to the desired distance once the obstacle is gone (m/s).
@export_range(0.5, 30.0, 0.1) var distance_recovery_speed: float = 6.5
## Layers the camera collides with.
@export_flags_3d_physics var collision_mask: int = 1 | 2 | 4 | 8

@export_group("Shake")
## Amplitude of the impact shake.
@export_range(0.0, 2.0, 0.01) var shake_amplitude: float = 0.35
## Shake decay time.
@export_range(0.05, 2.0, 0.01) var shake_decay: float = 0.45
## Speed (m/s) above which collisions trigger a shake.
@export_range(0.0, 60.0, 0.5) var shake_speed_threshold: float = 6.0

@export_group("Touch look")
## Touch look sensitivity (radians per pixel).
@export_range(0.0005, 0.02, 0.0005) var touch_sensitivity: float = 0.0038
## Mouse look sensitivity (radians per pixel).
@export_range(0.0005, 0.02, 0.0005) var mouse_sensitivity: float = 0.0042
## Gamepad look speed (radians per second).
@export_range(0.1, 8.0, 0.1) var stick_look_speed: float = 2.6
## Invert vertical look.
@export var invert_y: bool = false


## Converts the configured pitch to radians.
func pitch_radians() -> float:
	return deg_to_rad(pitch_deg)


## Distance used for a given vehicle speed: the camera pulls back slightly when driving
## fast so the player sees more of the road.
func distance_for_speed(speed: float) -> float:
	var t := clampf(speed / maxf(0.01, fov_speed_reference), 0.0, 1.4)
	return distance + t * 1.15


## FOV used for a given vehicle speed.
func fov_for_speed(speed: float) -> float:
	var t := clampf(speed / maxf(0.01, fov_speed_reference), 0.0, 1.2)
	return fov + fov_speed_bonus * t
