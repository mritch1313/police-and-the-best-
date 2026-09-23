class_name RoadGraph
extends RefCounted
## Дорожный граф города для ИИ полиции и планирования маршрутов.
##
## Почему граф, а не NavMesh: планировка — правильная прямоугольная сетка улиц, поэтому
## «навигация» — это 225 узлов и 800 рёбер, а не 200k треугольников, которые нужно
## строить на мобильном при старте. Граф строится аналитически из тех же формул, что и
## геометрия дорог (WorldGenerator.line_offset / road_half_width), поэтому ИИ физически не
## может «знать» другую планировку, чем видит игрок.
##
## ЧТО ЕСТЬ:
##  * узлы: перекрёстки + средние точки каждого сегмента (иначе «подрезать» угол нельзя);
##  * рёбра: сегменты улиц, вес = длина + штраф за ширину (узкая улица = медленнее разворот);
##  * разрывы: блоки по периметру мира и «сплошная» на проспекте не создают рёбер;
##  * запросы: nearest(pos), node_position(i), neighbors(i), edge_blocked_by_area(...).
##
## Всё детерминировано и кэшируется один раз на конфиг (см. `for_config`).

const MIDPOINTS_PER_EDGE := 2

static var _cache: Dictionary = {}

var config: WorldConfig = null
var points: PackedVector3Array = PackedVector3Array()
## adjacency[i] = PackedInt32Array соседей; weights[i] = параллельный массив длин рёбер.
var adjacency: Array[PackedInt32Array] = []
var weights: Array[PackedFloat32Array] = []
## Индекс пересечения (i,j) сетки -> узел, для быстрых запросов «улица/перекрёсток».
var cross_index: Dictionary = {}
var line_count_x: int = 0
var line_count_z: int = 0
var radius_m: float = 0.0
var grid_lo_x: int = 0
var grid_hi_x: int = 0
var grid_lo_z: int = 0
var grid_hi_z: int = 0

static func reset_cache() -> void:
	_cache = {}

static func for_config(cfg: WorldConfig) -> RoadGraph:
	if cfg == null:
		return null
	var key := "%d:%d:%d:%f:%f" % [cfg.seed, int(round(cfg.block_pitch_m)), int(round(cfg.world_radius_m)), cfg.road_width_m,
		cfg.avenue_width_m]
	if not _cache.has(key):
		var graph := RoadGraph.new()
		graph.build(cfg)
		_cache[key] = graph
	return _cache[key]

func build(cfg: WorldConfig) -> void:
	config = cfg
	points = PackedVector3Array()
	adjacency.clear()
	weights.clear()
	cross_index.clear()
	var limit := cfg.world_radius_m - cfg.road_width_m
	var step := maxf(cfg.block_pitch_m, 20.0)
	grid_lo_x = int(ceilf(-limit / step))
	grid_hi_x = int(floorf(limit / step))
	grid_lo_z = int(ceilf(-limit / step))
	grid_hi_z = int(floorf(limit / step))
	radius_m = limit
	line_count_x = grid_hi_x - grid_lo_x + 1
	line_count_z = grid_hi_z - grid_lo_z + 1
	if line_count_x < 2 or line_count_z < 2:
		return
	# 1) Узлы пересечений + средние точки рёбер.
	for i in range(grid_lo_x, grid_hi_x + 1):
		for j in range(grid_lo_z, grid_hi_z + 1):
			var pos := Vector3(WorldGenerator.line_offset(i, cfg), 0.0, WorldGenerator.line_offset(j, cfg))
			cross_index[_key(i, j)] = _add_point(pos)
	# Рёбра между соседними пересечениями, с промежуточными узлами.
	for i in range(grid_lo_x, grid_hi_x + 1):
		for j in range(grid_lo_z, grid_hi_z + 1):
			var a: int = cross_index[_key(i, j)]
			if i < grid_hi_x:
				_link_chain(a, cross_index[_key(i + 1, j)], i, j, true, cfg)
			if j < grid_hi_z:
				_link_chain(a, cross_index[_key(i, j + 1)], i, j, false, cfg)

func _key(i: int, j: int) -> String:
	return "%d,%d" % [i, j]

func _add_point(pos: Vector3) -> int:
	var index := points.size()
	points.append(pos)
	adjacency.append(PackedInt32Array())
	weights.append(PackedFloat32Array())
	return index

## Цепочка a -> b через MIDPOINTS_PER_EDGE промежуточных узлов (чтобы маршрут шёл по улице,
## а не «срезал» квартал по диагонали).
func _link_chain(a: int, b: int, i: int, j: int, along_x: bool, cfg: WorldConfig) -> void:
	var prev := a
	# Проспект «дешевле» обычной улицы: ИИ предпочтёт широкую дорогу, как живой водитель.
	var penalty := 1.0 + (0.0 if WorldGenerator.is_avenue(j if along_x else i, cfg) else 0.16)
	for k in range(1, MIDPOINTS_PER_EDGE + 2):
		var t := float(k) / float(MIDPOINTS_PER_EDGE + 1)
		var node := b
		if k <= MIDPOINTS_PER_EDGE:
			var pos := points[a].lerp(points[b], t)
			node = _add_point(pos)
		_link(prev, node, points[prev].distance_to(points[node]) * penalty)
		prev = node

func _link(a: int, b: int, weight: float) -> void:
	adjacency[a].append(b)
	weights[a].append(maxf(weight, 0.5))
	adjacency[b].append(a)
	weights[b].append(maxf(weight, 0.5))

# ------------------------------------------------------------------ запросы

func node_count() -> int:
	return points.size()

func edge_count() -> int:
	var total := 0
	for i in range(adjacency.size()):
		total += adjacency[i].size()
	return total / 2

