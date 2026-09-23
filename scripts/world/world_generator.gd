class_name WorldGenerator
extends RefCounted
## Детерминированная планировка мира: дороги, кварталы, здания, малые формы.
##
## Здесь НЕТ узлов и мешей — только данные. Геометрию собирает `ChunkBuilder`,
## стримингом командует `WorldStreamer`, топ-даун карта для превью уровня считается
## из ЭТИХ ЖЕ данных (иначе «скриншот карты» врал бы о том, что реально в игре).
##
## ДЕТЕРМИНИЗМ. Никакой зависимости от порядка обхода хеш-таблиц и от времени: на каждый
## объект свой `RandomNumberGenerator` с seed = хеш(global seed, индекс ячейки, тип объекта).
## Один и тот же чанк на Android и в headless-прогоне = бит-в-бит одинаковая застройка,
## поэтому скриншоты CI сравнимы, а баги воспроизводимы.
##
## ЧТО СТРОИТСЯ (соответствует требованию «бетон на 500 м во все стороны» + плотный город):
##   * квадрат мира ±world_radius_m, по периметру — бетонные блоки и забор (обрыва нет);
##   * центральная бетонная площадь `plaza_radius_m` с разметкой «полигона» (круги, прямые,
##     парковочные карманы) — именно на неё спавнится игрок;
##   * прямоугольная сетка дорог с шагом block_pitch_m, каждый avenue_every — проспект;
##   * кварталы: дома вдоль периметра (цоколь, этажные ленты, карниз, балконы, кровельная
##     инженерка), внутренний двор, парковка у бордюра, фонари, деревья, урны, конусы.
##
## ПОВЕРХНОСТИ РАЗНЫХ УРОВНЕЙ. Земля плоская, поэтому «слои» разнесены по Y на миллиметры
## (Y_ROAD < Y_PLAZA < Y_SIDEWALK < Y_MARKING) — стандартный приём против z-fighting
## без полигон-смещения шейдера, который на Mali стоит дороже.

const SURFACE_ROAD := &"road"
const SURFACE_PLAZA := &"concrete"
const SURFACE_SIDEWALK := &"sidewalk"
const SURFACE_LOT := &"lot"
const SURFACE_PARK := &"park"
const SURFACE_YARD := &"yard"

## Y-уровни плоскостей (метры над cfg.ground_y_m).
const Y_ROAD := 0.0
const Y_PLAZA := 0.003
const Y_SIDEWALK := 0.032
const Y_LOT := 0.012
const Y_MARKING := 0.056

const LAYOUT_CACHE_LIMIT := 40
## Допуск при проверке, что геометрия не вылезла за границы чанка (м).
const RECT_TOLERANCE_M := 0.02

static var _layout_cache: Dictionary = {}

static func reset() -> void:
	_layout_cache = {}

static func layout_cache_size() -> int:
	return _layout_cache.size()

# ------------------------------------------------------------------ сетка

static func chunk_size(cfg: WorldConfig) -> float:
	return maxf(cfg.chunk_size_m, 40.0)

static func pitch(cfg: WorldConfig) -> float:
	return maxf(cfg.block_pitch_m, 20.0)

static func chunk_index_for(position: Vector3, cfg: WorldConfig) -> Vector2i:
	var size := chunk_size(cfg)
	return Vector2i(int(floorf(position.x / size)), int(floorf(position.z / size)))

static func chunk_origin(index: Vector2i, cfg: WorldConfig) -> Vector2:
	var size := chunk_size(cfg)
	return Vector2(float(index.x) * size, float(index.y) * size)

## Чанк владеет кварталом, если центр ячейки попал в его прямоугольник: так один квартал
## не отстраивается двумя чанками и не исчезает на стыке.
static func cell_owned_by_chunk(cell: Vector2i, chunk: Vector2i, cfg: WorldConfig) -> bool:
	var center := cell_center(cell, cfg)
	var size := chunk_size(cfg)
	var origin := Vector2(float(chunk.x) * size, float(chunk.y) * size)
	var local := center - origin
	return local.x >= 0.0 and local.x < size and local.y >= 0.0 and local.y < size

static func cell_center(cell: Vector2i, cfg: WorldConfig) -> Vector2:
	var step := pitch(cfg)
	return Vector2((float(cell.x) + 0.5) * step, (float(cell.y) + 0.5) * step)

static func cell_from_position(position: Vector2, cfg: WorldConfig) -> Vector2i:
	var step := pitch(cfg)
	return Vector2i(int(floorf(position.x / step)), int(floorf(position.y / step)))

static func is_avenue(line_index: int, cfg: WorldConfig) -> bool:
	return posmod(line_index, maxi(cfg.avenue_every, 2)) == 0

static func road_half_width(line_index: int, cfg: WorldConfig) -> float:
	return (cfg.avenue_width_m if is_avenue(line_index, cfg) else cfg.road_width_m) * 0.5

