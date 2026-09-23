extends Node
## Autoload: scene navigation, the fade overlay and the loading screen.
##
## Responsibilities:
##   * the only code in the project that is allowed to change scenes
##   * fade in/out transitions that also cover the chunk streaming hitch
##   * a loading overlay with a progress bar driven by the world streamer
##   * re-applying the screen orientation after every scene switch
## The autoload keeps working while the tree is paused, so the pause menu can use it too.

signal scene_changed(path: String)
signal transition_started(path: String)

const MENU_SCENE := "res://scenes/main/MainMenu.tscn"
const ORIENTATION_SCENE := "res://scenes/main/OrientationSelect.tscn"
const WORLD_SCENE := "res://scenes/game/GameWorld.tscn"
const BOOT_SCENE := "res://scenes/main/Main.tscn"

var current_path: String = ""
var transitioning: bool = false

var _overlay: CanvasLayer
var _fade: ColorRect
var _loading_root: Control
var _loading_label: Label
var _progress: ProgressBar


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_overlay()


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "ScreenFlow"
	_overlay.layer = 100
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_overlay)

	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color(0.02, 0.03, 0.05, 0.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_fade)

	_loading_root = Control.new()
	_loading_root.name = "Loading"
	_loading_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_loading_root.visible = false
	_overlay.add_child(_loading_root)

	var background := ColorRect.new()
	background.color = Color(0.04, 0.05, 0.08, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_root.add_child(background)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	box.custom_minimum_size = Vector2(460.0, 0.0)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_loading_root.add_child(box)

	_loading_label = Label.new()
	_loading_label.text = "ЗАГРУЗКА..."
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 30)
	box.add_child(_loading_label)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(460.0, 18.0)
	box.add_child(_progress)


## Changes to another scene with a fade. Safe to call from a UI button.
func goto(path: String) -> void:
	if transitioning:
		return
	if not ResourceLoader.exists(path):
		push_error("ScreenFlow: scene not found: %s" % path)
		return
	transitioning = true
	transition_started.emit(path)
	await _fade_to(1.0, 0.22)
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("ScreenFlow: change_scene_to_file(%s) failed with %d" % [path, err])
		await _fade_to(0.0, 0.22)
		transitioning = false
		return
	await get_tree().process_frame
	await get_tree().process_frame
	current_path = path
	SettingsManager.apply_orientation(false)
	scene_changed.emit(path)
	await _fade_to(0.0, 0.25)
	transitioning = false


func goto_menu() -> void:
	await goto(MENU_SCENE)


func goto_world() -> void:
	await goto(WORLD_SCENE)


func goto_orientation_select() -> void:
	await goto(ORIENTATION_SCENE)


func reload_current() -> void:
	if current_path == "":
		return
	await goto(current_path)


func quit_game() -> void:
	get_tree().quit()


func show_loading(text: String = "ЗАГРУЗКА...") -> void:
	_loading_label.text = text
	_progress.value = 0.0
	_loading_root.visible = true


func set_loading_progress(value: float, text: String = "") -> void:
	_progress.value = clampf(value, 0.0, 1.0)
	if text != "":
		_loading_label.text = text


func hide_loading() -> void:
	_loading_root.visible = false


func is_loading_visible() -> bool:
	return _loading_root.visible


func _fade_to(alpha: float, duration: float) -> void:
	if duration <= 0.0:
		_fade.color.a = alpha
		return
	var tween := _overlay.create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_fade, "color:a", alpha, duration)
	await tween.finished
