extends Node
## Config — единственная точка входа для всех игровых чисел.
##
## Источник правды — простые текстовые файлы `res://autoloads/*.cfg`
## (INI-подобный синтаксис, значения парсятся как литералы Godot, комментарии через `;` или `#`).
## Файлы читаются в порядке: базовые -> `res://override_cfg/` -> `user://override_cfg/`,
## более поздние перекрывают ранние поключево, поэтому сборка/тесты/моддинг могут переопределить
## что угодно, не трогая базовые файлы.
##
## Значения загружаются в типизированные [Resource]-классы ([ConfigResource] и наследники),
## поэтому редактор видит их в инспекторе, а системы получают проверенные типы, а не строки.
## Неизвестный ключ, несовпадение типа или выход за `@export_range` — это не тихая ошибка:
## значение игнорируется/клампится, а запись попадает в `Config.warnings`
## (видно в DebugConsole, в HUD-отладке и в CI-отчёте).

signal config_reloaded

const BASE_DIR := "res://autoloads"
const OVERRIDE_DIR := "res://override_cfg"
const USER_OVERRIDE_DIR := "user://override_cfg"

## Накопленные проблемы конфигурации (пусто = конфиг чистый).
var warnings: PackedStringArray = PackedStringArray()
## Список реально загруженных файлов (для отладки и CI-отчёта).
var loaded_files: PackedStringArray = PackedStringArray()
## section -> key -> value
var _data: Dictionary = {}
## section -> путь файла, давшего последнее значение ключа
var _sources: Dictionary = {}
var _dirty: bool = true

func _ready() -> void:
	reload()

## Перечитать все файлы конфигурации с нуля.
func reload() -> int:
	_data = {}
	_sources = {}
	warnings = PackedStringArray()
	loaded_files = PackedStringArray()
	for dir in [BASE_DIR, OVERRIDE_DIR, USER_OVERRIDE_DIR]:
		for path in _list_cfg_files(dir):
			var err := _load_file(path)
			if err != OK:
				push_warning("Config: не удалось разобрать %s" % path)
	loaded_files.sort()
	_dirty = false
	config_reloaded.emit()
	return OK

## Есть ли незагруженные изменения (для `--reload`/горячей перезагрузки).
func is_dirty() -> bool:
	return _dirty

func mark_dirty() -> void:
	_dirty = true

## Создать типизированный конфиг-ресурс, залить в него значения из секции и проверить.
## Если в секции есть ключ `resource="res://..."`, базой служит этот .tres, иначе — дефолты скрипта.
func build(section: String, script: Script) -> Resource:
	var res: Resource = null
	var override_path: String = str(_data.get(section, {}).get("resource", ""))
	if not override_path.is_empty() and ResourceLoader.exists(override_path):
		res = ResourceLoader.load(override_path)
	if res == null:
		res = script.new()
	if res == null:
		warnings.append("config: секция [%s]: не удалось создать ресурс из %s" % [section, script.resource_path])
		return null
	res.set("config_section", section)
	apply_to_object(res, section)
	if res.has_method("validate"):
		for problem in res.call("validate"):
			warnings.append("config: [%s] %s" % [section, problem])
	res.call("mark_valid")
	return res

## Применить к объекту все значения секции, сопоставляя их по именам свойств.
func apply_to_object(obj: Object, section: String) -> int:
	var sec: Dictionary = _data.get(section, {})
	if sec.is_empty():
		warnings.append("config: отсутствует секция [%s] — использованы встроенные значения по умолчанию" % section)
		return 0
	var props: Dictionary = {}
	for info in obj.get_property_list():
		if info.usage & PROPERTY_USAGE_STORAGE:
			props[info.name] = info
	var applied := 0
	for key in sec.keys():
		if key == "resource":
			continue
		var info: Dictionary = props.get(key, {})
		if info.is_empty():
			warnings.append("config: [%s] неизвестный ключ '%s' (объект %s)" % [section, key, obj.get_class()])
			continue
		var value: Variant = sec[key]
		var current: Variant = obj.get(key)
		var coerced: Variant
		if typeof(value) == TYPE_STRING and int(info.get("type", -1)) == TYPE_OBJECT:
			# Ресурс по пути из текста: `visual_scene = "res://assets/models/my_car.glb"`.
			coerced = load_resource_path(String(value), String(info.get("class_name", "")), section, key)
		else:
			coerced = _coerce(value, current, section, key)
		if coerced == null:
			continue
		coerced = _clamp_to_range(coerced, info, section, key)
		obj.set(key, coerced)
		applied += 1
	return applied

func has_section(section: String) -> bool:
	return _data.has(section)

func num(section: String, key: String, fallback: float = 0.0) -> float:
	return float(_get_raw(section, key, fallback))

