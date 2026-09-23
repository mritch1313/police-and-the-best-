class_name Hud
extends Control
## Игровой HUD: скорость, передача, уровень розыска, нитро, мини-карта, баннеры, FPS.
##
## РЕНДЕР-БЮДЖЕТ: всё рисуется в `_draw()` одного Control (линии/прямоугольники/текст) —
## без TextureRect-слоёв, без шейдеров, без `QueueRedraw` на каждый кадр «на глаз»:
## перерисовка включается только когда данные реально изменились (см. `_dirty` и таймер
## 10 Гц). На Mali-G52 перерисовка CanvasItem — дорогая операция, поэтому 60 раз в секунду
## её делать не нужно.
##
## МИНИ-КАРТА рисует НЕ «скриншот мира», а те же данные, из которых строится мир
## (WorldConfig + RoadGraph + позиции патрулей) — она всегда актуальна и стоит ~40 линий.

const WANTED_STARS := 5
const REFRESH_INTERVAL_S := 0.1
const MINIMAP_ROAD_COLOR := Color(0.55, 0.58, 0.64, 0.75)
const MINIMAP_AVENUE_COLOR := Color(0.86, 0.88, 0.94, 0.9)
const MINIMAP_BLOCK_COLOR := Color(0.12, 0.13, 0.16, 0.9)
const POLICE_COLOR := Color(0.35, 0.65, 1.0)
const PLAYER_COLOR := Color(0.98, 0.42, 0.16)

var ui_config: UiConfig = null
var world_config: WorldConfig = null
var chase: Node = null
var player: Node = null
var streamer: Node = null
var speed_label: Label = null
var gear_label: Label = null
var wanted_label: Label = null
var nitro_bar: ProgressBar = null
var status_label: Label = null
var fps_label: Label = null
var banner_label: Label = null
var minimap: Control = null
var arrest_bar: ProgressBar = null
var show_fps: bool = false
var show_debug: bool = false
var banner_time: float = 0.0
var _timer: float = 0.0
var _fps_timer: float = 0.0
var _frames: int = 0
var _fps: float = 0.0
var _banner_flash: Color = Color(1, 1, 1)


func _ready() -> void:
	ui_config = GameSetup.get_config("ui") as UiConfig
	world_config = GameSetup.get_config("world") as WorldConfig
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	if Settings != null:
		Settings.settings_changed.connect(_on_settings)
	_on_settings()


func bind(player_node: Node, chase_node: Node, streamer_node: Node) -> void:
	player = player_node
	chase = chase_node
	streamer = streamer_node
	if chase != null and chase.has_signal("arrest_progress"):
		chase.arrest_progress.connect(_on_arrest_progress)
	if chase != null and chase.has_signal("wanted_changed"):
		chase.wanted_changed.connect(func(_l: int, _p: int) -> void: _mark_dirty())


func _on_settings() -> void:
	if Settings == null:
		return
	show_fps = bool(Settings.show_fps)
	if fps_label != null:
		fps_label.visible = show_fps


