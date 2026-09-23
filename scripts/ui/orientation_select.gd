extends CanvasLayer
class_name OrientationSelect
## The first-launch screen: the player picks the orientation once, and the game remembers it.
##
## The choice is permanent in the sense that it is written to the save file and applied on
## every following launch without asking again (the player can still change it later from the
## pause menu, which is what the note on this screen says). Godot applies the orientation to
## the window and the Android activity, so the choice is visible immediately: the preview
## rectangle and the two buttons re-lay out while the device rotates.

signal chosen(portrait: bool)

var _root: Control = null
var _preview: Panel = null
var _portrait_button: Button = null
var _landscape_button: Button = null
var _note: Label = null
var _title: Label = null


func _ready() -> void:
	layer = 8
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "OrientationRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.06, 0.07, 0.1)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(background)
	add_child(_root)

	_title = Label.new()
	_title.text = "ВЫБЕРИТЕ ОРИЕНТАЦИЮ"
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)

	_preview = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.15, 0.2, 0.9)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.border_width_left = 3
	style.border_width_top = 3
	style.border_width_right = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.9, 0.8, 0.5, 0.8)
	_preview.add_theme_stylebox_override("panel", style)
	_root.add_child(_preview)

	var preview_label := Label.new()
	preview_label.name = "PreviewLabel"
	preview_label.text = "ЭКРАН"
	preview_label.add_theme_font_size_override("font_size", 24)
	preview_label.add_theme_color_override("font_color", Color(0.7, 0.78, 0.9))
	preview_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview.add_child(preview_label)

	_portrait_button = _make_button("ВЕРТИКАЛЬНО (портрет)", _on_portrait)
	_root.add_child(_portrait_button)
	_landscape_button = _make_button("ГОРИЗОНТАЛЬНО (ландшафт)", _on_landscape)
	_root.add_child(_landscape_button)

	_note = Label.new()
	_note.text = "Основной режим игры - вертикальный.\nВыбор сохранится и будет применяться всегда;\nизменить его можно позже в меню паузы."
	_note.add_theme_font_size_override("font_size", 24)
	_note.add_theme_color_override("font_color", Color(0.72, 0.78, 0.88))
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(_note)

	_root.resized.connect(_relayout)
	_relayout()


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 32)
	button.pressed.connect(callback)
	return button


func _relayout() -> void:
	var size := _root.size
	if size.x <= 0.0:
		size = get_viewport().get_visible_rect().size
	var margin := 24.0
	var portrait := size.y >= size.x
	_title.size = Vector2(size.x - margin * 2.0, 60)
	_title.position = Vector2(margin, margin + 20.0)
	# The preview shows the shape of the chosen screen: a tall rectangle or a wide one.
	var preview_height := minf(size.y * 0.34, 420.0)
	var preview_width := preview_height * 0.5 if portrait else preview_height * 1.9
	_preview.size = Vector2(preview_width, preview_height)
	_preview.position = Vector2((size.x - preview_width) * 0.5, _title.position.y + 80.0)
	var button_width := minf(size.x - margin * 4.0, 470.0)
	var button_height := 96.0
	var y := _preview.position.y + preview_height + 36.0
	_portrait_button.size = Vector2(button_width, button_height)
	_portrait_button.position = Vector2((size.x - button_width) * 0.5, y)
	_landscape_button.size = Vector2(button_width, button_height)
	_landscape_button.position = Vector2((size.x - button_width) * 0.5, y + button_height + 20.0)
	_note.size = Vector2(size.x - margin * 2.0, 120)
	_note.position = Vector2(margin, y + (button_height + 20.0) * 2.0 + 20.0)


func _on_portrait() -> void:
	_apply(true)


func _on_landscape() -> void:
	_apply(false)


func _apply(portrait: bool) -> void:
	# `set_orientation` also clears the first-launch flag and writes the save file, so the
	# question is never asked again on this device.
	SettingsManager.set_orientation(portrait)
	SettingsManager.complete_first_launch()
	chosen.emit(portrait)
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow != null and screen_flow.has_method("goto_menu"):
		screen_flow.call("goto_menu")
	else:
		get_tree().change_scene_to_file("res://scenes/main/MainMenu.tscn")
