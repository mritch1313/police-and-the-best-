extends Node
## Autoload: persistent player settings (orientation, graphics, audio, controls).
##
## Settings live in `user://settings.cfg` (a plain Godot ConfigFile). Anything that the
## player can change in the UI is written here, everything else is a resource on disk so
## that a designer can re-balance the game without touching this file.

signal settings_changed()
signal orientation_changed(portrait: bool)

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_VERSION := 1

enum Orientation {
	PORTRAIT,
	LANDSCAPE,
}

## Portrait is the primary layout of the game (the HUD and the menus are designed for
## 720x1612), landscape stays playable for players who prefer it.
var orientation: int = Orientation.PORTRAIT
var first_launch: bool = true

## Graphics preset data. `graphics` is the live resource, `quality_override` lets the
## PerformanceManager drop the preset without overwriting the player's choice.
var graphics: GraphicsConfig = null
var graphics_path := "res://resources/config/graphics_config.tres"

var master_volume: float = 1.0
var music_volume: float = 0.7
var sfx_volume: float = 0.9

var touch_steering_sensitivity: float = 1.0
var touch_button_scale: float = 1.0
var steering_on_left: bool = true
var camera_sensitivity: float = 1.0
var invert_camera_y: bool = false
var show_fps: bool = false
var autoload_language: String = "ru"

var _config := ConfigFile.new()


func _ready() -> void:
	load_settings()
	# Autoloads may be created before the window exists (headless tests), so the
	# orientation is applied defensively.
	apply_orientation(false)


## Reads `user://settings.cfg`, filling in defaults for anything missing.
func load_settings() -> void:
	graphics = load(graphics_path) as GraphicsConfig
	if graphics == null:
		graphics = GraphicsConfig.new()

	var err := _config.load(SETTINGS_PATH)
	if err != OK:
		first_launch = true
		_apply_defaults()
		return

	first_launch = bool(_config.get_value("meta", "first_launch", true))
	if not _config.has_section_key("meta", "version"):
		first_launch = true

	orientation = int(_config.get_value("display", "orientation", Orientation.PORTRAIT))
	master_volume = clampf(float(_config.get_value("audio", "master", 1.0)), 0.0, 1.0)
	music_volume = clampf(float(_config.get_value("audio", "music", 0.7)), 0.0, 1.0)
	sfx_volume = clampf(float(_config.get_value("audio", "sfx", 0.9)), 0.0, 1.0)
	touch_steering_sensitivity = clampf(float(_config.get_value("controls", "steering_sensitivity", 1.0)), 0.4, 2.0)
	touch_button_scale = clampf(float(_config.get_value("controls", "button_scale", 1.0)), 0.7, 1.6)
	steering_on_left = bool(_config.get_value("controls", "steering_on_left", true))
	camera_sensitivity = clampf(float(_config.get_value("controls", "camera_sensitivity", 1.0)), 0.2, 3.0)
	invert_camera_y = bool(_config.get_value("controls", "invert_camera_y", false))
	show_fps = bool(_config.get_value("debug", "show_fps", false))
	autoload_language = String(_config.get_value("display", "language", "ru"))

	var gfx_data := {
		"preset": int(_config.get_value("graphics", "preset", graphics.preset)),
		"shadows": bool(_config.get_value("graphics", "shadows", graphics.shadows_enabled)),
		"glow": bool(_config.get_value("graphics", "glow", graphics.glow_enabled)),
	}
	graphics.from_dictionary(gfx_data)
	graphics.apply_to_engine()
	_apply_audio_buses()
	settings_changed.emit()


