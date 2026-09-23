class_name TextureLibrary
extends RefCounted
## Процедурные текстуры мира и машин — без единого «серого куба» и без внешних ассетов.
##
## Почему процедурно: (1) сборка остаётся маленькой и переносимой, (2) тайлы
## гарантированно бесшовные, (3) UV мира считаются в МЕТРАХ, поэтому масштаб
## текстуры — это `uv1_scale = 1/tile_m`, а не «подгони под глазами».
##
## ЗАМЕНА НА НАСТОЯЩИЕ АССЕТЫ: если рядом лежит `res://assets/textures/<имя>.png`,
## он используется вместо генерации (и `_<имя>_normal.png` / `_<имя>_rough.png` для
## карт нормалей и шероховатости). Никакого другого переключать не нужно — см. docs/ASSETS.md.
##
## Стоимость: генерация ~12 текстур занимает доли секунды и происходит один раз
## за запуск (кэш статический), потому что шум считается на 64x64 и растягивается,
## а вся «графика» (швы, окна, разметка) — прямоугольниками.

const SIZE := 256
const NOISE_SIZE := 64
const TEXTURE_ROOT := "res://assets/textures"

static var _cache: Dictionary = {}

## Имена, которые умеет генерировать библиотека.
static func names() -> PackedStringArray:
	return PackedStringArray([
		"asphalt", "concrete", "sidewalk", "road_marking", "facade_office", "facade_brick",
		"facade_glass", "facade_residential", "roof_gravel", "metal_panel", "brick",
		"paint_wear", "tyre_rubber", "rim_metal", "soil", "glass_sheet",
	])