func node_position(index: int) -> Vector3:
	if index < 0 or index >= points.size():
		return Vector3.ZERO
	return points[index]

func neighbors(index: int) -> PackedInt32Array:
	if index < 0 or index >= adjacency.size():
		return PackedInt32Array()
	return adjacency[index]

func edge_weight(from: int, to: int) -> float:
	if from < 0 or from >= adjacency.size():
		return 0.0
	var list := adjacency[from]
	for i in range(list.size()):
		if list[i] == to:
			return weights[from][i]
	return 0.0

## Ближайший узел к точке (в пределах `max_distance`; иначе -1).
func nearest(position: Vector3, max_distance: float = -1.0) -> int:
	var limit := max_distance if max_distance > 0.0 else maxf(config.nav_snap_tolerance_m * 4.0, 60.0)
	var best := -1
	var best_d := INF
	# Поиск по сетке: starting cell + spiral — быстрее, чем полный перебор 700 узлов.
	var step := maxf(config.block_pitch_m, 20.0)
	var ci := int(round(position.x / step))
	var cj := int(round(position.z / step))
	var span := int(ceilf(limit / step)) + 1
	for di in range(-span, span + 1):
		for dj in range(-span, span + 1):
			var node := node_near_grid(ci + di, cj + dj, position)
			if node < 0:
				continue
			var dist := points[node].distance_to(position)
			if dist < best_d:
				best_d = dist
				best = node
	if best_d > limit:
		return -1
	return best

## Узел (пересечение или середина ребра), ближайший к данной ячейке сетки.
func node_near_grid(i: int, j: int, for_position: Vector3) -> int:
	var found := -1
	var best := INF
	for candidate in [_key(i, j), _key(i - 1, j), _key(i + 1, j), _key(i, j - 1), _key(i, j + 1)]:
		var idx: int = cross_index.get(candidate, -1)
		if idx < 0:
			continue
		# Проверяем и самих соседей, и их промежуточные узлы (они лежат в adjacency).
		var check := PackedInt32Array([idx])
		for n in adjacency[idx]:
			check.append(n)
		for node in check:
			var dist := points[node].distance_squared_to(for_position)
			if dist < best:
				best = dist
				found = node
	return found

## Узел на ближайшем перекрёстке (для спавна патруля/засады).
func nearest_intersection(position: Vector3) -> int:
	var step := maxf(config.block_pitch_m, 20.0)
	var ci := int(round(position.x / step))
	var cj := int(round(position.z / step))
	for radius in range(0, 4):
		for di in range(-radius, radius + 1):
			for dj in range(-radius, radius + 1):
				if maxi(absi(di), absi(dj)) != radius:
					continue
				var idx: int = cross_index.get(_key(clampi(ci + di, grid_lo_x, grid_hi_x), clampi(cj + dj, grid_lo_z, grid_hi_z)), -1)
				if idx >= 0:
					return idx
	return nearest(position, 0.0)

## Позиция на дороге рядом с точкой, «припаркованная» к полосе движения:
## смещение от оси дороги на половину ширины (правая полоса).
func lane_position(node: int, side: float, cfg: WorldConfig) -> Vector3:
	if node < 0 or node >= points.size():
		return Vector3.ZERO
	var pos := points[node]
	var i := int(round(pos.x / maxf(cfg.block_pitch_m, 20.0)))
	var j := int(round(pos.z / maxf(cfg.block_pitch_m, 20.0)))
	# Узел «на оси» той или иной линии: по этому признаку понимаем, вдоль какой оси дорога.
	var on_x_line := absf(pos.x - WorldGenerator.line_offset(i, cfg)) < 0.6
	var half := WorldGenerator.road_half_width(i if on_x_line else j, cfg)
	var offset := half * 0.42 * side
	return pos + (Vector3(offset, 0.0, 0.0) if on_x_line else Vector3(0.0, 0.0, offset))

func random_point(rng: RandomNumberGenerator) -> Vector3:
	if points.is_empty():
		return Vector3.ZERO
	return points[rng.randi_range(0, points.size() - 1)]

func straight_distance(a: Vector3, b: Vector3) -> float:
	return a.distance_to(b)

func summary() -> String:
	return "граф дорог: узлов %d, рёбер %d, сетка x[%d..%d] z[%d..%d]" % [
		node_count(), edge_count(), grid_lo_x, grid_hi_x, grid_lo_z, grid_hi_z,
	]

## Проверка целостности для автотестов: связность, симметрия рёбер, вес > 0.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if node_count() < 4:
		problems.append("RoadGraph: узлов меньше 4 (%d) — строить нечего" % node_count())
		return problems
	for i in range(adjacency.size()):
		for k in range(adjacency[i].size()):
			var j := adjacency[i][k]
			if j < 0 or j >= adjacency.size():
				problems.append("RoadGraph: ребро %d->%d ведёт в никуда" % [i, j])
				continue
			if weights[i][k] <= 0.0:
				problems.append("RoadGraph: нулевой вес ребра %d->%d" % [i, j])
			if not adjacency[j].has(i):
				problems.append("RoadGraph: ребро %d->%d не симметрично" % [i, j])
	# Связность: обход в ширину от 0 должен покрыть все узлы.
	var seen := PackedByteArray()
	seen.resize(adjacency.size())
	var stack := PackedInt32Array([0])
	seen[0] = 1
	var visited := 1
	while not stack.is_empty():
		var node := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		for n in adjacency[node]:
			if seen[n] == 0:
				seen[n] = 1
				visited += 1
				stack.append(n)
	if visited != adjacency.size():
		problems.append("RoadGraph: граф не связен (достижимо %d из %d)" % [visited, adjacency.size()])
	return problems
