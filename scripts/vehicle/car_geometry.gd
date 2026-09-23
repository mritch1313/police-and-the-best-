class_name CarGeometry
extends RefCounted
## Процедурная геометрия автомобиля: кузов, остекление, оптика, решётка, зеркала,
## арки, пороги, спойлер, мигалка, колёса (протектор + диск + спицы + суппорт).
##
## Почему не «набор кубов»: кузов — loft (сечение-«суперэллипс», обтянутый по длине)
## со сваренными вершинами и сглаженными нормалями, поэтому блик по капоту и двери
## тянется непрерывно. Стёкла, оптика и обвес — отдельные поверхности своего материала.
## Модель выглядит «средне-реалистично» при нулевом размере ассетов и её можно заменить
## на GLB, не трогая физику/камеру (см. docs/CAR_MODEL.md).
##
## СОГЛАШЕНИЕ О КООРДИНАТАХ (совпадает с WheelSystem и vehicle_physics):
##   начало координат = плоскость ступиц колёс под центром масс; вперёд = -Z; вправо = +X;
##   земля в покое на y = -ride_height_m; днище на y = floor_clearance_m - ride_height_m;
##   «линия окон» = +body_height_m, крыша = +cabin_height_m сверх неё.
##
## НОРМАЛИ. Порядок обхода вершин нигде не подгоняется вручную: у билдера есть
## `ref_center`, и каждая грань разворачивается так, чтобы её нормаль смотрела ОТ этой
## точки (кузов — от центра машины, колесо — от центра ступицы). Все детали звезды-
## выпуклы относительно своей опорной точки, поэтому способ устойчив к правкам и
## гарантирует корректный backface culling на мобильном рендере.
##
## Всё параметризовано `VehicleConfig`: «другая машина» = другие цифры в autoloads/*.cfg.

const SEGMENTS := 18          # станций лофта кузова (чем больше, тем глаже боковина)
const SECTION_POINTS := 14    # точек в сечении
const WHEEL_SEGMENTS := 24
const UV_METERS_PER_TILE := 2.2  # «UV на метр» для кузова (мелкая потёртость по лаку)

static var _cache: Dictionary = {}

static func _key(config: VehicleConfig) -> String:
	return "|".join([
		str(config.body_style), str(config.body_length_m), str(config.body_width_m),
		str(config.wheelbase_m), str(config.track_width_m), str(config.wheel_radius_m),
		str(config.wheel_width_m), str(config.ride_height_m), str(config.floor_clearance_m),
		str(config.body_height_m), str(config.cabin_height_m),
		str(config.windshield_start_ratio), str(config.cabin_end_ratio),
	])

## Основной вход. Возвращает:
##   {"body": ArrayMesh (5 поверхностей), "wheel": ArrayMesh (2 поверхности),
##    "aabb": AABB, "info": Dictionary}
## Результат кэшируется по форме: 20 припаркованных машин и 6 патрульных = одна генерация.
static func build(config: VehicleConfig) -> Dictionary:
	var key := _key(config)
	if not _cache.has(key):
		_cache[key] = _build_parts(config)
	return _cache[key]

static func reset_cache() -> void:
	_cache = {}

static func cached_count() -> int:
	return _cache.size()

## Ключи info, которые обязан вернуть build() — проверяется автотестом.
static func required_info_keys() -> PackedStringArray:
	return PackedStringArray([
		"aabb", "floor_y", "belt_y", "roof_y", "half_length", "half_width",
		"ground_y", "lightbar", "headlight_pos", "taillight_pos", "surface_materials",
		"wheel_surfaces",
	])

## Основные высоты кузова в локальных координатах.
static func heights(config: VehicleConfig) -> Dictionary:
	var style := _style(config)
	var floor_y := config.floor_clearance_m - config.ride_height_m + float(style.get("ride_boost", 0.0))
	var belt_y := floor_y + config.body_height_m
	var roof_y := belt_y + config.cabin_height_m * float(style.get("cabin_scale", 1.0))
	return {
		"floor_y": floor_y,
		"belt_y": belt_y,
		"roof_y": roof_y,
		"half_length": config.body_length_m * 0.5,
		"half_width": config.body_width_m * 0.5,
		"ground_y": -config.ride_height_m,
	}