## Полный «пакет» материала: albedo + (опционально) normal + roughness + размер тайла в метрах.
static func get_pack(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var pack := _build_pack(name)
	_cache[name] = pack
	return pack

static func get_albedo(name: String) -> Texture2D:
	return get_pack(name).get("albedo") as Texture2D

static func get_normal(name: String) -> Texture2D:
	return get_pack(name).get("normal") as Texture2D

static func get_rough(name: String) -> Texture2D:
	return get_pack(name).get("rough") as Texture2D

## Размер одного тайла в метрах: Vector2(x_tile, y_tile). Для `uv1_scale` материала.
static func tile_meters(name: String) -> Vector2:
	return get_pack(name).get("tile", Vector2.ONE * 2.0) as Vector2

static func reset_cache() -> void:
	_cache = {}

## Сколько пакетов уже сгенерировано (для отладки и теста «кэш работает»).
static func cached_count() -> int:
	return _cache.size()

static func _build_pack(name: String) -> Dictionary:
	var override_dir := DirAccess.open(TEXTURE_ROOT)
	var albedo_override := TEXTURE_ROOT.path_join(name + ".png")
	if override_dir != null and (ResourceLoader.exists(albedo_override) or FileAccess.file_exists(albedo_override)):
		var loaded := _load_png(albedo_override)
		if loaded != null:
			return {
				"albedo": loaded,
				"normal": _load_png(TEXTURE_ROOT.path_join("_%s_normal.png" % name)),
				"rough": _load_png(TEXTURE_ROOT.path_join("_%s_rough.png" % name)),
				"tile": Vector2(2.0, 2.0),
				"source": "file",
			}
	# Генерация: сначала «карта высот» (шум, 64² -> 256²), потом узоры поверх.
	var height := _base_height(name)
	var color := _paint(name, height)
	var tile := _tile_size(name)
	var normal_img := _normal_from_height(height)
	var rough_img := _rough_from_height(name, height)
	return {
		"albedo": _texture(color, true),
		"normal": _texture(normal_img, false),
		"rough": _texture(rough_img, false),
		"tile": tile,
		"source": "procedural",
	}

static func _tile_size(name: String) -> Vector2:
	match name:
		"asphalt": return Vector2(2.5, 2.5)
		"concrete": return Vector2(6.0, 6.0)      # плита бетона 6x6 м (как в требованиях к площадке)
		"sidewalk": return Vector2(3.0, 3.0)
		"road_marking": return Vector2(1.5, 1.5)
		"facade_office": return Vector2(5.0, 3.25)   # одна «этажная лента»: 4 окна + простенок
		"facade_brick": return Vector2(5.0, 3.25)
		"facade_glass": return Vector2(2.5, 3.25)
		"facade_residential": return Vector2(5.0, 3.25)
		"roof_gravel": return Vector2(4.0, 4.0)
		"metal_panel": return Vector2(2.0, 2.0)
		"brick": return Vector2(2.0, 1.0)
		"paint_wear": return Vector2(1.0, 1.0)
		"tyre_rubber": return Vector2(0.5, 0.5)
		"rim_metal": return Vector2(0.4, 0.4)
		"soil": return Vector2(3.0, 3.0)
		"glass_sheet": return Vector2(1.0, 1.0)
	return Vector2(2.0, 2.0)

# ------------------------------------------------------------------ генерация

## Карта высот 256² (внутри — бесшовная за счёт периодического шума по модулю).
static func _base_height(name: String) -> Image:
	var octaves := 3
	var freq := 0.18
	match name:
		"asphalt":
			octaves = 4
			freq = 0.34
		"concrete":
			octaves = 3
			freq = 0.2
		"facade_glass", "glass_sheet", "rim_metal":
			octaves = 2
			freq = 0.12
		"roof_gravel", "soil", "brick":
			octaves = 4
			freq = 0.42
	var img := Image.create(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RF)
	for y in range(NOISE_SIZE):
		for x in range(NOISE_SIZE):
			# Периодический шум: решётка решается симметрично, швы тайла не видны.
			var v := 0.0
			var amp := 1.0
			var f := freq
			for o in range(octaves):
				v += _periodic_noise(x, y, NOISE_SIZE, f, o * 101 + name.length()) * amp
				amp *= 0.5
				f *= 2.0
			img.set_pixel(x, y, Color.from_hsv(0.0, 0.0, clampf(0.5 + v * 0.5, 0.0, 1.0)))
	img.resize(SIZE, SIZE, Image.INTERPOLATE_BILINEAR)
	return img

static func _periodic_noise(x: int, y: int, size: int, freq: float, salt: int) -> float:
	# Value-noise с решёточными узлами, период = size -> бесшовность по построению.
	var step := maxf(1.0 / maxf(freq, 0.01), 1.0)
	var gx := int(floorf(float(x) / step))
	var gy := int(floorf(float(y) / step))
	var fx := float(x) / step - float(gx)
	var fy := float(y) / step - float(gy)
	var a := _hash2(modfi(gx, size), modfi(gy, size), salt)
	var b := _hash2(modfi(gx + 1, size), modfi(gy, size), salt)
	var c := _hash2(modfi(gx, size), modfi(gy + 1, size), salt)
	var d := _hash2(modfi(gx + 1, size), modfi(gy + 1, size), salt)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy) * 2.0 - 1.0

static func _hash2(x: int, y: int, salt: int) -> float:
	var h := uint64(x) * 374761393 + uint64(y) * 668265263 + uint64(salt) * 2147483647
	h = h ^ (h >> 13)
	h *= 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0

static func modfi(a: int, b: int) -> int:
	return ((a % b) + b) % b

