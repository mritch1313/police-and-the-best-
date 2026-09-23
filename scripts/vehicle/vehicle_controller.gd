class_name VehicleController
extends Node
## Переводит «намерения» (тач, клавиши, автопилот харнесса) в [DriveInput] физики.
##
## Здесь: педали, передачи (газ/задний ход), ручник, запрос нитро, «застрял»/опрокинулся,
## мягкие рампы (чтобы машина не дёргалась от тапа по кнопке) и восстановление.
## Никакой физики и никаких координат — только целевые управляющие сигналы.

signal blocked_changed(is_blocked: bool)
signal gear_changed(index: int)
signal recovered

enum Gear { PARK = 0, REVERSE = 1, DRIVE = 2 }

## Откуда брать ввод. [MobileControls] (тач) или null — тогда только клавиши/override.
@export var controls: Node = null
## Разрешить клавиатуру (desktop-отладка и headless-тесты).
@export var allow_keyboard: bool = true
@export var throttle_ramp_up: float = 3.4
@export var throttle_ramp_down: float = 5.2
@export var brake_ramp: float = 8.0
@export var steer_from_keys: bool = true
## Сколько секунд «пру» в стену, прежде чем считать, что машина застряла.
@export var blocked_after_s: float = 1.6
## Переворот: сколько секунд кузовом вниз до автоматической помощи.
@export var flip_after_s: float = 2.4
## Импульс переворота (Н*с) — только крутящий момент и лёгкая вертикальная подсказка.
@export var flip_impulse: float = 900.0

var gear: int = Gear.DRIVE
var physics: VehiclePhysics = null
var nitro: NitroSystem = null
var body: RigidBody3D = null
## Если != null — ввод берётся отсюда (автопилот харнесса/ИИ), tач и клавиши игнорируются.
var override_input: DriveInput = null
var is_blocked: bool = false
var flip_time: float = 0.0
var _steer_target: float = 0.0
var _throttle: float = 0.0
var _brake: float = 0.0
var _handbrake: float = 0.0
var _nitro_request: bool = false

func _ready() -> void:
	var parent := get_parent()
	physics = parent.get_node_or_null("VehiclePhysics") as VehiclePhysics
	if physics == null:
		physics = parent.find_child("VehiclePhysics", true, false) as VehiclePhysics
	nitro = parent.find_child("NitroSystem", true, false) as NitroSystem
	body = parent as RigidBody3D
	if physics == null or body == null:
		push_error("VehicleController: рядом нет VehiclePhysics/RigidBody3D")
		set_physics_process(false)

func _physics_process(delta: float) -> void:
	if physics == null or physics.config == null:
		return
	if override_input != null:
		physics.input.throttle = override_input.throttle
		physics.input.brake = override_input.brake
		physics.input.handbrake = override_input.handbrake
		physics.input.steer = override_input.steer
		physics.input.steer_absolute = override_input.steer_absolute
		physics.input.source = override_input.source
		_apply_nitro_request(override_input.throttle > 0.5 and _nitro_request)
		return

	var raw := _read_raw_input()
	_gear_logic(raw)
	_ramp_controls(raw, delta)
	physics.input.source = raw.get("source", "keys")
	physics.input.steer = clampf(_steer_target, -1.0, 1.0)
	physics.input.throttle = clampf(_throttle, -1.0, 1.0)
	physics.input.brake = clampf(_brake, 0.0, 1.0)
	physics.input.handbrake = clampf(_handbrake, 0.0, 1.0)
	physics.input.steer_absolute = false
	_apply_nitro_request(bool(raw.get("nitro", false)))
	_watch_stuck(delta)
	_watch_flip(delta)

func _read_raw_input() -> Dictionary:
	var steer := 0.0
	var up := false
	var down := false
	var hand := false
	var nitro := false
	var reverse := false
	var source := "none"
	if controls != null and controls.has_method("read_drive"):
		var drive: Dictionary = controls.call("read_drive")
		steer = float(drive.get("steer", 0.0))
		up = bool(drive.get("throttle", false))
		down = bool(drive.get("brake", false))
		hand = bool(drive.get("handbrake", false))
		nitro = bool(drive.get("nitro", false))
		reverse = bool(drive.get("reverse", false))
		source = "touch"
	if allow_keyboard:
		var ks := Input.get_axis("steer_left", "steer_right") if InputMap.has_action("steer_left") else 0.0
		if steer_from_keys and absf(ks) > 0.0:
			steer = ks
			source = "keys"
		if InputMap.has_action("throttle") and Input.is_action_pressed("throttle"):
			up = true
			source = "keys"
		if InputMap.has_action("brake") and Input.is_action_pressed("brake"):
			down = true
			source = "keys"
		if InputMap.has_action("handbrake") and Input.is_action_pressed("handbrake"):
			hand = true
		if InputMap.has_action("nitro") and Input.is_action_pressed("nitro"):
			nitro = true
		if InputMap.has_action("reverse") and Input.is_action_pressed("reverse"):
			reverse = true
	return {
		"steer": steer,
		"throttle": up,
		"brake": down,
		"handbrake": hand,
		"nitro": nitro,
		"reverse": reverse,
		"source": source,
	}