func _build() -> void:
	var ui_scale := _scale()
	var panel := ColorRect.new()
	panel.color = Color(0.04, 0.05, 0.07, 0.55)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_bottom = 96.0 * ui_scale
	add_child(panel)
	speed_label = _label("72", 58.0, Vector2(18.0, 6.0))
	speed_label.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	gear_label = _label("D", 26.0, Vector2(20.0, 66.0))
	wanted_label = _label("*", 26.0, Vector2(-1.0, 10.0))
	wanted_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	wanted_label.offset_left = -190.0 * ui_scale
	wanted_label.offset_right = -16.0 * ui_scale
	wanted_label.offset_top = 10.0 * ui_scale
	wanted_label.offset_bottom = 44.0 * ui_scale
	nitro_bar = ProgressBar.new()
	nitro_bar.name = "NitroBar"
	nitro_bar.min_value = 0.0
	nitro_bar.max_value = 1.0
	nitro_bar.step = 0.0
	nitro_bar.show_percentage = false
	nitro_bar.custom_minimum_size = Vector2(190.0 * ui_scale, 14.0 * ui_scale)
	nitro_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	nitro_bar.offset_left = -206.0 * ui_scale
	nitro_bar.offset_right = -16.0 * ui_scale
	nitro_bar.offset_top = 52.0 * ui_scale
	nitro_bar.offset_bottom = 66.0 * ui_scale
	var fill := StyleBoxFlat.new()
	fill.bg_color = ui_config.nitro_color if ui_config != null else Color(0.34, 0.78, 1.0)
	fill.set_corner_radius_all(6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.11, 0.14, 0.8)
	bg.set_corner_radius_all(6)
	nitro_bar.add_theme_stylebox_override("fill", fill)
	nitro_bar.add_theme_stylebox_override("background", bg)
	arrest_bar = nitro_bar.duplicate() as ProgressBar
	arrest_bar.name = "ArrestBar"
	arrest_bar.offset_top = 72.0 * ui_scale
	arrest_bar.offset_bottom = 80.0 * ui_scale
	var arrest_fill := fill.duplicate() as StyleBoxFlat
	arrest_fill.bg_color = Color(1.0, 0.35, 0.3)
	arrest_bar.add_theme_stylebox_override("fill", arrest_fill)
	status_label = _label("", 15.0, Vector2(18.0, -34.0))
	status_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	status_label.offset_top = -34.0 * ui_scale
	status_label.offset_bottom = -6.0 * ui_scale
	fps_label = _label("-- fps", 15.0, Vector2(18.0, -58.0))
	fps_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	fps_label.offset_top = -58.0 * ui_scale
	fps_label.offset_bottom = -36.0 * ui_scale
	fps_label.visible = false
	banner_label = Label.new()
	banner_label.name = "Banner"
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner_label.offset_top = 108.0 * ui_scale
	banner_label.offset_bottom = 164.0 * ui_scale
	banner_label.add_theme_font_size_override("font_size", int(34.0 * ui_scale))
	banner_label.modulate.a = 0.0
	add_child(banner_label)
	minimap = Control.new()
	minimap.name = "Minimap"
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap.draw.connect(_draw_minimap)
	add_child(minimap)
	for node in [panel, speed_label, gear_label, wanted_label, nitro_bar, arrest_bar, status_label, fps_label]:
		if node != null and node != banner_label and node != minimap:
			add_child(node)
	_layout()
	resized.connect(_layout)


func _label(text_value: String, size: float, at: Vector2) -> Label:
	var label := Label.new()
	label.name = "Label_%d" % int(at.y)
	label.text = text_value
	label.position = at
	label.add_theme_font_size_override("font_size", int(size * _scale()))
	label.add_theme_color_override("font_color", (ui_config.text_color if ui_config != null else Color(0.92, 0.94, 0.97)))
	return label


func _scale() -> float:
	return clampf(Settings.ui_scale if Settings != null else 1.0, 0.6, 2.0)


func _layout() -> void:
	if minimap == null or ui_config == null:
		return
	var side := clampf(ui_config.minimap_size_px * _scale(), 80.0, 320.0)
	var rect := get_rect()
	minimap.size = Vector2(side, side)
	minimap.position = Vector2(rect.size.x - side - 14.0 * _scale(), 86.0 * _scale())


## Публичный API для остальной игры (см. PlayerCar).
func on_player_tick(car: Node) -> void:
	player = car
	_tick(REFRESH_INTERVAL_S)


func show_banner(text_value: String, color: Color) -> void:
	if banner_label == null:
		return
	banner_label.text = text_value
	banner_label.add_theme_color_override("font_color", color)
	banner_time = 2.4
	_flash_in()


func flash(text_value: String, color: Color) -> void:
	show_banner(text_value, color)


func _flash_in() -> void:
	if banner_label == null:
		return
	banner_label.modulate.a = 1.0
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_IDLE)
	tween.tween_property(banner_label, "modulate:a", 0.0, 1.6)


func _process(delta: float) -> void:
	_frames += 1
	_fps_timer += delta
	if _fps_timer >= 0.5:
		_fps = float(_frames) / _fps_timer
		_frames = 0
		_fps_timer = 0.0
		if fps_label != null and show_fps:
			fps_label.text = "%.0f fps / %s" % [_fps, PerformanceManager.tier_name()]
	if banner_time > 0.0:
		banner_time = maxf(banner_time - delta, 0.0)
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH_INTERVAL_S
		_tick(REFRESH_INTERVAL_S)


func _mark_dirty() -> void:
	_timer = 0.0


