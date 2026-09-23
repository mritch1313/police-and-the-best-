extends Node
## GameSetup — собирает типизированные конфиги из [Config] и раздаёт их системам.
##
## Порядок: автозагрузка `Config` читает .cfg -> GameSetup строит ресурсы ->
## сцены (`Game`, `MainMenu`, харнесс, тесты) берут конфиги отсюда.
## Так ни одна сцена не занимается чтением файлов, а headless-харнесс может
## подложить свой override-каталог, пересобрать конфиги и получить другой мир.

signal configs_ready

static var _cache: Dictionary = {}
static var _built: bool = false

var world: WorldConfig = null
var player_car: VehicleConfig = null
var police_car: VehicleConfig = null
var police_ai: PoliceConfig = null
var chase: ChaseConfig = null
var nitro: NitroConfig = null
var camera: CameraConfig = null
var graphics: GraphicsConfig = null
var tiers: Array[QualityTier] = []
var ui: UiConfig = null

func _ready() -> void:
	if not _built:
		build_configs()
	_publish()
	set_process(false)

## Собрать (или пересобрать при `force`) все конфиги. Статический вариант нужен
## тестам и харнессу, где инстанса автозагрузки может не быть.
static func build_configs(force: bool = false) -> Dictionary:
	if _built and not force:
		return _cache
	_cache = {}
	_built = true
	_build_one("world", WorldConfig)
	_build_one("vehicle.player", VehicleConfig)
	_build_one("vehicle.police", VehicleConfig)
	_build_one("police", PoliceConfig)
	_build_one("chase", ChaseConfig)
	_build_one("nitro", NitroConfig)
	_build_one("camera", CameraConfig)
	_build_one("graphics", GraphicsConfig)
	for section in tier_sections(_cache.get("graphics") as GraphicsConfig):
		_build_one(section, QualityTier)
	_build_one("ui", UiConfig)
	var balance := BalanceRules.check(
		_cache.get("vehicle.player") as VehicleConfig,
		_cache.get("vehicle.police") as VehicleConfig,
		_cache.get("nitro") as NitroConfig,
	)
	for problem in balance:
		Config.warnings.append("balance: %s" % problem)
	_cache["balance_problems"] = balance
	return _cache

static func _build_one(section: String, type: Script) -> void:
	var res: Resource = Config.build(section, type)
	if res == null:
		res = type.new()
		if res is ConfigResource:
			(res as ConfigResource).config_section = section
		Config.warnings.append("config: [%s] собран из значений по умолчанию класса" % section)
	_cache[section] = res

static func get_config(section: String) -> Resource:
	if not _built:
		build_configs()
	return _cache.get(section)

static func set_config(section: String, value: Resource) -> void:
	if not _built:
		build_configs()
	_cache[section] = value

static func project_version() -> String:
	var text := Config.str_value("ui", "project_version", "")
	if text.is_empty():
		text = str(ProjectSettings.get_setting("application/config/version", "?"))
	return text

static func version_line() -> String:
	var fmt := Config.str_value("ui", "version_line", "ВЕРСИЯ: %s")
	var version := project_version()
	if fmt.contains("%s"):
		return fmt % version
	return "%s %s" % [fmt, version]

## Секции пресетов качества. Имена читаются из GraphicsConfig, поэтому можно переименовать
## секции или оставить только две - код подстроится (порядок = low, medium, high).
static func tier_sections(gcfg: GraphicsConfig) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if gcfg == null:
		return PackedStringArray(["graphics.tier_low", "graphics.tier_medium", "graphics.tier_high"])
	for name in [gcfg.section_for_tier_0, gcfg.section_for_tier_1, gcfg.section_for_tier_2]:
		if not String(name).is_empty():
			names.append(String(name))
	if names.is_empty():
		names = PackedStringArray(["graphics.tier_low", "graphics.tier_medium", "graphics.tier_high"])
	return names


static func quality_tiers() -> Array[QualityTier]:
	var out: Array[QualityTier] = []
	for section in tier_sections(get_config("graphics") as GraphicsConfig):
		var t := get_config(section) as QualityTier
		if t != null:
			out.append(t)
	return out

func _publish() -> void:
	world = get_config("world") as WorldConfig
	player_car = get_config("vehicle.player") as VehicleConfig
	police_car = get_config("vehicle.police") as VehicleConfig
	police_ai = get_config("police") as PoliceConfig
	chase = get_config("chase") as ChaseConfig
	nitro = get_config("nitro") as NitroConfig
	camera = get_config("camera") as CameraConfig
	graphics = get_config("graphics") as GraphicsConfig
	ui = get_config("ui") as UiConfig
	tiers = quality_tiers()
	configs_ready.emit()
	DebugConsole.log_line("setup", "конфиги собраны:\n%s" % config_summary())

func config_summary() -> String:
	var parts := PackedStringArray()
	if world != null:
		parts.append("  world: r=%.0fм chunk=%.0fм lod=%.0f/%.0f/%.0f" % [
			world.world_radius_m, world.chunk_size_m, world.detail_distance_m, world.lod1_distance_m, world.lod2_distance_m,
		])
	if player_car != null and police_car != null and nitro != null:
		parts.append("  " + BalanceRules.describe(player_car, police_car, nitro))
	if police_ai != null:
		parts.append("  police: max %d шт, перехват с %.0f м, потеря цели %.1f с" % [
			police_ai.max_units, police_ai.engage_distance_m, police_ai.lose_time_s,
		])
	if chase != null:
		parts.append("  arrest: r=%.1fм, v<=%.0f км/ч, удержание %.1f с" % [
			chase.arrest_distance_m, chase.arrest_max_speed_kmh, chase.arrest_hold_s,
		])
	return "\n".join(parts)

## Только для тестов/харнесса: забыть собранные конфиги.
static func reset_for_tests() -> void:
	_cache = {}
	_built = false
