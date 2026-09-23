extends Node
## Autoload: the single place where every input device becomes a DriveInput.
##
## Keyboard, gamepad and the on-screen touch controls all write into one snapshot per
## frame. The vehicle never asks the OS for input, it only reads `drive_input`, which is
## what makes the car identical on a phone, on a desktop and inside an automated test.

signal input_device_changed(device: StringName)

const ACTION_STEER_LEFT := &"steer_left"
const ACTION_STEER_RIGHT := &"steer_right"
const ACTION_THROTTLE := &"throttle"
const ACTION_BRAKE := &"brake"
const ACTION_HANDBRAKE := &"handbrake"
const ACTION_NITRO := &"nitro"
const ACTION_REVERSE := &"reverse"
const ACTION_CAMERA_RESET := &"camera_reset"
const ACTION_PAUSE := &"pause"
const ACTION_LOOK_LEFT := &"look_left"
const ACTION_LOOK_RIGHT := &"look_right"
const ACTION_LOOK_UP := &"look_up"
const ACTION_LOOK_DOWN := &"look_down"

## Every action the game relies on, with the keyboard key that also drives it. The
## project.godot InputMap is the primary definition; this table is the safety net that
## guarantees the actions exist even when the project file is edited by hand.
const ACTION_TABLE := {
	ACTION_STEER_LEFT: [KEY_A, KEY_LEFT],
	ACTION_STEER_RIGHT: [KEY_D, KEY_RIGHT],
	ACTION_THROTTLE: [KEY_W, KEY_UP],
	ACTION_BRAKE: [KEY_S, KEY_DOWN],
	ACTION_HANDBRAKE: [KEY_SPACE],
	ACTION_NITRO: [KEY_SHIFT],
	ACTION_REVERSE: [KEY_R],
	ACTION_CAMERA_RESET: [KEY_C],
	ACTION_PAUSE: [KEY_ESCAPE],
	ACTION_LOOK_LEFT: [KEY_J],
	ACTION_LOOK_RIGHT: [KEY_L],
	ACTION_LOOK_UP: [KEY_I],
	ACTION_LOOK_DOWN: [KEY_K],
}

## The merged snapshot the game reads.
var drive_input := DriveInput.new()

var _keyboard := DriveInput.new()
var _gamepad := DriveInput.new()
var _touch := DriveInput.new()
var _last_device: StringName = &"none"
var _mouse_look_active := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ensure_input_map()
	_last_device = &"touch" if OS.has_feature("mobile") else &"keyboard"
	InputManager.drive_input.source = _last_device


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_notify_device(&"touch")
	elif event is InputEventKey and event.is_pressed():
		_notify_device(&"keyboard")
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_notify_device(&"gamepad")


func _process(_delta: float) -> void:
	_poll_keyboard()
	_poll_gamepad()
	_merge()


## Creates every action the game needs, adding only what is missing. Keeps the project
## playable even if the InputMap section of project.godot was emptied or hand edited.
func ensure_input_map() -> void:
	for action: StringName in ACTION_TABLE.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		var has_keyboard := false
		for existing: InputEvent in InputMap.action_get_events(action):
			if existing is InputEventKey or existing is InputEventJoypadButton or existing is InputEventJoypadMotion:
				has_keyboard = true
				break
		if has_keyboard:
			continue
		for key: int in ACTION_TABLE[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)


## True when every required action exists and has at least one bound event.
func input_map_is_complete() -> bool:
	for action: StringName in ACTION_TABLE.keys():
		if not InputMap.has_action(action):
			return false
		if InputMap.action_get_events(action).is_empty():
			return false
	return true


## Touch controls (MobileControls) push their raw values here. They are kept separate from
## the keyboard so the two devices can be blended instead of fighting each other.
func set_touch_steer(value: float) -> void:
	_touch.steer = clampf(value, -1.0, 1.0)
	_touch.source = &"touch"


func set_touch_throttle(value: float) -> void:
	_touch.throttle = clampf(value, 0.0, 1.0)
	_touch.source = &"touch"


func set_touch_brake(value: float) -> void:
	_touch.brake = clampf(value, 0.0, 1.0)
	_touch.source = &"touch"


func set_touch_handbrake(pressed: bool) -> void:
	_touch.handbrake = pressed
	_touch.source = &"touch"


func set_touch_nitro(pressed: bool) -> void:
	_touch.nitro = pressed
	_touch.source = &"touch"


