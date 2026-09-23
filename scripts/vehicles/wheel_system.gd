extends RefCounted
class_name WheelSystem
## Owns the four wheels: their geometry, their raycasts and their suspension forces.
##
## The system never touches the rigid body directly. The vehicle script asks it to update
## from the space state, then the physics asks it for the forces, and the visuals ask it
## for the wheel transforms. That split is what allows the whole driving model to be
## driven from a test with a fake body.

## Number of wheels; a car always has exactly four in this project.
const WHEEL_COUNT := 4
## Fraction of the car length used as the wheelbase.
const WHEELBASE_RATIO := 0.60
## Fraction of the car width used as the track.
const TRACK_RATIO := 0.84
## Distance from the bottom of the chassis to the ground when the car stands still.
const RIDE_HEIGHT := 0.16
## Extra stiffness once the suspension reaches its bump stop, so a hard landing cannot
## push the chassis through the ground.
const BUMP_STOP_MULTIPLIER := 9.0

var wheels: Array[VehicleWheel] = []

## Set to true by the tests to skip the physics server.
var simulate_without_server: bool = false

var _config: VehicleConfig = null
var _ray_length: float = 0.6


## Builds the four wheels from a configuration. Safe to call again (re-tunes the car).
func setup(config: VehicleConfig) -> void:
	_config = config
	if wheels.size() != WHEEL_COUNT:
		wheels.clear()
		for i in WHEEL_COUNT:
			var wheel := VehicleWheel.new()
			wheel.position = i
			wheel.is_front = i < 2
			wheel.is_left = i % 2 == 0
			wheels.append(wheel)
	var wheelbase := config.body_size.z * WHEELBASE_RATIO
	var track := config.body_size.x * TRACK_RATIO
	# The hub sits so that, with the car at its ride height, the spring is at its free
	# length. The car then settles by the static sag (mass * g / stiffness / 4), which is
	# exactly what a real suspension does.
	var ground_offset := RIDE_HEIGHT + config.body_size.y * 0.5
	var hub_y := (config.wheel_radius + config.suspension_rest_length) - ground_offset
	for wheel: VehicleWheel in wheels:
		wheel.rest_position = Vector3(
			(-1.0 if wheel.is_left else 1.0) * track * 0.5,
			hub_y,
			(-1.0 if wheel.is_front else 1.0) * wheelbase * 0.5
		)
		wheel.suspension_length = config.suspension_rest_length
		wheel.previous_suspension_length = config.suspension_rest_length
	_ray_length = config.suspension_rest_length + config.suspension_travel + config.wheel_radius


## Total wheelbase in metres (used by the AI and by the tests).
func wheelbase() -> float:
	if wheels.size() < 4:
		return 0.0
	return absf(wheels[VehicleWheel.Position.FRONT_LEFT].rest_position.z - wheels[VehicleWheel.Position.REAR_LEFT].rest_position.z)


## Track width in metres.
func track_width() -> float:
	if wheels.size() < 4:
		return 0.0
	return absf(wheels[VehicleWheel.Position.FRONT_LEFT].rest_position.x - wheels[VehicleWheel.Position.FRONT_RIGHT].rest_position.x)


func front_wheels() -> Array[VehicleWheel]:
	return [wheels[VehicleWheel.Position.FRONT_LEFT], wheels[VehicleWheel.Position.FRONT_RIGHT]] as Array[VehicleWheel]


func rear_wheels() -> Array[VehicleWheel]:
	return [wheels[VehicleWheel.Position.REAR_LEFT], wheels[VehicleWheel.Position.REAR_RIGHT]] as Array[VehicleWheel]


## Number of wheels currently touching the ground.
func contact_count() -> int:
	var total := 0
	for wheel: VehicleWheel in wheels:
		if wheel.contact:
			total += 1
	return total


func is_airborne() -> bool:
	return contact_count() == 0


## Total vertical load on the tyres, in newtons. Used to detect a car that is resting on
## its roof and to scale the tyre forces.
func total_load() -> float:
	var total := 0.0
	for wheel: VehicleWheel in wheels:
		total += wheel.load
	return total