static func line_offset(line_index: int, cfg: WorldConfig) -> float:
	return float(line_index) * pitch(cfg)

## Индексы линий сетки, которые видны в чанке (с запасом в 1 линию).
static func line_index_range(chunk_index: int, cfg: WorldConfig) -> Vector2i:
	var step := pitch(cfg)
	var size := chunk_size(cfg)
	var lo := int(floorf((float(chunk_index) * size) / step)) - 1
	var hi := int(ceilf((float(chunk_index) * size + size) / step)) + 1
	return Vector2i(lo, hi)

static func plaza_radius(cfg: WorldConfig) -> float:
	return clampf(pitch(cfg) * 1.65, 40.0, maxf(cfg.world_radius_m * 0.62, 60.0))

## Точка появления игрока: центр площади, Y = земля + высота ступиц + запас.
static func spawn_point(cfg: WorldConfig) -> Vector3:
	return Vector3(0.0, cfg.ground_y_m + cfg.spawn_height_m, 0.0)

# ------------------------------------------------------------------ случайности

static func _hash4(a: int, b: int, c: int, seed: int) -> int:
	var h := uint64(a) * 73856093 + uint64(b) * 19349663 + uint64(c) * 83492791 + uint64(seed) * 1103515245
	h = h ^ (h >> 15)
	h *= 2654435761
	h = h ^ (h >> 13)
	return int(h & 0x7fffffff)

static func rng_for(a: int, b: int, kind: int, cfg: WorldConfig) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = _hash4(a, b, kind, cfg.seed)
	return rng

# ------------------------------------------------------------------ планировка чанка

static func chunk_layout(chunk: Vector2i, cfg: WorldConfig) -> Dictionary:
	var key := "%d:%d:%d:%d" % [chunk.x, chunk.y, cfg.seed, int(round(pitch(cfg) * 10.0))]
	if _layout_cache.has(key):
		return _layout_cache[key]
	var layout := _build_layout(chunk, cfg)
	if _layout_cache.size() >= LAYOUT_CACHE_LIMIT:
		_layout_cache.clear()
	_layout_cache[key] = layout
	return layout

