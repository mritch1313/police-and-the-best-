class_name MainMenuBackground
extends Control
## Фон главного меню: `фон.jpg` (или процедурная подложка, если файла нет).
##
## Файл ищется по списку: res://assets/ui/фон.jpg, fon.jpg, background.jpg. Если ничего не
## найдено — рисуется «белый студийный градиент» сеткой, чтобы меню не было чёрным квадратом
## на свежем клоне репозитория (это НЕ заглушка-прототип: тот же код рисует фон, когда
## игрок положит свой файл и удалит старый).

const CANDIDATES: Array[String] = ["res://assets/ui/фон.jpg", "res://assets/ui/fon.jpg", "res://assets/ui/background.jpg"]

var texture: Texture2D = null
var used_path: String = ""
var grid_color: Color = Color(0.78, 0.80, 0.84, 0.55)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_next()
	resized.connect(queue_redraw)


func load_next() -> bool:
	for path in CANDIDATES:
		if ResourceLoader.exists(path):
			var loaded := load(path) as Texture2D
			if loaded != null:
				texture = loaded
				used_path = path
				queue_redraw()
				return true
	texture = null
	used_path = ""
	queue_redraw()
	return false


func _draw() -> void:
	var rect := get_rect()
	if texture != null:
		# Cover-масштабирование: кадр заполняет экран целиком, без чёрных полос по краям
		# (для 720x1612 это важнее, чем «пропорции картинки»: полосы на телефоне = баг).
		var tsize := texture.get_size()
		if tsize.x <= 0.0 or tsize.y <= 0.0:
			return
		var scale := maxf(rect.size.x / tsize.x, rect.size.y / tsize.y)
		var drawn := tsize * scale
		var offset := (rect.size - drawn) * 0.5
		draw_texture_rect(texture, Rect2(offset, drawn), false)
		return
	draw_rect(rect, Color(0.93, 0.94, 0.96), true)
	var step := 64.0
	var x := 0.0
	while x < rect.size.x:
		draw_line(Vector2(x, 0.0), Vector2(x, rect.size.y), grid_color, 1.0)
		x += step
	var y := 0.0
	while y < rect.size.y:
		draw_line(Vector2(0.0, y), Vector2(rect.size.x, y), grid_color, 1.0)
		y += step
	draw_rect(Rect2(Vector2.ZERO, rect.size), Color(1.0, 1.0, 1.0, 0.18), false, 2.0)


func status_text() -> String:
	return "фон: %s" % (used_path if not used_path.is_empty() else "процедурная подложка (фон.jpg не найден)")
