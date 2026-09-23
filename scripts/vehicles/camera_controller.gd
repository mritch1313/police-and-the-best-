extends Node3D
class_name CameraController
## Third person chase camera.
##
## The camera is *free*: the player can rotate it at any moment, including while the car is
## standing still, and it never locks to the car's heading. The optional auto-recentre starts
## only after a delay without look input, and it is disabled by default while reversing (the
## player must be able to see where they are backing into).
##
## Anti-clipping is done with a sphere cast from the car towards the camera: the camera slides
## in front of whatever it would otherwise sit inside of, and recovers its distance smoothly
## once the obstacle is gone. Without that, a chase camera in a city is permanently inside a
## wall.
##
## The camera also owns the impact shake and the speed/nitro FOV, which is where most of the
## "sense of speed" of a mobile racing game comes from.

signal look_changed(yaw: float, pitch: float)

@export var config_path: String = "res://resources/config/gameplay_config.tres"
@export var camera_index: int = 0

var config: CameraConfig
## The node the camera orbits (the player car).
var target: Node3D = null

var yaw: float = 0.0
var pitch: float = 0.0
var distance: float = 7.4
var current_distance: float = 7.4
var fov: float = 68.0
var shake: float = 0.0
var look_active: bool = false
var auto_recenter_enabled: bool = true

var _camera: Camera3D = null
var _time_since_look: float = 0.0
var _smoothed_position := Vector3.ZERO
var _smoothed_yaw: float = 0.0
var _initialized: bool = false
var _space_state: PhysicsDirectSpaceState3D = null


func _ready() -> void:
	config = load(config_path) as CameraConfig
	if config == null:
		config = CameraConfig.new()
	pitch = config.pitch_radians()
	distance = config.distance
	current_distance = distance
	fov = config.fov
	_camera = Camera3D.new()
	_camera.name = "ChaseCamera"
	_camera.fov = fov
	_camera.near = 0.15
	_camera.far = config.fov_speed_reference * 40.0
	add_child(_camera)


func setup(p_target: Node3D, config_override: CameraConfig = null) -> void:
	target = p_target
	if config_override != null:
		config = config_override
		pitch = config.pitch_radians()
		distance = config.distance
		current_distance = distance
		fov = config.fov
		if _camera != null:
			_camera.fov = fov
	# The camera starts behind the car it follows.
	if target != null:
		yaw = -target.global_rotation.y
		_smoothed_yaw = yaw
		_smoothed_position = _desired_position(0.016)
		_initialized = true
	update_camera(0.016)


## Applies look input for this frame, in pixels of touch drag.
func apply_look(delta_pixels: Vector2) -> void:
	if delta_pixels == Vector2.ZERO:
		return
	var sensitivity := config.touch_sensitivity * SettingsManager.camera_sensitivity
	yaw -= delta_pixels.x * sensitivity
	var pitch_delta := delta_pixels.y * sensitivity
	if config.invert_y:
		pitch_delta = -pitch_delta
	pitch = clampf(
		pitch + pitch_delta,
		deg_to_rad(config.min_pitch_deg),
		deg_to_rad(config.max_pitch_deg)
	)
	_time_since_look = 0.0
	look_active = true
	look_changed.emit(yaw, pitch)


func stop_look() -> void:
	look_active = false


## Puts the camera behind the car immediately (the "reset camera" button).
func reset_behind_car() -> void:
	if target == null:
		return
	yaw = -target.global_rotation.y
	pitch = config.pitch_radians()
	current_distance = config.distance
	_time_since_look = config.auto_recenter_delay + 1.0
	update_camera(0.016, true)


## Moves the camera for this frame.
func update_camera(delta: float, snap: bool = false) -> void:
	if target == null or _camera == null:
		return
	_time_since_look += delta
	_auto_recenter(delta)
	var desired := _desired_position(delta)
	var smoothing := 0.0 if snap else config.position_smoothing
	if not _initialized or snap:
		_smoothed_position = desired
		_smoothed_yaw = yaw
		_initialized = true
	else:
		# Frame rate independent smoothing: the camera behaves the same at 30 and 60 fps.
		var alpha := VehicleMath.damping_alpha(1.0 / maxf(smoothing, 0.0001), delta) if smoothing > 0.0 else 1.0
		_smoothed_position = _smoothed_position.lerp(desired, clampf(alpha, 0.0, 1.0))
		_smoothed_yaw = lerp_angle(_smoothed_yaw, yaw, clampf(alpha, 0.0, 1.0))
	global_position = _smoothed_position
	# The camera looks slightly ahead of the car so the road is visible, and the shake is
	# added on top of that.
	var look_target := target.global_position + Vector3.UP * 0.9
	look_target += -target.global_transform.basis.z * 2.0
	look_target.y += sin(Time.get_ticks_msec() * 0.001 * 24.0) * shake * 0.35
	look_target.x += cos(Time.get_ticks_msec() * 0.001 * 27.0) * shake * 0.25
	global_transform = global_transform.looking_at(look_target, Vector3.UP)
	shake = maxf(0.0, shake - delta * (1.0 / maxf(config.shake_decay, 0.05)) * 0.35)
	_update_fov(delta)
	_camera.make_current()