## Цвет поверх карты высот: здесь появляется вся «осмысленность» текстуры.
static func _paint(name: String, height: Image) -> Image:
	var out := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	match name:
		"asphalt":
			_draw_uniform(out, height, Color(0.086, 0.088, 0.094), Color(0.21, 0.212, 0.22), 0.55)
			_draw_wear_patches(out, Color(0.05, 0.05, 0.055), 9)
			_draw_cracks(out, Color(0.04, 0.04, 0.045), 14)
		"concrete":
			_draw_uniform(out, height, Color(0.50, 0.50, 0.487), Color(0.68, 0.68, 0.665), 0.8)
			_draw_stains(out, Color(0.36, 0.36, 0.35), 6)
			_draw_slab_joints(out)
		"sidewalk":
			_draw_uniform(out, height, Color(0.40, 0.40, 0.395), Color(0.57, 0.57, 0.56), 0.7)
			_draw_grid(out, 4, Color(0.29, 0.29, 0.285), 2)
		"road_marking":
			_draw_uniform(out, height, Color(0.72, 0.71, 0.66), Color(0.94, 0.93, 0.88), 0.6)
			_draw_wear_patches(out, Color(0.35, 0.35, 0.33), 14)
		"facade_office":
			_draw_uniform(out, height, Color(0.30, 0.31, 0.33), Color(0.44, 0.45, 0.47), 0.6)
			_draw_window_band(out, 4, Color(0.045, 0.055, 0.075), Color(0.62, 0.66, 0.70), 0.62)
		"facade_brick":
			_draw_uniform(out, height, Color(0.30, 0.155, 0.115), Color(0.46, 0.27, 0.20), 0.8)
			_draw_brick_rows(out)
			_draw_window_band(out, 3, Color(0.05, 0.055, 0.07), Color(0.70, 0.72, 0.74), 0.5)
		"facade_glass":
			_draw_uniform(out, height, Color(0.10, 0.13, 0.16), Color(0.26, 0.32, 0.37), 0.5)
			_draw_curtain_wall(out)
		"facade_residential":
			_draw_uniform(out, height, Color(0.55, 0.50, 0.42), Color(0.72, 0.68, 0.60), 0.7)
			_draw_window_band(out, 3, Color(0.06, 0.07, 0.09), Color(0.78, 0.80, 0.82), 0.55)
			_draw_balcony_rails(out)
		"roof_gravel":
			_draw_uniform(out, height, Color(0.16, 0.16, 0.165), Color(0.33, 0.33, 0.34), 1.0)
			_draw_grit(out, 900)
		"metal_panel":
			_draw_uniform(out, height, Color(0.33, 0.34, 0.35), Color(0.52, 0.53, 0.55), 0.5)
			_draw_panel_seams(out, 2)
		"brick":
			_draw_uniform(out, height, Color(0.32, 0.17, 0.13), Color(0.48, 0.29, 0.22), 0.9)
			_draw_brick_rows(out)
		"paint_wear":
			_draw_uniform(out, height, Color(0.55, 0.55, 0.56), Color(0.95, 0.95, 0.96), 0.35)
		"tyre_rubber":
			_draw_uniform(out, height, Color(0.035, 0.035, 0.038), Color(0.10, 0.10, 0.105), 0.8)
			_draw_tread(out)
		"rim_metal":
			_draw_uniform(out, height, Color(0.42, 0.43, 0.45), Color(0.72, 0.73, 0.75), 0.4)
		"soil":
			_draw_uniform(out, height, Color(0.16, 0.135, 0.10), Color(0.34, 0.30, 0.22), 1.0)
			_draw_grit(out, 1400)
		"glass_sheet":
			_draw_uniform(out, height, Color(0.35, 0.42, 0.48), Color(0.62, 0.70, 0.76), 0.25)
		_:
			_draw_uniform(out, height, Color(0.35, 0.35, 0.36), Color(0.62, 0.62, 0.62), 0.6)
	return out

static func _draw_uniform(out: Image, height: Image, dark: Color, light: Color, contrast: float) -> void:
	for y in range(SIZE):
		for x in range(SIZE):
			var h: float = height.get_pixel(x, y).r
			var t := clampf(0.5 + (h - 0.5) * contrast, 0.0, 1.0)
			out.set_pixel(x, y, dark.lerp(light, t))

static func _draw_stains(out: Image, color: Color, count: int) -> void:
	for i in range(count):
		var cx := int(_hash2(i * 31, 7, 4242) * SIZE)
		var cy := int(_hash2(i * 17, 91, 991) * SIZE)
		var r := 12 + int(_hash2(i, i * 5, 13) * 36.0)
		for y in range(maxi(cy - r, 0), mini(cy + r, SIZE)):
			for x in range(maxi(cx - r, 0), mini(cx + r, SIZE)):
				var dx := float(x - cx) / float(r)
				var dy := float(y - cy) / float(r)
				var fall := 1.0 - clampf(sqrtf(dx * dx + dy * dy), 0.0, 1.0)
				var cur := out.get_pixel(x, y)
				out.set_pixel(x, y, cur.lerp(color, fall * 0.35))

