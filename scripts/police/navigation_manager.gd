class_name NavigationManager
extends RefCounted
## Следование по маршруту для одного патруля (путевые точки, темп перепланирования).
##
## Отделяет «где я должен быть через 2 секунды» от «как крутить руль»: PoliceAI думает о
## руле и педалях, навигация — только о пути. Так можно заменить планировщик (A*, потоки)
## без переписывания вождения, и так же это покрывается автотестом.
##
## ВАЖНО ПРО СМАЗК: узел пути переключается, когда патруль проехал ближе `waypoint_radius_m`
## к СЛЕДУЮЩЕЙ точке, а не когда «поравнялся с текущей» — иначе на каждом перекрёстке ИИ
## дёргается (switch-on-boundary), и это классический источник «полиция мигает между двумя
## домами».

var graph: RoadGraph = null
var police_config: PoliceConfig = null
var path: PackedInt32Array = PackedInt32Array()
var index: int = 0
var waypoint_radius_m: float = 9.0
var replan_interval_s: float = 0.45
var target_node: int = -1
var last_target_position: Vector3 = Vector3.ZERO
var replan_timer: float = 0.0
var target_moved_m: float = 0.0
var replanned_count: int = 0
var stuck_time: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _last_progress: int = 0

func setup(p_graph: RoadGraph, p_police: PoliceConfig, p_chase: ChaseConfig) -> void:
	graph = p_graph
	police_config = p_police
	if police_config != null:
		replan_interval_s = police_config.repath_interval_s
	if p_chase != null:
		waypoint_radius_m = maxf(p_chase.spawn_clearance_m * 1.2, 6.0)

func reset() -> void:
	path = PackedInt32Array()
	index = 0
	target_node = -1
	target_moved_m = 0.0
	replan_timer = 0.0
	stuck_time = 0.0
	_last_progress = 0
	_last_position = Vector3.ZERO

## Цель — НЕ позиция убегающего, а упреждённая точка на графе (см. RoutePlanner).
func retarget(target_position: Vector3, target_velocity: Vector3, unit_position: Vector3, force: bool = false) -> bool:
	if graph == null:
		return false
	target_moved_m = last_target_position.distance_to(target_position)
	last_target_position = target_position
	if not force and not path.is_empty() and target_moved_m < 6.0 and replan_timer > 0.0:
		return false
	var lead := 0.0
	if police_config != null:
		lead = police_config.reaction_time_s + clampf(target_velocity.length() * 0.08, 0.0, 1.4)
	var world := GameSetup.get_config("world") as WorldConfig
	var node := RoutePlanner.chase_target_node(graph, target_position, target_velocity, lead, world)
	if node < 0:
		return false
	var start := graph.nearest(unit_position, 0.0)
	if start < 0:
		start = graph.nearest_intersection(unit_position)
	if start < 0:
		return false
	var found := RoutePlanner.find_path(graph, start, node)
	if found.is_empty():
		# Маршрута нет: цель «недостижима» — это сигнал ChaseManager'у считать цель потерянной.
		target_node = node
		return false
	if found.size() < 2:
		index = 0
		path = found
		return true
	path = found
	index = 1 if not force else 0
	target_node = node
	replanned_count += 1
	replan_timer = replan_interval_s
	return true

## Вызывается каждый физический шаг. Возвращает true, если маршрут протух и нужен retarget.
func update(delta: float, unit_position: Vector3, unit_speed_kmh: float) -> bool:
	replan_timer = maxf(replan_timer - delta, 0.0)
	if graph == null or path.is_empty():
		return true
	index = RoutePlanner.advance(graph, path, index, unit_position, waypoint_radius_m)
	var moved := _last_position.distance_to(unit_position)
	_last_position = unit_position
	# «Застрял» = едем медленно И не продвинулись по маршруту (иначе поворот на малой скорости
	# выглядел бы как застревание и патруль начал бы сдавать назад посреди улицы).
	var stalled := unit_speed_kmh < 3.0 and moved < 0.02
	stuck_time = stuck_time + delta if stalled else 0.0
	var remaining := remaining_m()
	var stale := replan_timer <= 0.0 and (remaining < 12.0 or target_moved_m > 18.0)
	return stale or stuck_time > 2.4

func waypoint() -> Vector3:
	if graph == null or path.is_empty():
		return Vector3.ZERO
	var node := path[clampi(index, 0, path.size() - 1)]
	return graph.node_position(node)

func next_waypoint() -> Vector3:
	if graph == null or path.size() < 2:
		return Vector3.ZERO
	var cursor := clampi(index + 1, 0, path.size() - 1)
	return graph.node_position(path[cursor])

func remaining_m() -> float:
	if graph == null or path.is_empty():
		return INF
	return RoutePlanner.remaining_length(graph, path, index)

func has_path() -> bool:
	return not path.is_empty() and index < path.size()

func is_stuck() -> bool:
	return stuck_time > (police_config.stuck_time_s if police_config != null else 2.6)

func finish_distance_m() -> float:
	if graph == null or path.is_empty():
		return INF
	return graph.node_position(path[path.size() - 1]).distance_to(last_target_position)

func state() -> Dictionary:
	return {
		"waypoints": path.size(),
		"index": index,
		"target_node": target_node,
		"remaining_m": remaining_m(),
		"replanned": replanned_count,
		"stuck_time": stuck_time,
	}

func debug_line() -> String:
	return "навигация: точек %d (курсор %d), осталось %.0f м, перестроений %d" % [
		path.size(), index, remaining_m(), replanned_count,
	]
