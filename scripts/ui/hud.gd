extends CanvasLayer
class_name GameHUD
## The driving interface.
##
## It is deliberately minimal, because the screen of a 720x1612 phone is small and the player
## has to see the road: a speedometer and a gear in the top left, the nitro bar top right, the
## heat level under it, a compact minimap in the top right corner under the nitro bar, the
## arrest warning in the middle, and the pause button in the top left corner of the safe area.
## Everything else (the pedals and the stick) belongs to `MobileControls`.
##
## The HUD never reads the input devices directly: it observes the player car and the game
## state, so it works identically in a real run and in the headless smoke test.

const SPEED_UNIT_KMH := "км/ч"

var player: CarBody = null
var police_manager: PoliceManager = null
var chase_manager: ChaseManager = null
var world_streamer: WorldStreamer = null
var performance: Node = null

var show_debug: bool = false
var show_minimap: bool = true

var _speed_label: Label = null
var _gear_label: Label = null
var _unit_label: Label = null
var _nitro_bar: ProgressBar = null
var _nitro_label: Label = null
var _heat_label: Label = null
var _rush_label: Label = null
var _arrest_panel: Panel = null
var _arrest_bar: ProgressBar = null
var _message_label: Label = null
var _debug_label: Label = null
var _minimap: TextureRect = null
var _minimap_dot: ColorRect = null
var _pause_button: Button = null
var _root: Control = null
var _message_timer: float = 0.0


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.name = "HUDRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build()
	resized.connect(_relayout)
	_relayout()


func _panel(colour: Color, radius: int = 14) -> Panel:
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = colour
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _label(text: String, font_size: int, colour: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _build() -> void:
	# Speed block (top left, inside the safe area of a notchless phone).
	var speed_panel := _panel(Color(0.05, 0.06, 0.09, 0.55))
	speed_panel.name = "SpeedPanel"
	_root.add_child(speed_panel)
	var speed_box := VBoxContainer.new()
	speed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speed_panel.add_child(speed_box)
	_speed_label = _label("0", 54)
	speed_box.add_child(_speed_label)
	_unit_label = _label(SPEED_UNIT_KMH, 20, Color(0.75, 0.8, 0.86))
	speed_box.add_child(_unit_label)
	_gear_label = _label("1", 26, Color(0.95, 0.85, 0.4))
	speed_box.add_child(_gear_label)

	# Nitro (top right).
	var nitro_panel := _panel(Color(0.05, 0.06, 0.09, 0.55))
	nitro_panel.name = "NitroPanel"
	_root.add_child(nitro_panel)
	var nitro_box := VBoxContainer.new()
	nitro_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nitro_panel.add_child(nitro_box)
	_nitro_label = _label("NITRO", 22, Color(0.55, 0.8, 1.0))
	nitro_box.add_child(_nitro_label)
	_nitro_bar = ProgressBar.new()
	_nitro_bar.min_value = 0.0
	_nitro_bar.max_value = 1.0
	_nitro_bar.value = 1.0
	_nitro_bar.show_percentage = false
	_nitro_bar.custom_minimum_size = Vector2(180, 18)
	nitro_box.add_child(_nitro_bar)
	_heat_label = _label("РОЗЫСК: 0", 20, Color(0.95, 0.6, 0.5))
	nitro_box.add_child(_heat_label)

	# Minimap (right, under the nitro bar).
	_minimap = TextureRect.new()
	_minimap.name = "Minimap"
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_minimap.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var map_texture := load("res://assets/ui/map_test_district_small.png") as Texture2D
	if map_texture != null:
		_minimap.texture = map_texture
	_root.add_child(_minimap)
	_minimap_dot = ColorRect.new()
	_minimap_dot.name = "MinimapDot"
	_minimap_dot.color = Color(1.0, 0.25, 0.15)
	_minimap_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_minimap_dot)

	# Pause button.
	_pause_button = Button.new()
	_pause_button.name = "PauseButton"
	_pause_button.text = "II"
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.add_theme_font_size_override("font_size", 30)
	_pause_button.pressed.connect(_on_pause_pressed)
	_root.add_child(_pause_button)

	# Arrest warning (centre).
	_arrest_panel = _panel(Color(0.5, 0.06, 0.06, 0.72), 18)
	_arrest_panel.name = "ArrestPanel"
	_arrest_panel.visible = false
	_root.add_child(_arrest_panel)
	var arrest_box := VBoxContainer.new()
	arrest_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrest_panel.add_child(arrest_box)
	var arrest_title := _label("ВАС БЛОКИРУЮТ!", 30, Color(1.0, 0.9, 0.85))
	arrest_box.add_child(arrest_title)
	_arrest_bar = ProgressBar.new()
	_arrest_bar.min_value = 0.0
	_arrest_bar.max_value = 1.0
	_arrest_bar.show_percentage = false
	_arrest_bar.custom_minimum_size = Vector2(300, 20)
	arrest_box.add_child(_arrest_bar)

	# Flashing messages ("ПОГОНЯ!", "ВЫ ОТОРВАЛИСЬ").
	_message_label = _label("", 44, Color(1.0, 0.85, 0.3))
	_message_label.name = "MessageLabel"
	_message_label.visible = false
	_root.add_child(_message_label)

	# Debug overlay (chunk budget, fps, police). Enabled with the "show fps" setting.
	_debug_label = _label("", 18, Color(0.7, 1.0, 0.75))
	_debug_label.name = "DebugLabel"
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_debug_label.visible = SettingsManager.show_fps
	_root.add_child(_debug_label)
	show_debug = SettingsManager.show_fps


