extends RefCounted
class_name SaveManager
## Persistent player profile (progress, unlocks, lifetime statistics).
##
## Separate from SettingsManager on purpose: settings are device preferences, the profile
## is progress. Both files are plain text so a player can inspect or delete them, and a
## corrupt profile can never stop the game from starting — it falls back to defaults.

const PROFILE_PATH := "user://profile.json"
const PROFILE_VERSION := 1

var data: Dictionary = {}
var last_error: String = ""


func _init() -> void:
	_apply_defaults()


func _apply_defaults() -> void:
	data = {
		"version": PROFILE_VERSION,
		"money": 0,
		"arrests": 0,
		"escapes": 0,
		"best_distance_m": 0.0,
		"best_top_speed_kmh": 0.0,
		"total_nitro_seconds": 0.0,
		"unlocked_maps": ["test_district"],
		"selected_map": "test_district",
		"runs": 0,
	}


## Loads the profile from disk. Missing or broken files produce a fresh profile and a
## message in `last_error` instead of an exception.
func load_profile() -> bool:
	last_error = ""
	if not FileAccess.file_exists(PROFILE_PATH):
		save_profile()
		return false
	var file := FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if file == null:
		last_error = "cannot open %s" % PROFILE_PATH
		return false
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "profile is not valid JSON, defaults restored"
		_apply_defaults()
		save_profile()
		return false
	var loaded := parsed as Dictionary
	for key: String in loaded.keys():
		data[key] = loaded[key]
	if int(data.get("version", 0)) != PROFILE_VERSION:
		# A version bump keeps what is still valid and re-adds anything new.
		var old_money := int(data.get("money", 0))
		_apply_defaults()
		data["money"] = old_money
		data["version"] = PROFILE_VERSION
		save_profile()
	return true


## Writes the profile. Returns false when the file system refused the write.
func save_profile() -> bool:
	var file := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write %s" % PROFILE_PATH
		push_warning("SaveManager: %s" % last_error)
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func get_profile_value(key: String, default_value: Variant = null) -> Variant:
	return data.get(key, default_value)


func set_profile_value(key: String, value: Variant) -> void:
	data[key] = value


func add_money(amount: int) -> int:
	var money := int(data.get("money", 0)) + amount
	data["money"] = money
	return money


## Called at the end of a run; keeps the personal bests up to date.
func register_run(stats: Dictionary) -> void:
	data["runs"] = int(data.get("runs", 0)) + 1
	var distance := float(stats.get("distance_m", 0.0))
	if distance > float(data.get("best_distance_m", 0.0)):
		data["best_distance_m"] = distance
	var speed := float(stats.get("top_speed_kmh", 0.0))
	if speed > float(data.get("best_top_speed_kmh", 0.0)):
		data["best_top_speed_kmh"] = speed
	data["total_nitro_seconds"] = float(data.get("total_nitro_seconds", 0.0)) + float(stats.get("nitro_seconds", 0.0))
	save_profile()


## Wipes the profile (used by the "reset progress" button in the settings).
func reset_profile() -> void:
	_apply_defaults()
	save_profile()


func selected_map() -> String:
	return String(data.get("selected_map", "test_district"))


func select_map(map_id: String) -> void:
	data["selected_map"] = map_id
	if not is_map_unlocked(map_id):
		var maps: Array = data.get("unlocked_maps", [])
		maps.append(map_id)
		data["unlocked_maps"] = maps
	save_profile()


func is_map_unlocked(map_id: String) -> bool:
	var maps: Array = data.get("unlocked_maps", [])
	return maps.has(map_id)