func integer(section: String, key: String, fallback: int = 0) -> int:
	return int(_get_raw(section, key, fallback))

func flag(section: String, key: String, fallback: bool = false) -> bool:
	return bool(_get_raw(section, key, fallback))

func str_value(section: String, key: String, fallback: String = "") -> String:
	var v: Variant = _get_raw(section, key, fallback)
	if v is String:
		return v
	return str(v)

func arr(section: String, key: String) -> Array:
	var v: Variant = _get_raw(section, key, [])
	if v is Array:
		return v
	return [v]

func vec3(section: String, key: String, fallback: Vector3) -> Vector3:
	var v: Variant = _get_raw(section, key, fallback)
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback

## Полный снимок конфигурации для отчётов/тестов.
func snapshot() -> Dictionary:
	return _data.duplicate(true)

func _get_raw(section: String, key: String, fallback: Variant) -> Variant:
	var sec: Dictionary = _data.get(section, {})
	if sec.has(key):
		return sec[key]
	return fallback

func _list_cfg_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(dir_path)
	if da == null:
		return out
	da.list_dir_begin()
	var name := da.get_next()
	while not name.is_empty():
		if not da.current_is_dir() and name.get_extension().to_lower() == "cfg":
			out.append(dir_path.path_join(name))
		name = da.get_next()
	da.list_dir_end()
	out.sort()
	return out

## Разобрать текст .cfg в { section: { key: value } }. Публичный: им пользуются
## [SaveManager] (сейвы тем же синтаксисом) и CI-харнесс (врезка тестовых секций).
func parse_text(text: String) -> Dictionary:
	var out: Dictionary = {}
	var section := ""
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with(";") or trimmed.begins_with("#"):
			continue
		if trimmed.begins_with("[") and trimmed.ends_with("]"):
			section = trimmed.substr(1, trimmed.length() - 2).strip_edges()
			if not out.has(section):
				out[section] = {}
			continue
		var eq := trimmed.find("=")
		if eq < 1 or section.is_empty():
			continue
		var key := trimmed.left(eq).strip_edges()
		var raw := trimmed.substr(eq + 1).strip_edges()
		var value: Variant = str_to_var(raw)
		if value == null or (typeof(value) == TYPE_STRING and value == "" and raw != '""'):
			value = raw
		out[section][key] = value
	return out

func _load_file(path: String) -> int:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		var probe := FileAccess.open(path, FileAccess.READ)
		if probe == null:
			return ERR_CANT_OPEN
		text = probe.get_as_text()
		probe.close()
	if text.is_empty():
		return ERR_FILE_BAD_PATH
	var section := ""
	var line_no := 0
	var count := 0
	for line in text.split("\n"):
		line_no += 1
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		if trimmed.begins_with(";") or trimmed.begins_with("#"):
			continue
		if trimmed.begins_with("[") and trimmed.ends_with("]"):
			section = trimmed.substr(1, trimmed.length() - 2).strip_edges()
			if not _data.has(section):
				_data[section] = {}
			continue
		var eq := trimmed.find("=")
		if eq < 1 or section.is_empty():
			warnings.append("config: %s:%d — строка не является `key = value` в секции: '%s'" % [path, line_no, trimmed])
			continue
		var key := trimmed.left(eq).strip_edges()
		var raw_value := trimmed.substr(eq + 1).strip_edges()
		var value: Variant = str_to_var(raw_value)
		if value == null or (typeof(value) == TYPE_STRING and value == "" and raw_value != '""'):
			# Литерал разобрать не удалось — считаем строкой без кавычек.
			value = raw_value
		if _data.get(section, {}).has(key):
			warnings.append("config: %s — ключ '%s/%s' объявлен дважды, берётся последний" % [path, section, key])
		_data[section][key] = value
		_sources[section + "/" + key] = path
		count += 1
	loaded_files.append("%s (%d ключей, %d секций)" % [path, count, _data.size()])
	return OK

## Загрузить ресурс по пути из .cfg и проверить тип. Неудача — не тихая: предупреждение
## в `warnings`, а значение остаётся дефолтным (то есть игра продолжает работать без модели).
func load_resource_path(path: String, expected_class: String, section: String, key: String) -> Resource:
	if path.is_empty():
		return null
	if not ResourceLoader.exists(path):
		warnings.append("config: [%s] ключ '%s' указывает на несуществующий ресурс '%s'" % [section, key, path])
		return null
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		warnings.append("config: [%s] ключ '%s' — ресурс '%s' не загрузился" % [section, key, path])
		return null
	if not expected_class.is_empty() and ClassDB.class_exists(expected_class) \
			and not res.get_class() == expected_class \
			and not ClassDB.is_parent_class(res.get_class(), expected_class):
		warnings.append("config: [%s] ключ '%s' — ждался %s, получен %s" % [section, key, expected_class, res.get_class()])
		return null
	return res