## Writes the settings file. Never throws: a failed write only prints a warning because a
## read-only user directory must not take the game down.
func save_settings() -> bool:
	_config.set_value("meta", "version", SETTINGS_VERSION)
	_config.set_value("meta", "first_launch", first_launch)
	_config.set_value("display", "orientation", orientation)
	_config.set_value("display", "language", autoload_language)
	_config.set_value("audio", "master", master_volume)
	_config.set_value("audio", "music", music_volume)
	_config.set_value("audio", "sfx", sfx_volume)
	_config.set_value("controls", "steering_sensitivity", touch_steering_sensitivity)
	_config.set_value("controls", "button_scale", touch_button_scale)
	_config.set_value("controls", "steering_on_left", steering_on_left)
	_config.set_value("controls", "camera_sensitivity", camera_sensitivity)
	_config.set_value("controls", "invert_camera_y", invert_camera_y)
	_config.set_value("debug", "show_fps", show_fps)
	_config.set_value("graphics", "preset", graphics.preset)
	_config.set_value("graphics", "shadows", graphics.shadows_enabled)
	_config.set_value("graphics", "glow", graphics.glow_enabled)
	var err := _config.save(SETTINGS_PATH)
	if err != OK:
		push_warning("SettingsManager: could not write %s (error %d)" % [SETTINGS_PATH, err])
		return false
	return true


## Sets the screen orientation and persists the choice. `portrait` true = vertical.
func set_orientation(portrait: bool, save: bool = true) -> void:
	orientation = Orientation.PORTRAIT if portrait else Orientation.LANDSCAPE
	first_launch = false
	apply_orientation(true)
	if save:
		save_settings()
	orientation_changed.emit(portrait)


## True when the game is currently laid out vertically.
func is_portrait() -> bool:
	return orientation == Orientation.PORTRAIT


func orientation_name() -> String:
	return "ПОРТРЕТ" if is_portrait() else "ЛАНДШАФТ"


## Applies the orientation to the OS window / Android activity. On desktop the window is
## resized instead so that the layout can be checked with the same aspect ratios as the
## target device (720x1612 portrait / 1612x720 landscape).
func apply_orientation(emit_signal: bool = true) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var portrait := is_portrait()
	if OS.has_feature("mobile"):
		var target := (
			DisplayServer.SCREEN_PORTRAIT if portrait else DisplayServer.SCREEN_LANDSCAPE
		)
		DisplayServer.screen_set_orientation(target)
	else:
		var size := Vector2i(720, 1612) if portrait else Vector2i(1612, 720)
		DisplayServer.window_set_size(size)
		var screen := DisplayServer.window_get_current_screen()
		var screen_pos := DisplayServer.screen_get_position(screen)
		var screen_size := DisplayServer.screen_get_size(screen)
		var centered := screen_pos + (screen_size - size) / 2
		DisplayServer.window_set_position(centered)
	if emit_signal:
		settings_changed.emit()


## Marks the first launch as done (called after the orientation question was answered).
func complete_first_launch() -> void:
	first_launch = false
	save_settings()


## Pushes the audio settings into the buses. The buses are created here when the project
## ships without a custom bus layout, which keeps the project file minimal.
func _apply_audio_buses() -> void:
	_ensure_bus("Music")
	_ensure_bus("SFX")
	_set_bus_volume("Master", master_volume)
	_set_bus_volume("Music", music_volume)
	_set_bus_volume("SFX", sfx_volume)


func set_master_volume(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)
	_set_bus_volume("Master", master_volume)
	save_settings()


func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	_set_bus_volume("Music", music_volume)
	save_settings()


func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)
	_set_bus_volume("SFX", sfx_volume)
	save_settings()


func set_graphics_preset(preset: int) -> void:
	graphics.preset = clampi(preset, 0, 2)
	graphics.apply_to_engine()
	save_settings()
	settings_changed.emit()


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)


func _set_bus_volume(bus_name: String, value: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.0001)))
	AudioServer.set_bus_mute(index, value <= 0.001)


func _apply_defaults() -> void:
	orientation = Orientation.PORTRAIT
	first_launch = true
	graphics.preset = 1
	graphics.apply_to_engine()
	_apply_audio_buses()
	save_settings()