static func _build_layout(chunk: Vector2i, cfg: WorldConfig) -> Dictionary:
	var size := chunk_size(cfg)
	var origin := chunk_origin(chunk, cfg)
	var plaza := plaza_radius(cfg)
	var ground: Array = []
	var markings: Array = []
	var buildings: Array = []
	var props: Array = []

	# 1) Дороги: полоса асфальта на каждую линию сетки, обрезанная прямоугольником чанка.
	var chunk_rect := Rect2(Vector2.ZERO, Vector2(size, size))
	var rx := line_index_range(chunk.x, cfg)
	var rz := line_index_range(chunk.y, cfg)
	for i in range(rx.x, rx.y + 1):
		var half := road_half_width(i, cfg)
		var rect := Rect2(Vector2(line_offset(i, cfg) - half, 0.0), Vector2(half * 2.0, size)).intersection(chunk_rect)
		if rect.size.x > 0.5:
			ground.append(_quad(rect, SURFACE_ROAD, Y_ROAD, 0.0))
			_mark_lane_lines(rect, true, origin, i, cfg, markings)
	for i in range(rz.x, rz.y + 1):
		var half := road_half_width(i, cfg)
		var rect := Rect2(Vector2(0.0, line_offset(i, cfg) - half), Vector2(size, half * 2.0)).intersection(chunk_rect)
		if rect.size.y > 0.5:
			ground.append(_quad(rect, SURFACE_ROAD, Y_ROAD + 0.0005, 0.0))
			_mark_lane_lines(rect, false, origin, i, cfg, markings)
	# 2) Тротуары по обе стороны каждой линии. Отрезки РЕЖУТСЯ по перпендикулярным дорогам:
	# иначе тротуар тянется через перекрёсток, а бордюр торчит посреди проспекта.
	for i in range(rx.x, rx.y + 1):
		var half := road_half_width(i, cfg)
		for side in [-1.0, 1.0]:
			var center_x := line_offset(i, cfg) + side * (half + cfg.sidewalk_width_m * 0.5)
			for seg in split_interval(0.0, size, rz, half + cfg.sidewalk_width_m * 0.5, cfg, origin.y):
				var rect := Rect2(Vector2(center_x - origin.x - cfg.sidewalk_width_m * 0.5, seg.x),
					Vector2(cfg.sidewalk_width_m, seg.y - seg.x)).intersection(chunk_rect)
				if rect.size.x > 0.4 and rect.size.y > 0.4:
					ground.append(_quad(rect, SURFACE_SIDEWALK, Y_SIDEWALK, 0.0))
	for i in range(rz.x, rz.y + 1):
		var half := road_half_width(i, cfg)
		for side in [-1.0, 1.0]:
			var center_z := line_offset(i, cfg) + side * (half + cfg.sidewalk_width_m * 0.5)
			for seg in split_interval(0.0, size, rx, half + cfg.sidewalk_width_m * 0.5, cfg, origin.x):
				var rect := Rect2(Vector2(seg.x, center_z - origin.y - cfg.sidewalk_width_m * 0.5),
					Vector2(seg.y - seg.x, cfg.sidewalk_width_m)).intersection(chunk_rect)
				if rect.size.x > 0.4 and rect.size.y > 0.4:
					ground.append(_quad(rect, SURFACE_SIDEWALK, Y_SIDEWALK, 0.0))

	# 3) Перекрёстки: «зебра» с четырёх сторон.
	for i in range(rx.x, rx.y + 1):
		for j in range(rz.x, rz.y + 1):
			var center := Vector2(line_offset(i, cfg), line_offset(j, cfg)) - origin
			if center.x < -12.0 or center.y < -12.0 or center.x > size + 12.0 or center.y > size + 12.0:
				continue
			_add_crosswalk(center, road_half_width(i, cfg), road_half_width(j, cfg), cfg, markings)
	# 4) Площадь под спавн поверх всего остального грунта.
	var plaza_rect := Rect2(Vector2(-plaza, -plaza), Vector2(plaza * 2.0, plaza * 2.0)).translated(-origin)
	var plaza_clipped := plaza_rect.intersection(chunk_rect)
	if plaza_clipped.size.x > 0.5 and plaza_clipped.size.y > 0.5:
		ground.append(_quad(plaza_clipped, SURFACE_PLAZA, Y_PLAZA, 0.0))
		_add_plaza_markings(plaza_clipped, plaza, cfg, markings)
	# 5) Кварталы.
	var step := pitch(cfg)
	var cell_base := Vector2i(int(floorf(origin.x / step)), int(floorf(origin.y / step)))
	for cx in range(cell_base.x - 1, cell_base.x + 3):
		for cy in range(cell_base.y - 1, cell_base.y + 3):
			if not cell_owned_by_chunk(Vector2i(cx, cy), chunk, cfg):
				continue
			var rect := _cell_rect(cx, cy, cfg).translated(-origin)
			var clipped := rect.intersection(chunk_rect)
			if clipped.size.x < 6.0 or clipped.size.y < 6.0:
				continue
			var in_plaza := cell_center(Vector2i(cx, cy), cfg).length() <= plaza + step * 0.35
			_build_block(cx, cy, clipped, in_plaza, cfg, ground, markings, buildings, props)
	# 6) Уличная мебель и граница мира.
	_add_street_furniture(chunk, origin, size, cfg, props)
	_add_world_edge(chunk, origin, size, cfg, buildings, props)

	var aabb := AABB(Vector3(0.0, 0.0, 0.0), Vector3(size, 1.0, size))
	return {
		"chunk": chunk,
		"origin": Vector3(origin.x, 0.0, origin.y),
		"origin_xz": origin,
		"size": size,
		"ground": ground,
		"markings": markings,
		"buildings": buildings,
		"props": props,
		"in_plaza": plaza_clipped.size.x > 0.5,
		"aabb_local": aabb,
	}

## Интервалы [lo,hi] (локальные координаты чанка) без «зон» перпендикулярных дорог.
## `pad` — половина выреза (дорога + зазор под тротуар), `subtract` — мировая координата
## начала чанка по нужной оси: переводит оси дорог из мировых координат в локальные.
static func split_interval(
	lo: float,
	hi: float,
	perp_range: Vector2i,
	pad: float,
	cfg: WorldConfig,
	subtract: float,
)-> PackedVector2Array:
	var out := PackedVector2Array()
	var cursor := lo
	for i in range(perp_range.x, perp_range.y + 1):
		var center := line_offset(i, cfg) - subtract
		var cut_lo := center - pad
		var cut_hi := center + pad
		if cut_hi <= lo or cut_lo >= hi:
			continue
		if cut_lo > cursor:
			out.append(Vector2(cursor, minf(cut_lo, hi)))
		cursor = maxf(cursor, minf(cut_hi, hi))
	if cursor < hi:
		out.append(Vector2(cursor, hi))
	return out

static func _quad(rect: Rect2, surface: StringName, y: float, tint: float) -> Dictionary:
	return {"rect": rect, "surface": surface, "y": y, "tint": tint}

## Прямоугольник квартала между осями дорог минус половина ширины каждой дороги.
static func _cell_rect(cx: int, cy: int, cfg: WorldConfig) -> Rect2:
	var step := pitch(cfg)
	var left := float(cx) * step + road_half_width(cx, cfg)
	var top := float(cy) * step + road_half_width(cy, cfg)
	var right := float(cx + 1) * step - road_half_width(cx + 1, cfg)
	var bottom := float(cy + 1) * step - road_half_width(cy + 1, cfg)
	return Rect2(Vector2(left, top), Vector2(maxf(right - left, 4.0), maxf(bottom - top, 4.0)))

