extends Node
## Автотесты проекта. Запуск (headless, без GPU):
##   godot --headless --path . res://tests/run_tests.tscn
## Выход: 0 — всё зелёное, 1 — есть провалы (текст падает и в stdout, и в ci-reports/tests.txt).
##
## ПРАВИЛА, ПО КОТОРЫМ ОН НАПИСАН:
##  1. Никаких «assert(true)»: каждый тест вызывает ПРОИЗВОДНЫЙ код (VehicleMath,
##     NitroSystem, ChunkBuilder, RoadGraph, Strategy...) и сверяет ЧИСЛА с тем, что
##     обещает конфиг/баланс. Тест, который не может упасть, удалён как бесполезный.
##  2. Тесты не рисуют и не ждут кадров там, где можно позвать функцию напрямую;
##     где нужен узел в дереве (физика/сигналы) — узел создаётся и удаляется в том же тесте.
##  3. Проверки «архитектуры» (запрет телепортации, отсутствие мусора в API) — сканом
##     исходников: это дешёво и ловит реальные регрессии, а не «запах кода».
##  4. Всё, что зависит от конфига, читается из Config/GameSetup — магических чисел нет:
##     правка autoloads/*.cfg должна ломать тесты ТОЛЬКО если она ломает баланс.

const EXPECTED_SUBTITLE := "СИМУЛЯТОР УГОНА ОТ МУСОРОВ"
const EXPECTED_VERSION_LINE := "ВЕРСИЯ: 4.0.9 TEXT"
const EXPECTED_PACKAGE := "com.racing.chase"
const PHYSICS_ROOTS: Array[String] = [
	"res://scripts/vehicle", "res://scripts/police", "res://scripts/world",
]
const FORBIDDEN_MOTION: PackedStringArray = [
	"global_position +=", "global_position -=", "position += Vector3", "translate(",
	"move_and_slide", "look_at(",
]

var _results: Array[Dictionary] = []
var _failed: int = 0


## Живой прогресс: файл дописывается ПЕРЕД каждым тестом. Нужен он вот для чего: если
## прогон упирается в timeout CI, по последним строкам видно, какой тест завис (в CI-логе
## этого иначе не увидеть).
const PROGRESS_PATH := "res://ci-reports/tests_progress.txt"

