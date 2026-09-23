class_name Game
extends Node3D
## Игровая сцена: мир + машина + камера + полиция + интерфейс, собранные кодом.
##
## Корень сцены — ОДИН узел с этим скриптом: состав подсистем одинаковый у всех запусков,
## а .tscn с 12 узлами превращается в «свадьбу конфликтов» при каждой правке архитектуры.
## Порядок сборки здесь принципиален (см. комментарии в теле):
##   1) окружение/свет         — иначе первый кадр чёрный;
##   2) мир (ближнее кольцо СИНХРОННО) — иначе машина спавнится «в пустоту» и падает;
##   3) машина, камера, HUD    — привязка к уже существующему миру;
##   4) полиция                — требует RoadGraph + построенные чанки под ногами;
##   5) остальное кольцо       — уже по бюджету кадров (WorldStreamer).
##
## РЕЖИМЫ ЗАПУСКА (нужны CI, см. docs/CI.md):
##   --capture-map [--capture-out=res://assets/ui/map_card.png]
##       -> собрать ВСЕ чанки, снять вид сверху, сохранить PNG и выйти с кодом 0;
##   --self-test -> прогнать проверки мира/баланса, напечатать отчёт и выйти (код != 0 при провале).

const CAPTURE_ARGS := ["--capture-map", "--capture_map"]
const TEST_ARGS := ["--self-test", "--self_test"]
const CAPTURE_HEIGHT_M := 420.0
const CAPTURE_OUT_DEFAULT := "res://assets/ui/map_card.png"
const ARREST_RESUME_S := 3.0

var config: WorldConfig = null
var streamer: WorldStreamer = null
var player: PlayerCar = null
var camera: CameraController = null
var chase: ChaseManager = null
var police: PoliceManager = null
var ui: UIManager = null
var sun: DirectionalLight3D = null
var environment: WorldEnvironment = null
var loading: Label = null
var capture_mode: bool = false
var test_mode: bool = false
var capture_out: String = CAPTURE_OUT_DEFAULT
var _capture_frames: int = 0
var _resume_timer: float = 0.0
var _resume_action: StringName = &"none"


func _ready() -> void:
	config = GameSetup.get_config("world") as WorldConfig
	if config == null:
		config = WorldConfig.new()
	_parse_args()
	_build_environment()
	_build_world()
	_build_player()
	_build_camera()
	_build_ui()
	_build_police()
	process_mode = Node.PROCESS_MODE_ALWAYS
	AppState.phase_changed.connect(_on_phase)
	if test_mode:
		_run_self_test()
	elif capture_mode:
		_prepare_capture()
	else:
		AppState.set_phase(AppState.Phase.PLAYING)
	# Мир достраивается в фоне: пока ближнего кольца нет, показываем прогресс.
	if streamer != null and not streamer.is_ready():
		_show_loading()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for raw in args:
		var arg := String(raw)
		if CAPTURE_ARGS.has(arg):
			capture_mode = true
		elif TEST_ARGS.has(arg):
			test_mode = true
		elif arg.begins_with("--capture-out="):
			capture_out = arg.substr("--capture-out=".length())
		elif arg.begins_with("--capture_out="):
			capture_out = arg.substr("--capture_out=".length())
	if args.is_empty():
		# При запуске из редактора аргументы приходят без «--user» обвязки.
		for arg_engine in OS.get_cmdline_arguments():
			if CAPTURE_ARGS.has(String(arg_engine)):
				capture_mode = true


func _build_environment() -> void:
	environment = WorldEnvironment.new()
	environment.name = "Environment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.16, 0.24, 0.38)
	material.sky_horizon_color = Color(0.62, 0.66, 0.72)
	material.ground_bottom_color = Color(0.14, 0.15, 0.17)
	material.ground_horizon_color = Color(0.55, 0.58, 0.64)
	sky.sky_material = material
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tone_mapper = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = PerformanceManager.glow_enabled()
	env.glow_bloom = 0.06
	env.glow_intensity = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.76, 0.82)
	env.fog_density = 0.0016 * PerformanceManager.fog_multiplier()
	env.fog_sky_affect = 0.4
	environment.environment = env
	add_child(environment)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.90)
	sun.shadow_enabled = PerformanceManager.shadows_enabled()
	sun.directional_shadow_max_distance = PerformanceManager.shadow_distance()
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL_SPLIT
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.53
	add_child(sun)
	PerformanceManager.tier_changed.connect(_on_tier_changed)