# ------------------------------------------------------------------ квартал

static func _build_block(
	cx: int, cy: int, rect: Rect2, in_plaza: bool, cfg: WorldConfig,
	ground: Array, markings: Array, buildings: Array, props: Array
) -> void:
	var rng := rng_for(cx, cy, 1, cfg)
	if in_plaza:
		ground.append(_quad(rect, SURFACE_PLAZA, Y_PLAZA + 0.001, rng.randf_range(-0.4, 0.4)))
		_parking_bays(rect, rng, cfg, markings, props)
		return
	var inset := cfg.lot_inset_m + cfg.sidewalk_width_m
	var inner := rect.grow(-inset)
	if inner.size.x < 8.0 or inner.size.y < 8.0:
		ground.append(_quad(rect, SURFACE_LOT, Y_LOT, 0.0))
		return
	var roll := rng_for(cx, cy, 2, cfg).randf()
	if roll < clampf(cfg.building_density, 0.05, 1.0):
		_perimeter_buildings(cx, cy, rect, inner, rng, cfg, buildings, props, ground, markings)
		return
	# Свободный квартал: парк / промзона / пустырь.
	var kind: StringName = SURFACE_LOT
	match int(roll * 7.0) % 3:
		0:
			kind = SURFACE_PARK
		1:
			kind = SURFACE_YARD
		_:
			kind = SURFACE_LOT
	ground.append(_quad(rect, kind, Y_LOT, rng.randf_range(-0.4, 0.4)))
	if kind == SURFACE_YARD:
		for i in range(rng.randi_range(1, 4)):
			_add_shed(cx * 7 + i, cy, inner, rng, cfg, buildings)
	var tree_count := rng.randi_range(4, 11) if kind == SURFACE_PARK else rng.randi_range(0, 3)
	for i in range(tree_count):
		_add_prop("tree", Vector2(
			rng.randf_range(inner.position.x, inner.end.x),
			rng.randf_range(inner.position.y, inner.end.y)), rng, cfg, props)
	_parking_bays(rect, rng, cfg, markings, props)

static func _perimeter_buildings(
	cx: int, cy: int, rect: Rect2, inner: Rect2, rng: RandomNumberGenerator, cfg: WorldConfig,
	buildings: Array, props: Array, ground: Array, markings: Array
) -> void:
	ground.append(_quad(rect, SURFACE_LOT, Y_LOT, rng.randf_range(-0.3, 0.3)))
	var density := clampf(cfg.building_density, 0.2, 1.0)
	for side in range(4):
		var along_x := side < 2
		var at_start := (side % 2) == 0
		var lo := inner.position.x if along_x else inner.position.y
		var hi := inner.end.x if along_x else inner.end.y
		var cross_lo := inner.position.y if along_x else inner.position.x
		var cross_hi := inner.end.y if along_x else inner.end.x
		var max_depth := maxf((cross_hi - cross_lo) * 0.55, 10.0)
		var cursor := lo
		# Жёсткий потолок итераций: генератор мира не имеет права зависнуть даже на
		# вырожденном конфиге (нулевой шаг, кривой pitch) - игра должна открыться.
		var guard := 0
		while cursor < hi - 8.0 and guard < 512:
			guard += 1
			if rng.randf() > density:
				cursor += rng.randf_range(5.0, 12.0)
				continue
			var width := minf(rng.randf_range(11.0, 28.0), hi - cursor)
			if width < 8.0:
				break
			var depth := rng.randf_range(9.0, max_depth)
			var footprint: Rect2
			if along_x:
				footprint = Rect2(Vector2(cursor, cross_lo if at_start else cross_hi - depth), Vector2(width, depth))
			else:
				footprint = Rect2(Vector2(cross_lo if at_start else cross_hi - depth, cursor), Vector2(depth, width))
			_add_building(cx * 31 + int(cursor * 4.0), cy * 17 + side, footprint, side, rng, cfg, buildings, props)
			cursor += width + rng.randf_range(1.0, 3.5)
	_courtyard(cx, cy, inner, rng, cfg, props, ground, markings)

static func _style_for(rng: RandomNumberGenerator, cfg: WorldConfig) -> String:
	var roll := rng.randf()
	if roll < cfg.office_share:
		return "office"
	roll -= cfg.office_share
	if roll < cfg.brick_share:
		return "brick"
	roll -= cfg.brick_share
	if roll < cfg.industrial_share:
		return "industrial"
	return "residential"

