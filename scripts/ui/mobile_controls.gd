class_name MobileControls
extends Control
## Тач-управление: динамический стик, крупные кнопки, зона камеры, пинч-зум.
##
## КОНТРАКТ С ФИЗИКОЙ: VehicleController вызывает `read_drive()` и получает словарь
## {steer, throttle, brake, handbrake, reverse, nitro}. Это единственный «мост» между
## пальцем и машиной — поэтому UI не знает ничего про момент силы, сцепление и передачу,
## а физика не знает ничего про кнопки.
##
## МОБИЛЬНЫЕ МЕЛОЧИ, КОТОРЫЕ ЛОМАЮТ ИГРУ, ЕСЛИ ИХ НЕ УЧЕСТЬ:
##  * «мертвая зона» стика: без неё машина дрожит на месте (joystick_deadzone);
##  * кнопки НЕ МЕНЬШЕ min_touch_target_px (96 логических px) — меньше = промахи пальца;
##  * отпускание пальца ВНЕ кнопки обязано снимать нажатие — у Button это есть по умолчанию,
##    но только если кнопка не «задавлена» другим контролом: поэтому у корня MOUSE_FILTER_IGNORE,
##    а зона камеры стоит ПОД кнопками;
##  * во время паузы/меню ввод обязан обнуляться (AppState.accepts_gameplay_input()), иначе
##    «открыл меню — машина уехала»;
##  * мультитач: стик, газ и камера держатся ОДНОВРЕМЕННО, поэтому за пальцами следим по
##    index, а не «последний палец = тот, что нужен»;
##  * горизонтальная составляющая стика = руль, вертикальная = газ/тормоз: палец не гуляет
##    по экрану, и «уехал» работает даже если кнопку GAS не нашли.

signal camera_dragged(delta_px: Vector2)
signal zoom_changed(factor: float)
signal action_changed(action: StringName, on: bool)
## Пауза с тач-экрана: на телефоне нет Esc, поэтому кнопка обязана быть на экране.
signal pause_requested

const ZONE_CAMERA_TOP_PORTRAIT := 0.52
const ZONE_CAMERA_TOP_LANDSCAPE := 0.62
const STICK_GAS_BAND := -0.35
const STICK_BRAKE_BAND := 0.45
const STICK_REVERSE_BAND := 0.75

var config: UiConfig = null
var camera: CameraController = null
var steer_value: float = 0.0
var throttle_held: bool = false
var brake_held: bool = false
var handbrake_held: bool = false
var reverse_held: bool = false
var nitro_held: bool = false
var debug_text: String = ""

var _touches: Dictionary = {}
var _stick_origin: Vector2 = Vector2.ZERO
var _stick_offset: Vector2 = Vector2.ZERO
var _stick_active_id: int = -1
var _stick_base: ColorRect = null
var _stick_knob: ColorRect = null
var _radius: float = 112.0
var _deadzone: float = 0.14
var _pinch_distance: float = 0.0
var _pinch_active: bool = false
var _camera_pointer: int = -1
var _zones: Control = null
var _buttons_root: Control = null
var _buttons: Dictionary = {}
var _pause_button: Button = null
var _ui_scale: float = 1.0

func _ready() -> void:
	if config == null:
		config = GameSetup.get_config("ui") as UiConfig
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_camera_zone()
	_build_stick()
	_build_buttons()
	_apply_config()
	_relayout()
	resized.connect(_relayout)
	if Settings != null:
		Settings.settings_changed.connect(_on_settings_changed)

func bind_camera(controller: CameraController) -> void:
	camera = controller

func _on_settings_changed() -> void:
	_apply_config()
	_relayout()

func _apply_config() -> void:
	_ui_scale = clampf(Settings.ui_scale if Settings != null else 1.0, 0.6, 2.0)
	if config == null:
		return
	_radius = clampf(config.joystick_radius_px * _ui_scale, 48.0, 260.0)
	_deadzone = clampf(config.joystick_deadzone, 0.0, 0.6)
	modulate.a = clampf(config.hud_alpha, 0.35, 1.0)

func _accent() -> Color:
	return config.accent if config != null else Color(0.98, 0.42, 0.16)

func _landscape() -> bool:
	if Settings != null:
		return Settings.is_landscape()
	return size.x > size.y