func _tick(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var speed_kmh := absf(player.ground_speed_kmh()) if player.has_method("ground_speed_kmh") else 0.0
	if speed_label != null:
		speed_label.text = "%.0f" % speed_kmh if (ui_config == null or ui_config.show_speed_number) else ""
	if gear_label != null and player.controller != null:
		gear_label.text = _gear_name(player.controller.gear)
	if wanted_label != null and chase != null:
		var level := int(chase.wanted_int)
		# Звёздочка — ASCII: в дефолтном шрифте OpenSans (1010 глифов) нет «★».
		wanted_label.text = ("*".repeat(level) + "  розыск %d" % level) if level > 0 else "розыск 0"
		wanted_label.add_theme_color_override("font_color", Color(1.0, 0.72 - 0.05 * float(level), 0.2))
	if nitro_bar != null and player.nitro != null:
		nitro_bar.value = player.nitro.charge_ratio()
		var color := (ui_config.nitro_color if ui_config != null else Color(0.34, 0.78, 1.0))
		nitro_bar.modulate = Color(1, 1, 1) if not player.nitro.active else color.lightened(0.4)
	if arrest_bar != null and chase != null and chase.arrest != null:
		arrest_bar.value = chase.arrest.progress()
		arrest_bar.visible = chase.arrest.progress() > 0.01
	if status_label != null:
		status_label.text = _status_line()
		minimap.queue_redraw()


func _status_line() -> String:
	var parts := PackedStringArray()
	if chase != null:
		parts.append(chase.status_text())
	if streamer != null and streamer.has_method("status_text"):
		parts.append(streamer.call("status_text"))
	if player != null and player.has_method("status_line"):
		parts.append(player.status_line())
	return "  |  ".join(parts)


func _gear_name(gear: int) -> String:
	match gear:
		-1:
			return "R"
		0:
			return "N"
		_:
			return "D%d" % gear


func _on_arrest_progress(ratio: float) -> void:
	if arrest_bar != null:
		arrest_bar.value = clampf(ratio, 0.0, 1.0)


func set_debug_visible(on: bool) -> void:
	show_debug = on
	if status_label != null:
		status_label.visible = on


func _draw_minimap() -> void:
	if minimap == null or world_config == null:
		return
	var size := minimap.size
	var span := maxf(world_config.world_radius_m, 100.0) * 2.2
	var center := player.global_position if player != null else Vector3.ZERO
	var to_map := func(world_xz: Vector3) -> Vector2:
		var nx := (world_xz.x - center.x) / span + 0.5
		var ny := (world_xz.z - center.z) / span + 0.5
		return Vector2(nx * size.x, ny * size.y)
	minimap.draw_rect(Rect2(Vector2.ZERO, size), MINIMAP_BLOCK_COLOR, true)
	# Улицы берём НЕ «по памяти», из той же формулы, что строит мир: line_offset(k).
	# Иначе мини-карта разошлась бы с реальностью при правке block_pitch_m.
	var step := maxf(world_config.block_pitch_m, 20.0)
	var lo := int(floorf((min(center.x, center.z) - span) / step))
	var hi := int(ceilf((maxf(center.x, center.z) + span) / step))
	for k in range(lo, hi + 1):
		var offset := WorldGenerator.line_offset(k, world_config)
		var avenue := WorldGenerator.is_avenue(k, world_config)
		var color := MINIMAP_AVENUE_COLOR if avenue else MINIMAP_ROAD_COLOR
		var thick := 2.4 if avenue else 1.2
		minimap.draw_line(
			to_map(Vector3(offset, 0.0, center.z - span)),
			to_map(Vector3(offset, 0.0, center.z + span)), color, thick)
		minimap.draw_line(
			to_map(Vector3(center.x - span, 0.0, offset)),
			to_map(Vector3(center.x + span, 0.0, offset)), color, thick)
	# Площадь спавна — круг из тех же данных (plaza_radius), что и геометрия.
	var plaza := WorldGenerator.plaza_radius(world_config)
	var plaza_center := to_map(Vector3.ZERO)
	var plaza_r := plaza / span * size.x
	if plaza_r > 1.0:
		minimap.draw_arc(plaza_center, plaza_r, 0.0, TAU, 28, Color(0.70, 0.75, 0.85, 0.45), 1.0)
	if player != null:
		var p := to_map(center)
		var heading: float = player.heading_rad() if player.has_method("heading_rad") else 0.0
		var fwd := Vector2(sin(heading), -cos(heading))
		var side := Vector2(-fwd.y, fwd.x)
		minimap.draw_colored_polygon(PackedVector2Array([
			p + fwd * 9.0, p - fwd * 5.0 + side * 5.5, p - fwd * 5.0 - side * 5.5,
		]), PLAYER_COLOR)
	if chase != null and chase.get("units") != null:
		for unit in chase.units:
			if unit == null or not is_instance_valid(unit):
				continue
			var u := to_map(unit.global_position)
			minimap.draw_circle(u, 3.6, POLICE_COLOR)
			if unit.ai != null and unit.ai.mode != PoliceStrategy.PATROL:
				minimap.draw_arc(u, 7.5, 0.0, TAU, 12, Color(POLICE_COLOR.r, POLICE_COLOR.g, POLICE_COLOR.b, 0.6), 1.4)
	minimap.draw_rect(Rect2(Vector2.ZERO, size), Color(0.9, 0.9, 0.9, 0.25), false, 1.0)


func fps() -> float:
	return _fps