static func _draw_wear_patches(out: Image, color: Color, count: int) -> void:
	_draw_stains(out, color, count)

static func _draw_cracks(out: Image, color: Color, count: int) -> void:
	for i in range(count):
		var x := int(_hash2(i * 3, 11, 77) * SIZE)
		var y := int(_hash2(i * 7, 23, 55) * SIZE)
		var dir := _hash2(i, i * 13, 12) * TAU
		for s in range(18 + int(_hash2(i, 5, 9) * 40.0)):
			x = int(x + cos(dir) * 1.6)
			y = int(y + sin(dir) * 1.6)
			dir += (_hash2(x, y, i) - 0.5) * 1.1
			out.set_pixel(modfi(x, SIZE), modfi(y, SIZE), color)

static func _draw_grid(out: Image, cells: int, color: Color, width: int) -> void:
	var step := SIZE / maxi(cells, 1)
	for i in range(cells + 1):
		var pos := (i * step) % SIZE
		for offset in range(width):
			out.fill_rect(Rect2i(pos + offset, 0, 1, SIZE), color)
			out.fill_rect(Rect2i(0, pos + offset, SIZE, 1), color)

## Швы бетонной плиты: по краям тайла (тогда при тайлинге получается сетка 6x6 м).
static func _draw_slab_joints(out: Image) -> void:
	# Шов = тёмная канавка + светлая фаска рядом: на солнце виден рельеф,
	# а в нормаль-карте это уже есть автоматически.
	var joint := Color(0.27, 0.27, 0.27)
	var highlight := Color(0.76, 0.76, 0.74)
	out.fill_rect(Rect2i(0, 0, 3, SIZE), joint)
	out.fill_rect(Rect2i(0, 0, SIZE, 3), joint)
	out.fill_rect(Rect2i(3, 0, 2, SIZE), highlight)
	out.fill_rect(Rect2i(0, 3, SIZE, 2), highlight)

static func _draw_window_band(out: Image, windows: int, glass: Color, frame: Color, bottom_ratio: float) -> void:
	var margin := int(SIZE * 0.08)
	var usable := SIZE - margin * 2
	var cell := usable / windows
	var w := int(cell * 0.62)
	var band_top := int(SIZE * (1.0 - bottom_ratio - 0.5) * 0.9) + int(SIZE * 0.22)
	var band_h := int(SIZE * 0.34)
	for i in range(windows):
		var x0 := margin + i * cell + int((cell - w) * 0.5)
		out.fill_rect(Rect2i(x0 - 2, band_top - 2, w + 4, band_h + 4), frame)
		out.fill_rect(Rect2i(x0, band_top, w, band_h), glass)
		# блик по диагонали
		for s in range(band_h):
			var px := x0 + int(float(s) / maxf(float(band_h), 1.0) * float(w))
			if px < x0 + w:
				out.set_pixel(px, band_top + s, glass.lerp(Color(0.30, 0.36, 0.42), 0.55))
		out.fill_rect(Rect2i(x0, band_top + band_h + 3, w, 3), Color(0.25, 0.25, 0.25))

static func _draw_brick_rows(out: Image) -> void:
	var row_h := SIZE / 16
	var mortar := Color(0.42, 0.40, 0.37)
	for r in range(16):
		out.fill_rect(Rect2i(0, r * row_h, SIZE, 2), mortar)
		var offset := (r % 2) * (SIZE / 12)
		for c in range(12):
			var x := modfi(offset + c * (SIZE / 12), SIZE)
			out.fill_rect(Rect2i(x, r * row_h, 2, row_h), mortar)