func _coerce(value: Variant, current: Variant, section: String, key: String) -> Variant:
	if typeof(value) == typeof(current):
		return value
	match typeof(current):
		TYPE_FLOAT:
			if typeof(value) in [TYPE_INT, TYPE_BOOL]:
				return float(value)
			if typeof(value) == TYPE_STRING:
				return float(value)
		TYPE_INT:
			if typeof(value) in [TYPE_FLOAT, TYPE_BOOL]:
				return int(round(float(value)))
			if typeof(value) == TYPE_STRING and value.is_valid_int():
				return int(value)
		TYPE_BOOL:
			if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
				return value != 0
			if typeof(value) == TYPE_STRING:
				return value.to_lower() in ["true", "1", "yes", "on"]
		TYPE_STRING:
			return str(value)
		TYPE_VECTOR3:
			if value is Array and value.size() >= 3:
				return Vector3(float(value[0]), float(value[1]), float(value[2]))
			if value is Vector2:
				return Vector3(value.x, 0.0, value.y)
		TYPE_COLOR, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return current
		TYPE_ARRAY:
			return _coerce_array(value, current, section, key)
		TYPE_PACKED_FLOAT32_ARRAY:
			var packed_f := PackedFloat32Array()
			for item in _as_array(value):
				packed_f.append(float(item))
			return packed_f
		TYPE_PACKED_INT32_ARRAY:
			var packed_i := PackedInt32Array()
			for item in _as_array(value):
				packed_i.append(int(round(float(item))))
			return packed_i
		TYPE_PACKED_STRING_ARRAY:
			var packed_s := PackedStringArray()
			for item in _as_array(value):
				packed_s.append(str(item))
			return packed_s
		TYPE_PACKED_VECTOR3_ARRAY:
			var packed_v := PackedVector3Array()
			for item in _as_array(value):
				if item is Vector3:
					packed_v.append(item)
				elif item is Array and (item as Array).size() >= 3:
					packed_v.append(Vector3(float(item[0]), float(item[1]), float(item[2])))
			return packed_v
		_:
			return value
	if typeof(value) == TYPE_STRING and typeof(current) == TYPE_VECTOR3:
		return current
	warnings.append("config: [%s] ключ '%s': значение '%s' не приводится к типу %s — пропущено" % [section, key, value,
		type_string(typeof(current))])
	return null

func _as_array(value: Variant) -> Array:
	return value if value is Array else [value]

## Массивы в конфиге — типизированные (`Array[int]` для уровней розыска, `Array[float]`
## для передаточных чисел). GDScript НЕ принимает обычный Array literal в типизированный
## массив, поэтому собираем новый массив того же типа, что у значения по умолчанию,
## с явным приведением каждого элемента.
func _coerce_array(value: Variant, current: Array, _section: String, _key: String) -> Variant:
	var source := _as_array(value)
	var builtin: int = current.get_typed_builtin()
	if builtin == TYPE_NIL:
		return source
	var out: Array = current.duplicate()
	out.clear()
	for item in source:
		match builtin:
			TYPE_FLOAT:
				out.append(float(item))
			TYPE_INT:
				out.append(int(round(float(item))))
			TYPE_BOOL:
				if typeof(item) == TYPE_STRING:
					out.append(String(item).to_lower() in ["true", "1", "yes", "on"])
				else:
					out.append(bool(item))
			TYPE_STRING:
				out.append(str(item))
			TYPE_VECTOR3:
				if item is Vector3:
					out.append(item)
				elif item is Array and (item as Array).size() >= 3:
					out.append(Vector3(float(item[0]), float(item[1]), float(item[2])))
			_:
				out.append(item)
	return out

func _clamp_to_range(value: Variant, info: Dictionary, section: String, key: String) -> Variant:
	if info.get("hint", PROPERTY_HINT_NONE) != PROPERTY_HINT_RANGE:
		return value
	if not (value is float or value is int):
		return value
	var parts: PackedStringArray = String(info.get("hint_string", "")).split(",")
	if parts.size() < 2:
		return value
	var lo := float(parts[0])
	var hi := float(parts[1])
	var numeric := float(value)
	if numeric < lo or numeric > hi:
		var clamped := clampf(numeric, lo, hi)
		warnings.append("config: [%s] ключ '%s': %.3f вне диапазона [%.3f..%.3f], зажат до %.3f" % [section, key, numeric, lo, hi,
			clamped])
		if typeof(value) == TYPE_INT:
			return int(round(clamped))
		return clamped
	return value