static func _add_building(
	a: int, b: int, footprint: Rect2, side: int, rng: RandomNumberGenerator, cfg: WorldConfig,
	buildings: Array, props: Array
) -> void:
	var style := _style_for(rng_for(a, b, 3, cfg), cfg)
	var floor_cap := 26 if style == "office" else (8 if style == "industrial" else 17)
	var floors := rng.randi_range(
		clampi(cfg.min_floors, 1, floor_cap),
		clampi(int(float(cfg.max_floors) * (1.25 if style == "office" else 1.0)), 2, floor_cap)
	)
	var floor_height := cfg.floor_height_m
	var height := maxf(float(floors) * floor_height, floor_height)
	buildings.append({
		"footprint": footprint,
		"side": side,
		"floors": floors,
		"height": height,
		"floor_height": floor_height,
		"style": style,
		"shopfront": style != "industrial" and rng.randf() < cfg.shopfront_share,
		"balconies": style == "residential" and rng.randf() < cfg.balcony_share,
		"parapet": 0.45 + rng.randf_range(0.0, 0.6),
		"roof_units": rng.randf() < cfg.rooftop_props_share,
		"tint": rng.randf_range(-0.09, 0.09),
		"entrance": rng.randf_range(0.15, 0.85),
		"wing": rng.randf_range(0.0, 1.0),
	})
	if style == "industrial":
		props.append({"type": "dumpster", "pos": Vector3(footprint.end.x - 2.0, 0.0, footprint.position.y + footprint.size.y * 0.5),
			"rot": 1.5708, "scale": rng.randf_range(0.95, 1.25), "tint": rng.randf()})
	elif rng.randf() < cfg.props_for_small_buildings:
		_add_prop("bin", Vector2(
			footprint.position.x + footprint.size.x * rng.randf_range(0.1, 0.9),
			footprint.position.y - 1.2 if side == 0 else footprint.end.y + 1.2), rng, cfg, props)

static func _add_shed(_a: int, _b: int, inner: Rect2, rng: RandomNumberGenerator, _cfg: WorldConfig, buildings: Array) -> void:
	var w := rng.randf_range(9.0, 20.0)
	var d := rng.randf_range(7.0, 15.0)
	var pos := Vector2(
		rng.randf_range(inner.position.x, maxf(inner.end.x - w, inner.position.x)),
		rng.randf_range(inner.position.y, maxf(inner.end.y - d, inner.position.y))
	)
	buildings.append({
		"footprint": Rect2(pos, Vector2(w, d)),
		"side": 0, "floors": 1, "height": rng.randf_range(4.5, 9.0), "floor_height": 4.0,
		"style": "industrial", "shopfront": false, "balconies": false, "parapet": 0.25,
		"roof_units": true, "tint": rng.randf_range(-0.05, 0.08), "entrance": 0.5, "wing": rng.randf(),
	})

static func _courtyard(
	_cx: int,
	_cy: int,
	inner: Rect2,
	rng: RandomNumberGenerator,
	cfg: WorldConfig,
	props: Array,
	ground: Array,
	_markings: Array,
)-> void:
	if rng.randf() > 0.6:
		return
	var center := inner.get_center()
	ground.append(_quad(Rect2(inner.position + inner.size * 0.18, inner.size * 0.64), SURFACE_LOT, Y_LOT + 0.004, 0.15))
	for i in range(rng.randi_range(2, 6)):
		_add_prop("tree", Vector2(center.x + rng.randf_range(-1.0, 1.0) * inner.size.x * 0.3, center.y + rng.randf_range(-1.0,
			1.0) * inner.size.y * 0.3), rng, cfg, props)
	for i in range(rng.randi_range(0, 3)):
		_add_prop("bench", Vector2(rng.randf_range(inner.position.x + 2.0, inner.end.x - 2.0), rng.randf_range(inner.position.y + 2.0,
			inner.end.y - 2.0)), rng, cfg, props)

static func _parking_bays(rect: Rect2, rng: RandomNumberGenerator, cfg: WorldConfig, markings: Array, props: Array) -> void:
	if cfg.parking_bay_m <= 0.05:
		return
	var bay := cfg.parking_bay_m
	for side in [-1.0, 1.0]:
		var z := rect.position.y - 1.5 if side < 0.0 else rect.end.y + 1.5
		var x := rect.position.x
		while x < rect.end.x - 3.0:
			markings.append({
				"rect": Rect2(Vector2(x, z - 0.05), Vector2(0.12, 2.0)),
				"surface": &"marking", "y": Y_MARKING - 0.002, "rot": 0.0,
			})
			if rng.randf() < 0.44:
				props.append({
					"type": "parked_car",
					"pos": Vector3(x + bay * 0.5, 0.0, z + side * 0.9),
					"rot": rng.randf_range(-0.05, 0.05) + (0.0 if side < 0.0 else PI),
					"scale": rng.randf_range(0.97, 1.05),
					"tint": rng.randf(),
				})
			x += bay

static func _add_prop(kind: String, position: Vector2, rng: RandomNumberGenerator, _cfg: WorldConfig, props: Array) -> void:
	props.append({
		"type": kind,
		"pos": Vector3(position.x, 0.0, position.y),
		"rot": rng.randf_range(0.0, TAU),
		"scale": rng.randf_range(0.85, 1.3),
		"tint": rng.randf(),
	})

