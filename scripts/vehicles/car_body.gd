extends RigidBody3D
class_name CarBody
## The node half of a car: it wires the physics model, the wheels, the drivetrain, the nitro
## tank and the visual layer together, and drives them once per physics tick.
##
## This script is shared by the player car, the police cruisers and the ambient traffic: they
## differ only in the `VehicleConfig` they load, in who writes their `drive_input`, and in a
## couple of flags. That is the whole point of the architecture - one car implementation,
## several drivers.
##
## The car never moves by writing to its transform. Every metre it travels comes out of
## `RigidBody3D` and the forces that `VehiclePhysics` applies at the contact patches. The
## only exception is an explicit recovery/respawn (`reset_to`), which exists so a car stuck
## on its roof cannot soft-lock the game - it is never used while driving.

## Emitted when the car hits something hard (camera shake, damage, AI reactions).
signal impact(speed: float, position: Vector3)
## Emitted when the car lands after being airborne.
signal landed(vertical_speed: float)
## Emitted when the wheels are visibly sliding (tyre smoke, skid marks).
signal sliding(intensity: float)

@export var config_path: String = "res://resources/config/vehicles/player_car.tres"
@export var model_id: int = CarMeshFactory.MODEL_SEDAN
@export var body_colour: Color = Color(0.72, 0.12, 0.12)
@export var detail_level: int = CarMeshFactory.DETAIL_HIGH
@export var collision_layer_value: int = CollisionLayers.TRAFFIC
@export var collision_mask_value: int = CollisionLayers.VEHICLE_COLLISION
@export var is_police: bool = false

var config: VehicleConfig = null
var wheels: WheelSystem = null
var physics: VehiclePhysics = null
var controller: VehicleController = null
var nitro: NitroSystem = null
var visual: CarVisual = null
var materials: MaterialLibrary = null

## The driver's request for this frame. The player car fills it from the input manager, the
## police from its AI, the traffic from its route follower.
var drive_input := DriveInput.new()
## Drivetrain state produced by the controller and consumed by the physics.
var drivetrain := DrivetrainOutput.new()

## True while the car is allowed to be driven (a wrecked police car is not).
var controllable: bool = true
## Set by the arrest system: the player's engine is cut and the car rolls to a stop.
var engine_disabled: bool = false

var _space_state: PhysicsDirectSpaceState3D = null
var _impact_cooldown: float = 0.0
var _slide_emit_timer: float = 0.0
var _was_airborne: bool = false
var _shake_speed: float = 0.0
var _wheel_radius_visual: float = 0.34


func _ready() -> void:
	_load_config()
	collision_layer = collision_layer_value
	collision_mask = collision_mask_value
	gravity_scale = 1.0
	_build_components()
	_ensure_collision_shape()
	# Contacts are only monitored when somebody is interested: the player car reports
	# impacts to the camera and to the game state, a parked traffic car does not.
	contact_monitor = true
	max_contacts_reported = 6
	continuous_cd = true
	can_sleep = false
	body_entered.connect(_on_body_entered)


func _load_config() -> void:
	config = load(config_path) as VehicleConfig
	if config == null:
		push_warning("CarBody: %s could not be loaded, using defaults" % config_path)
		config = VehicleConfig.new()
	if config.nitro == null:
		config.nitro = NitroConfig.new()


func _build_components() -> void:
	materials = MaterialLibrary.new()
	wheels = WheelSystem.new()
	wheels.setup(config)
	physics = VehiclePhysics.new()
	physics.setup(self, config, wheels)
	controller = VehicleController.new()
	controller.reset(config)
	nitro = NitroSystem.new(config.nitro)
	_wheel_radius_visual = config.wheel_radius
	visual = CarVisual.new()
	visual.name = "Visual"
	add_child(visual)
	visual.build(model_id, body_colour, config, materials, detail_level)


## Builds the collision box from the configuration when the scene did not provide one. A box
## (not a mesh shape) is intentional: a box is what makes a car push and be pushed in a
## believable, cheap and stable way in a physics engine running at 60 Hz on a phone.
func _ensure_collision_shape() -> void:
	var shape: CollisionShape3D = null
	for child in get_children():
		if child is CollisionShape3D:
			shape = child
			break
	if shape == null:
		shape = CollisionShape3D.new()
		shape.name = "Body"
		add_child(shape)
	# The shape always comes from the configuration, so a car can be re-sized (or turned into
	# a bus) from its .tres file without touching the scene.
	var box := BoxShape3D.new()
	box.size = config.body_size
	shape.shape = box
	shape.position = Vector3(0.0, config.body_size.y * 0.1, 0.0)
	# The centre of mass sits low, which is the difference between "a car" and "a box that
	# tips over in the first corner".
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, config.center_of_mass_height - (config.body_size.y * 0.5 + WheelSystem.RIDE_HEIGHT), 0.0)
	mass = config.mass
	linear_damp = config.linear_damping
	angular_damp = config.angular_damping


