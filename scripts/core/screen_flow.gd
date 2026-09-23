extends Node
## ScreenFlow — переходы между сценами, блокировка ввода на время фейда,
## смена ориентации экрана и лёгкий «оверлей» поверх текущей сцены.
##
## Затемнение рисуется кодом (CanvasLayer + ColorRect), чтобы меню, загрузка и пауза
## использовали один и тот же переход без дублирования сцен.

signal transition_started(to_path: String)
signal transition_finished(to_path: String)
signal scene_changed(scene: Node)

## Длительность одной половины фейда (сек).
var fade_time: float = 0.24
var busy: bool = false
var current_path: String = ""
var _layer: CanvasLayer = null
var _rect: ColorRect = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_overlay()
	# Ориентация из настроек применяется до первой сцены, чтобы Android
	# не перестроил экран уже после показа меню.
	apply_orientation(Settings.orientation)

func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 128
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_rect)

func set_fade_time(value: float) -> void:
	fade_time = maxf(value, 0.0)

## Плавная загрузка новой сцены. `deferred` полезен, когда текущая сцена
## сама инициирует переход (освобождение узлов нужно отложить на конец кадра).
func change_scene(path: String, deferred: bool = true) -> void:
	if busy:
		DebugConsole.log_line("flow", "переход уже идёт, %s отменён" % path)
		return
	if not ResourceLoader.exists(path):
		push_error("ScreenFlow: сцена не найдена: %s" % path)
		DebugConsole.log_line("flow", "ОШИБКА: нет сцены %s" % path)
		return
	busy = true
	transition_started.emit(path)
	var tween := create_tween()
	tween.tween_property(_rect, "color:a", 1.0, fade_time)
	await tween.finished
	if deferred:
		await get_tree().process_frame
	var packed := load(path) as PackedScene
	var next_scene: Node = null
	if packed != null:
		next_scene = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if next_scene == null:
		push_error("ScreenFlow: не удалось инстанцировать %s" % path)
		busy = false
		await _fade_out(path)
		return
	var previous := get_tree().current_scene
	if previous != null:
		get_tree().root.remove_child(previous)
		previous.queue_free()
	get_tree().root.add_child(next_scene)
	get_tree().current_scene = next_scene
	current_path = path
	AppState.current_scene_path = path
	scene_changed.emit(next_scene)
	await _fade_out(path)

func _fade_out(path: String) -> void:
	var tween := create_tween()
	tween.tween_property(_rect, "color:a", 0.0, fade_time)
	await tween.finished
	busy = false
	transition_finished.emit(path)

func reload_current() -> void:
	var path := current_path if not current_path.is_empty() else AppState.current_scene_path
	if path.is_empty():
		return
	current_path = ""
	change_scene(path, true)

## Простой оверлей (пауза/настройки) поверх текущей сцены, без загрузки заново.
func push_overlay_script(script: Script, name_hint: String = "Overlay") -> Node:
	var node := Node.new()
	node.name = name_hint
	node.set_script(script)
	get_tree().root.add_child(node)
	return node

func pop_overlay(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()

func set_black(on: bool) -> void:
	if _rect != null:
		_rect.color.a = 1.0 if on else 0.0

func is_landscape() -> bool:
	return Settings.is_landscape()

## Смена ориентации. На Android это `DisplayServer.screen_set_orientation`,
## на десктопе — поворот окна; в headless — безвредный no-op.
func apply_orientation(mode: int) -> void:
	var target := DisplayServer.SCREEN_LANDSCAPE if mode == 0 else DisplayServer.SCREEN_PORTRAIT
	if DisplayServer.get_name() == "headless":
		AppState.orientation = mode
		return
	if DisplayServer.screen_get_orientation() == target:
		AppState.orientation = mode
		return
	DisplayServer.screen_set_orientation(target)
	AppState.orientation = mode
	DebugConsole.log_line("flow", "ориентация -> %s" % AppState.orientation_name(mode))
