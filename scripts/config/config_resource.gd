class_name ConfigResource
extends Resource
## Базовый класс для типизированных блоков конфигурации.
##
## Наследники описывают *структуру* настроек (имена свойств, типы, `@export_range`,
## значения по умолчанию), а фактические числа приходят из `res://autoloads/*.cfg`
## через автозагрузку `Config`. Это даёт сразу два удобных способа настройки:
## правка текстового .cfg (git-друг, доступно CI и тестам) и инспектор Godot
## (когда ресурс сохранён как .tres и подключён ключом `resource="res://..."`).

## Имя секции в .cfg, откуда этот ресурс получает значения.
@export var config_section: String = ""

var _validated: bool = false

## Залить значения из секции (или из переданной секции `override_section`).
func bind(section: String = "", override_section: String = "") -> void:
	config_section = section if not section.is_empty() else config_section
	var target := override_section if not override_section.is_empty() else config_section
	if Engine.has_singleton("Config"):
		Config.apply_to_object(self, target)

## Проверка связности. Возвращает список проблем (пусто = всё хорошо).
func validate() -> PackedStringArray:
	return PackedStringArray()

func mark_valid() -> void:
	_validated = true

func is_validated() -> bool:
	return _validated

## Ключи, которые должны присутствовать в секции — для CI-проверки полноты конфига.
func required_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for info in get_property_list():
		if info.usage & PROPERTY_USAGE_STORAGE and info.name != "config_section":
			out.append(info.name)
	return out

func _problem(text: String) -> String:
	return "[%s] %s" % [config_section, text]