## Casts the four suspension rays and updates every wheel's geometry state.
##
## `space` is the physics space state, `body_transform` the world transform of the
## chassis. The ray always points straight down in world space so that a car that is
## upside down or leaning on two wheels still finds the ground reliably.
func update_rays(
	space: PhysicsDirectSpaceState3D,
	body_transform: Transform3D,
	delta: float,
	collision_mask: int = 0xFFFFFFFF,
	exclude: Array[RID] = []
) -> void:
	if _config == null:
		return
	var down := Vector3.DOWN
	var max_length := _config.suspension_rest_length + _config.suspension_travel
	for wheel: VehicleWheel in wheels:
		wheel.world_position = body_transform * wheel.rest_position
		wheel.previous_suspension_length = wheel.suspension_length
		wheel.reset_frame_state()
		if simulate_without_server or space == null:
			wheel.contact = false
			wheel.suspension_length = max_length
			continue
		var query := PhysicsRayQueryParameters3D.create(
			wheel.world_position,
			wheel.world_position + down * _ray_length,
			collision_mask,
			exclude
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			wheel.contact = false
			wheel.suspension_length = max_length
			continue
		var point: Vector3 = hit.get("position", wheel.world_position + down * _ray_length)
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		var distance := wheel.world_position.distance_to(point)
		wheel.contact = true
		wheel.contact_point = point
		wheel.contact_normal = normal if normal.dot(Vector3.UP) > 0.2 else Vector3.UP
		wheel.suspension_length = clampf(distance - _config.wheel_radius, 0.0, max_length)
		_update_compression(wheel, delta)


## Computes the compression and its speed for a wheel that is touching the ground.
func _update_compression(wheel: VehicleWheel, delta: float) -> void:
	var compression := _config.suspension_rest_length - wheel.suspension_length
	if delta > 0.0:
		wheel.compression_velocity = (compression - wheel.compression) / delta
	else:
		wheel.compression_velocity = 0.0
	wheel.compression = compression


## Computes the suspension force of every wheel and stores it in `wheel.suspension_force`.
## Includes the damper, the bump stop and the anti-roll bar.
func update_suspension_loads(config: VehicleConfig) -> void:
	for wheel: VehicleWheel in wheels:
		if not wheel.contact:
			wheel.suspension_force = 0.0
			wheel.load = 0.0
			continue
		wheel.suspension_force = state_to_force(config, wheel.compression, wheel.compression_velocity)
	# Anti-roll bar: transfers load from the compressed side to the extended side of an
	# axle. This is what keeps the body flat in a corner without making the springs stiff.
	var anti_roll_stiffness := config.anti_roll * config.suspension_stiffness * 0.5
	for axle_index in 2:
		var left := wheels[axle_index * 2]
		var right := wheels[axle_index * 2 + 1]
		if not left.contact and not right.contact:
			continue
		var difference := left.compression - right.compression
		if left.contact:
			left.suspension_force += anti_roll_stiffness * difference
		if right.contact:
			right.suspension_force -= anti_roll_stiffness * difference
	for wheel: VehicleWheel in wheels:
		wheel.suspension_force = maxf(wheel.suspension_force, 0.0)


## Converts a suspension state into the force pushing the chassis up, in newtons.
##
## Pure function: the unit tests call it directly to verify the spring law, the damper and
## the bump stop without any physics server.
static func state_to_force(config: VehicleConfig, compression: float, compression_velocity: float) -> float:
	if compression <= 0.0:
		# A fully extended spring cannot pull the wheel down, only the damper resists.
		return maxf(-compression_velocity * config.suspension_damping * 0.25, 0.0)
	var spring := config.suspension_force(compression)
	var damper := config.damper_force(compression_velocity)
	var force := spring + damper
	if compression > config.suspension_travel:
		# Bump stop: hit hard, but never punch the car through the floor.
		var overshoot := compression - config.suspension_travel
		force += overshoot * config.suspension_stiffness * BUMP_STOP_MULTIPLIER
	return maxf(force, 0.0)


## Load per wheel that the springs hold when the car stands still on flat ground.
func static_load_per_wheel(config: VehicleConfig, gravity: float) -> float:
	return config.mass * gravity / float(WHEEL_COUNT)


## Expected static sag in metres for the given configuration. Used by the tests and to
## sanity check a new car setup.
func static_sag(config: VehicleConfig, gravity: float) -> float:
	return static_load_per_wheel(config, gravity) / maxf(config.suspension_stiffness, 1.0)


## Front axle share of the total load, taking the centre of mass into account.
func static_front_load_share(config: VehicleConfig, gravity: float) -> float:
	return config.front_weight_ratio


## Updates the visual transform of every wheel: the wheel follows the suspension travel,
## aligns with the contact normal and spins with its own angular velocity.
func update_visuals(delta: float, wheel_radius: float) -> void:
	for wheel: VehicleWheel in wheels:
		wheel.spin_angle = fmod(wheel.spin_angle + wheel.angular_velocity * delta, TAU)
		var normal := wheel.contact_normal if wheel.contact else Vector3.UP
		var travel := wheel.suspension_length
		var position := wheel.rest_position - Vector3(0.0, travel, 0.0)
		var roll := Basis(Vector3.RIGHT, -wheel.spin_angle)
		var steer := Basis(Vector3.UP, wheel.steer_angle)
		var align := _basis_from_normal(normal)
		wheel.visual_position = position
		wheel.visual_basis = align * steer * roll
		if not wheel.contact:
			# In the air the wheel keeps its last alignment so it does not snap.
			wheel.visual_basis = steer * roll


## Builds a rotation basis whose Y axis points along `up`.
static func _basis_from_normal(up: Vector3) -> Basis:
	var y := up.normalized()
	if y.is_zero_approx():
		y = Vector3.UP
	var reference := Vector3.FORWARD
	if absf(y.dot(reference)) > 0.99:
		reference = Vector3.RIGHT
	var x := reference.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


## True when the wheel is skidding sideways fast enough to leave tyre marks (used by the
## skid mark spawner and by the arrest system).
func is_sliding(wheel: VehicleWheel) -> bool:
	return wheel.contact and absf(wheel.slip_angle) > 0.28


## True when the wheel spins faster than the car moves (burnout / wheelspin).
func is_spinning(wheel: VehicleWheel, vehicle_speed: float) -> bool:
	return wheel.contact and wheel.slip_ratio > 0.35 and vehicle_speed < 14.0


## Aggregate wheel state for the smoke test report.
func to_dictionary() -> Dictionary:
	var data := {}
	for wheel: VehicleWheel in wheels:
		data[str(wheel.position)] = wheel.to_dictionary()
	data["contact_count"] = contact_count()
	data["total_load"] = total_load()
	return data
