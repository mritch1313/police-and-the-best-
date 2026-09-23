class_name MainMenu
extends Control
## Главное меню. Состав и тексты — из res://autoloads/ui.cfg (UiConfig), не из кода.
##
## ТРЕБОВАНИЯ, КОТОРЫЕ ЗДЕСЬ ЗАФИКСИНЫ БУКВАЛЬНО:
##  1. фон = `фон.jpg` (MainMenuBackground);
##  2. в левом верхнем углу: «ВЕРСИЯ: 4.0.9 TEXT», под ним «СИМУЛЯТОР УГОНА ОТ МУСОРОВ»;
##  3. две кнопки ПО ЦЕНТРУ ЛЕВОЙ ПОЛОВИНЫ экрана по вертикали: «1 Играть», «2 Разработчики»;
##  4. «2 Разработчики» -> попап с тг-ботом и «МАТАДОРА...»; тап по попапу его закрывает;
##  5. «1 Играть» -> скрыть кнопки/тексты и показать ОДНУ карточку карты: квадрат со
##     скриншотом карты + подпись «TEST» ПОД квадратом; тап по карточке -> игровая сцена.
##
## КАРТА: картинка = assets/ui/map_card.png, которую генерирует CI (`--capture-map`), т.е.
## это реальный скриншот собранного мира, а не нарисованная заглушка (см. docs/WORLD.md).
## Если файла ещё нет — рисуется схема мира из WorldConfig (тот же код, что и мини-карта HUD).

const GAME_FALLBACK_SCENE := "res://scenes/game/Game.tscn"
const MAP_IMAGE := "res://assets/ui/map_card.png"

var ui: UiConfig = null
var background: MainMenuBackground = null
var header_box: VBoxContainer = null
var buttons_box: VBoxContainer = null
var map_box: Control = null
var popup: Control = null
var map_buttons: Array = []
var orientation_button: Button = null
var settings_button: Button = null
var settings: SettingsMenu = null
var _flow_busy: bool = false


func _ready() -> void:
	ui = GameSetup.get_config("ui") as UiConfig
	AppState.set_phase(AppState.Phase.MENU)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	background = MainMenuBackground.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	_build_header()
	_build_buttons()
	_build_corner_buttons()
	_build_map_view()
	resized.connect(_relayout)
	_relayout()
	DebugConsole.log_line("menu", "главное меню собрано; %s" % background.status_text())


func _text(key: String, fallback: String) -> String:
	if ui == null:
		return fallback
	var value: Variant = ui.get(key)
	return String(value) if value != null and String(value) != "" else fallback


func _label(text_value: String, px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", px)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.75))
	return label


func _build_header() -> void:
	header_box = VBoxContainer.new()
	header_box.name = "Header"
	header_box.add_theme_constant_override("separation", 2)
	add_child(header_box)
	var scale := _scale()
	var version := _text("version_line", "ВЕРСИЯ: %s") % _text("project_version", "4.0.9 TEXT")
	header_box.add_child(_label(version, int(20.0 * scale), Color(0.10, 0.11, 0.14)))
	var subtitle := _text("subtitle", "СИМУЛЯТОР УГОНА ОТ МУСОРОВ")
	header_box.add_child(_label(subtitle, int(17.0 * scale), Color(0.30, 0.32, 0.36)))


func _build_buttons() -> void:
	buttons_box = VBoxContainer.new()
	buttons_box.name = "Buttons"
	buttons_box.add_theme_constant_override("separation", int(18.0 * _scale()))
	add_child(buttons_box)
	var play := _menu_button(_text("play_label", "1 Играть"))
	play.pressed.connect(show_maps)
	buttons_box.add_child(play)
	var developers := _menu_button(_text("developers_label", "2 Разработчики"))
	developers.pressed.connect(show_developers)
	buttons_box.add_child(developers)


func _menu_button(text_value: String) -> Button:
	var scale := _scale()
	var button := Button.new()
	button.text = text_value
	var min_target := maxf(96.0 * scale, (ui.min_touch_target_px if ui != null else 96.0) * scale)
	button.custom_minimum_size = Vector2(minf(size.x * 0.42, 300.0 * scale), min_target)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", int(24.0 * scale))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.98, 0.42, 0.16, 0.96)
	style.set_corner_radius_all(int(18.0 * scale))
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1.0, 0.55, 0.25)
	var panel := (ui.panel_color if ui != null else Color(0.06, 0.07, 0.09, 0.82))
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", Color(0.05, 0.05, 0.06))
	button.add_theme_color_override("font_hover_color", Color(0.05, 0.05, 0.06))
	button.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	return button


