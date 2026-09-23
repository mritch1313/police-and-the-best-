class_name OrientationGate
extends Control
## Первый экран при ПЕРВОМ запуске: выбор ориентации (постоянная: горизонталь или вертикаль).
##
## ТРЕБОВАНИЕ ЗАКРЫТО ЦИКЛОМ: выбор спрашивается РОВНО ОДИН РАЗ и сохраняется
## (Settings.set_orientation(value, true) -> SaveManager.profile.orientation_chosen).
## При следующих запусках `_ready` сразу уходит в главное меню, без «показа на секунду».
##
## Ориентация применяется ДАЖЕ вне меню: ScreenFlow.apply_orientation пишет
## DisplayServer.screen_set_orientation(...) — на Android этого достаточно, а
## manifest-значение (portrait) остаётся лишь начальным кадром до первого layout.

const MENU_SCENE := "res://scenes/menu/MainMenu.tscn"

var _ui: UiConfig = null
var _busy: bool = false


func _ready() -> void:
	_ui = GameSetup.get_config("ui") as UiConfig
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	if Settings != null and Settings.orientation_chosen:
		_go(MENU_SCENE)
		return
	_build()


func _build() -> void:
	var background := MainMenuBackground.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	box.custom_minimum_size = Vector2(minf(size.x * 0.8, 460.0), 0.0)
	add_child(box)
	var title := Label.new()
	title.text = _text("orientation_title", "Выбери ориентацию экрана")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.06, 0.07, 0.09))
	box.add_child(title)
	var hint := Label.new()
	hint.text = _text("orientation_hint", "выбор сохраняется и больше не спрашивается")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 17)
	hint.add_theme_color_override("font_color", Color(0.28, 0.3, 0.34))
	box.add_child(hint)
	var landscape := _button(_text("landscape_label", "Горизонтальная"))
	landscape.pressed.connect(func() -> void: _choose(0))
	box.add_child(landscape)
	var portrait := _button(_text("portrait_label", "Вертикальная"))
	portrait.pressed.connect(func() -> void: _choose(1))
	box.add_child(portrait)


func _text(key: String, fallback: String) -> String:
	if _ui == null:
		return fallback
	var value: Variant = _ui.get(key)
	return String(value) if value != null and String(value) != "" else fallback


func _button(label: String) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(0.0, 96.0)
	button.focus_mode = Control.FOCUS_NONE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.98, 0.42, 0.16, 0.95)
	style.set_corner_radius_all(20)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1.0, 0.55, 0.25)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", Color(0.05, 0.05, 0.06))
	return button


func _choose(value: int) -> void:
	if _busy:
		return
	_busy = true
	Settings.set_orientation(value, true)
	AppState.orientation = value
	_go(MENU_SCENE)


func _go(path: String) -> void:
	ScreenFlow.set_black(false)
	ScreenFlow.change_scene(path, true)
