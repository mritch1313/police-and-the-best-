extends Control
class_name MobileControls
## The on-screen driving controls for a phone.
##
## Layout (portrait, 720x1612 design resolution):
##   * left thumb:  a virtual steering stick with a dead zone and a visible knob
##   * right thumb: the two pedals (gas above, brake below), the handbrake bar and NITRO
##   * the rest of the screen is the look area: dragging anywhere else rotates the camera
##     without moving the car, which is what makes a mobile chase game playable
##
## The sizes are deliberately generous (the smallest button is 96 px tall in the design
## resolution, which is roughly 9 mm on the target device) and every touch target grows with
## `SettingsManager.touch_button_scale`, so the interface stays usable on a small screen.
##
## The controls never touch the car: they only write into `InputManager`'s touch snapshot,
## which is the same snapshot the keyboard writes into. That is why the same build works on a
## phone, on a desktop and inside the automated tests.

## Radius of the steering stick in design pixels.
const STICK_RADIUS := 118.0
## Radius of the knob.
const KNOB_RADIUS := 52.0
## Fraction of the stick that does nothing (worn thumb, deliberate dead zone).
const STICK_DEAD_ZONE := 0.14

const BUTTON_BASE_COLOUR := Color(0.09, 0.11, 0.15, 0.55)
const BUTTON_ACTIVE_COLOUR := Color(0.85, 0.25, 0.18, 0.7)
const ACCENT_COLOUR := Color(0.2, 0.6, 0.95, 0.75)

var steering_active: bool = false
var steering_value: float = 0.0
var throttle_active: bool = false
var brake_active: bool = false
var handbrake_active: bool = false
var nitro_active: bool = false
var reverse_active: bool = false

var _stick_origin: Vector2 = Vector2.ZERO
var _stick_touch_index: int = -1
var _knob_position: Vector2 = Vector2.ZERO
var _look_touch_index: int = -1
var _look_last_position: Vector2 = Vector2.ZERO
var _button_touches: Dictionary = {}
var _buttons: Dictionary = {}
var _scale: float = 1.0
var _visible_rect: Rect2 = Rect2()
var _hud_blocks: Array[Rect2] = []


func _ready() -> void:
	# The controls must keep working while the game is paused (the pause menu is optional).
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_scale = SettingsManager.touch_button_scale
	_build_buttons()
	resized.connect(_rebuild_layout)
	_rebuild_layout()


## Every button of the interface, with its anchor and its size in design pixels. Keeping the
## definition in data means the layout can be re-arranged (or mirrored for left handed
## players) without touching the input code.
func button_definitions() -> Array[Dictionary]:
	var mirror := -1.0 if SettingsManager.steering_on_left else 1.0
	return [
		{"id": &"throttle", "label": "ГАЗ", "anchor": Vector2(-1.0, -1.0), "size": Vector2(200, 132), "colour": Color(0.15, 0.55, 0.3, 0.62)},
		{"id": &"brake", "label": "ТОРМОЗ", "anchor": Vector2(-1.0, -1.0), "size": Vector2(200, 118), "colour": Color(0.6, 0.16, 0.14, 0.62)},
		{"id": &"handbrake", "label": "РУЧНИК", "anchor": Vector2(-1.0, -1.0), "size": Vector2(200, 92), "colour": Color(0.55, 0.45, 0.12, 0.6)},
		{"id": &"nitro", "label": "NITRO", "anchor": Vector2(mirror, 1.0), "size": Vector2(180, 180), "colour": ACCENT_COLOUR},
		{"id": &"reverse", "label": "ЗАДНИЙ", "anchor": Vector2(mirror, 1.0), "size": Vector2(150, 104), "colour": Color(0.3, 0.3, 0.34, 0.6)},
	]


