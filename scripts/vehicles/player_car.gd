extends CarBody
class_name PlayerCar
## The car the player drives.
##
## It is the only car whose `drive_input` comes from the InputManager (touch controls,
## keyboard or gamepad). Everything else - physics, wheels, gearbox, nitro - is the shared
## CarBody implementation.
##
## Nitro balance (a design rule of the game, see resources/config/vehicles/player_car.tres):
##   * player top speed      = 46.0 m/s   (165.6 km/h)
##   * police top speed      = 46.46 m/s  = player * 1.01  -> they can slowly close in
##   * player with nitro     = 58.0 m/s   = police speed * 1.25 -> the player can escape
## Nitro raises the *torque* and the *speed cap* of the physics; it never moves the car.

## Emitted when the auto-recovery flipped the car back onto its wheels.
signal recovered()

## Seconds of being upside down before the car is put back on its wheels.
const RECOVER_AFTER := 4.0
## Speed (m/s) below which a car with no wheels on the ground counts as rolled over.
const STUCK_SPEED := 1.5

@export var recover_automatically: bool = true

var _stuck_time: float = 0.0
var _nitro_time_used: float = 0.0
var _handbrake_time: float = 0.0
var _distance_accumulator: float = 0.0
var _last_position := Vector3.ZERO
var _air_time_accumulator: float = 0.0


func _ready() -> void:
	config_path = "res://resources/config/vehicles/player_car.tres"
	model_id = CarMeshFactory.MODEL_SPORTS
	body_colour = Color(0.78, 0.13, 0.1)
	collision_layer_value = CollisionLayers.PLAYER
	collision_mask_value = CollisionLayers.VEHICLE_COLLISION
	is_police = false
	super._ready()
	_last_position = global_position


func _physics_process(delta: float) -> void:
	# The player's input comes from the input manager, which merges touch, keyboard and
	# gamepad into one snapshot.
	drive_input.copy_from(InputManager.drive_input)
	drive_input.nitro = drive_input.nitro and not engine_disabled
	super._physics_process(delta)
	_update_statistics(delta)
	if recover_automatically:
		_check_recovery(delta)


func _update_statistics(delta: float) -> void:
	var state := get_node_or_null("/root/GameState")
	if state != null and state.run_active:
		var travelled := _last_position.distance_to(global_position)
		_distance_accumulator += travelled
		if _distance_accumulator > 5.0:
			state.add_distance(_distance_accumulator)
			_distance_accumulator = 0.0
		state.register_speed(linear_velocity.length())
		if is_boosting():
			_nitro_time_used += delta
			if _nitro_time_used > 0.25:
				state.register_nitro(_nitro_time_used)
				_nitro_time_used = 0.0
		if drive_input.handbrake:
			_handbrake_time += delta
			if _handbrake_time > 0.25:
				state.register_handbrake(_handbrake_time)
				_handbrake_time = 0.0
		# Air time is fun enough to be worth tracking.
		if not is_grounded():
			_air_time_accumulator += delta
		elif _air_time_accumulator > 0.0:
			if _air_time_accumulator > 0.6:
				state.register_air_time(_air_time_accumulator)
			_air_time_accumulator = 0.0
	_last_position = global_position


## Rolls the car back onto its wheels after a few seconds on the roof. Without this a player
## who lands on their roof after a jump has no way back into the game.
func _check_recovery(delta: float) -> void:
	var upside_down := global_transform.basis.y.dot(Vector3.UP) < 0.25
	if upside_down and linear_velocity.length() < STUCK_SPEED:
		_stuck_time += delta
	else:
		_stuck_time = 0.0
	if _stuck_time >= RECOVER_AFTER:
		_stuck_time = 0.0
		recover_upright()
		recovered.emit()


## True when the player asked to reset the car onto the nearest road position.
func request_reset_to(target: Transform3D) -> void:
	reset_to(target)