# ------------------------------------------------------------------ разметка

## Пунктир между полосами + осевая линия. Фаза считается в МИРОВЫХ координатах,
## иначе через границу чанка пунктир «разъезжается».
static func _mark_lane_lines(
	rect: Rect2,
	along_x: bool,
	origin: Vector2,
	line_index: int,
	cfg: WorldConfig,
	markings: Array,
)-> void:
	if not cfg.road_markings:
		return
	var dash := maxf(cfg.dash_length_m, 0.5)
	var gap := maxf(cfg.dash_gap_m, 0.5)
	var period := dash + gap
	var avenue := is_avenue(line_index, cfg)
	var width := rect.size.x if along_x else rect.size.y
	var center := (rect.size.y * 0.5) if along_x else (rect.size.x * 0.5)
	var lanes := 2 if avenue else 1
	for lane in range(-lanes, lanes + 1):
		if lane == 0 and not avenue:
			continue
		var offset := center + float(lane) * (width / float(2 * lanes + 1))
		var world_start := (rect.position.x if along_x else rect.position.y) + (origin.x if along_x else origin.y)
		var first := ceilf(world_start / period) * period
		var k := 0
		while true:
			var world_pos := first + float(k) * period
			var local := world_pos - (origin.x if along_x else origin.y)
			if local > (rect.end.x if along_x else rect.end.y):
				break
			if local + dash > (rect.position.x if along_x else rect.position.y) - 0.1:
				var seg: Rect2
				var length := minf(dash * 2.4, (rect.end.x if along_x else rect.end.y) - local)
				if lane == 0:
					# Осевая: двойная сплошная на проспекте, одинарная на обычной дороге.
					seg = _dash_rect(Rect2(Vector2(local, offset - 0.30), Vector2(length, 0.16)),
						Rect2(Vector2(offset - 0.30, local), Vector2(0.16, length)), along_x)
					markings.append({"rect": seg, "surface": &"marking", "y": Y_MARKING, "rot": 0.0})
					seg = _dash_rect(Rect2(Vector2(local, offset + 0.16), Vector2(length, 0.16)),
						Rect2(Vector2(offset + 0.16, local), Vector2(0.16, length)), along_x)
				else:
					seg = _dash_rect(Rect2(Vector2(local, offset - 0.09), Vector2(dash, 0.18)),
						Rect2(Vector2(offset - 0.09, local), Vector2(0.18, dash)), along_x)
					markings.append({"rect": seg, "surface": &"marking", "y": Y_MARKING, "rot": 0.0})
			k += 1
			if k > 400:
				break

## «Зебра»: 4 полосы с обеих сторон перекрёстка. Вынесено, чтобы вызовы оставались
## короткими и читаемыми (иначе строки на 170 символов, которые режет даже форматтер).
static func _zebra(markings: Array, rect: Rect2) -> void:
	markings.append({"rect": rect, "surface": &"marking", "y": Y_MARKING + 0.001, "rot": 0.0})


static func _dash_rect(along_rect: Rect2, across_rect: Rect2, along_x: bool) -> Rect2:
	return along_rect if along_x else across_rect


static func _add_crosswalk(center: Vector2, half_x: float, half_z: float, cfg: WorldConfig, markings: Array) -> void:
	if not cfg.road_markings:
		return
	for i in range(8):
		var t := (float(i) - 3.5) * 0.72
		var band := Vector2(0.52, 0.70)
		var band_t := Vector2(0.70, 0.52)
		var top := Vector2(center.x + t - 0.26, center.y + half_z + 0.45)
		var bottom := Vector2(center.x + t - 0.26, center.y - half_z - 1.15)
		var right := Vector2(center.x + half_x + 0.45, center.y + t - 0.26)
		var left := Vector2(center.x - half_x - 1.15, center.y + t - 0.26)
		_zebra(markings, Rect2(top, band))
		_zebra(markings, Rect2(bottom, band))
		_zebra(markings, Rect2(right, band_t))
		_zebra(markings, Rect2(left, band_t))

