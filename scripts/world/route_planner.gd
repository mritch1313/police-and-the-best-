class_name RoutePlanner
extends RefCounted
## Планирование маршрута патруля по RoadGraph (Дейкстра без эвристики + «догоняющий» цель).
##
## Почему Дейкстра, а не A*: на графе из ~700 узлов разница в скорости незначительна,
## зато у Дейкстры нет эвристики, которую надо настраивать (недопустимая эвристика даёт
## «странные» маршруты, которые сложно ловить). Каждый патруль пересчитывает маршрут не
## чаще, чем раз в `replan_interval` секунд (см. ChaseConfig), и только если цель ушла.
##
## Что важно для «погони», а не «ближайшей точки»:
##  * цель берётся НЕ в текущей позиции убегающего, а с упреждением (`lead_time`), иначе
##    полицейский вечно «догоняет хвост» и никогда не перерезает путь;
##  * если упреждённая цель вне графа (игрок уехал в поле), цель «притягивается» к
##    ближайшему узлу, а маршрут остаётся валидным;
##  * точка «потери цели» — расстояние по графу, а не по прямой: за домом цель формально
##    близко, но маршрута нет -> это и есть потеря (см. PoliceStrategy).

static func find_path(graph: RoadGraph, from_node: int, to_node: int, max_visited: int = 4000) -> PackedInt32Array:
	var empty := PackedInt32Array()
	if graph == null:
		return empty
	if from_node < 0 or to_node < 0 or from_node >= graph.node_count() or to_node >= graph.node_count():
		return empty
	if from_node == to_node:
		return PackedInt32Array([from_node])
	var count := graph.node_count()
	var dist := PackedFloat32Array()
	var prev := PackedInt32Array()
	var done := PackedByteArray()
	dist.resize(count)
	prev.resize(count)
	done.resize(count)
	for i in range(count):
		dist[i] = INF
		prev[i] = -1
	dist[from_node] = 0.0
	var visited := 0
	while true:
		var best := -1
		var best_d := INF
		for i in range(count):
			if done[i] == 1:
				continue
			if dist[i] < best_d:
				best_d = dist[i]
				best = i
		if best < 0:
			break
		if best == to_node:
			break
		done[best] = 1
		visited += 1
		if visited > max_visited:
			break
		for k in range(graph.adjacency[best].size()):
			var next_node := graph.adjacency[best][k]
			if done[next_node] == 1:
				continue
			var candidate := best_d + graph.weights[best][k]
			if candidate < dist[next_node]:
				dist[next_node] = candidate
				prev[next_node] = best
	if prev[to_node] < 0 and to_node != from_node:
		return empty
	var path := PackedInt32Array()
	var cursor := to_node
	var guard := 0
	while cursor >= 0 and guard < count + 4:
		path.insert(0, cursor)
		cursor = prev[cursor]
		guard += 1
	if path.is_empty() or path[0] != from_node:
		return empty
	return path

static func path_length(graph: RoadGraph, path: PackedInt32Array) -> float:
	if graph == null or path.size() < 2:
		return 0.0
	var total := 0.0
	for i in range(path.size() - 1):
		total += graph.node_position(path[i]).distance_to(graph.node_position(path[i + 1]))
	return total

static func path_points(graph: RoadGraph, path: PackedInt32Array, y: float = 0.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	for node in path:
		var pos := graph.node_position(node)
		out.append(Vector3(pos.x, y, pos.z))
	return out

## «Догоняющая» цель: узел, куда стоит ехать, чтобы перерезать путь убегающему.
static func chase_target_node(
	graph: RoadGraph,
	target_position: Vector3,
	target_velocity: Vector3,
	lead_time: float,
	cfg: WorldConfig,
)-> int:
	if graph == null:
		return -1
	var predicted := target_position + target_velocity * clampf(lead_time, 0.0, 6.0)
	var node := graph.nearest(predicted, maxf(cfg.nav_snap_tolerance_m * 6.0, 120.0))
	if node < 0:
		node = graph.nearest(target_position, 0.0)
	if node < 0:
		node = graph.nearest_intersection(target_position)
	return node

## Преследование «в лоб»: точка перехвата на маршруте убегающего (используется
## стратегией «отрезать»). Возвращает -1, если перехват невозможен.
static func intercept_node(
	graph: RoadGraph,
	hunter_position: Vector3,
	prey_position: Vector3,
	prey_velocity: Vector3,
	speed_ratio: float,
	cfg: WorldConfig,
)-> int:
	if graph == null or speed_ratio <= 0.05:
		return -1
	var lead := prey_position.distance_to(hunter_position) / maxf(prey_velocity.length(), 1.0)
	var limited := clampf(lead * clampf(speed_ratio, 0.2, 2.0), 0.4, 6.0)
	return chase_target_node(graph, prey_position, prey_velocity, limited, cfg)

## Расстояние по графу между двумя точками (для «потери цели» и приоритета спавна).
static func graph_distance(graph: RoadGraph, a: Vector3, b: Vector3, max_visited: int = 1200) -> float:
	if graph == null:
		return a.distance_to(b)
	var na := graph.nearest(a, 0.0)
	var nb := graph.nearest(b, 0.0)
	if na < 0 or nb < 0:
		return a.distance_to(b)
	var path := find_path(graph, na, nb, max_visited)
	if path.is_empty():
		return a.distance_to(b)
	return path_length(graph, path)

## Есть ли вообще маршрут (проверка «заперт в квартале» / блокпост перекрыл всё).
static func has_route(graph: RoadGraph, from_node: int, to_node: int) -> bool:
	return not find_path(graph, from_node, to_node).is_empty()

## Следующая путевая точка после `current_node`.
static func next_node(path: PackedInt32Array, from_node: int) -> int:
	for i in range(path.size() - 1):
		if path[i] == from_node:
			return path[i + 1]
	return -1

## Прогресс по маршруту: сдвигает индекс вперёд, пока цель ближе `threshold` метров.
## Нужен, чтобы патруль не «плевался» с уже пройденной точкой после перепланирования.
static func advance(graph: RoadGraph, path: PackedInt32Array, index: int, position: Vector3, threshold: float) -> int:
	var cursor := clampi(index, 0, maxi(path.size() - 1, 0))
	var guard := 0
	while cursor < path.size() - 1 and guard < path.size():
		var waypoint: Vector3 = graph.node_position(path[cursor])
		if position.distance_to(waypoint) > maxf(threshold, 1.0):
			break
		cursor += 1
		guard += 1
	return cursor

## Сколько пути осталось (метры) — используется для «стоит ли вообще ехать» и для
## сравнения «по графу vs по прямой» в тесте потери цели.
static func remaining_length(graph: RoadGraph, path: PackedInt32Array, index: int) -> float:
	if graph == null or path.is_empty():
		return 0.0
	var total := 0.0
	for i in range(clampi(index, 0, path.size() - 1), path.size() - 1):
		total += graph.node_position(path[i]).distance_to(graph.node_position(path[i + 1]))
	return total
