extends CanvasLayer
class_name PauseMenu
## The pause screen: resume, graphics preset, orientation, controls hint, back to the menu.
##
## It is created by `GameWorld` when the player taps the pause button and it is the only place
## where a running game can be re-configured (graphics preset and orientation take effect
## immediately, without restarting the run).

var game_world: Node = null

var _panel: Panel = null
var _preset_label: Label = null
var _orientation_label: Label = null
var _sensitivity_label: Label = null


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	_panel = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 0.95)
	style.corner_radius_top_left = 20
	style.corner_radius_top_right = 20
	style.corner_radius_bottom_left = 20
	style.corner_radius_bottom_right = 20
	style.content_margin_left = 24.0
	style.content_margin_right = 24.0
	style.content_margin_top = 20.0
	style.content_margin_bottom = 20.0
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "ПАУЗА"
	title.add_theme_font_size_override("font_size", 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	box.add_child(_make_button("ПРОДОЛЖИТЬ", _on_resume))

	_preset_label = Label.new()
	_preset_label.add_theme_font_size_override("font_size", 24)
	_preset_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_preset_label)

	var preset_row := HBoxContainer.new()
	preset_row.alignment = BoxContainer.ALIGNMENT_CENTER
	preset_row.add_theme_constant_override("separation", 10)
	preset_row.add_child(_make_button("НИЗКОЕ", _on_preset.bind(0)))
	preset_row.add_child(_make_button("СРЕДНЕЕ", _on_preset.bind(1)))
	preset_row.add_child(_make_button("ВЫСОКОЕ", _on_preset.bind(2)))
	box.add_child(preset_row)

	_orientation_label = Label.new()
	_orientation_label.add_theme_font_size_override("font_size", 24)
	_orientation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_orientation_label)

	var orientation_row := HBoxContainer.new()
	orientation_row.alignment = BoxContainer.ALIGNMENT_CENTER
	orientation_row.add_theme_constant_override("separation", 10)
	orientation_row.add_child(_make_button("ПОРТРЕТ", _on_orientation.bind(true)))
	orientation_row.add_child(_make_button("ЛАНДШАФТ", _on_orientation.bind(false)))
	box.add_child(orientation_row)

	_sensitivity_label = Label.new()
	_sensitivity_label.add_theme_font_size_override("font_size", 24)
	_sensitivity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_sensitivity_label)
	var sensitivity_row := HBoxContainer.new()
	sensitivity_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sensitivity_row.add_theme_constant_override("separation", 10)
	sensitivity_row.add_child(_make_button("РУЛЬ -", _on_sensitivity.bind(-0.1)))
	sensitivity_row.add_child(_make_button("РУЛЬ +", _on_sensitivity.bind(0.1)))
	sensitivity_row.add_child(_make_button("КАМЕРА -", _on_camera_sensitivity.bind(-0.1)))
	sensitivity_row.add_child(_make_button("КАМЕРА +", _on_camera_sensitivity.bind(0.1)))
	box.add_child(sensitivity_row)

	box.add_child(_make_button("СБРОСИТЬ МАШИНУ", _on_reset_car))
	box.add_child(_make_button("В ГЛАВНОЕ МЕНЮ", _on_menu))

	root.resized.connect(_relayout)
	_relayout()
	# The menu keeps working while the tree is paused, and the game is paused while it is up.
	_refresh_labels()


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 28)
	button.custom_minimum_size = Vector2(0, 62)
	button.pressed.connect(callback)
	return button


func _relayout() -> void:
	var size := get_viewport().get_visible_rect().size
	_panel.size = Vector2(minf(size.x - 40.0, 560.0), minf(size.y - 80.0, 900.0))
	_panel.position = (size - _panel.size) * 0.5


func _refresh_labels() -> void:
	if _preset_label != null:
		_preset_label.text = "ГРАФИКА: %s%s" % [
			SettingsManager.graphics.preset_name(),
			" (авто)" if not get_node("/root/PerformanceManager").auto_quality else "",
		]
	if _orientation_label != null:
		_orientation_label.text = "ОРИЕНТАЦИЯ: %s" % SettingsManager.orientation_name()
	if _sensitivity_label != null:
		_sensitivity_label.text = "ЧУВСТВИТЕЛЬНОСТЬ: %.1f / %.1f" % [
			SettingsManager.touch_steering_sensitivity,
			SettingsManager.camera_sensitivity,
		]


func _on_resume() -> void:
	if game_world != null and game_world.has_method("resume"):
		game_world.call("resume")
	queue_free()


func _on_preset(preset: int) -> void:
	SettingsManager.set_graphics_preset(preset)
	var world := _world_generator()
	if world != null and world.has_method("apply_graphics"):
		world.call("apply_graphics", SettingsManager.graphics)
	var performance := get_node_or_null("/root/PerformanceManager")
	if performance != null:
		performance.call("applied_preset_override", preset)
	_refresh_labels()


func _on_orientation(portrait: bool) -> void:
	SettingsManager.set_orientation(portrait)
	_refresh_labels()


func _on_sensitivity(delta: float) -> void:
	SettingsManager.touch_steering_sensitivity = clampf(SettingsManager.touch_steering_sensitivity + delta, 0.4, 2.0)
	SettingsManager.save_settings()
	_refresh_labels()


func _on_camera_sensitivity(delta: float) -> void:
	SettingsManager.camera_sensitivity = clampf(SettingsManager.camera_sensitivity + delta, 0.2, 3.0)
	SettingsManager.save_settings()
	_refresh_labels()


func _on_reset_car() -> void:
	var world := _world_generator()
	if world == null or game_world == null:
		return
	var player: Node = game_world.get("player")
	if player != null and player.has_method("reset_to"):
		var graph = world.get("road_graph")
		var target_position: Vector3 = player.global_position
		if graph != null and graph.has_method("nearest_node_position"):
			target_position = graph.call("nearest_node_position", player.global_position)
		player.call("reset_to", Transform3D(Basis(), target_position + Vector3.UP * 0.6))
	_refresh_labels()


func _on_menu() -> void:
	var state := get_node_or_null("/root/GameState")
	if state != null:
		state.set_paused(false)
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow != null:
		screen_flow.call("goto_menu")


func _world_generator() -> Node:
	if game_world == null:
		return null
	return game_world.get("world")
