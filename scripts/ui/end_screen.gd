extends CanvasLayer
class_name EndScreen
## The end-of-run screen: why the run ended and what the player did.
##
## Statistics are shown from `GameState.summary()`, which is also what the automated tests
## inspect, so the numbers on this screen are the same numbers the tests assert on.

var summary: Dictionary = {}
var game_world: Node = null

var _panel: Panel = null
var _body: Label = null


func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	_panel = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, 0.97)
	style.corner_radius_top_left = 22
	style.corner_radius_top_right = 22
	style.corner_radius_bottom_left = 22
	style.corner_radius_bottom_right = 22
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	style.content_margin_top = 22.0
	style.content_margin_bottom = 22.0
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "ВАС ЗАДЕРЖАЛИ" if _reason() == "arrested" else "ЗАЕЗД ОКОНЧЕН"
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.45))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 26)
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_body)

	box.add_child(_make_button("ЕЩЁ ЗАЕЗД", _on_restart))
	box.add_child(_make_button("В ГЛАВНОЕ МЕНЮ", _on_menu))

	root.resized.connect(_relayout)
	_relayout()
	_fill()


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 30)
	button.custom_minimum_size = Vector2(0, 66)
	button.pressed.connect(callback)
	return button


func _reason() -> String:
	return String(summary.get("reason", "quit"))


func _relayout() -> void:
	var size := get_viewport().get_visible_rect().size
	_panel.size = Vector2(minf(size.x - 40.0, 560.0), minf(size.y - 80.0, 720.0))
	_panel.position = (size - _panel.size) * 0.5


func _fill() -> void:
	if _body == null:
		return
	var distance_km := float(summary.get("distance_m", 0.0)) / 1000.0
	var top_speed := float(summary.get("top_speed_kmh", 0.0))
	var time := float(summary.get("time", 0.0))
	var heat := int(summary.get("heat", 0))
	var nitro_time := float(summary.get("nitro_seconds", 0.0))
	var contacts := int(summary.get("police_contact", 0))
	var air_time := float(summary.get("air_time", 0.0))
	var money := int(summary.get("money", 0))
	_body.text = (
		"ДИСТАНЦИЯ: %.2f км\n"
		+ "МАКС. СКОРОСТЬ: %d км/ч\n"
		+ "ВРЕМЯ: %02d:%02d\n"
		+ "УРОВЕНЬ РОЗЫСКА: %d\n"
		+ "NITRO ИСПОЛЬЗОВАНО: %.1f с\n"
		+ "КОНТАКТОВ С ПОЛИЦИЕЙ: %d\n"
		+ "ВРЕМЯ В ВОЗДУХЕ: %.1f с\n"
		+ "ДЕНЬГИ: %d"
	) % [
		distance_km,
		int(round(top_speed)),
		int(time) / 60,
		int(time) % 60,
		heat,
		nitro_time,
		contacts,
		air_time,
		money,
	]


func _on_restart() -> void:
	var state := get_node_or_null("/root/GameState")
	if state != null:
		state.set_paused(false)
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow != null:
		screen_flow.call("goto_world")


func _on_menu() -> void:
	var state := get_node_or_null("/root/GameState")
	if state != null:
		state.set_paused(false)
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow != null:
		screen_flow.call("goto_menu")