func _build_world() -> void:
	streamer = WorldStreamer.new()
	streamer.name = "WorldStreamer"
	streamer.config = config
	add_child(streamer)
	# Ближнее кольцо — СИНХРОННО: у игрока под колёсами обязана быть коллизия в первом
	# же физикальном шаге, иначе машина «падает сквозь бетон» на старте.
	var built := streamer.build_all_immediately(9)
	DebugConsole.log_line("world", "первое кольцо чанков: %d, дальше по бюджету %.1f мс/кадр" % [
		built, config.chunk_build_budget_ms])


func _build_player() -> void:
	var spawn := WorldGenerator.spawn_point(config)
	player = PlayerCar.new()
	player.name = "PlayerCar"
	add_child(player)
	player.assemble()
	var ground := config.ground_y_m
	player.place_at(Vector3(spawn.x, ground, spawn.z), PI * 0.25, ground)
	DebugConsole.log_line("game", "спавн игрока: (%.0f; %.0f), бетонная площадь %.0f м" % [
		spawn.x, spawn.z, WorldGenerator.plaza_radius(config)])


func _build_camera() -> void:
	camera = CameraController.new()
	camera.name = "Camera"
	add_child(camera)
	var cfg := GameSetup.get_config("camera") as CameraConfig
	if cfg != null:
		camera.apply_config(cfg)
	camera.make_current()


func _build_ui() -> void:
	ui = UIManager.new()
	ui.name = "UI"
	ui.build(self, player, chase, camera, streamer)


func _build_police() -> void:
	chase = ChaseManager.new()
	chase.name = "ChaseManager"
	add_child(chase)
	police = PoliceManager.new()
	police.name = "PoliceManager"
	add_child(police)
	chase.arrested.connect(_on_arrested)
	player.player_destroyed.connect(_on_destroyed)
	if player != null:
		chase.attach_target(player)
	police.attach(player)


func _process(delta: float) -> void:
	if loading != null:
		var progress := clampf(streamer.progress(), 0.0, 1.0)
		loading.text = "ЗАГРУЗКА МИРА %.0f%%" % (progress * 100.0)
		if streamer.is_ready():
			_hide_loading()
	if _resume_timer > 0.0:
		_resume_timer = maxf(_resume_timer - delta, 0.0)
		if _resume_timer <= 0.0:
			_finish_event()
	if capture_mode:
		_tick_capture()


func _show_loading() -> void:
	if loading != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "Loading"
	layer.layer = 5
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	loading = Label.new()
	loading.text = "ЗАГРУЗКА МИРА"
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.add_theme_font_size_override("font_size", 24)
	layer.add_child(loading)


func _hide_loading() -> void:
	if loading != null and loading.get_parent() != null:
		loading.get_parent().queue_free()
	loading = null


func _on_phase(previous: int, current: int) -> void:
	if current == AppState.Phase.PLAYING and previous == AppState.Phase.LOADING:
		if camera != null:
			camera.snap_behind_target()


func _on_arrested() -> void:
	if player != null:
		player.on_arrest()
	_schedule_resume(ARREST_RESUME_S, &"arrest")
	if chase != null:
		AppState.record_arrest_survived()


func _on_destroyed() -> void:
	AppState.set_phase(AppState.Phase.DESTROYED)
	_schedule_resume(ARREST_RESUME_S, &"destroy")


func _schedule_resume(seconds: float, action: StringName) -> void:
	_resume_timer = seconds
	_resume_action = action


func _finish_event() -> void:
	if _resume_action == &"arrest":
		if ui != null:
			ui.resume()
		if chase != null:
			chase.clear_units()
			chase.arrest.reset(&"after_arrest")
		if player != null:
			player.respawn(WorldGenerator.spawn_point(config), PI * 0.25)
		AppState.set_phase(AppState.Phase.PLAYING)
	elif _resume_action == &"destroy":
		if player != null:
			var heading := player.heading_rad() + PI
			player.respawn(player.global_position + Vector3(0.0, 0.0, -8.0), heading)
		AppState.set_phase(AppState.Phase.PLAYING)
	_resume_action = &"none"