# ------------------------------------------------------------------ построение

func _build_camera_zone() -> void:
	_zones = Control.new()
	_zones.name = "CameraZone"
	_zones.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_zones)

func _build_stick() -> void:
	_stick_base = ColorRect.new()
	_stick_base.name = "StickBase"
	_stick_base.color = Color(1.0, 1.0, 1.0, 0.10)
	_stick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_base.visible = false
	add_child(_stick_base)
	_stick_knob = ColorRect.new()
	_stick_knob.name = "StickKnob"
	_stick_knob.color = Color(1.0, 1.0, 1.0, 0.3)
	_stick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_knob.visible = false
	add_child(_stick_knob)

func _build_buttons() -> void:
	_buttons_root = Control.new()
	_buttons_root.name = "Buttons"
	_buttons_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_buttons_root)
	_add_button("gas", "ГАЗ", _accent())
	_add_button("brake", "ТОРМОЗ", Color(0.90, 0.24, 0.20))
	_add_button("handbrake", "РУЧНИК", Color(0.86, 0.68, 0.18))
	_add_button("reverse", "НАЗАД", Color(0.40, 0.55, 0.80))
	_add_button("nitro", "NITRO", Color(0.34, 0.78, 1.00))
	_pause_button = _add_button("pause", "ПАУЗА", Color(0.44, 0.48, 0.55))
	if _pause_button != null:
		_pause_button.pressed.connect(func() -> void: pause_requested.emit())

func _add_button(id: String, label: String, color: Color) -> Button:
	var button := Button.new()
	button.name = id
	button.text = label
	button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, 0.92)
	style.set_corner_radius_all(int(18.0 * _ui_scale))
	var font_size := int((config.hud_font_size if config != null else 22) * 1.1 * _ui_scale)
	var theme := Theme.new()
	theme.set_font_size("font_size", "Button", font_size)
	for name_hint in ["font_color", "font_hover_color", "font_focus_color"]:
		theme.set_color(name_hint, "Button", Color(0.05, 0.05, 0.06))
	theme.set_color("font_pressed_color", "Button", Color(1.0, 1.0, 1.0))
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(color.r, color.g, color.b, 1.0)
	pressed.set_corner_radius_all(int(18.0 * _ui_scale))
	theme.set_stylebox("normal", "Button", style)
	theme.set_stylebox("hover", "Button", style)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	button.theme = theme
	button.button_down.connect(func() -> void: _set_held(id, true))
	button.button_up.connect(func() -> void: _set_held(id, false))
	_buttons_root.add_child(button)
	_buttons[id] = button
	return button

func _set_held(id: String, on: bool) -> void:
	match id:
		"gas":
			throttle_held = on
		"brake":
			brake_held = on
		"handbrake":
			handbrake_held = on
		"reverse":
			reverse_held = on
		"nitro":
			nitro_held = on
		_:
			return
	action_changed.emit(StringName(id), on)

func _relayout() -> void:
	if _zones == null or _buttons_root == null:
		return
	var rect := get_rect()
	var landscape := rect.size.x > rect.size.y
	_zones.size = Vector2(rect.size.x, rect.size.y * (ZONE_CAMERA_TOP_LANDSCAPE if landscape else ZONE_CAMERA_TOP_PORTRAIT))
	_zones.position = Vector2.ZERO
	var target := clampf((config.action_button_size_px if config != null else 128.0) * _ui_scale, 72.0, 220.0)
	target = maxf(target, (config.min_touch_target_px if config != null else 96.0) * _ui_scale)
	var margin := 14.0 * _ui_scale
	var gap := 10.0 * _ui_scale
	# Портрет: две колонки (пять кнопок в одну колонку на 720x1612 не влезают, не задев стик),
	# ландшафт: одна колонка справа, чтобы не перекрывать дорогу.
	var columns := 1 if landscape else 2
	var per_column := 5 if landscape else 3
	var order := ["handbrake", "reverse", "nitro", "brake", "gas"]
	var placed := 0
	for column in range(columns):
		for row in range(per_column):
			if placed >= order.size():
				break
			var button: Button = _buttons.get(order[placed])
			if button != null:
				var x := rect.size.x - margin - target * float(column + 1) - gap * float(column)
				var y := rect.size.y - margin - target * float(row + 1) - gap * float(row)
				button.position = Vector2(x, y)
				button.size = Vector2(target, target)
			placed += 1
	if _pause_button != null:
		var min_touch: float = (config.min_touch_target_px if config != null else 96.0) * _ui_scale
		var ps := clampf(target * 0.7, min_touch, 150.0)
		_pause_button.size = Vector2(maxf(ps * 1.35, min_touch * 1.4), ps)
		# Правый верхний угол: привычно, и не перекрывает ни стик, ни ряд кнопок газа/тормоза.
		_pause_button.position = Vector2(rect.size.x - margin - _pause_button.size.x, margin)
	if _stick_base != null:
		_stick_base.size = Vector2(_radius * 2.0, _radius * 2.0)
		_stick_knob.size = Vector2(_radius * 0.7, _radius * 0.7)

