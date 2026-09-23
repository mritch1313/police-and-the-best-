class_name UiConfig
extends ConfigResource
## Надписи меню, список карт и параметры HUD. Всё текстовое живёт здесь,
## чтобы локализация/ребрендинг не требовали правки сцен.

@export_group("Menu texts")
@export var version_line: String = "ВЕРСИЯ: %s"
@export var project_version: String = "4.0.9 TEXT"
@export var subtitle: String = "СИМУЛЯТОР УГОНА ОТ МУСОРОВ"
@export var play_label: String = "1 Играть"
@export var developers_label: String = "2 Разработчики"
@export var orientation_title: String = "Выбери ориентацию экрана"
@export var orientation_hint: String = "выбор сохраняется и больше не спрашивается"
@export var landscape_label: String = "Горизонтальная"
@export var portrait_label: String = "Вертикальная"
@export var back_label: String = "Назад"
@export var settings_label: String = "Настройки"
@export var resume_label: String = "Продолжить"
@export var to_menu_label: String = "В меню"

@export_group("Developers dialog")
@export var dev_lines: Array = [
	"тг бот для связи @connection9191_bot",
	"МАТАДОРА МАТАДОРА МАТАДАОРА",
]
@export var dev_hint: String = "нажми на окно, чтобы закрыть"

@export_group("Maps")
## Список карт стартового экрана. Каждая запись:
## {"title": String, "scene": String, "thumbnail": String, "enabled": bool}
## thumbnail — скриншот самой карты (см. tools/capture_map_thumbnails.gd).
@export var maps: Array = [
	{
		"title": "TEST",
		"scene": "res://scenes/game/Game.tscn",
		"thumbnail": "res://assets/ui/map_card.png",
		"enabled": true,
	},
]
@export var map_card_size_px: float = 232.0
@export var map_card_label_size: int = 22
## Что писать, если скриншот карты ещё не готов.
@export var map_card_fallback: String = "res://assets/ui/map_card_placeholder.png"

@export_group("HUD sizes")
## Минимальный размер кнопки под палец (px при 720px ширины).
@export_range(56.0, 200.0, 1.0) var min_touch_target_px: float = 96.0
@export_range(0.5, 2.0, 0.05) var ui_scale: float = 1.0
@export_range(12.0, 64.0, 1.0) var hud_font_size: int = 22
@export_range(24.0, 200.0, 2.0) var speed_font_size: int = 58
@export_range(40.0, 220.0, 2.0) var joystick_radius_px: float = 112.0
@export_range(0.0, 1.0, 0.02) var joystick_deadzone: float = 0.14
@export_range(40.0, 240.0, 4.0) var action_button_size_px: float = 128.0
@export_range(0.0, 1.0, 0.01) var hud_alpha: float = 0.9
@export_range(60.0, 400.0, 4.0) var minimap_size_px: float = 168.0
@export var show_speed_number: bool = true
@export var show_fps: bool = false
@export var show_debug_panel: bool = false

@export_group("Colors")
@export var accent: Color = Color(0.98, 0.42, 0.16, 1.0)
@export var nitro_color: Color = Color(0.34, 0.78, 1.0, 1.0)
@export var panel_color: Color = Color(0.06, 0.07, 0.09, 0.82)
@export var text_color: Color = Color(0.92, 0.94, 0.97, 1.0)
@export var dim_text_color: Color = Color(0.62, 0.66, 0.72, 1.0)

func map_count() -> int:
	return maps.size()

func map_entry(index: int) -> Dictionary:
	if index < 0 or index >= maps.size():
		return {}
	var entry: Variant = maps[index]
	if entry is Dictionary:
		return entry
	return {}

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if maps.is_empty():
		problems.append(_problem("пустой список карт: кнопка «Играть» никуда не поведёт"))
	for i in range(maps.size()):
		var entry := map_entry(i)
		if entry.is_empty():
			problems.append(_problem("карта #%d должна быть словарём" % i))
			continue
		for key in ["title", "scene"]:
			if not entry.has(key):
				problems.append(_problem("карта #%d: нет поля '%s'" % [i, key]))
		var scene := str(entry.get("scene", ""))
		if not scene.is_empty() and not scene.begins_with("res://"):
			problems.append(_problem("карта #%d: scene должен быть res:// путём" % i))
	if min_touch_target_px < 72.0:
		problems.append(_problem("min_touch_target_px=%.0f: кнопки слишком мелкие для пальца" % min_touch_target_px))
	if dev_lines.is_empty():
		problems.append(_problem("dev_lines пуст: диалог «Разработчики» нечего показывать"))
	return problems
