class_name UIManager
extends CanvasLayer
## Единая точка сборки интерфейса: HUD + тач-управление + оверлеи (пауза/настройки).
##
## ЗАЧЕМ НУЖЕН ПОСРЕДНИК: PlayerCar не должен знать про пауз-меню, а меню паузы — про
## RigidBody3D. Здесь — вся «склейка»: привязал контролы к машине, показал настройки из
## оверлея, поставил игру на паузу по кнопке/Back.
##
## ПАУЗА: `get_tree().paused = true` + `process_mode` у узлов игры = PAUSABLE (см.
## VehicleRig) + `TWEEN_PAUSE_IDLE` у анимаций интерфейса. Интерфейс живёт на
## PROCESS_MODE_ALWAYS, поэтому кнопки работают на паузе.

signal pause_toggled(on: bool)

var player: Node = null
var chase: Node = null
var camera: CameraController = null
var streamer: Node = null
var hud: Hud = null
var controls: MobileControls = null
var pause_panel: Control = null
var settings: SettingsMenu = null
var _paused: bool = false


func build(host: Node, player_node: Node, chase_node: Node, camera_node: CameraController, streamer_node: Node) -> void:
	layer = 1
	host.add_child(self)
	player = player_node
	chase = chase_node
	camera = camera_node
	streamer = streamer_node
	controls = MobileControls.new()
	controls.name = "MobileControls"
	add_child(controls)
	controls.bind_camera(camera)
	# Тач-пауза: UIManager - единственный, кто знает про панель паузы, поэтому вешаем сюда.
	controls.pause_requested.connect(toggle_pause)
	if player != null and player.has_method("set_controls"):
		player.set_controls(controls)
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.bind(player, chase, streamer)
	if player is PlayerCar:
		(player as PlayerCar).bind(controls, camera, chase, hud)
	_build_pause_panel()
	AppState.phase_changed.connect(_on_phase_changed)


func _on_phase_changed(_previous: int, current: int) -> void:
	var paused := current == AppState.Phase.PAUSED
	_paused = paused
	get_tree().paused = paused
	if pause_panel != null:
		pause_panel.visible = paused
	if paused:
		refresh_pause_labels()


func toggle_pause() -> void:
	if _paused:
		resume()
	else:
		AppState.set_phase(AppState.Phase.PAUSED)


func resume() -> void:
	settings_close()
	AppState.set_phase(AppState.Phase.PLAYING)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause_game"):
		toggle_pause()
		get_viewport().set_input_as_handled()


func _build_pause_panel() -> void:
	pause_panel = Control.new()
	pause_panel.name = "PausePanel"
	pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_panel.visible = false
	pause_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(pause_panel)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(dim)
	var box := VBoxContainer.new()
	box.name = "Buttons"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(300.0, 0.0)
	pause_panel.add_child(box)
	var title := Label.new()
	title.text = "ПАУЗА"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	box.add_child(title)
	var info := Label.new()
	info.name = "Info"
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 16)
	info.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	box.add_child(info)
	_pause_button(box, "resume", func() -> void: resume())
	_pause_button(box, "settings", func() -> void: settings_open())
	_pause_button(box, "to_menu", func() -> void:
		get_tree().paused = false
		AppState.end_session()
		AppState.set_phase(AppState.Phase.MENU)
		ScreenFlow.change_scene("res://scenes/menu/MainMenu.tscn"))
	_quality_row(box)


## Подпись кнопки берётся из UiConfig — тексты меню правятся в autoloads/ui.cfg.
func _pause_button(box: VBoxContainer, key: String, action: Callable) -> void:
	var ui := GameSetup.get_config("ui") as UiConfig
	var label := {
		"resume": "Продолжить",
		"settings": "Настройки",
		"to_menu": "В меню",
	}
	var text_value := String(label.get(key, key))
	if ui != null:
		var from_config := ""
		match key:
			"resume":
				from_config = ui.resume_label
			"settings":
				from_config = ui.settings_label
			"to_menu":
				from_config = ui.to_menu_label
		if not from_config.is_empty():
			text_value = from_config
	var button := Button.new()
	button.name = key
	button.text = text_value
	button.custom_minimum_size = Vector2(0.0, 72.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	box.add_child(button)


func _quality_row(box: VBoxContainer) -> void:
	var ui := GameSetup.get_config("ui") as UiConfig
	var size := int((ui.hud_font_size if ui != null else 22))
	var label := Label.new()
	label.name = "Quality"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size - 2)
	label.add_theme_color_override("font_color", Color(0.6, 0.66, 0.74))
	box.add_child(label)


func refresh_pause_labels() -> void:
	if pause_panel == null:
		return
	var info := pause_panel.find_child("Info", true, false) as Label
	if info != null:
		info.text = PerformanceManager.status_text()
	var quality := pause_panel.find_child("Quality", true, false) as Label
	if quality != null:
		quality.text = (streamer.call("status_text") as String) if streamer != null and streamer.has_method("status_text") else ""


func settings_open() -> void:
	if settings != null and is_instance_valid(settings):
		return
	settings = SettingsMenu.new()
	settings.name = "Settings"
	add_child(settings)
	settings.closed.connect(settings_close)


func settings_close() -> void:
	if settings != null and is_instance_valid(settings):
		settings.queue_free()
	settings = null


func read_drive() -> Dictionary:
	return controls.read_drive() if controls != null else {}


func on_orientation_changed() -> void:
	if controls != null:
		controls._relayout()
	if hud != null:
		hud._layout()
	if settings != null and is_instance_valid(settings):
		settings._layout()