## Разметка «полигона»: концентрические круги, продольные оси, парковочные карманы.
static func _add_plaza_markings(rect: Rect2, plaza: float, cfg: WorldConfig, markings: Array) -> void:
	if not cfg.road_markings:
		return
	for radius in [13.0, 27.0, 45.0, 62.0]:
		var steps := 44
		for i in range(steps):
			var a0 := TAU * float(i) / float(steps)
			var a1 := TAU * float(i + 1.0) / float(steps)
			var p0 := Vector2(cos(a0), sin(a0)) * radius
			var p1 := Vector2(cos(a1), sin(a1)) * radius
			var mid := (p0 + p1) * 0.5
			var length := p0.distance_to(p1) * 1.06
			if absf(mid.x) > plaza or absf(mid.y) > plaza:
				continue
			markings.append({
				"rect": Rect2(Vector2(mid.x - length * 0.5, mid.y - 0.11) + rect.position, Vector2(length, 0.22)),
				"surface": &"marking", "y": Y_MARKING, "rot": atan2(mid.y, mid.x),
			})
	for lane in [-56.0, -28.0, 0.0, 28.0, 56.0]:
		for axis in [0, 1]:
			var long := Rect2(Vector2(lane - 0.10, -plaza) if axis == 0 else Vector2(-plaza, lane - 0.10), Vector2(0.20, plaza * 2.0))
			long = long.intersection(rect)
			if long.size.x > 0.5 and long.size.y > 6.0:
				markings.append({"rect": long, "surface": &"marking", "y": Y_MARKING, "rot": 0.0})

# ------------------------------------------------------------------ малые формы

static func _add_street_furniture(chunk: Vector2i, origin: Vector2, size: float, cfg: WorldConfig, props: Array) -> void:
	var density := PerformanceManager.prop_density()
	var lamps := int(round(float(cfg.street_lamps_per_chunk) * density))
	var trees := int(round(float(cfg.trees_per_chunk) * density))
	var bins := int(round(float(cfg.bins_per_chunk) * density))
	var cones := int(round(float(cfg.cones_per_chunk) * density))
	var barriers := int(round(float(cfg.barriers_per_chunk) * density))
	var lights := int(round(float(cfg.traffic_lights_per_chunk) * density))
	var dumpsters := int(round(float(cfg.dumpsters_per_chunk) * density))
	var rng := rng_for(chunk.x, chunk.y, 11, cfg)
	var step := pitch(cfg)
	var rx := line_index_range(chunk.x, cfg)
	var rz := line_index_range(chunk.y, cfg)
	var placed_lamps := 0
	var placed_trees := 0
	# Фонари и деревья — ровно вдоль тротуаров: регулярность и есть «городская» картина.
	for i in range(rx.x, rx.y + 1):
		var half := road_half_width(i, cfg)
		for side in [-1.0, 1.0]:
			var lateral := line_offset(i, cfg) + side * (half + cfg.sidewalk_width_m * 0.6)
			var t := -fmod(lateral, step * 0.25)
			var guard := 0
			while t < size + step * 0.25 and guard < 4096:
				guard += 1
				if placed_lamps < lamps:
					var p := Vector2(t, lateral)
					props.append({
						"type": "lamp", "pos": Vector3(p.x, 0.0, p.y),
						"rot": (PI * 0.5 if side > 0.0 else -PI * 0.5), "scale": 1.0, "tint": rng.randf(),
					})
					placed_lamps += 1
				if placed_trees < lamps + trees and int(t / (step * 0.25)) % 3 == 1 and placed_trees < trees:
					props.append({
						"type": "tree", "pos": Vector3(t, 0.0, lateral),
						"rot": rng.randf_range(0.0, TAU), "scale": rng.randf_range(0.85, 1.25), "tint": rng.randf(),
					})
					placed_trees += 1
				t += step * 0.5
	for i in range(rz.x, rz.y + 1):
		var half := road_half_width(i, cfg)
		for side in [-1.0, 1.0]:
			var lateral := line_offset(i, cfg) + side * (half + cfg.sidewalk_width_m * 0.6)
			var t := -fmod(lateral, step * 0.5)
			var guard := 0
			while t < size + step * 0.5 and guard < 4096:
				guard += 1
				if placed_lamps < lamps:
					props.append({
						"type": "lamp", "pos": Vector3(lateral, 0.0, t),
						"rot": (0.0 if side > 0.0 else PI), "scale": 1.0, "tint": rng.randf(),
					})
					placed_lamps += 1
				t += step
	# «Случайная» мелочь: урны, конусы-группы, ремонтные барьеры, мусорные контейнеры.
	for i in range(bins):
		_add_prop("bin", Vector2(rng.randf_range(4.0, size - 4.0), rng.randf_range(4.0, size - 4.0)), rng, cfg, props)
	for i in range(dumpsters):
		_add_prop("dumpster", Vector2(rng.randf_range(6.0, size - 6.0), rng.randf_range(6.0, size - 6.0)), rng, cfg, props)
	for i in range(cones):
		var base := Vector2(rng.randf_range(6.0, size - 6.0), rng.randf_range(6.0, size - 6.0))
		for k in range(4):
			props.append({
				"type": "cone", "pos": Vector3(base.x + cos(TAU * float(k) / 4.0) * 2.2, 0.0, base.y + sin(TAU * float(k) / 4.0) * 2.2),
				"rot": 0.0, "scale": 1.0, "tint": 0.5,
			})
	for i in range(barriers):
		var base := Vector2(rng.randf_range(8.0, size - 8.0), rng.randf_range(8.0, size - 8.0))
		var rot := rng.randf_range(0.0, PI)
		for k in range(5):
			props.append({
				"type": "barrier",
				"pos": Vector3(base.x + cos(rot) * float(k) * 2.2, 0.0, base.y + sin(rot) * float(k) * 2.2),
				"rot": rot, "scale": 1.0, "tint": rng.randf(),
			})
	for i in range(lights):
		var cx := line_offset(rng.randi_range(rx.x, rx.y), cfg) - origin.x
		var cz := line_offset(rng.randi_range(rz.x, rz.y), cfg) - origin.y
		props.append({
			"type": "traffic_light", "pos": Vector3(cx + 2.1, 0.0, cz + 2.1),
			"rot": rng.randf_range(0.0, TAU), "scale": 1.0, "tint": 0.5,
		})

