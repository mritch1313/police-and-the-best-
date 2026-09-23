extends Node
## SaveManager — маленький персистентный слой (`user://save/game.cfg`).
##
## Формат — тот же, что у игровых конфигов (см. [Config]), поэтому сейв можно
## прочитать глазами и поправить руками. Пишем атомарно: temp -> rename, иначе
## убийство процесса на Android оставляет побитый файл.

const SAVE_DIR := "user://save"
const SAVE_PATH := "user://save/game.cfg"
const SAVE_TMP := "user://save/game.cfg.tmp"
const CURRENT_FORMAT := 1

signal save_loaded(path: String)
signal save_written(path: String)

var data: Dictionary = {}
var path: String = SAVE_PATH
var loaded: bool = false
var dirty: bool = false
var _flush_due: float = 0.0

func _ready() -> void:
	load_save()

func load_save() -> bool:
	data = {}
	loaded = false
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			data = Config.parse_text(text)
			loaded = true
	if not loaded:
		data = _defaults()
	save_loaded.emit(path)
	return loaded

func _defaults() -> Dictionary:
	return {
		"meta": {"format": CURRENT_FORMAT, "created_version": GameSetup.project_version()},
		"profile": {
			"orientation": 1,
			"orientation_chosen": false,
			"graphics_tier": -1,
			"camera_sensitivity": 1.0,
			"camera_distance": 0.0,
			"camera_height": 0.0,
			"ui_scale": 1.0,
			"show_fps": false,
			"auto_quality": true,
		},
		"records": {
			"distance_m": 0.0,
			"top_speed_kms": 0.0,
			"boost_time_s": 0.0,
			"arrests_survived": 0,
			"sessions": 0,
		},
	}

func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
	var sec: Dictionary = data.get(section, {})
	if sec.has(key):
		return sec[key]
	return fallback

func set_value(section: String, key: String, value: Variant) -> void:
	if not data.has(section):
		data[section] = {}
	if data[section].get(key, null) == value:
		return
	data[section][key] = value
	dirty = true

func section_dict(section: String) -> Dictionary:
	return (data.get(section, {}) as Dictionary).duplicate(true)

func mark_dirty() -> void:
	dirty = true

func _process(delta: float) -> void:
	if not dirty:
		return
	_flush_due -= delta
	if _flush_due <= 0.0:
		_flush_due = 2.0
		flush()

func flush() -> bool:
	if not dirty:
		return false
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists(SAVE_DIR.trim_prefix("user://")):
		dir.make_dir_recursive(SAVE_DIR.trim_prefix("user://"))
	var file := FileAccess.open(SAVE_TMP, FileAccess.WRITE)
	if file == null:
		push_warning("SaveManager: не могу открыть %s для записи (%s)" % [SAVE_TMP, error_string(FileAccess.get_open_error())])
		return false
	for section in data.keys():
		file.store_line("[%s]" % section)
		var sec: Dictionary = data[section]
		var keys: Array = sec.keys()
		keys.sort()
		for key in keys:
			file.store_line("%s = %s" % [key, var_to_str(sec[key])])
		file.store_line("")
	file.close()
	var da := DirAccess.open("user://")
	if da == null:
		return false
	if da.file_exists(SAVE_PATH.trim_prefix("user://")):
		da.remove(SAVE_PATH.trim_prefix("user://"))
	var err := da.rename(SAVE_TMP.trim_prefix("user://"), SAVE_PATH.trim_prefix("user://"))
	if err != OK:
		push_warning("SaveManager: rename() вернул %s" % error_string(err))
		return false
	dirty = false
	save_written.emit(path)
	return true

## Полный сброс (кнопка в настройках).
func wipe() -> void:
	data = _defaults()
	dirty = true
	flush()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_GO_BACK_REQUEST]:
		flush()
