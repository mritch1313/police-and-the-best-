extends Node
## Autoload: watches the frame rate and adapts the quality of the world to the device.
##
## A 720x1612 phone with a Mali-G52 class GPU cannot hold the "high" preset while driving
## through a dense district, and it should not have to: this manager lowers the LOD bias,
## the prop density and the traffic count when the frame time grows, and raises them again
## when there is headroom. The player's own choice is stored in SettingsManager and is
## used as the ceiling, never overwritten.

signal quality_changed(preset: int, auto_adjusted: bool)
signal budgets_changed()

const SAMPLE_COUNT := 90
const DOWNGRADE_FPS := 47.0
const UPGRADE_FPS := 57.0
const DOWNGRADE_TIME := 2.5
const UPGRADE_TIME := 9.0
const MIN_PRESET := 0
const MAX_PRESET := 2

## When false the preset never moves on its own (used by the tests and by the "фиксированное
## качество" option in the settings screen).
var auto_quality: bool = true

var _samples: PackedFloat32Array = PackedFloat32Array()
var _sample_index: int = 0
var _samples_filled: int = 0
var _below_time: float = 0.0
var _above_time: float = 0.0
var _applied_preset: int = -1
var _auto_adjusted: bool = false
var _physics_ms: float = 0.0
var _process_ms: float = 0.0

## Quality of service values the world systems read every frame.
var lod_bias: float = 1.0
var prop_density: float = 1.0
var traffic_cars: int = 14
var max_chunks: int = 160
var stream_radius_scale: float = 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_samples.resize(SAMPLE_COUNT)
	_samples.fill(1.0 / 60.0)
	_sync_from_settings()


func _process(delta: float) -> void:
	if Engine.get_process_frames() % 2 != 0:
		return
	_physics_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_process_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_push_sample(delta)
	if auto_quality:
		_evaluate(delta)


func _push_sample(delta: float) -> void:
	_samples[_sample_index] = maxf(delta, 0.0005)
	_sample_index = (_sample_index + 1) % SAMPLE_COUNT
	_samples_filled = mini(_samples_filled + 1, SAMPLE_COUNT)


## Rolling average frame rate over the sample window.
func average_fps() -> float:
	if _samples_filled == 0:
		return 60.0
	var total := 0.0
	for i in _samples_filled:
		total += _samples[i]
	if total <= 0.0:
		return 60.0
	return float(_samples_filled) / total


## The worst single frame inside the window, in milliseconds. Spikes matter more than the
## average on a phone: a chunk build must never show up as a visible hitch.
func worst_frame_ms() -> float:
	var worst := 0.0
	for i in _samples_filled:
		worst = maxf(worst, _samples[i] * 1000.0)
	return worst


func _evaluate(delta: float) -> void:
	var fps := average_fps()
	if fps < DOWNGRADE_FPS:
		_below_time += delta
		_above_time = 0.0
	elif fps > UPGRADE_FPS:
		_above_time += delta
		_below_time = 0.0
	else:
		_below_time = maxf(0.0, _below_time - delta * 0.5)
		_above_time = maxf(0.0, _above_time - delta * 0.5)

	if _below_time > DOWNGRADE_TIME:
		_below_time = 0.0
		_step_quality(-1)
	elif _above_time > UPGRADE_TIME:
		_above_time = 0.0
		_step_quality(1)


## Moves the active preset by `direction` (-1 = lower, +1 = higher) without ever going
## above the preset the player selected in the settings.
func _step_quality(direction: int) -> void:
	var ceiling := _player_preset()
	var current := _applied_preset if _applied_preset >= 0 else ceiling
	var target := clampi(current + direction, MIN_PRESET, ceiling)
	if target == current:
		# Nothing to do, but stop re-evaluating the same decision every few seconds.
		if current == ceiling:
			_above_time = 0.0
		return
	_auto_adjusted = target != ceiling
	applied_preset_override(target)
	quality_changed.emit(target, _auto_adjusted)


## Applies a preset immediately (used by the settings screen and by the auto adjustment).
func applied_preset_override(preset: int) -> void:
	_applied_preset = clampi(preset, MIN_PRESET, MAX_PRESET)
	var graphics: GraphicsConfig = _graphics_config()
	if graphics == null:
		return
	var scale := float(_applied_preset) / float(MAX_PRESET)
	lod_bias = lerpf(0.62, 1.35, scale)
	prop_density = lerpf(0.45, 1.0, scale)
	traffic_cars = int(round(lerpf(6.0, 20.0, scale)))
	max_chunks = int(round(lerpf(96.0, 220.0, scale)))
	stream_radius_scale = lerpf(0.75, 1.15, scale)
	RenderingServer.directional_shadow_atlas_set_size(
		int(round(lerpf(1024.0, 4096.0, scale))), false
	)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		tree.root.positional_shadow_atlas_size = int(round(lerpf(1024.0, 4096.0, scale)))
		tree.root.positional_shadow_atlas_16_bits = true
	budgets_changed.emit()


## Forces a preset and disables the automatic adjustment (settings screen).
func set_preset_locked(preset: int) -> void:
	auto_quality = false
	_auto_adjusted = false
	applied_preset_override(preset)
	quality_changed.emit(_applied_preset, false)


## Re-enables the automatic adjustment and returns to the player's preset.
func enable_auto_quality() -> void:
	auto_quality = true
	applied_preset_override(_player_preset())
	quality_changed.emit(_applied_preset, false)


func player_preset() -> int:
	return _player_preset()


func active_preset() -> int:
	return _applied_preset


func is_auto_adjusted() -> bool:
	return _auto_adjusted


func _player_preset() -> int:
	var graphics: GraphicsConfig = _graphics_config()
	if graphics == null:
		return 1
	return clampi(graphics.preset, MIN_PRESET, MAX_PRESET)


func _graphics_config() -> GraphicsConfig:
	var settings := get_node_or_null("/root/SettingsManager")
	if settings and settings.graphics is GraphicsConfig:
		return settings.graphics
	return null


func _sync_from_settings() -> void:
	applied_preset_override(_player_preset())


## Short status line for the debug overlay and for the CI smoke test report.
func debug_string() -> String:
	return (
		"fps=%.1f worst=%.1fms preset=%d(ceiling=%d%s) lod=%.2f props=%.2f traffic=%d chunks=%d"
		% [
			average_fps(),
			worst_frame_ms(),
			_applied_preset,
			_player_preset(),
			" auto" if _auto_adjusted else "",
			lod_bias,
			prop_density,
			traffic_cars,
			max_chunks,
		]
	)


## Dictionary form used by tests and by the CI report.
func snapshot() -> Dictionary:
	return {
		"fps": average_fps(),
		"worst_ms": worst_frame_ms(),
		"preset": _applied_preset,
		"ceiling": _player_preset(),
		"auto": auto_quality,
		"lod_bias": lod_bias,
		"prop_density": prop_density,
		"traffic": traffic_cars,
		"chunks": max_chunks,
		"physics_ms": _physics_ms,
		"process_ms": _process_ms,
	}