## Логика педали «газ» с реверсом: назад можно только почти остановившись.
func _gear_logic(raw: Dictionary) -> void:
	var want_reverse := bool(raw.get("reverse", false))
	var forward := bool(raw.get("throttle", false))
	var speed := absf(physics.forward_speed_kms) / 3.6
	if want_reverse and gear != Gear.REVERSE and speed < 1.2:
		_set_gear(Gear.REVERSE)
	elif not want_reverse and gear == Gear.REVERSE and (forward or speed > 2.5):
		_set_gear(Gear.DRIVE)

func _set_gear(index: int) -> void:
	if gear == index:
		return
	gear = index
	gear_changed.emit(gear)

func _ramp_controls(raw: Dictionary, delta: float) -> void:
	var forward := bool(raw.get("throttle", false))
	var braking := bool(raw.get("brake", false))
	var hand := bool(raw.get("handbrake", false))
	var target := 0.0
	if gear == Gear.REVERSE:
		target = -1.0 if forward else (1.0 if braking else 0.0)
	else:
		target = 1.0 if forward else 0.0
	var rate := throttle_ramp_up if absf(target) > absf(_throttle) else throttle_ramp_down
	_throttle = move_toward(_throttle, target, rate * delta)
	_brake = move_toward(_brake, 1.0 if braking else 0.0, brake_ramp * delta)
	_handbrake = move_toward(_handbrake, 1.0 if hand else 0.0, brake_ramp * 0.8 * delta)
	# На малой скорости тормоз дожимает машину до нуля, чтобы она не «плыла».
	if braking and absf(physics.forward_speed_kms) < 3.0 and gear != Gear.REVERSE:
		_throttle = 0.0
		_brake = 1.0
	_steer_target = clampf(float(raw.get("steer", 0.0)), -1.0, 1.0)

func _apply_nitro_request(on: bool) -> void:
	_nitro_request = on
	if nitro != null and nitro.has_method("set_requested"):
		nitro.call("set_requested", on)

func _watch_stuck(_delta: float) -> void:
	var was := is_blocked
	is_blocked = physics.blocked_time > blocked_after_s
	if was != is_blocked:
		blocked_changed.emit(is_blocked)
		if is_blocked:
			DebugConsole.log_line("vehicle", "машина застряла: тяга есть, скорости нет (%.1f с)" % physics.blocked_time)

func _watch_flip(delta: float) -> void:
	if body == null or physics.config == null:
		return
	var up := body.global_transform.basis.y
	var upside_down := up.y < -0.25
	flip_time = flip_time + delta if upside_down else 0.0
	if flip_time > flip_after_s:
		recover_upright()

## Помощь при перевороте: момент + короткий вертикальный импульс. Никаких set_position.
func recover_upright() -> void:
	if body == null:
		return
	flip_time = 0.0
	var basis := body.global_transform.basis
	var up := basis.y
	var axis := up.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		axis = basis.x
	var impulse := Vector3.UP * flip_impulse * 0.35
	body.apply_impulse(impulse, Vector3.ZERO)
	body.apply_torque_impulse(axis.normalized() * flip_impulse * 0.5)
	recovered.emit()
	DebugConsole.log_line("vehicle", "переворот: выворачиваемся импульсом")

func reset() -> void:
	_throttle = 0.0
	_brake = 0.0
	_handbrake = 0.0
	_steer_target = 0.0
	gear = Gear.DRIVE
	is_blocked = false
	flip_time = 0.0
	_nitro_request = false
	if physics != null:
		physics.input.reset()
	if nitro != null:
		nitro.set_requested(false)

func set_autopilot(input_override: DriveInput) -> void:
	override_input = input_override