## Стиль кузова -> пропорции. 0 седан, 1 купе, 2 кроссовер, 3 «перехватчик» ППС.
static func _style(config: VehicleConfig) -> Dictionary:
	match config.body_style:
		1:
			return {
				"cabin_scale": 0.90, "rear_glass": 0.80, "spoiler": true, "lightbar": false,
				"pushbar": false, "rails": false, "ride_boost": 0.0, "haunch": 1.05,
			}
		2:
			return {
				"cabin_scale": 1.14, "rear_glass": 1.05, "spoiler": false, "lightbar": false,
				"pushbar": false, "rails": true, "ride_boost": 0.05, "haunch": 1.06,
			}
		3:
			return {
				"cabin_scale": 1.0, "rear_glass": 1.0, "spoiler": true, "lightbar": true,
				"pushbar": true, "rails": false, "ride_boost": 0.01, "haunch": 1.04,
			}
	return {
		"cabin_scale": 1.0, "rear_glass": 1.0, "spoiler": false, "lightbar": false,
		"pushbar": false, "rails": false, "ride_boost": 0.0, "haunch": 1.0,
	}

# ------------------------------------------------------------------ сборка

static func _build_parts(config: VehicleConfig) -> Dictionary:
	var h := heights(config)
	var style := _style(config)
	var half_l: float = h["half_length"]
	var half_w: float = h["half_width"]
	var floor_y: float = h["floor_y"]
	var belt_y: float = h["belt_y"]
	var roof_y: float = h["roof_y"]
	var ref := Vector3(0.0, (floor_y + roof_y) * 0.5, 0.0)

	var paint := MeshBuilder.new(ref, UV_METERS_PER_TILE)
	var trim := MeshBuilder.new(ref, UV_METERS_PER_TILE)
	var glass := MeshBuilder.new(ref, UV_METERS_PER_TILE)
	var lights := MeshBuilder.new(ref, UV_METERS_PER_TILE)
	var tails := MeshBuilder.new(ref, UV_METERS_PER_TILE)
	var tyre := MeshBuilder.new(Vector3.ZERO, UV_METERS_PER_TILE)
	var metal := MeshBuilder.new(Vector3.ZERO, UV_METERS_PER_TILE)

	# ---- Лофт кузова: сечения по длине + крышка носа/кормы.
	var rings: Array[PackedVector3Array] = []
	for i in range(SEGMENTS + 1):
		var t := lerpf(-1.0, 1.0, float(i) / float(SEGMENTS))
		var nose := clampf((t + 1.0) / 0.32, 0.0, 1.0)
		var tail := clampf((1.0 - t) / 0.28, 0.0, 1.0)
		# Свесы сужаются, «плечи» над арками чуть шире, днище на свесах поднимается
		# (углы въезда/съезда), крыша переднего срезa ниже линии окон (капот).
		var width := half_w * (1.0 - 0.17 * (1.0 - nose) - 0.09 * (1.0 - tail))
		if absf(t) < 0.5:
			width *= float(style.get("haunch", 1.0))
		# Капот ниже линии окон; самая носовая секция уходит ещё ниже — так силуэт
		# читается как седан, а не как «хлебница».
		var top := belt_y - 0.075 * (1.0 - nose) - 0.035 * pow(1.0 - nose, 2.0)
		if t > 0.30:
			top -= 0.045 * clampf((t - 0.30) / 0.7, 0.0, 1.0)
		var bottom := floor_y + 0.11 * (1.0 - nose) + 0.10 * (1.0 - tail)
		rings.append(_ring_at(_section(width, bottom, maxf(top, bottom + 0.08)), t * half_l))
	for i in range(SEGMENTS):
		paint.connect_rings(rings[i], rings[i + 1])
	paint.cap_ring(rings[0], Vector3(0.0, 0.0, -1.0))
	paint.cap_ring(rings[SEGMENTS], Vector3(0.0, 0.0, 1.0))

	# ---- Рубка: крыша (краска) + 4 стекла + уплотнители + стойки.
	var cabin_front := (config.windshield_start_ratio * 2.0 - 1.0) * half_l
	var cabin_rear := clampf(config.cabin_end_ratio * 2.0 - 1.0, -0.2, 0.98) * half_l
	var wind_top_z := lerpf(cabin_front, cabin_rear, 0.34)
	var rear_top_z := lerpf(cabin_rear, cabin_front, 0.24 / maxf(float(style.get("rear_glass", 1.0)), 0.2))
	var bottom_w := half_w * 0.905
	var top_w := half_w * 0.745
	var glass_low := belt_y - 0.03
	paint.add_quad(Vector3(-top_w, roof_y, wind_top_z), Vector3(top_w, roof_y, wind_top_z),
		Vector3(top_w, roof_y, rear_top_z), Vector3(-top_w, roof_y, rear_top_z))
	for side in [-1.0, 1.0]:
		var a_bot := Vector3(side * bottom_w, glass_low, cabin_front)
		var b_bot := Vector3(side * bottom_w, glass_low, cabin_rear)
		var a_top := Vector3(side * top_w, roof_y - 0.008, wind_top_z)
		var b_top := Vector3(side * top_w, roof_y - 0.008, rear_top_z)
		glass.add_quad(a_bot, b_bot, b_top, a_top)
		trim.add_strip(a_top, b_top, Vector3(0.0, -0.026, 0.0))
		trim.add_strip(a_bot, b_bot, Vector3(0.0, 0.024, 0.0))
		paint.add_strip(a_bot, a_top, Vector3(side * 0.030, 0.0, 0.0))
		paint.add_strip(b_bot, b_top, Vector3(side * 0.026, 0.0, 0.0))
	glass.add_quad(Vector3(-bottom_w, glass_low, cabin_front), Vector3(bottom_w, glass_low, cabin_front),
		Vector3(top_w, roof_y - 0.008, wind_top_z), Vector3(-top_w, roof_y - 0.008, wind_top_z))
	glass.add_quad(Vector3(top_w, roof_y - 0.008, rear_top_z), Vector3(-top_w, roof_y - 0.008, rear_top_z),
		Vector3(-bottom_w, glass_low, cabin_rear), Vector3(bottom_w, glass_low, cabin_rear))
	trim.add_strip(Vector3(-bottom_w, glass_low, cabin_front), Vector3(bottom_w, glass_low, cabin_front),
		Vector3(0.0, -0.020, -0.014))

	# ---- Бамперы, «губы», порог, решётка, воздухозаборники.
	for front in [true, false]:
		var bz := -half_l - 0.028 if front else half_l + 0.028
		trim.add_box(Vector3(0.0, floor_y + 0.135, bz), Vector3(half_w * 1.012, 0.085, 0.072))
		trim.add_box(Vector3(0.0, floor_y + 0.030, bz * 0.99), Vector3(half_w * 0.90, 0.020, 0.052))
	trim.add_box(Vector3(0.0, floor_y + 0.018, 0.0), Vector3(half_w + 0.010, 0.040, config.wheelbase_m * 0.46))
	trim.add_box(Vector3(0.0, floor_y + 0.185, -half_l - 0.004), Vector3(half_w * 0.40, 0.052, 0.022))
	for side in [-1.0, 1.0]:
		trim.add_box(Vector3(side * half_w * 0.60, floor_y + 0.135, -half_l - 0.006),
			Vector3(half_w * 0.15, 0.040, 0.018))

	# ---- Оптика, зеркала, ручки, арки.
	for side in [-1.0, 1.0]:
		lights.add_box(Vector3(side * half_w * 0.70, floor_y + 0.255, -half_l + 0.018),
			Vector3(half_w * 0.19, 0.042, 0.028))
		lights.add_box(Vector3(side * half_w * 0.64, floor_y + 0.205, -half_l + 0.010),
			Vector3(half_w * 0.10, 0.014, 0.026))
		tails.add_box(Vector3(side * half_w * 0.68, floor_y + 0.265, half_l - 0.014),
			Vector3(half_w * 0.20, 0.048, 0.024))
		tails.add_box(Vector3(0.0, floor_y + 0.268, half_l - 0.004), Vector3(half_w * 0.26, 0.014, 0.018))
		tails.add_box(Vector3(side * half_w * 0.46, floor_y + 0.120, half_l - 0.010),
			Vector3(0.048, 0.020, 0.018))
		var mirror_z := cabin_front + 0.12
		trim.add_box(Vector3(side * (half_w + 0.050), belt_y - 0.055, mirror_z),
			Vector3(0.072, 0.014, 0.020))
		trim.add_box(Vector3(side * (half_w + 0.118), belt_y - 0.028, mirror_z + 0.012),
			Vector3(0.058, 0.042, 0.028))
		glass.add_box(Vector3(side * (half_w + 0.172), belt_y - 0.026, mirror_z + 0.012),
			Vector3(0.006, 0.032, 0.021))
		trim.add_box(Vector3(side * (half_w + 0.010), belt_y - 0.165, mirror_z + 0.32),
			Vector3(0.012, 0.018, 0.070))
		# Зазор двери — тонкая тёмная полоса: даёт «читаемый» бок машины.
		trim.add_strip(Vector3(side * (half_w + 0.002), floor_y + 0.07, cabin_front - 0.10),
			Vector3(side * (half_w + 0.002), belt_y - 0.02, cabin_front - 0.10), Vector3(0.0, 0.0, 0.012))
		# Арка: тёмная дуга-«шахта» над каждым колесом.
		for front in [true, false]:
			var wz := -config.wheelbase_m * 0.5 if front else config.wheelbase_m * 0.5
			trim.add_arch(Vector3(0.0, floor_y + config.wheel_radius_m * 0.95, wz),
				side * (half_w + 0.004), config.wheel_radius_m * 1.24, 0.05)

	# ---- Стилевые дополнения.
	if bool(style.get("spoiler", false)):
		var wing_z := half_l - 0.040
		paint.add_box(Vector3(0.0, belt_y + 0.085, wing_z), Vector3(half_w * 0.78, 0.014, 0.110))
		for side in [-1.0, 1.0]:
			trim.add_box(Vector3(side * half_w * 0.60, belt_y + 0.045, wing_z - 0.008),
				Vector3(0.020, 0.050, 0.070))
	if bool(style.get("rails", false)):
		for side in [-1.0, 1.0]:
			trim.add_box(Vector3(side * top_w * 0.84, roof_y + 0.020, (wind_top_z + rear_top_z) * 0.5),
				Vector3(0.024, 0.013, absf(rear_top_z - wind_top_z) * 0.44))
	var lightbar: PackedVector3Array = PackedVector3Array()
	var bar_z := (wind_top_z + rear_top_z) * 0.5
	if bool(style.get("lightbar", false)):
		trim.add_box(Vector3(0.0, roof_y + 0.038, bar_z), Vector3(top_w * 1.00, 0.038, 0.140))
		for side in [-1.0, 1.0]:
			trim.add_box(Vector3(side * top_w * 0.34, roof_y + 0.070, bar_z),
				Vector3(top_w * 0.30, 0.026, 0.126))
		lightbar.append(Vector3(-top_w * 0.62, roof_y + 0.070, bar_z))
		lightbar.append(Vector3(top_w * 0.62, roof_y + 0.070, bar_z))
		# «Сине-белые» борта на капоте и дверях — патрульный кузов без текстуры.
		for side in [-1.0, 1.0]:
			trim.add_box(Vector3(side * (half_w + 0.004), floor_y + 0.30, cabin_front - 0.42),
				Vector3(0.008, 0.075, 0.30))
	if bool(style.get("pushbar", false)):
		trim.add_box(Vector3(0.0, floor_y + 0.20, -half_l - 0.095), Vector3(half_w * 0.84, 0.022, 0.022))
		for side in [-1.0, 1.0]:
			trim.add_box(Vector3(side * half_w * 0.70, floor_y + 0.135, -half_l - 0.055),
				Vector3(0.024, 0.075, 0.024))

	_build_wheel(config, tyre, metal)

	var body_mesh := ArrayMesh.new()
	paint.commit(body_mesh)
	trim.commit(body_mesh)
	glass.commit(body_mesh)
	lights.commit(body_mesh)
	tails.commit(body_mesh)
	var wheel_mesh := ArrayMesh.new()
	tyre.commit(wheel_mesh)
	metal.commit(wheel_mesh)

	var info := {
		"aabb": body_mesh.get_aabb(),
		"floor_y": floor_y,
		"belt_y": belt_y,
		"roof_y": roof_y,
		"half_length": half_l,
		"half_width": half_w,
		"ground_y": h["ground_y"],
		"lightbar": lightbar,
		"bar_z": bar_z,
		"headlight_pos": Vector3(half_w * 0.70, floor_y + 0.255, -half_l + 0.018),
		"taillight_pos": Vector3(half_w * 0.68, floor_y + 0.265, half_l - 0.014),
		"surface_materials": PackedStringArray(["car_paint", "car_trim", "car_glass", "car_light", "car_tail"]),
		"wheel_surfaces": PackedStringArray(["car_tyre", "car_rim"]),
		"triangle_counts": [paint.count(), trim.count(), glass.count(), lights.count(), tails.count()],
		"wheel_triangles": [tyre.count(), metal.count()],
	}
	return {"body": body_mesh, "wheel": wheel_mesh, "aabb": info["aabb"], "info": info}