func _on_tier_changed(_index: int) -> void:
	var tier: QualityTier = PerformanceManager.tier()
	if sun != null:
		sun.shadow_enabled = PerformanceManager.shadows_enabled()
		sun.directional_shadow_max_distance = PerformanceManager.shadow_distance()
		if tier != null:
			# Смещение тени от поверхности: на 512-атласе без увеличенного bias появляются
			# «полосы» (shadow acne), поэтому bias едет в связке с размером атласа.
			sun.shadow_bias = tier.shadow_bias
	if environment != null and environment.environment != null:
		var env := environment.environment
		env.glow_enabled = PerformanceManager.glow_enabled()
		env.glow_intensity = tier.glow_intensity if tier != null else 0.0
		env.fog_density = 0.0016 * PerformanceManager.fog_multiplier()
		if env.sky != null and tier != null:
			# Пересборка radiance map - дорогая операция: на medium/low обновление не в реальном
			# времени, а инкрементальное (небо у нас статичное, меняется только солнце-угол).
			env.sky.set("process_mode", Sky.PROCESS_MODE_REALTIME if tier.sky_realtime_update else Sky.PROCESS_MODE_INCREMENTAL)


# ------------------------------------------------------------------ CI-режимы

func _prepare_capture() -> void:
	AppState.set_phase(AppState.Phase.PAUSED)
	get_tree().paused = true
	if streamer != null:
		var total := streamer.build_all_immediately(64)
		DebugConsole.log_line("capture", "построено чанков для снимка: %d" % total)
	_capture_frames = 0
	if camera != null and player != null:
		camera.position = Vector3(player.global_position.x, CAPTURE_HEIGHT_M, player.global_position.z + 0.01)
		camera.rotation_degrees = Vector3(-89.0, 0.0, 0.0)
		camera.current = true


func _tick_capture() -> void:
	_capture_frames += 1
	if _capture_frames < 4:
		return
	var image := get_viewport().get_texture().get_image()
	if image == null:
		DebugConsole.log_line("capture", "ОШИБКА: viewport вернул пустое изображение")
		get_tree().quit(2)
		return
	var path := capture_out
	var error := image.save_png(path)
	DebugConsole.log_line("capture", "сохранено %s (%d x %d, код %d)" % [path, image.get_width(), image.get_height(), error])
	# Дополнительно — текстовый отчёт, чтобы CI мог проверить содержимое мира.
	var report := _capture_report()
	var report_path := path.replace(".png", "_report.txt")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(report)
		file.close()
	get_tree().quit(0 if error == OK else 1)


func _capture_report() -> String:
	var lines := PackedStringArray()
	lines.append("=== MAP CAPTURE REPORT ===")
	lines.append("godot=%s" % Engine.get_version_info().get("string", "?"))
	lines.append("world_radius_m=%.1f chunk_size_m=%.1f pitch_m=%.1f" % [
		config.world_radius_m, config.chunk_size_m, config.block_pitch_m])
	if streamer != null:
		var stats := streamer.stats()
		lines.append("chunks_loaded=%d triangles=%d prop_instances=%d" % [
			int(stats.get("loaded", 0)), int(stats.get("triangles", 0)), int(stats.get("prop_instances", 0))])
		lines.append(streamer.status_text())
		var problems := streamer.self_check()
		lines.append("streamer_self_check=%s" % ("ok" if problems.is_empty() else " ;".join(problems)))
	lines.append("player=%s" % (player.status_line() if player != null else "нет"))
	lines.append("materials=%d textures=%d prop_kinds=%d cached=%d" % [
		MaterialLibrary.types().size(), TextureLibrary.cached_count(),
		PropMeshes.kinds().size(), PropMeshes.cached_count()])
	return "\n".join(lines) + "\n"


func _run_self_test() -> void:
	var problems := PackedStringArray()
	problems.append_array(streamer.self_check())
	problems.append_array(BalanceRules.check(
		GameSetup.get_config("vehicle.player") as VehicleConfig,
		GameSetup.get_config("vehicle.police") as VehicleConfig,
		GameSetup.get_config("nitro") as NitroConfig))
	var fatal := DebugConsole.has_fatal_output()
	print("[GAME SELF-TEST] ", "ok" if problems.is_empty() and not fatal else " ;".join(problems))
	if fatal:
		print("[ENGINE OUTPUT]\n", DebugConsole.report_text())
	get_tree().quit(0 if problems.is_empty() and not fatal else 1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if AppState.is_in_game():
			AppState.end_session()


func state() -> Dictionary:
	return {
		"player": player.state() if player != null else {},
		"chase": chase.state() if chase != null else {},
		"police": police.stats() if police != null else {},
		"streamer": streamer.stats() if streamer != null else {},
		"ui": ui.controls.state() if ui != null and ui.controls != null else {},
		"capture": capture_mode,
	}