static func _draw_curtain_wall(out: Image) -> void:
	var cols := 3
	var rows := 2
	var cell_x := SIZE / cols
	var cell_y := SIZE / rows
	for r in range(rows):
		for c in range(cols):
			var x0 := c * cell_x
			var y0 := r * cell_y
			var glass := Color(0.055, 0.085, 0.11).lerp(Color(0.32, 0.42, 0.5), _hash2(c, r, 3))
			out.fill_rect(Rect2i(x0 + 2, y0 + 2, cell_x - 4, cell_y - 4), glass)
			out.fill_rect(Rect2i(x0, y0, cell_x, 3), Color(0.16, 0.17, 0.18))
			out.fill_rect(Rect2i(x0, y0, 3, cell_y), Color(0.16, 0.17, 0.18))
			for s in range(cell_y - 4):
				var px := x0 + 3 + int(float(s) / maxf(float(cell_y), 1.0) * float(cell_x - 6))
				out.set_pixel(mini(px, x0 + cell_x - 4), y0 + 3 + s, glass.lightened(0.18))

static func _draw_balcony_rails(out: Image) -> void:
	var y := int(SIZE * 0.66)
	out.fill_rect(Rect2i(0, y, SIZE, 3), Color(0.2, 0.2, 0.2))
	for x in range(0, SIZE, 6):
		out.fill_rect(Rect2i(x, y, 2, int(SIZE * 0.13)), Color(0.24, 0.24, 0.25))

static func _draw_panel_seams(out: Image, panels: int) -> void:
	var step := SIZE / panels
	for i in range(panels + 1):
		out.fill_rect(Rect2i(0, (i * step) % SIZE, SIZE, 2), Color(0.16, 0.16, 0.17))
		out.fill_rect(Rect2i((i * step) % SIZE, 0, 2, SIZE), Color(0.16, 0.16, 0.17))
		out.fill_rect(Rect2i(0, ((i * step) + 2) % SIZE, SIZE, 1), Color(0.62, 0.63, 0.65))

static func _draw_grit(out: Image, count: int) -> void:
	for i in range(count):
		var x := int(_hash2(i, i * 3, 17) * SIZE)
		var y := int(_hash2(i * 5, i, 29) * SIZE)
		var cur := out.get_pixel(x, y)
		out.set_pixel(x, y, cur.lightened(0.16) if _hash2(x, y, 3) > 0.5 else cur.darkened(0.2))

static func _draw_tread(out: Image) -> void:
	for y in range(0, SIZE, 8):
		out.fill_rect(Rect2i(0, y, SIZE, 3), Color(0.02, 0.02, 0.022))
	for x in range(0, SIZE, 24):
		out.fill_rect(Rect2i(x, 0, 3, SIZE), Color(0.06, 0.06, 0.062))

static func _normal_from_height(height: Image) -> Image:
	var normal := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var bump := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in range(SIZE):
		for x in range(SIZE):
			var v: float = height.get_pixel(x, y).r
			bump.set_pixel(x, y, Color(v, v, v))
	bump.bump_map_to_normal_map(2.2)
	for y in range(SIZE):
		for x in range(SIZE):
			normal.set_pixel(x, y, bump.get_pixel(x, y))
	return normal

static func _rough_from_height(name: String, height: Image) -> Image:
	var out := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var base := 0.92
	match name:
		"asphalt": base = 0.88
		"concrete", "sidewalk", "roof_gravel", "soil": base = 0.93
		"facade_glass", "glass_sheet", "rim_metal": base = 0.24
		"facade_office": base = 0.44
		"metal_panel": base = 0.4
		"paint_wear": base = 0.35
		"tyre_rubber": base = 0.95
	for y in range(SIZE):
		for x in range(SIZE):
			var v: float = height.get_pixel(x, y).r
			var rough := clampf(base - (v - 0.5) * 0.25, 0.04, 1.0)
			out.set_pixel(x, y, Color(rough, rough, rough))
	return out

static func _texture(img: Image, srgb: bool) -> ImageTexture:
	if img == null:
		return null
	if srgb:
		img.set_srgb(true)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	return tex

static func _load_png(path: String) -> ImageTexture:
	if not ResourceLoader.exists(path):
		if not FileAccess.file_exists(path):
			return null
	var res := ResourceLoader.load(path)
	if res is ImageTexture:
		return res
	if res is CompressedTexture2D or res is Texture2D:
		var tex := ImageTexture.create_from_image((res as Texture2D).get_image())
		return tex
	return null