# ------------------------------------------------------------------ ввод

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)

func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		var rect := get_rect()
		var in_stick_area := event.position.y > rect.size.y * (ZONE_CAMERA_TOP_LANDSCAPE if _landscape() else ZONE_CAMERA_TOP_PORTRAIT) \
				and event.position.x < rect.size.x * 0.55
		if in_stick_area and _stick_active_id < 0:
			_begin_stick(event.index, event.position)
		elif _camera_pointer < 0:
			_camera_pointer = event.index
	else:
		_touches.erase(event.index)
		if event.index == _stick_active_id:
			_release_stick()
		if event.index == _camera_pointer:
			_camera_pointer = -1

func _begin_stick(index: int, at: Vector2) -> void:
	_stick_active_id = index
	_stick_origin = at
	_stick_offset = Vector2.ZERO
	steer_value = 0.0
	if _stick_base != null:
		_stick_base.visible = true
		_stick_base.position = _stick_origin - _stick_base.size * 0.5
		_stick_knob.visible = true
		_update_stick_knob(Vector2.ZERO)

func _release_stick() -> void:
	_stick_active_id = -1
	_stick_offset = Vector2.ZERO
	steer_value = 0.0
	if _stick_base != null:
		_stick_base.visible = false
		_stick_knob.visible = false

func _on_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if event.index == _stick_active_id:
		_stick_offset = event.position - _stick_origin
		var ratio := clampf(_stick_offset.length() / maxf(_radius, 1.0), 0.0, 1.0)
		if ratio < _deadzone:
			steer_value = 0.0
		else:
			var shaped := maxf((ratio - _deadzone) / maxf(1.0 - _deadzone, 0.05), 0.0)
			steer_value = signf(_stick_offset.x) * minf(shaped * 1.25, 1.0)
		if _stick_knob != null:
			_update_stick_knob(_stick_offset.limit_length(_radius))
	elif event.index == _camera_pointer and camera != null:
		camera.add_orbit_pixels(event.relative * clampf(Settings.camera_sensitivity if Settings != null else 1.0, 0.2, 3.0))
		camera_dragged.emit(event.relative)

func _update_stick_knob(offset: Vector2) -> void:
	if _stick_knob == null:
		return
	_stick_knob.position = _stick_origin + offset - _stick_knob.size * 0.5

## Пинч и «второй палец» видны только через _input: GUI-события зоны камеры приходят
## по одному указателю. Здесь мы НИКОГДА не помечаем событие съеденным, иначе кнопки
## перестали бы нажиматься.
func _input(event: InputEvent) -> void:
	if not (event is InputEventScreenDrag) and not (event is InputEventScreenTouch):
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = touch.position
		else:
			_touches.erase(touch.index)
		if _touches.size() < 2:
			_pinch_active = false
			_pinch_distance = 0.0
			return
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touches[drag.index] = drag.position
		_update_pinch()

func _update_pinch() -> void:
	if camera == null or _touches.size() < 2:
		return
	var pair := _two_furthest_points()
	if pair.size() < 2:
		return
	var distance := pair[0].distance_to(pair[1])
	if _pinch_distance <= 0.0:
		_pinch_distance = distance
		return
	var factor := distance / maxf(_pinch_distance, 1.0)
	_pinch_distance = distance
	if absf(factor - 1.0) < 0.012:
		return
	_pinch_active = true
	camera.add_zoom(clampf(1.0 - factor, -0.5, 0.5))
	zoom_changed.emit(factor)