## Сечение кузова: суперэллипс (почти прямоугольник со скруглением) в плоскости XY.
static func _section(half_w: float, y0: float, y1: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var cy := (y0 + y1) * 0.5
	var hy := maxf((y1 - y0) * 0.5, 0.02)
	var power := 0.62  # <1 -> «квадратное со скруглением», как у штампованной панели
	for i in range(SECTION_POINTS):
		var a := TAU * float(i) / float(SECTION_POINTS)
		var ca := cos(a)
		var sa := sin(a)
		var sx := signf(ca) * pow(absf(ca), power)
		var sy := signf(sa) * pow(absf(sa), power)
		pts.append(Vector3(half_w * sx, cy + hy * sy, 0.0))
	return pts

## Колесо: беговая дорожка, боковины, диск, спицы, колпак, тормозной диск, суппорт.
static func _build_wheel(config: VehicleConfig, tyre: MeshBuilder, metal: MeshBuilder) -> void:
	var r := config.wheel_radius_m
	var w := config.wheel_width_m
	var rim_r := r * 0.64
	var disc_r := r * 0.52
	for side in [-1.0, 1.0]:
		tyre.add_band(side * w * 0.50, side * w * 0.26, r * 0.97, r, WHEEL_SEGMENTS)
		tyre.add_band(side * w * 0.26, side * w * 0.20, rim_r * 1.03, r * 0.97, WHEEL_SEGMENTS)
		metal.add_band(side * w * 0.20, side * w * 0.08, rim_r * 0.99, rim_r * 1.03, WHEEL_SEGMENTS)
		metal.add_disc(side * w * 0.08, rim_r * 0.99, WHEEL_SEGMENTS)
		metal.add_disc(side * w * 0.065, r * 0.19, 12)
		for i in range(5):
			var a := TAU * float(i) / 5.0 + side * 0.08
			var dir := Vector2(cos(a), sin(a))
			var nrm := Vector2(-dir.y, dir.x) * r * 0.075
			var z := side * w * 0.10
			metal.add_quad(
				Vector3(dir.x * r * 0.17 + nrm.x, dir.y * r * 0.17 + nrm.y, z),
				Vector3(dir.x * r * 0.17 - nrm.x, dir.y * r * 0.17 - nrm.y, z),
				Vector3(dir.x * rim_r * 0.97 - nrm.x * 0.7, dir.y * rim_r * 0.97 - nrm.y * 0.7, z),
				Vector3(dir.x * rim_r * 0.97 + nrm.x * 0.7, dir.y * rim_r * 0.97 + nrm.y * 0.7, z),
			)
	# Тормозной диск «сквозной» + суппорт: видно между спицами.
	tyre.add_band(-w * 0.055, w * 0.055, disc_r, disc_r * 0.99, WHEEL_SEGMENTS)
	metal.add_band(w * 0.055, w * 0.11, disc_r * 0.60, disc_r, WHEEL_SEGMENTS)
	metal.add_box(Vector3(disc_r * 0.80, disc_r * 0.35, w * 0.085), Vector3(w * 0.075, disc_r * 0.24, disc_r * 0.30))

# ------------------------------------------------------------------ коллизия

## Точки для ConvexPolygonShape3D: силуэт машины вместо «коробки». Берём contour
## сечений по длине + колёса, оболочку строит сам движок.
static func collision_points(config: VehicleConfig) -> PackedVector3Array:
	var h := heights(config)
	var half_l: float = h["half_length"]
	var half_w: float = h["half_width"]
	var pts := PackedVector3Array()
	for t in [-1.0, -0.55, 0.0, 0.55, 1.0]:
		var z := t * half_l
		var shrink := 0.87 if absf(t) > 0.95 else 1.0
		for sx in [-1.0, 1.0]:
			for sy in [h["floor_y"], h["belt_y"], h["roof_y"]]:
				pts.append(Vector3(sx * half_w * shrink, sy, z))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			pts.append(Vector3(
				sx * (config.track_width_m * 0.5 + config.wheel_width_m * 0.5),
				-config.ride_height_m + config.wheel_radius_m,
				sz * config.wheelbase_m * 0.5))
	for sx in [-1.0, 1.0]:
		pts.append(Vector3(sx * (half_w + 0.18), h["belt_y"] - 0.03, (config.windshield_start_ratio * 2.0 - 1.0) * half_l + 0.12))
	return pts

static func collision_aabb(config: VehicleConfig) -> AABB:
	var h := heights(config)
	var half_l: float = h["half_length"]
	var half_w: float = h["half_width"]
	return AABB(
		Vector3(-half_w, h["floor_y"], -half_l),
		Vector3(half_w * 2.0, maxf(h["roof_y"] - h["floor_y"], 0.2), half_l * 2.0)
	)

## Развесовка «визуальных» масс для теста центровки: не используется в физике,
## только в отладочном выводе (docs/PHYSICS.md).
static func describe(config: VehicleConfig) -> String:
	var h := heights(config)
	return "Кузов: L=%.2f W=%.2f floor=%.2f belt=%.2f roof=%.2f style=%d" % [
		config.body_length_m, config.body_width_m, h["floor_y"], h["belt_y"], h["roof_y"], config.body_style,
	]

## Assign materials to surfaces in the order produced above (5 для кузова, 2 для колеса).
static func set_surface_materials(mesh: ArrayMesh, names: PackedStringArray) -> void:
	for i in range(mini(mesh.get_surface_count(), names.size())):
		var mat := MaterialLibrary.get_material(names[i])
		if mat != null:
			mesh.surface_set_material(i, mat)

## Перемещает z-компоненту сечения (loft собирается кольцами в XY, z задаётся станцией).
static func _ring_at(section: PackedVector3Array, z: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in section:
		out.append(Vector3(p.x, p.y, z))
	return out