func _build_buttons() -> void:
	for definition: Dictionary in button_definitions():
		var button := Button.new()
		button.name = String(definition["id"])
		button.text = String(definition["label"])
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_theme_font_size_override("font_size", int(30 * _scale))
		var style := StyleBoxFlat.new()
		style.bg_color = definition["colour"]
		style.corner_radius_top_left = 22
		style.corner_radius_top_right = 22
		style.corner_radius_bottom_left = 22
		style.corner_radius_bottom_right = 22
		style.border_width_left = 3
		style.border_width_top = 3
		style.border_width_right = 3
		style.border_width_bottom = 3
		style.border_color = Color(1, 1, 1, 0.35)
		button.add_theme_stylebox_override("normal", style)
		var active_style := style.duplicate() as StyleBoxFlat
		active_style.bg_color = Color(
			minf(style.bg_color.r + 0.3, 1.0), minf(style.bg_color.g + 0.25, 1.0), minf(style.bg_color.b + 0.2, 1.0), 0.85
		)
		button.add_theme_stylebox_override("pressed", active_style)
		button.add_theme_stylebox_override("hover", active_style)
		add_child(button)
		_buttons[definition["id"]] = button


## Places the buttons for the current screen size. Called on every resize, so rotating the
## device re-lays out the interface correctly.
func _rebuild_layout() -> void:
	_visible_rect = Rect2(Vector2.ZERO, size)
	var margin := 26.0 * _scale
	var total_width := size.x
	var total_height := size.y
	var steering_side := -1.0 if SettingsManager.steering_on_left else 1.0
	# The stick lives in the bottom corner chosen by the settings, the pedals in the other one.
	var stick_centre := Vector2(
		total_width * 0.5 + steering_side * (total_width * 0.5 - STICK_RADIUS * _scale - margin),
		total_height - STICK_RADIUS * _scale - margin * 2.0
	)
	_stick_origin = stick_centre
	_knob_position = stick_centre
	var pedals_right := steering_side < 0.0
	var pedals_x := total_width - margin if pedals_right else margin
	var definitions := button_definitions()
	var y := total_height - margin
	for definition: Dictionary in definitions:
		var id: StringName = definition["id"]
		var button: Button = _buttons[id]
		var button_size: Vector2 = definition["size"] * _scale
		match id:
			&"nitro":
				# Nitro is the accent control: a large round button above the steering stick,
				# where the thumb that steers can also reach it without letting go.
				var nitro_centre := Vector2(
					total_width * 0.5 + steering_side * (total_width * 0.5 - button_size.x * 0.5 - margin),
					total_height - STICK_RADIUS * _scale * 2.0 - margin * 3.5 - button_size.y * 0.5
				)
				button.position = nitro_centre - button_size * 0.5
				button.size = button_size
			&"reverse":
				# Reverse sits high on the pedal side so it is never hit by accident.
				var reverse_x := total_width - margin - button_size.x if pedals_right else margin
				button.position = Vector2(reverse_x, margin * 1.2)
				button.size = button_size
			_:
				y -= button_size.y
				button.position = Vector2(pedals_x - button_size.x if pedals_right else pedals_x, y)
				button.size = button_size
				y -= margin * 0.6
	_rebuild_touch_targets()


## The touch targets are plain rectangles derived from the button placement. Using rectangles
## instead of Control hit testing keeps multi touch handling exact: every finger is matched to
## the target it started on, which is what allows steering, gas and nitro at the same time.
func _rebuild_touch_targets() -> void:
	_hud_blocks.clear()
	for definition: Dictionary in button_definitions():
		var id: StringName = definition["id"]
		var button: Button = _buttons[id]
		_hud_blocks.append(Rect2(button.position, button.size))


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		# Desktop testing path: the mouse emulates touches.
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT:
			var touch := InputEventScreenTouch.new()
			touch.position = mouse.position
			touch.pressed = mouse.pressed
			touch.index = 0
			_handle_touch(touch)
	elif event is InputEventMouseMotion and _stick_touch_index == 0:
		var drag := InputEventScreenDrag.new()
		drag.position = (event as InputEventMouseMotion).position
		drag.index = 0
		_handle_drag(drag)