func _physics_process(delta: float) -> void:
	if config == null or wheels == null:
		return
	var world := get_world_3d()
	_space_state = world.direct_space_state if world != null else null
	# 1. wheels: cast the suspension rays, find the ground and the spring forces.
	physics.update_wheels(_space_state, delta, CollisionLayers.WHEEL_RAY)
	# 2. drivetrain: pedals, steering, gearbox and the speed cap.
	if engine_disabled:
		drive_input.throttle = 0.0
		drive_input.nitro = false
	if not controllable:
		drive_input.throttle = 0.0
		drive_input.brake = maxf(drive_input.brake, 0.3)
	# The nitro tank is updated before the controller so that a boost that starts this frame
	# already has its torque applied this frame.
	nitro.update(delta, drive_input.nitro and controllable and not engine_disabled)
	controller.update(drive_input, wheels, config, nitro, forward_speed(), delta, drivetrain)
	# 3. physics: tyre forces, drag, downforce, speed cap, air stability.
	if _space_state != null:
		physics.apply_forces(delta, drivetrain)
	# 4. visuals and feedback: the wheel meshes follow the suspension and the spin of the
	#    physics wheels, and brake/nitro feedback follows the driver's input.
	wheels.update_visuals(delta, config.wheel_radius)
	visual.sync_wheels(wheels, delta, config.wheel_radius)
	visual.update_lights(
		delta,
		drive_input.brake > 0.05 or drive_input.handbrake,
		drivetrain.gear == 0 and forward_speed() < -0.5,
		nitro.is_boosting(),
		linear_velocity.length(),
		is_police
	)
	_feedback(delta)


## Impacts, landings and tyre slip are turned into signals here so that other systems do not
## have to poll the physics body.
func _feedback(delta: float) -> void:
	if _impact_cooldown > 0.0:
		_impact_cooldown = maxf(0.0, _impact_cooldown - delta)
	if _was_airborne and physics.grounded and physics.impact_speed > 0.0:
		_was_airborne = false
		landed.emit(physics.impact_speed)
		_shake_speed = maxf(_shake_speed, physics.impact_speed * 0.06)
	elif not physics.grounded:
		_was_airborne = true
	_slide_emit_timer += delta
	if _slide_emit_timer > 0.1:
		_slide_emit_timer = 0.0
		var slip := physics.lateral_slip
		if slip > 0.25:
			sliding.emit(clampf(slip, 0.0, 1.5))


func _on_body_entered(body: Node) -> void:
	if _impact_cooldown > 0.0:
		return
	var speed := linear_velocity.length()
	if speed < 3.0:
		return
	_impact_cooldown = 0.35
	_shake_speed = maxf(_shake_speed, minf(speed * 0.05, 0.6))
	impact.emit(speed, global_position)
	if body is CarBody and (body as CarBody).is_police and is_police == false:
		var state := get_node_or_null("/root/GameState")
		if state != null:
			state.register_police_contact()


# --------------------------------------------------------------------------------------
# public API
# --------------------------------------------------------------------------------------
## Forward speed in m/s (signed: positive = driving forward).
func forward_speed() -> float:
	return linear_velocity.dot(-global_transform.basis.z)


## Forward speed in km/h, for the HUD and the statistics.
func speed_kmh() -> float:
	return linear_velocity.length() * 3.6


func is_boosting() -> bool:
	return nitro != null and nitro.is_boosting()


func nitro_ratio() -> float:
	return nitro.charge_ratio() if nitro != null else 0.0


func engine_rpm() -> float:
	return controller.engine_rpm if controller != null else 0.0


func gear() -> int:
	return drivetrain.gear


func max_speed_kmh() -> float:
	return config.max_speed_kmh()


## True while at least one wheel touches the ground.
func is_grounded() -> bool:
	return physics != null and physics.grounded


## Current sideways slide, used by the HUD and by the traffic AI.
func lateral_slip() -> float:
	return physics.lateral_slip if physics != null else 0.0


## Turns the whole car back onto its wheels. This is the only place in the game that writes
## to a car's transform, it is never used while the car is being driven, and it exists so a
## player who lands on their roof is not stuck forever.
func recover_upright() -> void:
	var basis := global_transform.basis
	if basis.y.dot(Vector3.UP) > 0.5:
		return
	var forward := -basis.z
	var flattened := Vector3(forward.x, 0.0, forward.z)
	if flattened.length_squared() < 0.01:
		flattened = Vector3.FORWARD
	var upright := Basis()
	upright = upright.looking_at(-flattened.normalized(), Vector3.UP)
	var position := global_position + Vector3(0.0, config.body_size.y * 0.75 + 0.3, 0.0)
	global_transform = Transform3D(upright, position)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## Puts the car on a given transform with no velocity. Used for spawning and for the
## explicit "reset car" button, never for normal movement.
func reset_to(target: Transform3D) -> void:
	global_transform = Transform3D(Basis(target.basis.get_rotation_quaternion()), target.origin + Vector3.UP * 0.55)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if controller != null:
		controller.reset(config)
	if nitro != null:
		nitro.refill()
	if wheels != null:
		for wheel: VehicleWheel in wheels.wheels:
			wheel.angular_velocity = 0.0


## Disables the engine (arrest sequence, wrecks).
func set_engine_disabled(value: bool) -> void:
	engine_disabled = value


func shake_amount() -> float:
	var amount := _shake_speed
	_shake_speed = 0.0
	return amount


## Everything about the car in one dictionary: used by the HUD, by the tests and by the
## headless smoke test report.
func telemetry() -> Dictionary:
	return {
		"speed": linear_velocity.length(),
		"speed_kmh": speed_kmh(),
		"forward_speed": forward_speed(),
		"max_speed": config.max_speed,
		"rpm": engine_rpm(),
		"gear": gear(),
		"boosting": is_boosting(),
		"nitro": nitro_ratio(),
		"grounded": is_grounded(),
		"airborne": physics != null and not physics.grounded,
		"slip": lateral_slip(),
		"steer": controller.steer_angle if controller != null else 0.0,
		"wheels": wheels.to_dictionary() if wheels != null else {},
		"position": global_position,
	}


func describe() -> String:
	return "%s(%.1f km/h gear=%d rpm=%.0f %s%s)" % [
		name,
		speed_kmh(),
		gear(),
		engine_rpm(),
		"boost " if is_boosting() else "",
		"grounded" if is_grounded() else "airborne",
	]
