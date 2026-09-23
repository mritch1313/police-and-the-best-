class_name SettingsMenu
extends Control
## Меню настроек: единый экран и для главного меню, и для паузы в игре.
##
## Пишет ТОЛЬКО в Settings (единый источник настроек), а Settings уже растасовывает
## значения по SaveManager/PerformanceManager/camera_modulation(). Поэтому «сохранить
## настройки» = ничего не делать: они сохраняются в момент изменения (и это переживает
## смерть процесса на Android).
##
## Никаких `get_tree().paused = ...` отсюда: оверлей не владеет игрой.

signal closed

const ROW_H := 56.0

var panel: PanelContainer = null
var rows: Dictionary = {}
var _ui: UiConfig = null


func _ready() -> void:
	_ui = GameSetup.get_config("ui") as UiConfig
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	dim.gui_input.connect(_on_dim_input)
	panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = (_ui.panel_color if _ui != null else Color(0.06, 0.07, 0.09, 0.82))
	style.set_corner_radius_all(20)
	style.content_margin_left = 20.0
	style.content_margin_right = 20.0
	style.content_margin_top = 18.0
	style.content_margin_bottom = 18.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	_title(box)
	_slider_row(box, "Камера: дистанция", -4.0, 6.0, Settings.camera_distance_offset,
		func(v: float) -> void: Settings.set_camera_distance_offset(v))
	_slider_row(box, "Камера: высота", -2.0, 4.0, Settings.camera_height_offset,
		func(v: float) -> void: Settings.set_camera_height_offset(v))
	_slider_row(box, "Камера: чувствительность", 0.2, 3.0, Settings.camera_sensitivity,
		func(v: float) -> void: Settings.set_sensitivity(v))
	_slider_row(box, "Интерфейс: масштаб", 0.6, 1.6, Settings.ui_scale,
		func(v: float) -> void: Settings.set_ui_scale(v))
	_slider_row(box, "Полиция: интенсивность", 0.0, 2.0, Settings.police_intensity,
		func(v: float) -> void: Settings.set_police_intensity(v))
	_cycle_row(box, "Качество", ["АВТО (по device profile)", "НИЗКОЕ", "СРЕДНЕЕ", "ВЫСОКОЕ"],
		Settings.forced_tier + 1, func(i: int) -> void: Settings.set_tier(i - 1))
	_cycle_row(box, "Ориентация экрана", ["ГОРИЗОНТАЛЬНАЯ", "ВЕРТИКАЛЬНАЯ"],
		0 if Settings.is_landscape() else 1, func(i: int) -> void: Settings.set_orientation(i, true))
	_check_row(box, "Показывать FPS", Settings.show_fps, func(on: bool) -> void: Settings.set_show_fps(on))
	var close := _button("ЗАКРЫТЬ")
	close.custom_minimum_size = Vector2(0.0, 64.0 * _scale())
	close.pressed.connect(func() -> void:
		closed.emit()
		queue_free())
	box.add_child(close)
	_layout()
	resized.connect(_layout)
	Settings.settings_changed.connect(_refresh)
	_refresh()


func _scale() -> float:
	return clampf(Settings.ui_scale if Settings != null else 1.0, 0.6, 2.0)


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		closed.emit()
		queue_free()
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		closed.emit()
		queue_free()


func _layout() -> void:
	if panel == null:
		return
	var rect := get_rect()
	var width := minf(rect.size.x - 24.0, 520.0 * _scale())
	panel.size = Vector2(width, minf(rect.size.y - 40.0, 620.0 * _scale()))
	panel.position = Vector2((rect.size.x - panel.size.x) * 0.5, (rect.size.y - panel.size.y) * 0.5)
	panel.clip_contents = true


func _title(box: VBoxContainer) -> void:
	var label := Label.new()
	label.text = "НАСТРОЙКИ"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", int(26.0 * _scale()))
	label.add_theme_color_override("font_color", (_ui.text_color if _ui != null else Color.WHITE))
	box.add_child(label)


func _row(box: VBoxContainer, title_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0.0, ROW_H * _scale() * 0.8)
	var label := Label.new()
	label.text = title_text
	label.custom_minimum_size = Vector2(150.0 * _scale(), 0.0)
	label.add_theme_font_size_override("font_size", int(16.0 * _scale()))
	label.add_theme_color_override("font_color", (_ui.dim_text_color if _ui != null else Color(0.6, 0.6, 0.7)))
	row.add_child(label)
	box.add_child(row)
	return row


func _slider_row(box: VBoxContainer, title_text: String, lo: float, hi: float, value: float, setter: Callable) -> void:
	var row := _row(box, title_text)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = 0.01
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0.0, 44.0 * _scale())
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(54.0 * _scale(), 0.0)
	readout.add_theme_font_size_override("font_size", int(16.0 * _scale()))
	row.add_child(slider)
	row.add_child(readout)
	slider.value_changed.connect(func(v: float) -> void:
		setter.call(v)
		readout.text = "%.2f" % v)
	readout.text = "%.2f" % value
	rows[title_text] = {"slider": slider, "readout": readout}


func _cycle_row(box: VBoxContainer, title_text: String, options: Array, current: int, setter: Callable) -> void:
	var row := _row(box, title_text)
	var button := _button(String(options[clampi(current, 0, options.size() - 1)]))
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0.0, 52.0 * _scale())
	row.add_child(button)
	var state := {"index": clampi(current, 0, options.size() - 1), "options": options}
	button.pressed.connect(func() -> void:
		var next := (int(state["index"]) + 1) % state["options"].size()
		state["index"] = next
		button.text = String(state["options"][next])
		setter.call(next))
	rows[title_text] = {"button": button, "options": options, "index": current}


func _check_row(box: VBoxContainer, title_text: String, value: bool, setter: Callable) -> void:
	var row := _row(box, title_text)
	var check := CheckBox.new()
	check.button_pressed = value
	check.custom_minimum_size = Vector2(0.0, 48.0 * _scale())
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.toggled.connect(func(on: bool) -> void: setter.call(on))
	row.add_child(check)
	rows[title_text] = {"check": check}


func _button(text_value: String) -> Button:
	var button := Button.new()
	button.text = text_value
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", int(19.0 * _scale()))
	return button


func _refresh() -> void:
	if not rows.has("Качество"):
		return
	var tier_data: Dictionary = rows["Качество"]
	var index := clampi(Settings.forced_tier + 1, 0, (tier_data["options"] as Array).size() - 1)
	tier_data["index"] = index
	if tier_data.has("button"):
		(tier_data["button"] as Button).text = String(tier_data["options"][index])


func state() -> Dictionary:
	return {
		"tier": Settings.forced_tier,
		"auto_quality": Settings.auto_quality,
		"camera_distance": Settings.camera_distance_offset,
		"camera_height": Settings.camera_height_offset,
		"sensitivity": Settings.camera_sensitivity,
		"ui_scale": Settings.ui_scale,
		"police_intensity": Settings.police_intensity,
		"show_fps": Settings.show_fps,
		"orientation": Settings.orientation,
	}