func _handle_touch(touch: InputEventScreenTouch) -> void:
	if touch.pressed:
		# 1. A button?
		for definition: Dictionary in button_definitions():
			var id: StringName = definition["id"]
			var button: Button = _buttons[id]
			if Rect2(button.position, button.size).grow(10.0).has_point(touch.position):
				_button_touches[touch.index] = id
				_set_button_state(id, true)
				return
		# 2. The steering stick?
		if touch.position.distance_to(_stick_origin) < STICK_RADIUS * _scale * 1.35:
			_stick_touch_index = touch.index
			steering_active = true
			_update_stick(touch.position)
			return
		# 3. Otherwise the finger drives the camera.
		if _look_touch_index < 0:
			_look_touch_index = touch.index
			_look_last_position = touch.position
	else:
		if _button_touches.has(touch.index):
			_set_button_state(_button_touches[touch.index], false)
			_button_touches.erase(touch.index)
			return
		if touch.index == _stick_touch_index:
			_stick_touch_index = -1
			steering_active = false
			steering_value = 0.0
			_knob_position = _stick_origin
			InputManager.set_touch_steer(0.0)
		if touch.index == _look_touch_index:
			_look_touch_index = -1


func _handle_drag(drag: InputEventScreenDrag) -> void:
	if drag.index == _stick_touch_index:
		_update_stick(drag.position)
	elif drag.index == _look_touch_index:
		var delta := drag.position - _look_last_position
		_look_last_position = drag.position
		InputManager.add_touch_look(delta)


func _update_stick(position: Vector2) -> void:
	var offset := position - _stick_origin
	var radius := STICK_RADIUS * _scale
	if offset.length() > radius:
		offset = offset.normalized() * radius
	_knob_position = _stick_origin + offset
	var steer := offset.x / radius
	if absf(steer) < STICK_DEAD_ZONE:
		steer = 0.0
	else:
		steer = signf(steer) * (absf(steer) - STICK_DEAD_ZONE) / (1.0 - STICK_DEAD_ZONE)
	steering_value = clampf(steer * SettingsManager.touch_steering_sensitivity, -1.0, 1.0)
	InputManager.set_touch_steer(steering_value)


func _set_button_state(id: StringName, pressed: bool) -> void:
	var button: Button = _buttons.get(id)
	match id:
		&"throttle":
			throttle_active = pressed
			InputManager.set_touch_throttle(1.0 if pressed else 0.0)
		&"brake":
			brake_active = pressed
			InputManager.set_touch_brake(1.0 if pressed else 0.0)
		&"handbrake":
			handbrake_active = pressed
			InputManager.set_touch_handbrake(pressed)
		&"nitro":
			nitro_active = pressed
			InputManager.set_touch_nitro(pressed)
		&"reverse":
			reverse_active = pressed
			InputManager.set_touch_reverse(pressed)
	if button != null:
		button.modulate = Color(1.25, 1.25, 1.25) if pressed else Color.WHITE


## Draws the steering stick. The buttons draw themselves, the stick is drawn here because a
## pair of circles is cheaper than a hierarchy of nodes.
func _draw() -> void:
	if not visible:
		return
	var radius := STICK_RADIUS * _scale
	draw_circle(_stick_origin, radius, Color(0.05, 0.06, 0.09, 0.35))
	draw_arc(_stick_origin, radius, 0.0, TAU, 40, Color(1, 1, 1, 0.28), 3.0)
	draw_circle(_stick_origin, radius * 0.16, Color(1, 1, 1, 0.12))
	var knob_colour := BUTTON_ACTIVE_COLOUR if steering_active else Color(0.75, 0.78, 0.85, 0.5)
	draw_circle(_knob_position, KNOB_RADIUS * _scale * 0.5, knob_colour)
	draw_arc(_knob_position, KNOB_RADIUS * _scale * 0.5, 0.0, TAU, 24, Color(1, 1, 1, 0.4), 2.0)
	# Steering angle feedback: a small tick that shows how much lock is applied.
	var steer := steering_value
	if absf(steer) > 0.01:
		var direction := Vector2(steer, 0.0) * radius * 0.8
		draw_line(_stick_origin, _stick_origin + direction, Color(0.9, 0.9, 0.95, 0.55), 4.0)


func _process(_delta: float) -> void:
	queue_redraw()


## Releases every control (used when the game is paused or the run ends).
func release_all() -> void:
	for id: StringName in _buttons.keys():
		_set_button_state(id, false)
	_button_touches.clear()
	_stick_touch_index = -1
	_look_touch_index = -1
	steering_active = false
	steering_value = 0.0
	_knob_position = _stick_origin
	InputManager.clear_touch_state()


## True when the player is currently asking for reverse.
func is_reversing() -> bool:
	return reverse_active