func _relayout() -> void:
	var size := _root.size
	var margin := 18.0
	# Speed panel.
	var speed_panel := _root.get_node_or_null("SpeedPanel") as Panel
	if speed_panel != null:
		speed_panel.size = Vector2(190, 168)
		speed_panel.position = Vector2(margin + 74, margin + 66)
	var nitro_panel := _root.get_node_or_null("NitroPanel") as Panel
	if nitro_panel != null:
		nitro_panel.size = Vector2(210, 132)
		nitro_panel.position = Vector2(size.x - nitro_panel.size.x - margin, margin + 66)
	if _minimap != null:
		var minimap_size := minf(size.x * 0.34, 190.0)
		_minimap.size = Vector2(minimap_size, minimap_size)
		_minimap.position = Vector2(size.x - minimap_size - margin, margin + 208.0)
		show_minimap = true
	if _minimap_dot != null:
		_minimap_dot.size = Vector2(10, 10)
	if _pause_button != null:
		_pause_button.size = Vector2(62, 62)
		_pause_button.position = Vector2(margin, margin)
	if _arrest_panel != null:
		_arrest_panel.size = Vector2(340, 110)
		_arrest_panel.position = Vector2((size.x - _arrest_panel.size.x) * 0.5, size.y * 0.32)
	if _message_label != null:
		_message_label.size = Vector2(size.x - 40.0, 70)
		_message_label.position = Vector2(20, size.y * 0.2)
	if _debug_label != null:
		_debug_label.size = Vector2(size.x * 0.7, 220)
		_debug_label.position = Vector2(margin, size.y - 240.0)


func _process(delta: float) -> void:
	if _message_timer > 0.0:
		_message_timer -= delta
		if _message_timer <= 0.0 and _message_label != null:
			_message_label.visible = false
	_update_speed()
	_update_nitro()
	_update_heat()
	_update_minimap()
	_update_debug()


func _update_speed() -> void:
	if player == null or _speed_label == null:
		return
	var kmh := player.speed_kmh()
	_speed_label.text = "%d" % int(round(kmh))
	var ratio := kmh / maxf(player.max_speed_kmh(), 1.0)
	_speed_label.add_theme_color_override(
		"font_color", Color(1.0, 0.55 + 0.4 * (1.0 - ratio), 0.35 + 0.4 * (1.0 - ratio))
	)
	if _gear_label != null:
		var gear := player.gear()
		_gear_label.text = "R" if gear == 0 else "%d" % gear
	if _unit_label != null:
		_unit_label.text = "%s  макс %d" % [SPEED_UNIT_KMH, int(round(player.max_speed_kmh()))]


func _update_nitro() -> void:
	if player == null or _nitro_bar == null:
		return
	_nitro_bar.value = player.nitro_ratio()
	var boosting := player.is_boosting()
	if _nitro_label != null:
		_nitro_label.text = "NITRO  ЗАДЕЙСТВОВАН" if boosting else "NITRO  %d%%" % int(round(player.nitro_ratio() * 100.0))
		_nitro_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5) if boosting else Color(0.55, 0.8, 1.0))


func _update_heat() -> void:
	if _heat_label == null:
		return
	var state := get_node_or_null("/root/GameState")
	var level := state.heat_level if state != null else 0
	var max_level := 5
	if _heat_label != null:
		_heat_label.text = "РОЗЫСК: %d/%d" % [level, max_level]
	if _rush_label == null and police_manager != null:
		pass


func _update_minimap() -> void:
	if _minimap == null or _minimap_dot == null or player == null:
		return
	var world_config: WorldConfig = null
	if world_streamer != null:
		world_config = world_streamer.world_config
	var extent := 500.0
	if world_config != null:
		extent = world_config.world_size * 0.5
	var normalized := Vector2(
		clampf(player.global_position.x / extent, -1.0, 1.0),
		clampf(player.global_position.z / extent, -1.0, 1.0)
	)
	var centre := _minimap.position + _minimap.size * 0.5
	var radius := _minimap.size.x * 0.5
	_minimap_dot.position = centre + normalized * radius * 0.94 - _minimap_dot.size * 0.5


## The debug line is the same information the CI smoke test prints, so a bug report from a
## phone contains everything needed to reproduce it.
func _update_debug() -> void:
	if _debug_label == null or not show_debug:
		return
	var lines := PackedStringArray()
	if performance != null:
		lines.append(String(performance.call("debug_string")))
	if world_streamer != null:
		lines.append(world_streamer.debug_string())
	if police_manager != null:
		lines.append(police_manager.debug_string())
	if chase_manager != null:
		lines.append(chase_manager.status())
	if player != null:
		lines.append(player.describe())
	_debug_label.text = "\n".join(lines)


func show_message(text: String, seconds: float = 2.6, colour: Color = Color(1.0, 0.85, 0.3)) -> void:
	if _message_label == null:
		return
	_message_label.text = text
	_message_label.add_theme_color_override("font_color", colour)
	_message_label.visible = true
	_message_timer = seconds


func set_arrest_progress(ratio: float) -> void:
	if _arrest_panel == null or _arrest_bar == null:
		return
	_arrest_panel.visible = ratio > 0.01
	_arrest_bar.value = ratio


func toggle_debug() -> void:
	show_debug = not show_debug
	SettingsManager.show_fps = show_debug
	SettingsManager.save_settings()
	if _debug_label != null:
		_debug_label.visible = show_debug


func _on_pause_pressed() -> void:
	var parent := get_parent()
	if parent != null and parent.has_method("toggle_pause"):
		parent.call("toggle_pause")
