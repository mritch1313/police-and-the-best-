extends CarBody
class_name PoliceCar
## A police cruiser: a normal car whose driver is the AI.
##
## The cruiser is a little faster than the player (player_max * 1.01) and grips a little
## better, which is what makes the chase tense without making it unfair: a player who drives
## cleanly stays ahead, and a player who crashes gets caught. Nitro is the escape valve.
##
## A cruiser can be *wrecked* (heavy impact) - it then sits still for a few seconds before it
## rejoins the chase - and it can be *blocked* (stuck against a wall or another car), which
## the AI reports to the manager so the unit can be re-spawned ahead of the player instead of
## hopelessly pushing into a wall.

signal wrecked()
signal recovered_from_wreck()

enum State {
	SPAWNING,
	ACTIVE,
	WRECKED,
	BLOCKED,
	IDLE,
}

@export var unit_index: int = 0

var state: int = State.SPAWNING
var wreck_timer: float = 0.0
var blocked_timer: float = 0.0
var spawn_timer: float = 0.0
## The route the unit currently follows (world positions).
var route: PackedVector3Array = PackedVector3Array()
var route_index: int = 0
## Distance the unit has travelled since the last stuck check.
var _stuck_distance_check := Vector3.ZERO
var _stuck_check_timer: float = 0.0


func _ready() -> void:
	if config_path == "res://resources/config/vehicles/player_car.tres":
		config_path = "res://resources/config/vehicles/police_cruiser.tres"
	model_id = CarMeshFactory.MODEL_POLICE
	if body_colour == Color(0.72, 0.12, 0.12):
		body_colour = Color(0.88, 0.88, 0.9)
	collision_layer_value = CollisionLayers.POLICE
	collision_mask_value = CollisionLayers.VEHICLE_COLLISION
	is_police = true
	super._ready()
	spawn_timer = 0.0
	_stuck_distance_check = global_position


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	match state:
		State.SPAWNING:
			spawn_timer -= delta
			if spawn_timer <= 0.0:
				state = State.ACTIVE
		State.WRECKED:
			wreck_timer -= delta
			drive_input.throttle = 0.0
			drive_input.brake = 0.6
			if wreck_timer <= 0.0:
				state = State.ACTIVE
				controllable = true
				visual.update_lights(delta, false, false, false, 0.0, true)
				recovered_from_wreck.emit()
		State.ACTIVE:
			_check_blocked(delta)
	_update_police_lights(delta)


## Blinks the light bar while the unit is active. Purely cosmetic, but it is what makes a
## chase readable in the mirror.
func _update_police_lights(delta: float) -> void:
	if visual == null or not is_police:
		return
	visual.update_lights(
		delta,
		drive_input.brake > 0.05,
		forward_speed() < -0.5,
		false,
		linear_velocity.length(),
		true
	)


## A unit that hardly moves for a few seconds is stuck (against a wall, a fence or another
## car). The AI uses this to switch strategy; the manager uses it to recycle the unit.
func _check_blocked(delta: float) -> void:
	_stuck_check_timer += delta
	if _stuck_check_timer < 1.5:
		return
	_stuck_check_timer = 0.0
	var moved := global_position.distance_to(_stuck_distance_check)
	_stuck_distance_check = global_position
	if moved < 1.5 and forward_speed() < 4.0 and drive_input.throttle > 0.3:
		blocked_timer += 1.5
		if blocked_timer >= 3.0 and state == State.ACTIVE:
			state = State.BLOCKED
	else:
		blocked_timer = maxf(0.0, blocked_timer - 1.5)


## Marks the unit as wrecked: it stops for `recovery` seconds and then rejoins.
func mark_wrecked(recovery: float) -> void:
	if state == State.WRECKED:
		return
	state = State.WRECKED
	controllable = false
	wreck_timer = recovery
	drive_input.throttle = 0.0
	drive_input.brake = 1.0
	drive_input.handbrake = true
	wrecked.emit()


func mark_blocked(reason: String = "") -> void:
	if state == State.WRECKED:
		return
	state = State.BLOCKED
	if reason != "":
		set_meta("blocked_reason", reason)


func clear_blocked() -> void:
	if state == State.BLOCKED:
		state = State.ACTIVE
		blocked_timer = 0.0


func is_active() -> bool:
	return state == State.ACTIVE


func is_wrecked() -> bool:
	return state == State.WRECKED


func state_name() -> String:
	match state:
		State.SPAWNING:
			return "spawning"
		State.ACTIVE:
			return "active"
		State.WRECKED:
			return "wrecked"
		State.BLOCKED:
			return "blocked"
		_:
			return "idle"


func describe() -> String:
	return "police#%d %s %.0f km/h" % [unit_index, state_name(), speed_kmh()]
