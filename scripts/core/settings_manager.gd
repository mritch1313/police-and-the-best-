extends Node
## SettingsManager — пользовательские настройки (качество, камера, HUD).
##
## Все значения живут в сейве и применяются «горячо»: настройки камеры читает
## [CameraController] при каждом кадре, качество — [PerformanceManager].
## Никаких рестартов, кроме размера shadow atlas (его читает рендерер на старте).

signal settings_changed

var camera_sensitivity: float = 1.0
## Смещения к камере, 0 = «как в CameraConfig» (игрок крутит «своё» положение).
var camera_distance_offset: float = 0.0
var camera_height_offset: float = 0.0
var ui_scale: float = 1.0
var show_fps: bool = false
var auto_quality: bool = true
var forced_tier: int = -1
## 0 = landscape, 1 = portrait (выбор первого запуска).
var orientation: int = 1
var orientation_chosen: bool = false
## Множитель числа патрулей (0..2), из настроек — «поиграть жёстче/мягче».
var police_intensity: float = 1.0

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	orientation = int(SaveManager.get_value("profile", "orientation", 1))
	orientation_chosen = bool(SaveManager.get_value("profile", "orientation_chosen", false))
	forced_tier = int(SaveManager.get_value("profile", "graphics_tier", -1))
	camera_sensitivity = float(SaveManager.get_value("profile", "camera_sensitivity", 1.0))
	camera_distance_offset = float(SaveManager.get_value("profile", "camera_distance", 0.0))
	camera_height_offset = float(SaveManager.get_value("profile", "camera_height", 0.0))
	ui_scale = float(SaveManager.get_value("profile", "ui_scale", 1.0))
	show_fps = bool(SaveManager.get_value("profile", "show_fps", false))
	auto_quality = bool(SaveManager.get_value("profile", "auto_quality", true))
	police_intensity = float(SaveManager.get_value("profile", "police_intensity", 1.0))
	AppState.orientation = orientation
	settings_changed.emit()

func persist() -> void:
	SaveManager.set_value("profile", "orientation", orientation)
	SaveManager.set_value("profile", "orientation_chosen", orientation_chosen)
	SaveManager.set_value("profile", "graphics_tier", forced_tier)
	SaveManager.set_value("profile", "camera_sensitivity", camera_sensitivity)
	SaveManager.set_value("profile", "camera_distance", camera_distance_offset)
	SaveManager.set_value("profile", "camera_height", camera_height_offset)
	SaveManager.set_value("profile", "ui_scale", ui_scale)
	SaveManager.set_value("profile", "show_fps", show_fps)
	SaveManager.set_value("profile", "auto_quality", auto_quality)
	SaveManager.set_value("profile", "police_intensity", police_intensity)

func set_orientation(value: int, remember: bool = true) -> void:
	orientation = 0 if value == 0 else 1
	if remember:
		orientation_chosen = true
	AppState.orientation = orientation
	SaveManager.set_value("profile", "orientation", orientation)
	SaveManager.set_value("profile", "orientation_chosen", orientation_chosen)
	ScreenFlow.apply_orientation(orientation)
	settings_changed.emit()

func is_landscape() -> bool:
	return orientation == 0

func set_tier(index: int) -> void:
	forced_tier = clampi(index, -1, 2)
	auto_quality = forced_tier < 0
	PerformanceManager.set_tier(forced_tier, auto_quality)
	SaveManager.set_value("profile", "graphics_tier", forced_tier)
	SaveManager.set_value("profile", "auto_quality", auto_quality)
	settings_changed.emit()

func set_camera_distance_offset(value: float) -> void:
	camera_distance_offset = clampf(value, -4.0, 6.0)
	SaveManager.set_value("profile", "camera_distance", camera_distance_offset)
	settings_changed.emit()

func set_camera_height_offset(value: float) -> void:
	camera_height_offset = clampf(value, -2.0, 4.0)
	SaveManager.set_value("profile", "camera_height", camera_height_offset)
	settings_changed.emit()

func set_sensitivity(value: float) -> void:
	camera_sensitivity = clampf(value, 0.2, 3.0)
	SaveManager.set_value("profile", "camera_sensitivity", camera_sensitivity)
	settings_changed.emit()

func set_ui_scale(value: float) -> void:
	ui_scale = clampf(value, 0.7, 1.6)
	SaveManager.set_value("profile", "ui_scale", ui_scale)
	settings_changed.emit()

func set_show_fps(value: bool) -> void:
	show_fps = value
	SaveManager.set_value("profile", "show_fps", value)
	settings_changed.emit()

func set_police_intensity(value: float) -> void:
	police_intensity = clampf(value, 0.0, 2.0)
	SaveManager.set_value("profile", "police_intensity", police_intensity)
	settings_changed.emit()

func camera_modulation() -> Dictionary:
	return {
		"sensitivity": camera_sensitivity,
		"distance_offset": camera_distance_offset,
		"height_offset": camera_height_offset,
	}

func reset_all() -> void:
	camera_sensitivity = 1.0
	camera_distance_offset = 0.0
	camera_height_offset = 0.0
	ui_scale = 1.0
	show_fps = false
	auto_quality = true
	forced_tier = -1
	police_intensity = 1.0
	persist()
	PerformanceManager.set_tier(-1, true)
	settings_changed.emit()
