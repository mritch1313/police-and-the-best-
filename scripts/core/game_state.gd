extends Node
## Autoload: everything that describes the current run.
##
## The game is a single continuous session (drive around, get chased, escape or get
## busted), so the state is deliberately small: heat, statistics, pause flag and the run
## result. Systems talk to each other through the signals here instead of reaching into
## each other's nodes.

signal run_started(seed_value: int)
signal run_ended(reason: StringName, stats: Dictionary)
signal heat_changed(heat: float, level: int)
signal wanted_state_changed(wanted: bool)
signal statistics_changed(stats: Dictionary)
signal pause_changed(paused: bool)
signal player_arrested()
signal player_escaped()

const REASON_ARRESTED := &"arrested"
const REASON_QUIT := &"quit"

## Heat is a float "wanted level" between 0 and `PoliceConfig.max_heat`; the integer level
## is what the HUD and the spawner use.
var heat: float = 0.0
var heat_level: int = 0
var wanted: bool = false

var paused: bool = false
var run_active: bool = false
var run_seed: int = 0
var run_time: float = 0.0

var police_config: PoliceConfig = null
var world_config: WorldConfig = null
var graphics_config_provider: Node = null

var save := SaveManager.new()
var stats := {
	"distance_m": 0.0,
	"top_speed_kmh": 0.0,
	"nitro_seconds": 0.0,
	"handbrake_seconds": 0.0,
	"police_contact": 0,
	"arrests": 0,
	"escapes": 0,
	"air_time": 0.0,
	"money": 0,
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	police_config = load("res://resources/config/police_config.tres") as PoliceConfig
	if police_config == null:
		police_config = PoliceConfig.new()
	world_config = load("res://resources/config/world_config.tres") as WorldConfig
	if world_config == null:
		world_config = WorldConfig.new()
	save.load_profile()
	stats["money"] = int(save.get_profile_value("money", 0))
	stats["arrests"] = int(save.get_profile_value("arrests", 0))
	stats["escapes"] = int(save.get_profile_value("escapes", 0))


func _process(delta: float) -> void:
	if not run_active or paused:
		return
	run_time += delta


## Starts a new run. The seed drives the whole generated world, so the same seed always
## produces the same city.
func start_run(seed_value: int = 0) -> void:
	if seed_value == 0:
		seed_value = int(Time.get_unix_time_from_system()) ^ (randi() & 0xFFFF)
	run_seed = seed_value
	run_active = true
	run_time = 0.0
	heat = 0.0
	heat_level = 0
	wanted = false
	paused = false
	stats["distance_m"] = 0.0
	stats["top_speed_kmh"] = 0.0
	stats["nitro_seconds"] = 0.0
	stats["handbrake_seconds"] = 0.0
	stats["police_contact"] = 0
	stats["air_time"] = 0.0
	run_started.emit(run_seed)
	statistics_changed.emit(stats)


func end_run(reason: StringName) -> void:
	if not run_active:
		return
	run_active = false
	if reason == REASON_ARRESTED:
		stats["arrests"] = int(stats["arrests"]) + 1
		save.set_profile_value("arrests", stats["arrests"])
	elif reason == REASON_QUIT:
		stats["escapes"] = int(stats["escapes"]) + 1
		save.set_profile_value("escapes", stats["escapes"])
	save.save_profile()
	run_ended.emit(reason, stats.duplicate())


func set_paused(value: bool) -> void:
	if paused == value:
		return
	paused = value
	get_tree().paused = value
	pause_changed.emit(value)


func toggle_pause() -> void:
	set_paused(not paused)


## Adds driven distance to the statistics (called by the player car).
func add_distance(meters: float) -> void:
	if meters <= 0.0 or not run_active:
		return
	stats["distance_m"] = float(stats["distance_m"]) + meters


## Records a speed sample; keeps the maximum.
func register_speed(meters_per_second: float) -> void:
	if not run_active:
		return
	var kmh := meters_per_second * 3.6
	if kmh > float(stats["top_speed_kmh"]):
		stats["top_speed_kmh"] = kmh


func register_nitro(seconds: float) -> void:
	if run_active:
		stats["nitro_seconds"] = float(stats["nitro_seconds"]) + seconds


func register_handbrake(seconds: float) -> void:
	if run_active:
		stats["handbrake_seconds"] = float(stats["handbrake_seconds"]) + seconds


func register_air_time(seconds: float) -> void:
	if run_active:
		stats["air_time"] = float(stats["air_time"]) + seconds


func register_police_contact() -> void:
	if run_active:
		stats["police_contact"] = int(stats["police_contact"]) + 1


## Raises (or lowers) the heat value and keeps the discrete wanted level in sync.
func add_heat(amount: float) -> void:
	if police_config == null:
		return
	var previous_level := heat_level
	heat = clampf(heat + amount, 0.0, float(police_config.max_heat))
	heat_level = int(floor(heat))
	wanted = heat_level >= 1
	if heat_level != previous_level:
		heat_changed.emit(heat, heat_level)
		wanted_state_changed.emit(wanted)


func set_heat(value: float) -> void:
	if police_config == null:
		return
	var previous_level := heat_level
	heat = clampf(value, 0.0, float(police_config.max_heat))
	heat_level = int(floor(heat))
	wanted = heat_level >= 1
	if heat_level != previous_level:
		heat_changed.emit(heat, heat_level)
		wanted_state_changed.emit(wanted)


## Heat decays while the player is not seen by any unit.
func decay_heat(delta: float) -> void:
	if police_config == null or heat <= 0.0:
		return
	add_heat(-police_config.heat_decay_per_second * delta)


func notify_arrested() -> void:
	player_arrested.emit()
	end_run(REASON_ARRESTED)


func notify_escaped() -> void:
	player_escaped.emit()
	end_run(REASON_QUIT)


## Adds money to the profile (used by the end-of-run screen).
func add_money(amount: int) -> void:
	stats["money"] = int(stats["money"]) + amount
	save.set_profile_value("money", stats["money"])
	save.save_profile()


## Snapshot of the run for the end screen and for the automated tests.
func summary() -> Dictionary:
	var result := stats.duplicate()
	result["time"] = run_time
	result["heat"] = heat_level
	result["seed"] = run_seed
	return result


## Headless tests and the smoke test call this to get a clean, deterministic state.
func reset_for_test() -> void:
	run_active = false
	heat = 0.0
	heat_level = 0
	wanted = false
	run_time = 0.0
	paused = false
