class_name MapPreview
extends Control
## Картинка внутри карточки карты: скриншот собранного мира, либо схема из WorldConfig.
##
## Почему у карточки есть «схема»: assets/ui/map_card.png генерируется прогоном игры в
## режиме `--capture-map` (CI делает настоящий скриншот и коммитит его обратно). Пока
## файла в репозитории нет, меню не должно показывать пустой квадрат — рисуется план мира
## по тем же данным (WorldConfig), из которых он строится.

const FALLBACK := "res://assets/ui/map_card_placeholder.png"

var image_path: String = "res://assets/ui/map_card.png"
var fallback_path: String = FALLBACK
var texture: Texture2D = null
var source: String = ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reload()


func _reload() -> void:
	for path in [image_path, fallback_path]:
		if not path.is_empty() and ResourceLoader.exists(path):
			var loaded := load(path) as Texture2D
			if loaded != null:
				texture = loaded
				source = path
				queue_redraw()
				return
	texture = null
	source = "схема мира"
	queue_redraw()


func _draw() -> void:
	var rect := get_rect()
	if texture != null:
		var tsize := texture.get_size()
		var scale := minf(rect.size.x / maxf(tsize.x, 1.0), rect.size.y / maxf(tsize.y, 1.0))
		var drawn := tsize * scale
		draw_texture_rect(texture, Rect2((rect.size - drawn) * 0.5, drawn), false)
		return
	_draw_plan(rect)


## План мира: бетонная площадь, сетка улиц, кварталы. Данные — WorldConfig/WorldGenerator.
func _draw_plan(rect: Rect2) -> void:
	draw_rect(rect, Color(0.11, 0.12, 0.14), true)
	var cfg := GameSetup.get_config("world") as WorldConfig
	if cfg == null:
		draw_rect(rect, Color(0.2, 0.22, 0.26), true)
		return
	var span := maxf(cfg.world_radius_m, 100.0) * 2.0
	var to_px := func(x: float, z: float) -> Vector2:
		return Vector2((x / span + 0.5) * rect.size.x, (z / span + 0.5) * rect.size.y)
	var step := maxf(cfg.block_pitch_m, 20.0)
	var count := int(ceilf(span / step))
	for i in range(-count, count + 1):
		var offset := WorldGenerator.line_offset(i, cfg)
		var avenue := WorldGenerator.is_avenue(i, cfg)
		var color := Color(0.80, 0.83, 0.88, 0.95) if avenue else Color(0.55, 0.58, 0.64, 0.8)
		var thick := 2.5 if avenue else 1.2
		draw_line(to_px(offset, -cfg.world_radius_m), to_px(offset, cfg.world_radius_m), color, thick)
		draw_line(to_px(-cfg.world_radius_m, offset), to_px(cfg.world_radius_m, offset), color, thick)
	var plaza := WorldGenerator.plaza_radius(cfg)
	draw_circle(to_px(0.0, 0.0), plaza / span * rect.size.x, Color(0.86, 0.87, 0.90, 0.9))
	draw_circle(to_px(0.0, 0.0), plaza / span * rect.size.x * 0.35, Color(0.98, 0.42, 0.16, 0.95))


func status_text() -> String:
	return "карта: %s" % source