func _corner_buttons_box() -> VBoxContainer:
	var box := get_node_or_null("Corner") as VBoxContainer
	if box != null:
		return box
	box = VBoxContainer.new()
	box.name = "Corner"
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	return box


func _build_corner_buttons() -> void:
	var box := _corner_buttons_box()
	orientation_button = Button.new()
	orientation_button.text = "ОРИЕНТАЦИЯ: " + AppState.orientation_name()
	orientation_button.focus_mode = Control.FOCUS_NONE
	orientation_button.add_theme_font_size_override("font_size", 14)
	orientation_button.pressed.connect(_toggle_orientation)
	box.add_child(orientation_button)
	settings_button = Button.new()
	settings_button.text = _text("settings_label", "Настройки")
	settings_button.focus_mode = Control.FOCUS_NONE
	settings_button.add_theme_font_size_override("font_size", 14)
	settings_button.pressed.connect(_open_settings)
	box.add_child(settings_button)


func _toggle_orientation() -> void:
	Settings.set_orientation(0 if Settings.is_landscape() else 1, true)
	if orientation_button != null:
		orientation_button.text = "ОРИЕНТАЦИЯ: " + AppState.orientation_name()
	_relayout()


func _open_settings() -> void:
	if settings != null and is_instance_valid(settings):
		return
	settings = SettingsMenu.new()
	add_child(settings)
	settings.closed.connect(func() -> void: settings = null)


func _build_map_view() -> void:
	map_box = Control.new()
	map_box.name = "Maps"
	map_box.visible = false
	map_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(map_box)
	map_buttons.clear()
	var entries: Array = (ui.maps as Array) if ui != null else []
	if entries.is_empty():
		entries = [{"title": "TEST", "scene": GAME_FALLBACK_SCENE, "thumbnail": MAP_IMAGE, "enabled": true}]
	for entry in entries:
		var card := _map_card(entry as Dictionary)
		map_box.add_child(card)
		map_buttons.append(card)
	var back := Button.new()
	back.name = "Back"
	back.text = _text("back_label", "Назад")
	back.custom_minimum_size = Vector2(160.0 * _scale(), 64.0 * _scale())
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(hide_maps)
	map_box.add_child(back)