func set_touch_reverse(pressed: bool) -> void:
	_touch.reverse_requested = pressed
	_touch.source = &"touch"


func add_touch_look(delta: Vector2) -> void:
	_touch.look_delta += delta


func clear_touch_state() -> void:
	_touch.reset()


## Merges all sources into `drive_input`. Touch wins when the player actually touched
## something, otherwise keyboard/gamepad drive the car (the same build is playable on a
## phone and on a desktop).
func _merge() -> void:
	_keyboard.reset()
	_gamepad.reset()
	drive_input.reset()
	drive_input.source = _last_device
	var touch_active := not _touch.is_neutral() or _touch.look_delta.length_squared() > 0.0
	if touch_active:
		drive_input.merge(_touch)
	drive_input.merge(_keyboard)
	drive_input.merge(_gamepad)
	if _touch.look_delta != Vector2.ZERO:
		drive_input.look_delta += _touch.look_delta
		_touch.look_delta = Vector2.ZERO
	drive_input.sanitize()


func _poll_keyboard() -> void:
	var left := Input.is_action_pressed(ACTION_STEER_LEFT)
	var right := Input.is_action_pressed(ACTION_STEER_RIGHT)
	var steer := (1.0 if right else 0.0) - (1.0 if left else 0.0)
	_keyboard.steer = steer
	_keyboard.throttle = 1.0 if Input.is_action_pressed(ACTION_THROTTLE) else 0.0
	_keyboard.brake = 1.0 if Input.is_action_pressed(ACTION_BRAKE) else 0.0
	_keyboard.handbrake = Input.is_action_pressed(ACTION_HANDBRAKE)
	_keyboard.nitro = Input.is_action_pressed(ACTION_NITRO)
	_keyboard.reverse_requested = Input.is_action_pressed(ACTION_REVERSE)
	_keyboard.camera_reset = Input.is_action_just_pressed(ACTION_CAMERA_RESET)
	if not _keyboard.is_neutral() and _keyboard.steer != 0.0:
		_keyboard.source = &"keyboard"
	if absf(_gamepad.steer) < 0.01:
		var look := Vector2.ZERO
		if Input.is_action_pressed(ACTION_LOOK_LEFT):
			look.x -= 1.0
		if Input.is_action_pressed(ACTION_LOOK_RIGHT):
			look.x += 1.0
		if Input.is_action_pressed(ACTION_LOOK_UP):
			look.y -= 1.0
		if Input.is_action_pressed(ACTION_LOOK_DOWN):
			look.y += 1.0
		_keyboard.look_delta += look * 12.0


func _poll_gamepad() -> void:
	var dead_zone := 0.18
	var steer := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	if absf(steer) < dead_zone:
		steer = 0.0
	var trigger := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT)
	var brake_axis := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT)
	_gamepad.steer = steer
	_gamepad.throttle = clampf(maxf(trigger, 0.0 if Input.is_action_pressed(ACTION_THROTTLE) else 0.0), 0.0, 1.0)
	if trigger > 0.05 or brake_axis > 0.05:
		_gamepad.source = &"gamepad"
	_gamepad.brake = clampf(brake_axis, 0.0, 1.0)
	_gamepad.handbrake = Input.is_joy_button_pressed(0, JOY_BUTTON_B) if Input.get_connected_joypads().size() > 0 else false
	_gamepad.nitro = Input.is_joy_button_pressed(0, JOY_BUTTON_A) if Input.get_connected_joypads().size() > 0 else false
	var look_x := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var look_y := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(look_x) > dead_zone or absf(look_y) > dead_zone:
		_gamepad.look_delta += Vector2(look_x, look_y) * 18.0
		_gamepad.source = &"gamepad"


## Look delta from mouse dragging (desktop debugging) is read directly by the camera, the
## touch path goes through the MobileControls overlay.
func consume_mouse_look() -> Vector2:
	if not _mouse_look_active:
		return Vector2.ZERO
	var delta := Vector2.ZERO
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		delta = _last_mouse_delta
	_last_mouse_delta = Vector2.ZERO
	return delta


var _last_mouse_delta := Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		_mouse_look_active = true
		_last_mouse_delta += (event as InputEventMouseMotion).relative


func is_touch_device() -> bool:
	return OS.has_feature("mobile") or _last_device == &"touch"


func current_device() -> StringName:
	return _last_device


func _notify_device(device: StringName) -> void:
	if device == _last_device:
		return
	_last_device = device
	drive_input.source = device
	input_device_changed.emit(device)