## The auto recentre keeps the camera behind the car while driving, but only after the
## player stopped looking around, and never while reversing.
func _auto_recenter(delta: float) -> void:
	if not auto_recenter_enabled or config.auto_recenter_speed <= 0.0 or target == null:
		return
	if _time_since_look < config.auto_recenter_delay:
		return
	var speed := 0.0
	var reversing := false
	if target is CarBody:
		speed = (target as CarBody).forward_speed()
		reversing = speed < -0.5
	if reversing and not config.recenter_when_reversing:
		return
	# Below 4 m/s the player is manoeuvring: leave the camera where they put it.
	if absf(speed) < 4.0:
		return
	var target_yaw := -target.global_rotation.y
	var strength := clampf(absf(speed) / 12.0, 0.15, 1.0)
	yaw = lerp_angle(yaw, target_yaw, clampf(config.auto_recenter_speed * strength * delta, 0.0, 1.0))


func _desired_position(delta: float) -> Vector3:
	if target == null:
		return global_position
	var speed := 0.0
	if target is CarBody:
		speed = absf((target as CarBody).forward_speed())
	var wanted_distance := config.distance_for_speed(speed)
	var wanted_height := config.height + config.height_at_top * maxf(-pitch, 0.0) / maxf(deg_to_rad(-config.min_pitch_deg), 0.001)
	var orbit := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -pitch)
	var offset := orbit * Vector3(0.0, 0.0, wanted_distance) + Vector3.UP * wanted_height
	var desired := target.global_position + offset
	return _avoid_collision(target.global_position + Vector3.UP * 1.1, desired, delta)


## Sphere cast from the car towards the camera. The camera is pulled in front of the first
## blocking surface and recovers its distance smoothly afterwards.
func _avoid_collision(pivot: Vector3, desired: Vector3, delta: float) -> Vector3:
	if not config.collision_enabled:
		return desired
	var world := target.get_world_3d() if target != null else null
	if world == null:
		return desired
	_space_state = world.direct_space_state
	if _space_state == null:
		return desired
	var to_camera := desired - pivot
	var length := to_camera.length()
	if length < 0.001:
		return desired
	var query := PhysicsRayQueryParameters3D.create(
		pivot, pivot + to_camera.normalized() * length, CollisionLayers.CAMERA_BLOCKERS
	)
	query.collide_with_areas = false
	if target is CollisionObject3D:
		query.exclude = [(target as CollisionObject3D).get_rid()]
	var hit := _space_state.intersect_ray(query)
	var wanted_distance := length
	if not hit.is_empty():
		var hit_position: Vector3 = hit.get("position", desired)
		wanted_distance = maxf(pivot.distance_to(hit_position) - config.collision_margin, config.min_collision_distance)
	else:
		wanted_distance = length
	# Snap in (never clip), ease out (never pop).
	if wanted_distance < current_distance:
		current_distance = wanted_distance
	else:
		current_distance = minf(wanted_distance, current_distance + config.distance_recovery_speed * delta)
	return pivot + to_camera.normalized() * current_distance


func _update_fov(delta: float) -> void:
	if _camera == null:
		return
	var speed := 0.0
	var boosting := false
	if target is CarBody:
		speed = absf((target as CarBody).forward_speed())
		boosting = (target as CarBody).is_boosting()
	var wanted := config.fov_for_speed(speed)
	if boosting and config is CameraConfig:
		var bonus := 0.0
		var car := target as CarBody
		if car != null and car.config != null and car.config.nitro != null:
			bonus = car.config.nitro.camera_fov_bonus
		wanted += bonus
	fov = lerpf(fov, wanted, clampf(delta * 3.0, 0.0, 1.0))
	_camera.fov = fov


## Adds shake to the camera (impacts, landings, police ramming).
func add_shake(amount: float) -> void:
	shake = minf(shake + amount, config.shake_amplitude * 2.0)


func camera() -> Camera3D:
	return _camera


func yaw_degrees() -> float:
	return rad_to_deg(yaw)


func describe() -> String:
	return "camera(dist=%.2f/%.2f yaw=%.0f pitch=%.0f fov=%.0f shake=%.2f)" % [
		current_distance,
		distance,
		yaw_degrees(),
		rad_to_deg(pitch),
		fov,
		shake,
	]
