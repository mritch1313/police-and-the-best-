class_name PlayerCar
extends VehicleRig
## Машина игрока: каркас (VehicleRig) + ввод с тач-UI + учёт статистики сессии + реакция на
## арест/разбитие. Никакой физики здесь нет — только «обвязка» игрока.
##
## ВВОД: MobileControls отдаёт словарь через `read_drive()`, его подхватывает
## VehicleController (см. `_read_raw_input`). Поэтому «поменять способ управления»
## (геймпад, клавиатура, стрим-кнопки) = передать другой узел в `set_controls()`.

signal nitro_requested(on: bool)
signal player_arrested
signal player_destroyed

const ARREST_FREEZE_SPEED_KMH := 4.0
const DESTROY_IMPACT_KMS := 24.0

var controls: Node = null
var camera: CameraController = null
var chase: Node = null
var hud: Node = null
var last_input_source: String = "none"
var arrest_lock_left: float = 0.0
var destroyed: bool = false
var _stats_base_m: float = 0.0
var _stats_timer: float = 0.0
var _reported_speed_kms: float = 0.0

func _ready() -> void:
	is_player = true
	wants_nitro = true
	config_section = "vehicle.player"
	assemble()
	crashed.connect(_on_crashed)
	process_mode = Node.PROCESS_MODE_ALWAYS

func bind(controls_node: Node, camera_node: CameraController, chase_node: Node, hud_node: Node = null) -> void:
	controls = controls_node
	camera = camera_node
	chase = chase_node
	hud = hud_node
	set_controls(controls)
	if camera != null:
		camera.set_target(self, physics)
		camera.snap_behind_target()
	if chase != null and chase.has_method("attach_target"):
		chase.attach_target(self)

func _process(_delta: float) -> void:
	_stats_timer -= _delta
	if _stats_timer > 0.0:
		return
	_stats_timer = 0.1
	var speed_kms := absf(linear_velocity.length())
	_reported_speed_kms = speed_kms
	if last_input_source == "none" and controller != null:
		last_input_source = String(physics.input.source) if physics != null else "none"
	if AppState.is_playing():
		AppState.update_speed_record(speed_kms)
	if hud != null and hud.has_method("on_player_tick"):
		hud.call("on_player_tick", self)

func _physics_process(delta: float) -> void:
	super(delta)
	if arrest_lock_left > 0.0:
		arrest_lock_left = maxf(arrest_lock_left - delta, 0.0)
		if arrest_lock_left <= 0.0:
			# Отпустили: снимаем «залипание» газа, иначе первый кадр после ареста = дрифт.
			if controller != null:
				controller.reset()

## Статистика «пробег с последнего запроса»: ChaseManager забирает её раз в кадр, и передавать
## «весь пробег» нельзя — счётчик дистанции сессии превратился бы в квадрат времени.
## Считаем по реальным позициям (rig.travelled_m), а не по «скорость*dt»: при ударе о стену
## пройденный путь = 0, и накручивать за это километры нечестно.
func travelled_m_reset() -> float:
	var now := travelled_m()
	var delta_m := maxf(now - _stats_base_m, 0.0)
	_stats_base_m = now
	return delta_m

func ground_y() -> float:
	if physics != null:
		return global_position.y - physics.height_above_ground
	return global_position.y

func set_nitro_request(on: bool) -> void:
	nitro_requested.emit(on)

func respawn(position: Vector3, heading: float) -> void:
	destroyed = false
	place_at(position, heading, ground_y())
	_stats_base_m = travelled_m()
	if camera != null:
		camera.snap_behind_target()
	if hud != null and hud.has_method("flash"):
		hud.call("flash", "респавн", Color(0.7, 0.9, 1.0))

func _on_crashed(impact_speed_ms: float, _rig: VehicleRig) -> void:
	if impact_speed_ms < DESTROY_IMPACT_KMS:
		if camera != null:
			camera.add_shake(clampf(impact_speed_ms / DESTROY_IMPACT_KMS, 0.0, 1.0) * 0.5)
		return
	if not destroyed and config != null:
		# «Разбит» = очень сильный удар: игра оканчивается, а не чинится на ходу.
		destroyed = true
		if physics != null:
			physics.input.throttle = 0.0
		player_destroyed.emit()
		if hud != null and hud.has_method("show_banner"):
			hud.call("show_banner", "АВАРИЯ", Color(1.0, 0.45, 0.3))

func on_arrest() -> void:
	destroyed = false
	arrest_lock_left = 2.4
	player_arrested.emit()
	if hud != null and hud.has_method("show_banner"):
		hud.call("show_banner", "ЗАДЕРЖАН", Color(0.55, 0.8, 1.0))
	if camera != null:
		camera.on_event("arrest")

func state() -> Dictionary:
	var data := snapshot()
	data["destroyed"] = destroyed
	data["arrest_lock_left"] = arrest_lock_left
	data["input_source"] = last_input_source
	if controls != null and controls.has_method("state"):
		data["controls"] = controls.call("state")
	return data