## Кольцо по периметру мира: бетонные блоки и забор — «500 м во все стороны»
## заканчиваются препятствием, а не обрывом в никуда.
static func _add_world_edge(
	chunk: Vector2i,
	origin: Vector2,
	size: float,
	cfg: WorldConfig,
	buildings: Array,
	props: Array,
)-> void:
	var limit := cfg.world_radius_m
	var rng := rng_for(chunk.x * 3 + 1, chunk.y * 5 + 2, 13, cfg)
	for axis in range(2):
		for sign in [-1.0, 1.0]:
			var coord := sign * limit
			var lo := (origin.x if axis == 0 else origin.y)
			var hi := lo + size
			# Нужен ли этот край чанку: линия края попадает в чанк с запасом 8 м.
			if coord < lo - 8.0 or coord > hi + 8.0:
				continue
			var along_lo := (origin.x if axis == 1 else lo)
			var count := int(ceilf(size / 12.0))
			for i in range(count):
				var along := along_lo + (float(i) + 0.5) * (size / float(count))
				var pos := Vector2(along, coord) if axis == 0 else Vector2(coord, along)
				var local := pos - origin
				var footprint := Rect2(local - Vector2(6.0, 1.3), Vector2(12.0, 2.6)) if axis == 0 else Rect2(local - Vector2(1.3, 6.0),
					Vector2(2.6, 12.0))
				buildings.append({
					"footprint": footprint, "side": 0, "floors": 1, "height": 1.6, "floor_height": 1.6,
					"style": "block", "shopfront": false, "balconies": false, "parapet": 0.0,
					"roof_units": false, "tint": rng.randf_range(-0.03, 0.03), "entrance": 0.5, "wing": rng.randf(),
				})
				props.append({
					"type": "fence", "pos": Vector3(local.x, 0.0, local.y + sign * 4.0),
					"rot": 0.0 if axis == 0 else 1.5708, "scale": 1.0, "tint": rng.randf(),
				})

# ------------------------------------------------------------------ сервис

static func describe_chunk(chunk: Vector2i, cfg: WorldConfig) -> String:
	var layout := chunk_layout(chunk, cfg)
	return "чанк %s: грунт %d, разметка %d, здания %d, малые формы %d" % [
		chunk, (layout["ground"] as Array).size(), (layout["markings"] as Array).size(),
		(layout["buildings"] as Array).size(), (layout["props"] as Array).size(),
	]

## Быстрая самопроверка планировки для автотестов: возвращает список проблем.
static func validate_layout(chunk: Vector2i, cfg: WorldConfig) -> PackedStringArray:
	var problems := PackedStringArray()
	var layout := chunk_layout(chunk, cfg)
	var size: float = layout["size"]
	var ground: Array = layout["ground"]
	if ground.is_empty():
		problems.append("чанк %s: ни одного куска грунта" % chunk)
	for entry in ground:
		var rect: Rect2 = entry["rect"]
		if rect.size.x < 0.05 or rect.size.y < 0.05:
			problems.append("чанк %s: вырожденный прямоугольник грунта %s" % [chunk, rect])
		if not chunk_rect_ok(rect, size):
			problems.append("чанк %s: грунт %s вылез за границы чанка" % [chunk, rect])
	for b in (layout["buildings"] as Array):
		var fp: Rect2 = b["footprint"]
		if fp.size.x < 1.0 or fp.size.y < 1.0:
			problems.append("чанк %s: здание со слишком маленьким пятном %s" % [chunk, fp])
		if float(b["height"]) <= 0.5:
			problems.append("чанк %s: здание нулевой высоты" % chunk)
	# Проверка детерминизма: второй вызов обязан отдать тот же объём данных.
	var again := chunk_layout(chunk, cfg)
	if (again["buildings"] as Array).size() != (layout["buildings"] as Array).size():
		problems.append("чанк %s: планировка не детерминирована" % chunk)
	return problems

static func chunk_rect_ok(rect: Rect2, size: float) -> bool:
	return rect.position.x >= -TOL and rect.position.y >= -TOL \
		and rect.end.x <= size + TOL and rect.end.y <= size + TOL