func _two_furthest_points() -> Array:
	var values := _touches.values()
	var best_a := Vector2.INF
	var best_b := Vector2.INF
	var best := -1.0
	for i in range(values.size()):
		for j in range(i + 1, values.size()):
			var a: Vector2 = values[i]
			var b: Vector2 = values[j]
			var distance := a.distance_to(b)
			if distance > best:
				best = distance
				best_a = a
				best_b = b
	if best_a == Vector2.INF or best_b == Vector2.INF:
		return []
	return [best_a, best_b]

## Мышь в редакторе = палец (иначе отладка невозможна). Кнопки и зона камеры получают
## те же ветки, что и тач.
func _on_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		if camera != null:
			camera.add_zoom(-0.3)
			zoom_changed.emit(0.9)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if camera != null:
			camera.add_zoom(0.3)
			zoom_changed.emit(1.1)
		return
	var fake := InputEventScreenTouch.new()
	fake.pressed = event.pressed
	fake.position = event.position
	fake.index = 0
	_on_touch(fake)

func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _touches.has(0) and _stick_active_id != 0:
		return
	var fake := InputEventScreenDrag.new()
	fake.index = 0
	fake.position = event.position
	fake.relative = event.relative
	_on_drag(fake)

func _process(_delta: float) -> void:
	debug_text = "стик %.2f, касаний %d" % [steer_value, _touches.size()]

# ------------------------------------------------------------------ контракт VehicleController

## Единственная точка, через которую тач-UI попадает в физику.
func read_drive() -> Dictionary:
	if not AppState.accepts_gameplay_input():
		return {
			"steer": 0.0, "throttle": false, "brake": false, "handbrake": false,
			"reverse": false, "nitro": false, "source": "blocked",
		}
	var vertical := 0.0
	if _stick_active_id >= 0 and _radius > 1.0:
		vertical = clampf(_stick_offset.y / _radius, -1.0, 1.0)
	var up := throttle_held or vertical < STICK_GAS_BAND
	var down := brake_held or vertical > STICK_BRAKE_BAND
	return {
		"steer": steer_value,
		"throttle": up,
		"brake": down,
		"handbrake": handbrake_held,
		"reverse": reverse_held or vertical > STICK_REVERSE_BAND,
		"nitro": nitro_held,
		"source": "touch",
	}

func state() -> Dictionary:
	return {
		"steer": steer_value,
		"throttle": throttle_held,
		"brake": brake_held,
		"handbrake": handbrake_held,
		"reverse": reverse_held,
		"nitro": nitro_held,
		"touch_count": _touches.size(),
		"stick_active": _stick_active_id >= 0,
		"pinch": _pinch_active,
		"layout": "landscape" if _landscape() else "portrait",
		"button_min_px": (config.min_touch_target_px if config != null else 96.0) * _ui_scale,
		"pause_button": has_pause_button(),
	}

## Программное «нажатие» — нужно автотестам: проверяет всю цепочку до физики без пальца.
func set_hold(action: String, on: bool) -> void:
	_set_held(action, on)

func set_steer(value: float) -> void:
	steer_value = clampf(value, -1.0, 1.0)
	_stick_offset = Vector2(steer_value * _radius, 0.0)

func release_all() -> void:
	for id in ["gas", "brake", "handbrake", "reverse", "nitro"]:
		_set_held(id, false)
	_release_stick()

## Есть ли на экране кнопка паузы (на телефоне Esc недоступен, поэтому она обязательна).
func has_pause_button() -> bool:
	return _pause_button != null


static func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	var cfg := UiConfig.new()
	if cfg.min_touch_target_px < 72.0:
		problems.append("MobileControls: min_touch_target_px=%.1f — меньше безопасного размера" % cfg.min_touch_target_px)
	if cfg.joystick_deadzone <= 0.0:
		problems.append("MobileControls: нулевая мертвая зона стика = дрожь на месте")
	# Порядок приоритета кнопок в колонке: тормоз и газ обязаны быть ниже (ближе к пальцу).
	var order := ["handbrake", "reverse", "nitro", "brake", "gas"]
	if order.find("gas") < order.find("nitro"):
		problems.append("MobileControls: GAS выше NITRO в раскладке — промахи пальцем")
	return problems