func _map_card(entry: Dictionary) -> Control:
	var scale := _scale()
	var side := maxf((ui.map_card_size_px if ui != null else 232.0) * scale, 140.0 * scale)
	var card := Button.new()
	card.name = "Map_%s" % String(entry.get("title", "TEST"))
	card.custom_minimum_size = Vector2(side, side)
	card.focus_mode = Control.FOCUS_NONE
	card.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.12, 1.0)
	style.border_color = Color(0.98, 0.42, 0.16, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(int(14.0 * scale))
	card.add_theme_stylebox_override("normal", style)
	card.add_theme_stylebox_override("hover", style)
	card.add_theme_stylebox_override("pressed", style)
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var image_path := String(entry.get("thumbnail", MAP_IMAGE))
	var preview := MapPreview.new()
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	preview.image_path = image_path if not image_path.is_empty() else MAP_IMAGE
	preview.fallback_path = String(entry.get("fallback", ui.map_card_fallback if ui != null else MAP_IMAGE))
	card.add_child(preview)
	var title_px := int((ui.map_card_label_size if ui != null else 22) * scale)
	var title := _label(String(entry.get("title", "TEST")), title_px, Color(0.08, 0.09, 0.11))
	title.set_anchors_preset(Control.PRESET_TOP_LEFT)
	title.position = Vector2(0.0, side + 6.0 * scale)
	var wrapper := Control.new()
	wrapper.name = "Card_%s" % String(entry.get("title", "TEST"))
	wrapper.custom_minimum_size = Vector2(side, side + 34.0 * scale)
	wrapper.add_child(card)
	card.position = Vector2.ZERO
	card.custom_minimum_size = Vector2(side, side)
	wrapper.add_child(title)
	title.position = Vector2(0.0, side + 4.0 * scale)
	var scene_path := String(entry.get("scene", GAME_FALLBACK_SCENE))
	var enabled := bool(entry.get("enabled", true))
	card.disabled = not enabled
	card.pressed.connect(func() -> void: _play_scene(scene_path))
	return wrapper


func _play_scene(path: String) -> void:
	if _flow_busy:
		return
	_flow_busy = true
	AppState.begin_session(_title_of(path))
	ScreenFlow.change_scene(path if ResourceLoader.exists(path) else GAME_FALLBACK_SCENE, true)


func _title_of(_path: String) -> String:
	var entries: Array = (ui.maps as Array) if ui != null else []
	for entry in entries:
		if String((entry as Dictionary).get("scene", "")) == _path:
			return String((entry as Dictionary).get("title", "TEST"))
	return "TEST"


func show_maps() -> void:
	if buttons_box != null:
		buttons_box.visible = false
	if header_box != null:
		header_box.visible = false
	if map_box != null:
		map_box.visible = true
	_relayout()


func hide_maps() -> void:
	if map_box != null:
		map_box.visible = false
	if buttons_box != null:
		buttons_box.visible = true
	if header_box != null:
		header_box.visible = true
	_relayout()


## Попап «Разработчики»: тап ЛЮБОГО места по окну его закрывает (по требованию).
func show_developers() -> void:
	if popup != null and is_instance_valid(popup):
		popup.modulate.a = 1.0
		return
	var scale := _scale()
	popup = Control.new()
	popup.name = "DevelopersPopup"
	popup.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(popup)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(dim)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = (ui.panel_color if ui != null else Color(0.06, 0.07, 0.09, 0.82))
	style.border_color = _accent()
	style.set_border_width_all(3)
	style.set_corner_radius_all(int(22.0 * scale))
	style.content_margin_left = 22.0
	style.content_margin_right = 22.0
	style.content_margin_top = 22.0
	style.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(minf(size.x * 0.82, 420.0 * scale), 0.0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	for line in _dev_lines():
		var label := _label(line, int(20.0 * scale), Color(0.94, 0.95, 0.98))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(label)
	var hint := _label(_text("dev_hint", "нажми на окно, чтобы закрыть"), int(14.0 * scale), Color(0.62, 0.66, 0.72))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	var closer := func() -> void: close_developers()
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if _is_press(event):
			closer.call())
	dim.gui_input.connect(func(event: InputEvent) -> void:
		if _is_press(event):
			closer.call())
	_center_popup()


func _is_press(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	return false


func _dev_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var configured: Array = (ui.dev_lines as Array) if ui != null else []
	if configured.is_empty():
		out.append("тг бот для связи @connection9191_bot")
		out.append("МАТАДОРА МАТАДОРА МАТАДАОРА")
		return out
	for line in configured:
		out.append(String(line))
	return out


func close_developers() -> void:
	if popup != null and is_instance_valid(popup):
		popup.queue_free()
	popup = null


func _accent() -> Color:
	return (ui.accent if ui != null else Color(0.98, 0.42, 0.16))


func _scale() -> float:
	return clampf(Settings.ui_scale if Settings != null else 1.0, 0.6, 2.0)


func _relayout() -> void:
	var rect := get_rect()
	var scale := _scale()
	if header_box != null:
		header_box.position = Vector2(16.0 * scale, 14.0 * scale)
	if buttons_box != null:
		# «по центру левой половины экрана»: X = четверть ширины, Y = половина высоты.
		buttons_box.reset_size()
		var width := minf(rect.size.x * 0.42, 300.0 * scale)
		var height := buttons_box.get_combined_minimum_size().y
		buttons_box.position = Vector2(rect.size.x * 0.25 - width * 0.5, rect.size.y * 0.5 - height * 0.5)
	if corner_box_present():
		var box := get_node_or_null("Corner") as VBoxContainer
		if box != null:
			box.position = Vector2(rect.size.x - 190.0 * scale, rect.size.y - 92.0 * scale)
	if map_box != null and map_box.visible:
		var column := map_box.get_child(0) as Control
		var total := 0.0
		for child in map_box.get_children():
			total += (child as Control).custom_minimum_size.y + 10.0
		var y := (rect.size.y - total) * 0.5
		for child in map_box.get_children():
			var control := child as Control
			control.position = Vector2((rect.size.x - control.custom_minimum_size.x) * 0.5, y)
			y += control.custom_minimum_size.y + 10.0
	_center_popup()


func corner_box_present() -> bool:
	return get_node_or_null("Corner") != null


func _center_popup() -> void:
	if popup == null or not is_instance_valid(popup):
		return
	var panel := popup.get_child(1) as Control
	if panel == null:
		return
	var rect := get_rect()
	panel.position = (rect.size - panel.size) * 0.5


func state() -> Dictionary:
	return {
		"maps_visible": map_box != null and map_box.visible,
		"popup_visible": popup != null and is_instance_valid(popup),
		"map_count": map_buttons.size(),
		"background": background.status_text() if background != null else "",
		"orientation": Settings.orientation if Settings != null else -1,
	}