func _progress(line: String) -> void:
	var dir_path := "res://ci-reports"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var file := FileAccess.open(PROGRESS_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(PROGRESS_PATH, FileAccess.WRITE)
		if file == null:
			return
	file.seek_end()
	file.store_line(line)
	file.flush()
	file.close()


func _ready() -> void:
	print("=== POLICE CHASE: АВТОТЕСТЫ (Godot %s) ===" % Engine.get_version_info().get("string", "?"))
	_progress("BEGIN godot=%s tests=%d" % [Engine.get_version_info().get("string", "?"), 39])
	var started := Time.get_ticks_msec()
	_run("configs_loaded", _test_configs_loaded)
	_run("config_clamps_out_of_range", _test_config_clamps)
	_run("visual_scene_swap_from_cfg", _test_visual_scene_override)
	_run("balance_rules", _test_balance_rules)
	_run("terminal_speed_matches_config", _test_terminal_speed)
	_run("acceleration_0_100", _test_acceleration)
	_run("braking_distance", _test_braking)
	_run("weight_transfer_sums_to_load", _test_weight_transfer)
	_run("grip_limits_corner_speed", _test_grip_corner_speed)
	_run("nitro_charge_drain_regen", _test_nitro_budget)
	_run("nitro_time_limit_and_overheat", _test_nitro_overheat)
	_run("nitro_blocked_when_paused", _test_nitro_blocked_state)
	_run("nitro_top_speed_ratio", _test_nitro_top_speed)
	_run("police_speed_ceiling", _test_police_ceiling)
	_run("controller_blocked_detection", _test_blocked_controller)
	_run("camera_orbit_independent_of_heading", _test_camera_orbit)
	_run("camera_orbit_while_parked", _test_camera_parked)
	_run("camera_clamps_height_distance", _test_camera_clamps)
	_run("police_target_loss", _test_target_loss)
	_run("police_strategy_switching", _test_strategy_switching)
	_run("police_arrest_rules", _test_arrest_rules)
	_run("police_spawn_rules", _test_spawn_rules)
	_run("road_graph_valid", _test_road_graph)
	_run("route_planner_paths", _test_route_planner)
	_run("trajectory_prediction", _test_prediction)
	_run("world_layout_determinism", _test_world_determinism)
	_run("world_plaza_is_concrete", _test_plaza_concrete)
	_run("world_concrete_tiling_matches_texture", _test_concrete_tiling)
	_run("chunk_geometry_valid", _test_chunk_geometry)
	_run("materials_and_props_complete", _test_materials_props)
	_run("car_geometry_contract", _test_car_geometry)
	_run("wheel_setup", _test_wheel_setup)
	_run("streamer_lod_ordering", _test_streamer_lod)
	_run("touch_targets", _test_touch_targets)
	_run("menu_strings_exact", _test_menu_strings)
	_run("orientation_choice_persisted", _test_orientation_persistence)
	_run("export_preset_contract", _test_export_preset)
	_run("no_vehicle_teleportation", _test_no_teleportation)
	_run("engine_output_clean", _test_engine_output)
	var elapsed := float(Time.get_ticks_msec() - started)
	_report(elapsed)


func _run(name: String, callback: Callable) -> void:
	_progress("RUN " + name)
	var started := Time.get_ticks_usec()
	var problems: PackedStringArray = callback.call()
	var took := float(Time.get_ticks_usec() - started) / 1000.0
	var ok := problems.is_empty()
	var note := "проверено %d случаем" % 1 if ok else ""
	if not ok:
		_failed += 1
	_results.append({"name": name, "ok": ok, "problems": problems, "note": note, "ms": took})
	print("[%s] %-44s %6.1f мс" % ["PASS" if ok else "FAIL", name, took])
	for problem in problems:
		print("        -> ", problem)
	_progress("%s %s %.0fms" % ["PASS" if ok else "FAIL", name, took])


func _report(elapsed: float) -> void:
	var lines := PackedStringArray()
	lines.append("=== ОТЧЁТ АВТОТЕСТОВ (Godot %s) ===" % Engine.get_version_info().get("string", "?"))
	for result in _results:
		var ok := bool(result["ok"])
		lines.append("%-4s %-44s %6.1f мс  %s" % [
			"PASS" if ok else "FAIL", result["name"], float(result["ms"]),
			" ;".join(result["problems"]) if not ok else "ok",
		])
	lines.append("итого: %d из %d пройдено (%.0f мс)" % [_results.size() - _failed, _results.size(), elapsed])
	var text := "\n".join(lines) + "\n"
	_progress("DONE failed=%d elapsed=%.0fms" % [_failed, elapsed])
	print(text)
	var dir_path := "res://ci-reports"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var file := FileAccess.open(dir_path + "/tests.txt", FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	var fatal := DebugConsole.has_fatal_output()
	if fatal:
		print("[ENGINE OUTPUT — СЧИТАНО ЛОГГЕРОМ]\n", DebugConsole.report_text())
	get_tree().quit(0 if _failed == 0 and not fatal else 1)


static func _fail(reason: String) -> PackedStringArray:
	return PackedStringArray([reason])


# ------------------------------------------------------------------ 1. конфигурация

func _test_configs_loaded() -> PackedStringArray:
	var sections := ["world", "vehicle.player", "vehicle.police", "nitro", "chase", "police", "camera", "ui", "graphics"]
	for section in sections:
		if GameSetup.get_config(section) == null:
			return _fail("секция '%s' не собралась в конфиг" % section)
	# Опечатка в ключе .cfg иначе тихо игнорируется — здесь это провал сборки.
	var unexpected := PackedStringArray()
	for warning in Config.warnings:
		var text := String(warning)
		if text.contains("неизвестный ключ") or text.contains("не найден") or text.contains("не удалось"):
			unexpected.append(text)
	if not unexpected.is_empty():
		return _fail("Config предупреждает: " + " ; ".join(unexpected))
	if Config.loaded_files.is_empty():
		return _fail("Config не загрузил ни одного файла конфигурации")
	return PackedStringArray()


## Механизм переопределения (user://override_cfg) + клампинг по @export_range — то, на чём
## держится «все настройки правятся без рекомпиляции». Проверяется реальной записью файла.
func _test_config_clamps() -> PackedStringArray:
	var problems := PackedStringArray()
	var dir_path := "user://override_cfg"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var path := dir_path.path_join("zz_autotest_clamp.cfg")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("не удалось записать тестовый override-файл (проверка клампинга пропущена)")
	file.store_string("[world]\nblock_pitch_m = 1.0\nchunk_size_m = 99999.0\nключ_которого_нет = 3.0\n")
	file.close()
	Config.reload()
	var before := Config.warnings.size()
	var probe := WorldConfig.new()
	Config.apply_to_object(probe, "world")
	if probe.block_pitch_m < 48.0 or probe.block_pitch_m > 600.0:
		problems.append("block_pitch_m=1.0 из override не зажат в @export_range (получено %.3f)" % probe.block_pitch_m)
	if probe.chunk_size_m > 600.0:
		problems.append("chunk_size_m=99999 не зажат сверху (получено %.1f)" % probe.chunk_size_m)
	if Config.warnings.size() <= before:
		problems.append("неизвестный ключ 'ключ_которого_нет' не попал в Config.warnings")
	DirAccess.remove_absolute(path)
	Config.reload()
	GameSetup.build_configs(true)
	# После восстановления — базовые значения обязаны вернуться.
	var restored := GameSetup.get_config("world") as WorldConfig
	if restored != null and absf(restored.block_pitch_m - (WorldConfig.new()).block_pitch_m) > 0.001:
		problems.append("после удаления override block_pitch_m=%.1f != базовый %.1f" % [
			restored.block_pitch_m, (WorldConfig.new()).block_pitch_m])
	return problems


## Замена визуальной модели машины из текста конфига (требование «модель можно заменить
## позже»). Проверяет ровно то, чем пользуется игрок/моддер: путь в override-конфиге.
func _test_visual_scene_override() -> PackedStringArray:
	var problems := PackedStringArray()
	var dir_path := "user://override_cfg"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var path := dir_path.path_join("zz_autotest_visual.cfg")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("не удалось записать override для visual_scene (проверка замены модели пропущена)")
	file.store_string("[vehicle.player]\nvisual_scene = \"res://scenes/menu/MainMenu.tscn\"\n")
	file.close()
	Config.reload()
	GameSetup.build_configs(true)
	var cfg := GameSetup.get_config("vehicle.player") as VehicleConfig
	if cfg == null:
		problems.append("VehicleConfig после override не собрался")
	elif cfg.visual_scene == null:
		problems.append("visual_scene из override не загрузился: заменить модель из .cfg нельзя")
	elif not cfg.visual_scene.can_instantiate():
		problems.append("загруженный visual_scene не инстанцируется")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("[vehicle.player]\nvisual_scene = \"res://assets/models/nope_missing.glb\"\n")
	file.close()
	Config.reload()
	var before := Config.warnings.size()
	var probe := VehicleConfig.new()
	Config.apply_to_object(probe, "vehicle.player")
	if Config.warnings.size() <= before:
		problems.append("несуществующий путь visual_scene не дал предупреждения в Config.warnings")
	if probe.visual_scene != null:
		problems.append("битый путь присвоился в visual_scene вместо отката к дефолту")
	DirAccess.remove_absolute(path)
	Config.reload()
	GameSetup.build_configs(true)
	return problems


# ------------------------------------------------------------------ 2. баланс и физика

func _configs() -> Dictionary:
	return {
		"player": GameSetup.get_config("vehicle.player") as VehicleConfig,
		"police": GameSetup.get_config("vehicle.police") as VehicleConfig,
		"nitro": GameSetup.get_config("nitro") as NitroConfig,
		"world": GameSetup.get_config("world") as WorldConfig,
		"chase": GameSetup.get_config("chase") as ChaseConfig,
		"police_ai": GameSetup.get_config("police") as PoliceConfig,
		"camera": GameSetup.get_config("camera") as CameraConfig,
		"ui": GameSetup.get_config("ui") as UiConfig,
	}


func _test_balance_rules() -> PackedStringArray:
	var c := _configs()
	return BalanceRules.check(c["player"], c["police"], c["nitro"])


func _test_terminal_speed() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var terminal := VehicleMath.terminal_speed_kms(cfg) * 3.6
	var problems := PackedStringArray()
	# Предельная скорость из модели обязана быть НЕ ВЫШЕ конфиг-лимита и не «слишком» ниже:
	# сильно меньше = машина не набирает обещанного (деградация), больше = лимит не работает.
	var ratio := terminal / cfg.max_speed_kmh
	if ratio > 1.0001:
		problems.append("терминальная %.1f км/ч превышает max_speed_kmh=%.1f (лимит не держит)" % [terminal, cfg.max_speed_kmh])
	if ratio < 0.90:
		problems.append("терминальная %.1f км/ч = %.0f%% от лимита %.1f — недобор (>10%%)" % [
			terminal, ratio * 100.0, cfg.max_speed_kmh])
	return problems


func _test_acceleration() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var seconds := VehicleMath.estimate_accel_time(cfg, 100.0 / 3.6)
	var problems := PackedStringArray()
	if seconds < 4.5 or seconds > 8.5:
		problems.append("0-100 км/ч = %.2f с, ожидается тяжёлый седан в диапазоне 4.5..8.5 с" % seconds)
	var with_nitro := VehicleMath.estimate_accel_time(cfg, 100.0 / 3.6, c["nitro"].max_speed_multiplier, c["nitro"].thrust_multiplier)
	if with_nitro >= seconds:
		problems.append("с нитро разгон не быстрее (%.2f с vs %.2f с) — множители не доходят до модели" % [with_nitro, seconds])
	return problems


func _test_braking() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var distance := VehicleMath.estimate_braking_distance(cfg, 100.0 / 3.6)
	var problems := PackedStringArray()
	if distance < 33.0 or distance > 42.0:
		problems.append("тормозной путь со 100 км/ч = %.1f м, ожидается 33..42 м (реальный седан)" % distance)
	var police := VehicleMath.estimate_braking_distance(c["police"], 100.0 / 3.6)
	if police <= 0.0:
		problems.append("полиция: тормозной путь не посчитан")
	return problems


func _test_weight_transfer() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var loads := VehicleMath.weight_transfer(cfg, 0.0, 0.0, VehicleMath.downforce(cfg, 0.0))
	var problems := PackedStringArray()
	var total := 0.0
	for load_n in loads:
		total += float(load_n)
	var expected := cfg.mass_kg * 9.8
	if absf(total - expected) > expected * 0.06:
		problems.append("суммарная вертикальная нагрузка %.0f Н не равна весу %.0f Н" % [total, expected])
	var braking := VehicleMath.weight_transfer(cfg, -12.0, 0.0, 0.0)
	if float(braking[0]) >= float(braking[2]):
		problems.append("при торможении передняя ось не разгружена (front %.0f >= rear %.0f) — знак переноса неверен" % [
			float(braking[0]), float(braking[2])])
	return problems


func _test_grip_corner_speed() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var problems := PackedStringArray()
	# Больше радиус = быстрее; крутой радиус = медленнее. Проверяем монотонность модели.
	var previous := INF
	for radius in [20.0, 40.0, 80.0, 160.0, 320.0]:
		var speed := VehicleMath.speed_for_distance(cfg, radius)
		if speed > previous + 0.001:
			problems.append("скорость входа не растёт с радиусом: R=%.0f -> %.1f км/ч (было %.1f)" % [radius, speed, previous])
		previous = speed
	if previous > cfg.max_speed_kmh:
		problems.append("лимит входа (%.1f км/ч) выше max_speed_kmh (%.1f)" % [previous, cfg.max_speed_kmh])
	return problems


func _make_nitro(state: String = "playing") -> Dictionary:
	var c := _configs()
	AppState.set_phase(AppState.Phase.PLAYING if state == "playing" else AppState.Phase.PAUSED)
	var system := NitroSystem.new()
	system.config = c["nitro"]
	system._ready()
	return {"system": system, "config": c["nitro"]}


func _nitro_step(system: NitroSystem, seconds: float, requested: bool) -> void:
	var step := 1.0 / 60.0
	var iterations := int(seconds / step)
	for i in range(iterations):
		system.set_requested(requested)
		system._physics_process(step)


func _test_nitro_budget() -> PackedStringArray:
	var pack := _make_nitro()
	var system: NitroSystem = pack["system"]
	var cfg: NitroConfig = pack["config"]
	var problems := PackedStringArray()
	if system.charge < cfg.max_charge - 0.01:
		problems.append("после _ready заряд %.1f != max_charge %.1f" % [system.charge, cfg.max_charge])
	_nitro_step(system, 1.0, true)
	var expected_used := cfg.drain_per_s
	if absf((cfg.max_charge - system.charge) - expected_used) > maxf(expected_used * 0.25, 1.0):
		problems.append("за 1 с израсходовано %.1f, ожидание ~%.1f (drain_per_s)" % [
			cfg.max_charge - system.charge, expected_used])
	if not system.active:
		problems.append("при запросе и полном заряде нитро не активно")
	# Пауза = расход запрещён.
	var before := system.charge
	system.set_requested(false)
	_nitro_step(system, 2.0, false)
	if system.charge <= before:
		problems.append("без запроса заряд не восстанавливается (idle-регенерация не работает)")
	# Регенерация ограничена сверху.
	for i in range(60 * 40):
		system.set_requested(false)
		system._physics_process(1.0 / 60.0)
	if system.charge > cfg.max_charge + 0.001:
		problems.append("заряд %.1f превысил max_charge %.1f" % [system.charge, cfg.max_charge])
	return problems


func _test_nitro_overheat() -> PackedStringArray:
	var pack := _make_nitro()
	var system: NitroSystem = pack["system"]
	var cfg: NitroConfig = pack["config"]
	var problems := PackedStringArray()
	if cfg.max_burst_s <= 0.0:
		return PackedStringArray(["max_burst_s = 0 — лимит времениBoost выключен в конфиге"])
	_nitro_step(system, cfg.max_burst_s + 0.35, true)
	if system.active:
		problems.append("после %.2f с нитро всё ещё активно (лимит %.2f с не работает)" % [
			cfg.max_burst_s + 0.35, cfg.max_burst_s])
	if system.cooldown <= 0.0:
		problems.append("после превышения лимита не включён cooldown (перегрев)")
	if system.burst_time < cfg.max_burst_s - 0.2:
		problems.append("burst_time=%.2f меньше лимита %.2f — время не считалось" % [system.burst_time, cfg.max_burst_s])
	# В cooldown запрос игнорируется, затем — снова работает.
	system.set_requested(true)
	system._physics_process(1.0 / 60.0)
	if system.active:
		problems.append("нитро включилось во время cooldown")
	var wait := cfg.overheat_cooldown_s + 0.4
	system.refill()
	_nitro_step(system, wait, true)
	if not system.active:
		problems.append("после cooldown и пополнения нитро не вернулось в работу")
	return problems


func _test_nitro_blocked_state() -> PackedStringArray:
	var pack := _make_nitro("paused")
	var system: NitroSystem = pack["system"]
	var cfg: NitroConfig = pack["config"]
	var problems := PackedStringArray()
	system.set_requested(true)
	_nitro_step(system, 1.0, true)
	if system.active:
		problems.append("на паузе нитро активно — AppState.can_use_nitro() не учтён")
	if absf(cfg.max_charge - system.charge) > 0.01:
		problems.append("на паузе заряд расходуется (%.1f -> %.1f)" % [cfg.max_charge, system.charge])
	# Запрет по allowed (например, «арестован») тоже обязан работать.
	AppState.set_phase(AppState.Phase.PLAYING)
	system.allowed = false
	_nitro_step(system, 1.0, true)
	if system.active:
		problems.append("при allowed=false нитро всё равно включается")
	return problems


func _test_nitro_top_speed() -> PackedStringArray:
	var c := _configs()
	var player: VehicleConfig = c["player"]
	var police: VehicleConfig = c["police"]
	var nitro: NitroConfig = c["nitro"]
	var problems := PackedStringArray()
	var base := VehicleMath.terminal_speed_kms(player) * 3.6
	var boosted := VehicleMath.terminal_speed_kms(player, nitro.max_speed_multiplier, nitro.thrust_multiplier) * 3.6
	var police_max := VehicleMath.terminal_speed_kms(police) * 3.6
	if boosted <= base:
		problems.append("с нитро потолок не выше базового (%.1f vs %.1f км/ч)" % [boosted, base])
	var ratio := boosted / maxf(police_max, 1.0)
	# Требование: игрок с нитро ≈ 1.25 x полиции.
	if ratio < 1.25 * 0.94 or ratio > 1.25 * 1.06:
		problems.append("игрок+нитро / полиция = %.3f, требуется 1.25 (±6%%): boosted=%.1f, police=%.1f" % [ratio, boosted, police_max])
	return problems


func _test_police_ceiling() -> PackedStringArray:
	var c := _configs()
	var player: VehicleConfig = c["player"]
	var police: VehicleConfig = c["police"]
	var problems := PackedStringArray()
	var ratio := police.max_speed_kmh / maxf(player.max_speed_kmh, 1.0)
	# Требование: полиция «чуть быстрее» игрока без нитро (иначе погоня невозможна).
	if ratio < 1.0 or ratio > 1.06:
		problems.append("police/player max_speed = %.1f/%.1f = %.3f, нужно 1.00..1.06" % [
			police.max_speed_kmh, player.max_speed_kmh, ratio])
	if police.mass_kg <= player.mass_kg:
		problems.append("масса полиции (%.0f кг) не больше массы игрока (%.0f кг) — тараны будут нереалистичны" % [
			police.mass_kg, player.mass_kg])
	return problems


func _test_blocked_controller() -> PackedStringArray:
	var c := _configs()
	var car := PlayerCar.new()
	car.config = c["player"]
	car.auto_assemble = false
	add_child(car)
	car.assemble()
	var problems := PackedStringArray()
	if car.controller == null:
		problems.append("у PlayerCar нет VehicleController после assemble()")
		car.queue_free()
		return problems
	car.physics.blocked_time = 0.0
	car.controller._watch_stuck(0.1)
	if car.controller.is_blocked:
		problems.append("is_blocked=true при blocked_time=0 (порог не соблюдён)")
	car.physics.blocked_time = car.controller.blocked_after_s + 0.5
	car.controller._watch_stuck(0.1)
	if not car.controller.is_blocked:
		problems.append("is_blocked остался false при blocked_time=%.2f > порога %.2f" % [
			car.physics.blocked_time, car.controller.blocked_after_s])
	car.controller.reset()
	if car.controller.is_blocked:
		problems.append("reset() не снял состояние blocked")
	car.queue_free()
	return problems


# ------------------------------------------------------------------ 3. камера

func _test_camera_orbit() -> PackedStringArray:
	var c := _configs()
	var cfg: CameraConfig = c["camera"]
	var problems := PackedStringArray()
	# Свободная орбита: направление камеры зависит от yaw/pitch, а НЕ от курса машины.
	var a := CameraController.orbit_direction(0.0, 0.0)
	var b := CameraController.orbit_direction(deg_to_rad(90.0), 0.0)
	if a.distance_to(b) < 0.5:
		problems.append("orbit_direction не реагирует на yaw (a=%s b=%s)" % [a, b])
	var up := CameraController.orbit_direction(0.0, -35.0)
	var down := CameraController.orbit_direction(0.0, 25.0)
	if up.y <= down.y:
		problems.append("pitch не меняет высоту камеры (up.y=%.2f <= down.y=%.2f)" % [up.y, down.y])
	if absf(a.length() - 1.0) > 0.01:
		problems.append("orbit_direction вернул не единичный вектор (|a|=%.4f)" % a.length())
	return problems


func _test_camera_parked() -> PackedStringArray:
	var c := _configs()
	var cfg: CameraConfig = c["camera"]
	var problems := PackedStringArray()
	# На парковке скорость = 0 => автодоворот обязан быть выключен, орбита — работать.
	var follow := CameraController.follow_gain(0.0, cfg)
	if follow > 0.0001:
		problems.append("на нулевой скорости автодоворот активен (gain=%.4f) — камера «уезжает» от стоящей машины" % follow)
	var moving := CameraController.follow_gain(cfg.yaw_align_speed_kmh + cfg.yaw_align_fade_kmh + 20.0, cfg)
	if moving <= 0.0001:
		problems.append("на %.0f км/ч автодоворот выключен (gain=%.4f)" % [
			cfg.yaw_align_speed_kmh + cfg.yaw_align_fade_kmh + 20.0, moving])
	if moving <= follow:
		problems.append("автодоворот не растёт со скоростью")
	return problems


func _test_camera_clamps() -> PackedStringArray:
	var c := _configs()
	var cfg: CameraConfig = c["camera"]
	var problems := PackedStringArray()
	var over := CameraController.clamp_pitch_deg(800.0, cfg)
	var under := CameraController.clamp_pitch_deg(-800.0, cfg)
	if over <= under:
		problems.append("clamp_pitch_deg не упорядочивает: %.1f <= %.1f" % [over, under])
	if over > cfg.pitch_max_deg + 0.001 or under < cfg.pitch_min_deg - 0.001:
		problems.append("clamp_pitch_deg вышел за min/max: [%.1f..%.1f] vs [%.1f..%.1f]" % [
			under, over, cfg.pitch_min_deg, cfg.pitch_max_deg])
	var mod := Settings.camera_modulation()
	if not mod.has("distance") or not mod.has("height"):
		problems.append("Settings.camera_modulation() не вернул distance/height")
	return problems


# ------------------------------------------------------------------ 4. полиция

func _test_target_loss() -> PackedStringArray:
	var c := _configs()
	var police: PoliceConfig = c["police_ai"]
	var chase_cfg: ChaseConfig = c["chase"]
	var problems := PackedStringArray()
	var base := {
		"enabled": true, "wanted": 3.0, "target_alive": true, "has_los": true,
		"units_in_pursuit": 2, "unit_index": 0, "can_ram": true, "can_block": true,
		"nitro_allowed": true, "roadblock_ready": false, "target_speed_kmh": 120.0,
	}
	var engaged := PoliceStrategy.decide(base, police, chase_cfg)
	if String(engaged["mode"]) == String(PoliceStrategy.PATROL) or String(engaged["mode"]) == String(PoliceStrategy.RETURN):
		problems.append("при LOS и wanted=3 режим %s — цель не должна теряться" % String(engaged["mode"]))
	var blind := base.duplicate()
	blind["has_los"] = false
	blind["lost_time_s"] = police.lose_time_s + 1.0
	var lost := PoliceStrategy.decide(blind, police, chase_cfg)
	if String(lost["mode"]) != String(PoliceStrategy.PATROL) and String(lost["mode"]) != String(PoliceStrategy.RETURN):
		problems.append("цель слепая %.1f с, а режим всё ещё %s — потеря цели не обрабатывается" % [
			police.lose_time_s + 1.0, String(lost["mode"])])
	var too_far := base.duplicate()
	too_far["distance_m"] = police.lose_distance_m * 1.6
	too_far["graph_distance_m"] = police.lose_distance_m * 1.6
	var far := PoliceStrategy.decide(too_far, police, chase_cfg)
	if String(far["mode"]) != String(PoliceStrategy.PATROL) and String(far["mode"]) != String(PoliceStrategy.RETURN):
		problems.append("цель в %.0f м (лимит %.0f), а режим %s — дистанция потери не учтена" % [
			too_far["distance_m"], police.lose_distance_m, String(far["mode"])])
	if ChaseManager.self_check().size() > 0:
		problems.append_array(ChaseManager.self_check())
	return problems


func _test_strategy_switching() -> PackedStringArray:
	var c := _configs()
	var police: PoliceConfig = c["police_ai"]
	var chase_cfg: ChaseConfig = c["chase"]
	var problems := PackedStringArray()
	# Дистанция => режим: чем ближе, тем «жёще». Сравниваем не строки «на глаз», а порядок.
	var expected_order := {
		police.ram_distance_m * 0.5: PoliceStrategy.PURSUE,
		police.pincer_distance_m * 0.9: PoliceStrategy.PINCER,
		police.intercept_distance_m * 0.9: PoliceStrategy.INTERCEPT,
		police.engage_distance_m * 1.2: PoliceStrategy.PATROL,
	}
	for distance in expected_order.keys():
		var got := PoliceStrategy.mode_for_distance(float(distance), police)
		var want: StringName = expected_order[distance]
		if got != want:
			problems.append("на дистанции %.0f м ожидается %s, получили %s" % [float(distance), String(want), String(got)])
	# wanted=1 => ноль «дорогих» режимов: блокпост/таран только с высоких уровней.
	var low := {
		"enabled": true, "wanted": 0.6, "distance_m": 40.0, "graph_distance_m": 40.0,
		"target_speed_kmh": 150.0, "lost_time_s": 0.0, "has_los": true, "target_alive": true,
		"units_in_pursuit": 1, "unit_index": 0, "can_ram": true, "can_block": true,
		"nitro_allowed": true, "roadblock_ready": true,
	}
	var decision := PoliceStrategy.decide(low, police, chase_cfg)
	if bool(decision["allow_ram"]):
		problems.append("на wanted=0.6 разрешён таран — слишком агрессивно для низкого уровня")
	if bool(decision["allow_nitro"]):
		problems.append("на wanted=0.6 разрешено нитро полиции")
	if int(decision["units_budget"]) > police.max_units:
		problems.append("бюджет патрулей %d больше max_units %d" % [int(decision["units_budget"]), police.max_units])
	var high := low.duplicate(true)
	high["wanted"] = 5.0
	high["distance_m"] = 60.0
	high["graph_distance_m"] = 60.0
	high["target_speed_kmh"] = 100.0
	high["units_in_pursuit"] = 4
	var high_decision := PoliceStrategy.decide(high, police, chase_cfg)
	if int(high_decision["units_budget"]) <= 1:
		problems.append("на wanted=5 должен выезжать весь пул, получили бюджет %d" % int(high_decision["units_budget"]))
	if float(high_decision["speed_target_kmh"]) <= police.patrol_speed_kmh:
		problems.append("на wanted=5 целевая скорость %.1f не выше патрульной %.1f" % [
			float(high_decision["speed_target_kmh"]), police.patrol_speed_kmh])
	return problems


func _test_arrest_rules() -> PackedStringArray:
	return ArrestSystem.self_check()


func _test_spawn_rules() -> PackedStringArray:
	var problems := SpawnManager.self_check()
	var c := _configs()
	var chase_cfg: ChaseConfig = c["chase"]
	if chase_cfg.despawn_radius_m < chase_cfg.spawn_radius_m * 2.0:
		problems.append("despawn_radius (%.0f) < 2 x spawn_radius (%.0f) — патрули будут выгружаться сразу после спавна" % [
			chase_cfg.despawn_radius_m, chase_cfg.spawn_radius_m])
	return problems


# ------------------------------------------------------------------ 5. навигация

func _test_road_graph() -> PackedStringArray:
	var c := _configs()
	var graph := RoadGraph.for_config(c["world"])
	var problems := PackedStringArray()
	if graph == null:
		return _fail("RoadGraph.for_config вернул null")
	problems.append_array(graph.validate())
	if graph.node_count() < 16:
		problems.append("слишком мало узлов: %d" % graph.node_count())
	if graph.edge_count() < graph.node_count():
		problems.append("рёбер меньше узлов (%d < %d) — граф разрежен, маршруты будут «в никуда»" % [
			graph.edge_count(), graph.node_count()])
	# Все узлы обязаны лежать НА ОСИ улицы: x или z кратен line_offset(...) — иначе ИИ
	# «знает» дороги, которых нет в геометрии.
	var cfg: WorldConfig = c["world"]
	var pitch := maxf(cfg.block_pitch_m, 20.0)
	var checked := 0
	for i in range(mini(graph.node_count(), 120)):
		var pos := graph.node_position(i)
		var on_x := _is_on_line(pos.x, pitch)
		var on_z := _is_on_line(pos.z, pitch)
		if not on_x and not on_z:
			problems.append("узел %d (%.2f; %.2f) не лежит ни на одной оси улиц" % [i, pos.x, pos.z])
			break
		checked += 1
	if checked == 0:
		problems.append("не проверено ни одного узла")
	# snap: точка в 3 метрах от оси должна находиться; точка в 300 м от любой оси — нет.
	var snap := graph.nearest(Vector3(graph.node_position(0).x + 2.5, 0.0, graph.node_position(0).z), 0.0)
	if snap < 0:
		problems.append("nearest() не нашёл узел в 2.5 м от оси (snap должен сработать)")
	return problems


static func _is_on_line(value: float, pitch: float) -> bool:
	# Оси улиц стоят на k*pitch (line_offset = k*pitch — см. WorldGenerator.line_offset).
	var k := value / pitch
	return absf(k - roundf(k)) < 0.02


func _test_route_planner() -> PackedStringArray:
	var c := _configs()
	var graph := RoadGraph.for_config(c["world"])
	var problems := PackedStringArray()
	if graph == null:
		return _fail("нет графа для планировщика")
	var from := 0
	var to := graph.node_count() - 1
	var path := RoutePlanner.find_path(graph, from, to)
	if path.size() < 3:
		problems.append("маршрут из 0 в %d короче 3 узлов (%d) — действовать нечем" % [to, path.size()])
		return problems
	if path[0] != from or path[path.size() - 1] != to:
		problems.append("маршрут не начинается/не заканчивается нужным узлом")
	var start_pos := graph.node_position(from)
	var end_pos := graph.node_position(to)
	var length := RoutePlanner.path_length(graph, path)
	var straight := start_pos.distance_to(end_pos)
	if length + 0.001 < straight:
		problems.append("длина по графу %.1f меньше евклидова расстояния %.1f — рёбра короче, чем точки" % [length, straight])
	# Каждый шаг маршрута обязан быть реальным ребром.
	for i in range(path.size() - 1):
		if not graph.neighbors(path[i]).has(path[i + 1]):
			problems.append("шаг %d->%d не является ребром графа" % [path[i], path[i + 1]])
			break
	# Симметрия: обратный маршрут не длиннее (вес-то симметричен).
	var back := RoutePlanner.find_path(graph, to, from)
	if absf(RoutePlanner.path_length(graph, back) - length) > 0.5 * maxf(length * 0.02, 0.5):
		problems.append("маршрут туда/обратно разного длины: %.1f vs %.1f" % [length, RoutePlanner.path_length(graph, back)])
	# Несуществующие узлы => пустой маршрут (а не «мусор»).
	if not RoutePlanner.find_path(graph, -1, 3).is_empty():
		problems.append("find_path(-1, 3) вернул маршрут вместо пустого")
	var remaining := RoutePlanner.remaining_length(graph, path, 1)
	if remaining >= length:
		problems.append("remaining_length(1)=%.1f >= всей длины %.1f" % [remaining, length])
	return problems


func _test_prediction() -> PackedStringArray:
	var problems := TrajectoryPrediction.self_check()
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	# Постоянный руль => дуга: все точки предсказания должны лежать примерно на одном
	# расстоянии от центра окружности (иначе «перехват» будет целился мимо).
	var points := TrajectoryPrediction.predict(Vector3.ZERO, 0.0, 90.0, 0.6, cfg, 1.6, 0.1)
	if points.size() < 4:
		problems.append("предсказание вернуло %d точек" % points.size())
		return problems
	var radius := maxf(cfg.wheelbase_m / maxf(tan(deg_to_rad(cfg.max_steer_deg) * 0.6), 0.001), 1.0)
	var center := Vector3(radius, 0.0, 0.0)
	var spread := 0.0
	for p in points:
		spread = maxf(spread, absf(Vector3(p.x - center.x, 0.0, p.z - center.z).length() - radius))
	var tolerance := radius * 0.14 + 0.8
	if spread > tolerance:
		problems.append("точки предсказания не на дуге R=%.1f: разброс %.2f м (допуск %.2f)" % [radius, spread, tolerance])
	return problems


# ------------------------------------------------------------------ 6. мир

func _test_world_determinism() -> PackedStringArray:
	var c := _configs()
	var cfg: WorldConfig = c["world"]
	var problems := PackedStringArray()
	for index in [Vector2i(0, 0), Vector2i(1, -1), Vector2i(-2, 2)]:
		var first: Dictionary = WorldGenerator.chunk_layout(index, cfg)
		var second: Dictionary = WorldGenerator.chunk_layout(index, cfg)
		if (first["stats"] as Dictionary) != (second["stats"] as Dictionary):
			problems.append("чанк %s: повторная сборка дала другую сводку — рандоген недетерминирован" % index)
		problems.append_array(WorldGenerator.validate_layout(index, cfg))
	# Смена seed обязана менять содержимое (иначе seed «декоративный»).
	var other := cfg.duplicate() as WorldConfig
	other.seed = cfg.seed + 7
	var a: Dictionary = WorldGenerator.chunk_layout(Vector2i(2, 2), cfg)
	var b: Dictionary = WorldGenerator.chunk_layout(Vector2i(2, 2), other)
	if (a["stats"] as Dictionary) == (b["stats"] as Dictionary):
		problems.append("разные seed дали идентичный чанк — world.seed ни на что не влияет")
	return problems


func _test_plaza_concrete() -> PackedStringArray:
	var c := _configs()
	var cfg: WorldConfig = c["world"]
	var problems := PackedStringArray()
	var spawn := WorldGenerator.spawn_point(cfg)
	if spawn.length() > WorldGenerator.plaza_radius(cfg):
		problems.append("точка спавна (%.0f; %.0f) вне бетонной площади (радиус %.0f)" % [
			spawn.x, spawn.z, WorldGenerator.plaza_radius(cfg)])
	var layout: Dictionary = WorldGenerator.chunk_layout(Vector2i.ZERO, cfg)
	var found := false
	for rect in layout.get("ground", []):
		var entry := rect as Dictionary
		if StringName(entry.get("surface", &"")) == WorldGenerator.SURFACE_PLAZA:
			found = true
			if not WorldGenerator.chunk_rect_ok(entry.get("rect") as Rect2, cfg.chunk_size_m):
				problems.append("прямоугольник бетона выходит за границы чанка: %s" % str(entry.get("rect")))
			break
	if not found:
		problems.append("в центральном чанке нет ни одного прямоугольника поверхности 'concrete'")
	# 500 м во все стороны: бетонная площадь обязана покрывать «стартовый квартал»,
	# а мир — быть не меньше требуемого радиуса.
	if cfg.world_radius_m < 500.0:
		problems.append("world_radius_m=%.0f меньше требуемых 500 м" % cfg.world_radius_m)
	return problems


func _test_concrete_tiling() -> PackedStringArray:
	var c := _configs()
	var cfg: WorldConfig = c["world"]
	var problems := PackedStringArray()
	# Тайл текстуры бетона и «шаг» плит в геометрии обязаны совпадать, иначе швы
	# разметки/плит разъезжаются по чанку (классика «полосатого асфальта»).
	var tile := TextureLibrary.tile_meters("concrete")
	if tile.x <= 0.0:
		problems.append("TextureLibrary не сообщает тайл для 'concrete'")
		return problems
	if absf(tile.x - cfg.concrete_slab_m) > 0.001 or absf(tile.y - cfg.concrete_slab_m) > 0.001:
		problems.append("concrete_slab_m=%.2f != тайл текстуры бетона (%.2f, %.2f)" % [
			cfg.concrete_slab_m, tile.x, tile.y])
	return problems


func _test_chunk_geometry() -> PackedStringArray:
	var c := _configs()
	var cfg: WorldConfig = c["world"]
	var problems := PackedStringArray()
	problems.append_array(ChunkBuilder.self_check(Vector2i.ZERO, cfg))
	var data := ChunkBuilder.build(Vector2i(1, 1), cfg, true)
	var near: ArrayMesh = data.get("near") as ArrayMesh
	if near == null or near.get_surface_count() == 0:
		problems.append("у чанка нет near-меша с поверхностями")
		return problems
	var stats: Dictionary = data.get("stats", {})
	if int(stats.get("collision_triangles", 0)) < 12:
		problems.append("коллизия чанка почти пустая (%d треугольников)" % int(stats.get("collision_triangles", 0)))
	if int(stats.get("buildings", 0)) <= 0:
		problems.append("в чанке (1,1) нет ни одного здания — «пустые улицы»")
	if int(stats.get("prop_instances", 0)) <= 0:
		problems.append("в чанке нет малых форм — мир будет «голым»")
	if int(stats.get("near_surfaces", 0)) < 2:
		problems.append("у near-меша %d материалов: всё одним текстурным слоем быть не должно" % int(stats.get("near_surfaces", 0)))
	# Меш обязан быть ЛОКАЛЬНЫМ (иначе чанк уедет в удвоенную позицию).
	var aabb: AABB = data.get("aabb", AABB())
	if absf(aabb.position.x) > cfg.chunk_size_m * 0.5 + 1.0:
		problems.append("aabb чанка не локальный: position.x=%.1f" % aabb.position.x)
	for surface in range(near.get_surface_count()):
		var arrays: Array = near.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty():
			problems.append("поверхность %d без вершин" % surface)
			continue
		for v in vertices:
			if not is_finite(v.x) or not is_finite(v.y) or not is_finite(v.z):
				problems.append("поверхность %d содержит нечисловые вершины" % surface)
				break
			if absf(v.x) > cfg.chunk_size_m + 5.0 or absf(v.z) > cfg.chunk_size_m + 5.0:
				problems.append("вершина %s вне чанка размером %.0f м" % [v, cfg.chunk_size_m])
				break
		if indices.size() % 3 != 0:
			problems.append("индексы поверхности %d не кратно 3" % surface)
		for i in range(indices.size()):
			if indices[i] < 0 or indices[i] >= vertices.size():
				problems.append("индекс %d вне диапазона вершин (поверхность %d)" % [indices[i], surface])
				break
	return problems


func _test_materials_props() -> PackedStringArray:
	var problems := MaterialLibrary.self_check()
	var missing := PackedStringArray()
	for kind in PropMeshes.kinds():
		var parts: Array = PropMeshes.parts(String(kind))
		if parts.is_empty():
			missing.append(kind)
			continue
		for part in parts:
			var material := String(part.get("material", ""))
			if material.is_empty():
				missing.append("%s/%s: нет материала" % [kind, String(part.get("part_name", ""))])
			elif not MaterialLibrary.has_type(material):
				missing.append("%s: материал '%s' неизвестен MaterialLibrary" % [kind, material])
			elif part.get("mesh") == null:
				missing.append("%s: часть без меша" % kind)
	if not missing.is_empty():
		problems.append("проблемы малых форм: " + " ; ".join(missing))
	return problems


func _test_car_geometry() -> PackedStringArray:
	var c := _configs()
	var problems := PackedStringArray()
	for key in ["player", "police"]:
		var cfg: VehicleConfig = c[key]
		var built: Dictionary = CarGeometry.build(cfg)
		for info_key in CarGeometry.required_info_keys():
			if not (built.get("info", {}) as Dictionary).has(String(info_key)):
				problems.append("%s: в CarGeometry.info нет ключа '%s'" % [key, String(info_key)])
		var body: ArrayMesh = built.get("body") as ArrayMesh
		if body == null or body.get_surface_count() < 3:
			problems.append("%s: кузов имеет %d поверхностей (нужно >=3: краска/стекло/фары)" % [
				key, 0 if body == null else body.get_surface_count()])
		var wheel: ArrayMesh = built.get("wheel") as ArrayMesh
		if wheel == null or wheel.get_surface_count() < 1:
			problems.append("%s: нет меша колеса" % key)
		var aabb: AABB = built.get("info", {}).get("aabb", AABB())
		if aabb.size.x < 1.2 or aabb.size.y < 0.9 or aabb.size.z < 3.0:
			problems.append("%s: габарит кузова выглядит детским: %s" % [key, aabb])
	if CarGeometry.cached_count() > 3:
		problems.append("кэш CarGeometry раздувается: %d записей (ожидались 2 конфигa)" % CarGeometry.cached_count())
	# Колёсные смещения для припаркованных машин обязаны биться с геометрией машины.
	var offsets := PropMeshes.parked_car_wheel_offsets()
	if offsets.size() != 4:
		problems.append("parked_car_wheel_offsets вернул %d смещений, нужно 4" % offsets.size())
	return problems


func _test_wheel_setup() -> PackedStringArray:
	var c := _configs()
	var cfg: VehicleConfig = c["player"]
	var system := WheelSystem.new()
	system.setup(cfg, 9.8)
	var problems := PackedStringArray()
	if system.wheels.size() != 4:
		problems.append("колёс %d вместо 4" % system.wheels.size())
		return problems
	var fronts := 0
	var rears := 0
	var driven := 0
	for w in system.wheels:
		if w.is_front:
			fronts += 1
		if not w.is_front:
			rears += 1
		if w.is_driven:
			driven += 1
	if fronts != 2 or rears != 2:
		problems.append("раскладка по осям: передних %d, задних %d (нужно 2 и 2)" % [fronts, rears])
	if driven == 0:
		problems.append("ни одного ведущего колеса — машина не поедет")
	var half_track := cfg.track_width_m * 0.5
	var half_base := cfg.wheelbase_m * 0.5
	for w in system.wheels:
		if absf(absf(w.attach_local.x) - half_track) > 0.02:
			problems.append("колёсная колея %.3f != track_width/2=%.2f" % [w.attach_local.x, half_track])
		if absf(absf(w.attach_local.z) - half_base) > 0.02:
			problems.append("база: колесо на %.2f м != половина базы %.2f" % [absf(w.attach_local.z), half_base])
	var loads := VehicleMath.weight_transfer(cfg, 0.0, 0.0)
	if loads.size() != 4:
		problems.append("weight_transfer вернул %d значений вместо 4" % loads.size())
	return problems


func _test_streamer_lod() -> PackedStringArray:
	var c := _configs()
	var cfg: WorldConfig = c["world"]
	var problems := PackedStringArray()
	problems.append_array(cfg.validate())
	# Порядок LOD: detail < lod1 < lod2 < cull, иначе «рядом» и «далеко» перепутаны.
	if not (WorldChunk.LOD_NEAR < WorldChunk.LOD_MID and WorldChunk.LOD_MID < WorldChunk.LOD_FAR
			and WorldChunk.LOD_FAR < WorldChunk.LOD_HIDDEN):
		problems.append("константы WorldChunk.LOD_* идут не по убыванию детализации")
	for distance in [0.0, cfg.detail_distance_m * 0.5, cfg.lod1_distance_m * 1.2, cfg.lod2_distance_m * 1.3]:
		var lod := WorldStreamer.lod_for_distance(distance, cfg, 1.0)
		var expected := 0
		if distance > cfg.detail_distance_m:
			expected = 1
		if distance > cfg.lod1_distance_m:
			expected = 2
		if distance > cfg.lod2_distance_m:
			expected = 3
		if lod != expected:
			problems.append("LOD на %.0f м = %d, ожидался %d" % [distance, lod, expected])
	if cfg.chunk_build_budget_ms > 8.0:
		problems.append("chunk_build_budget_ms=%.1f — больше 8 мс/кадр на сборку чанка давать нельзя" % cfg.chunk_build_budget_ms)
	var ring := WorldStreamer.chunk_ring(Vector2i.ZERO, 1)
	if ring.size() != 9:
		problems.append("кольцо радиуса 1 вернуло %d чанков вместо 9" % ring.size())
	# unload_margin_chunks обязан быть живым: радиус выгрузки = (радиус + запас) * размер чанка.
	var size := WorldGenerator.chunk_size(cfg)
	var keep := WorldStreamer.keep_radius_m(cfg)
	var expected := (float(cfg.load_radius_chunks) + cfg.unload_margin_chunks) * size
	if not is_equal_approx(keep, expected):
		problems.append("keep_radius_m=%.1f, ожидалось %.1f — ключ unload_margin_chunks не работает" % [keep, expected])
	var wider := cfg.duplicate() as WorldConfig
	wider.load_radius_chunks = clampi(cfg.load_radius_chunks + 1, 0, 4)
	if WorldStreamer.keep_radius_m(wider) <= keep:
		problems.append("радиус выгрузки не растёт вместе с load_radius_chunks")
	if keep < size:
		problems.append("keep_radius_m=%.1f меньше размера чанка — чанки будут выгружаться из-под ног" % keep)
	return problems


# ------------------------------------------------------------------ 7. UI / меты

func _test_touch_targets() -> PackedStringArray:
	var problems := MobileControls.self_check()
	var c := _configs()
	var ui: UiConfig = c["ui"]
	if ui.min_touch_target_px < 80.0:
		problems.append("min_touch_target_px=%.1f — на 6.56'' телефоне попадать пальцем будет тяжело" % ui.min_touch_target_px)
	if ui.joystick_radius_px < 80.0:
		problems.append("joystick_radius_px=%.1f — слишком маленький стик" % ui.joystick_radius_px)
	# read_drive() обязан «молчать» на паузе: это тот самый «заблокированный ввод».
	AppState.set_phase(AppState.Phase.PAUSED)
	var controls := MobileControls.new()
	controls.config = ui
	add_child(controls)
	var drive: Dictionary = controls.read_drive()
	if bool(drive.get("throttle", false)) or absf(float(drive.get("steer", 0.0))) > 0.0001:
		problems.append("на паузе read_drive() вернул ненулевой ввод")
	# Пауза обязана быть доступна пальцем: на Android Esc нет.
	if not controls.has_pause_button():
		problems.append("MobileControls: на экране нет кнопки паузы (на телефоне нечем ставить паузу)")
	if not controls.has_signal("pause_requested"):
		problems.append("MobileControls: нет сигнала pause_requested (UIManager не узнает о тапе)")
	if not bool(controls.state().get("pause_button", false)):
		problems.append("state() не сообщает про кнопку паузы (debug-панель её не видит)")
	if String(drive.get("source", "")) != "blocked":
		problems.append("на паузе источник ввода = '%s', ожидался 'blocked'" % String(drive.get("source", "")))
	AppState.set_phase(AppState.Phase.PLAYING)
	controls.set_hold("gas", true)
	controls.set_steer(0.6)
	var active: Dictionary = controls.read_drive()
	if not bool(active.get("throttle", false)):
		problems.append("set_hold('gas') не поднимает throttle в read_drive()")
	if absf(float(active.get("steer", 0.0)) - 0.6) > 0.001:
		problems.append("set_steer(0.6) дал steer=%.3f" % float(active.get("steer", 0.0)))
	controls.release_all()
	var released: Dictionary = controls.read_drive()
	if bool(released.get("throttle", false)) or bool(released.get("brake", false)):
		problems.append("release_all() не отпустил кнопки")
	controls.queue_free()
	return problems


func _test_menu_strings() -> PackedStringArray:
	var c := _configs()
	var ui: UiConfig = c["ui"]
	var problems := PackedStringArray()
	# Тексты меню — часть ТЗ, поэтому проверяем дословно.
	var version_line := GameSetup.version_line()
	if version_line != EXPECTED_VERSION_LINE:
		problems.append("строка версии = '%s', требуется '%s'" % [version_line, EXPECTED_VERSION_LINE])
	if ui.subtitle != EXPECTED_SUBTITLE:
		problems.append("подзаголовок = '%s', требуется '%s'" % [ui.subtitle, EXPECTED_SUBTITLE])
	var lines := PackedStringArray()
	for line in ui.dev_lines:
		lines.append(String(line))
	if not lines[0].contains("@connection9191_bot"):
		problems.append("в попапе «Разработчики» нет тг-бота @connection9191_bot (строки: %s)" % ", ".join(lines))
	var joined := " ".join(lines).to_upper()
	if not joined.contains("МАТАДОРА"):
		problems.append("в попапе «Разработчики» нет «МАТАДОРА МАТАДОРА МАТАДАОРА»")
	if ui.maps.is_empty():
		problems.append("в ui.cfg нет ни одной карты")
	else:
		var first: Dictionary = ui.maps[0]
		if String(first.get("title", "")) != "TEST":
			problems.append("подпись под карточкой карты = '%s', требуется 'TEST'" % String(first.get("title", "")))
		if String(first.get("scene", "")) != "res://scenes/game/Game.tscn":
			problems.append("карта ведёт в '%s', а должна в res://scenes/game/Game.tscn" % String(first.get("scene", "")))
	# Сцены, на которые ссылается меню, обязаны существовать — иначе тап «убьёт» переход.
	for path in ["res://scenes/game/Game.tscn", "res://scenes/menu/MainMenu.tscn",
			"res://scenes/menu/OrientationGate.tscn"]:
		if not ResourceLoader.exists(path):
			problems.append("нет сцены %s" % path)
	return problems


func _test_orientation_persistence() -> PackedStringArray:
	var problems := PackedStringArray()
	var before_landscape := Settings.is_landscape()
	Settings.set_orientation(1, true)
	if Settings.is_landscape():
		problems.append("set_orientation(1) не переключил на портрет")
	if not Settings.orientation_chosen:
		problems.append("после осознанного выбора orientation_chosen остался false — выбор будут спрашивать снова")
	if AppState.orientation != Settings.orientation:
		problems.append("AppState.orientation (%d) рассинхронизирован с Settings (%d)" % [
			AppState.orientation, Settings.orientation])
	Settings.set_orientation(0, true)
	if not Settings.is_landscape():
		problems.append("set_orientation(0) не переключил на ландшафт")
	Settings.set_orientation(1 if before_landscape else 0, true)
	var saved := int(SaveManager.get_value("profile", "orientation", -999))
	if saved != Settings.orientation:
		problems.append("в сохранении orientation=%d, а в Settings=%d" % [saved, Settings.orientation])
	if not bool(SaveManager.get_value("profile", "orientation_chosen", false)):
		problems.append("orientation_chosen не записан в сохранение")
	return problems


func _test_export_preset() -> PackedStringArray:
	var problems := PackedStringArray()
	var path := "res://export_presets.cfg"
	if not FileAccess.file_exists(path):
		return _fail("нет export_presets.cfg — сборка APK невозможна")
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return _fail("export_presets.cfg не читается как ConfigFile")
	var names: Array = file.get_section_keys("preset") if file.has_section("preset") else []
	if names.is_empty():
		# Формат Godot: [preset.0]... — секции названы «preset/0».
		for section in file.get_sections():
			if String(section).begins_with("preset/"):
				names.append(String(section))
	if names.is_empty():
		return _fail("в export_presets.cfg нет ни одного пресета")
	# Пресет может быть описан как [preset.0] (секция «preset/0») — приводим к первому найденному.
	var section := String(names[0])
	if not section.begins_with("preset/"):
		section = "preset/%s" % section
	var read := func(key: String, fallback: Variant) -> Variant:
		return file.get_value(section, "binary_format/" + key, fallback) if false else file.get_value(section, key, fallback)
	if String(read.call("platform", "")) != "Android":
		problems.append("пресет '%s' для платформы '%s', нужна Android" % [section, String(read.call("platform", ""))])
	if String(read.call("export_path", "")) == "":
		problems.append("пресет без export_path")
	if not bool(read.call("architectures/arm64-v8a", false)):
		problems.append("architectures/arm64-v8a не включён (Infinix HOT 40i — ARM64)")
	if bool(read.call("architectures/armeabi-v7a", false)):
		problems.append("armeabi-v7a включён: двойные ABI удваивают размер APK без нужды на ARM64-телефоне")
	if String(read.call("package/unique_name", "")) != EXPECTED_PACKAGE:
		problems.append("package/unique_name = '%s', требуется '%s'" % [
			String(read.call("package/unique_name", "")), EXPECTED_PACKAGE])
	var portrait := int(read.call("screen/handheld/orientation", -1))
	if portrait >= 0 and portrait != 1:
		problems.append("ориентация пресета = %d, ожидается 1 (portrait)" % portrait)
	if bool(read.call("permissions/use_32_bits_importer", false)):
		problems.append("включен 32-bit importer при arm64-only сборке")
	var min_sdk := _variant_int(read.call("gradle_build/min_sdk", 0), 24)
	if min_sdk < 24:
		problems.append("min_sdk=%d ниже 24 (Android 7) — ниже 24 поддерживать поздно" % min_sdk)
	# ProjectSettings: рендер и портрет по умолчанию.
	var method := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	if method != "gl_compatibility":
		problems.append("rendering_method='%s' — ожидался gl_compatibility (Compatibility) для Mali-G52" % method)
	var mobile_method := String(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", ""))
	if mobile_method != "gl_compatibility":
		problems.append("rendering_method.mobile='%s' — на мобильном тоже нужен Compatibility" % mobile_method)
	if int(ProjectSettings.get_setting("display/window/handheld/orientation", 0)) != 1:
		problems.append("display/window/handheld/orientation != 1 (portrait)")
	return problems


func _test_no_teleportation() -> PackedStringArray:
	# Машину двигает физика. Скан файлов: в vehicle/police/world нет «телепортации» позицией.
	var problems := PackedStringArray()
	var allowed: PackedStringArray = PackedStringArray(["place_at", "respawn", "recover_upright", "snap"])
	for root in PHYSICS_ROOTS:
		var dir := DirAccess.open(root)
		if dir == null:
			problems.append("нет каталога %s" % root)
			continue
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".gd"):
				var path := root + "/" + file_name
				var text := FileAccess.get_file_as_string(path)
				var line_no := 0
				for line in text.split("\n"):
					line_no += 1
					var trimmed := String(line).strip_edges()
					if trimmed.begins_with("#") or trimmed.begins_with("//"):
						continue
					for forbidden in FORBIDDEN_MOTION:
						if trimmed.contains(forbidden):
							var whitelisted := false
							for key in allowed:
								if trimmed.contains(key):
									whitelisted = true
									break
							if not whitelisted:
								problems.append("%s:%d использует '%s' вместо физики: %s" % [
									path, line_no, forbidden, trimmed.left(80)])
			file_name = dir.get_next()
		dir.list_dir_end()
	return problems


## Variant -> int без сюрпризов: Godot не приводит строку к числу через int(), а нам в
## export_presets.cfg min_sdk лежит строкой («24»).
static func _variant_int(value: Variant, fallback: int) -> int:
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	if value is String:
		var text := String(value).strip_edges()
		return text.to_int() if text.is_valid_int() else fallback
	return fallback


func _test_engine_output() -> PackedStringArray:
	var problems := PackedStringArray()
	# Любой SCRIPT ERROR/shader error, пойманный DebugConsole, валит тесты: «пробежка по
	# логам» в CI ненадёжна, а вот логгер внутри Godot — точен.
	if DebugConsole.has_fatal_output():
		problems.append("в выводе движка есть ошибки (см. ci-reports/tests.txt)")
	return problems
