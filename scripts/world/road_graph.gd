extends RefCounted
class_name RoadGraph
## The drivable network of the city, as an AStar3D graph of intersections and road segments.
##
## Everything that has to move through the city uses this graph instead of blindly steering
## towards the player: the ambient traffic drives from intersection to intersection, the
## police pick interception points on the graph (which is what makes a cruiser appear in
## front of the player instead of always behind them), and the spawn manager only ever
## places cars on nodes that are actually on a road.
##
## The graph is derived from the same `DistrictLayout` the geometry uses, so a road that
## exists is drivable and a road that is drivable exists.

## Full graph.
var graph := AStar3D.new()
## Grid size (number of intersections per axis).
var grid_size: int = 0
var pitch: float = 125.0
var ground_y: float = 0.0

var _layout: DistrictLayout = null


func build(layout: DistrictLayout, world_config: WorldConfig = null) -> void:
	_layout = layout
	var config := world_config if world_config != null else layout.config
	grid_size = layout.intersection_count()
	pitch = config.block_pitch
	ground_y = config.ground_height
	graph.clear()
	graph.reserve_space(grid_size * grid_size)
	for iz in grid_size:
		for ix in grid_size:
			var id := _id(ix, iz)
			graph.add_point(id, layout.intersection_position(ix, iz))
	# Connect every intersection with its neighbours (the city is a regular grid).
	for iz in grid_size:
		for ix in grid_size:
			var id := _id(ix, iz)
			if ix + 1 < grid_size:
				graph.connect_points(id, _id(ix + 1, iz), true)
			if iz + 1 < grid_size:
				graph.connect_points(id, _id(ix, iz + 1), true)


func _id(ix: int, iz: int) -> int:
	return iz * grid_size + ix


func coords_of(id: int) -> Vector2i:
	return Vector2i(id % grid_size, id / grid_size)


func is_valid() -> bool:
	return grid_size > 0 and graph.get_point_count() > 0


## Nearest intersection to a world position.
func nearest_node_id(position: Vector3) -> int:
	if not is_valid():
		return -1
	return graph.get_closest_point(position, true)


func nearest_node_position(position: Vector3) -> Vector3:
	var id := nearest_node_id(position)
	if id < 0:
		return position
	return graph.get_point_position(id)


## Path of world positions between two world positions, following the roads.
func path_between(from: Vector3, to: Vector3, allow_partial: bool = true) -> PackedVector3Array:
	if not is_valid():
		return PackedVector3Array([to])
	var start := nearest_node_id(from)
	var goal := nearest_node_id(to)
	if start < 0 or goal < 0 or start == goal:
		return PackedVector3Array([to])
	var ids := graph.get_id_path(start, goal, allow_partial)
	var points := PackedVector3Array()
	for id in ids:
		points.append(graph.get_point_position(id))
	points.append(to)
	return points


## A random intersection inside `radius` metres of a position. Returns the position or
## Vector3.INF when nothing suitable exists (for example outside the city).
func random_node_near(position: Vector3, radius: float, generator: RandomNumberGenerator, min_distance: float = 0.0) -> Vector3:
	if not is_valid():
		return Vector3.INF
	var attempts := 24
	for _attempt in attempts:
		var id := generator.randi_range(0, graph.get_point_count() - 1)
		var point := graph.get_point_position(id)
		var distance := point.distance_to(position)
		if distance <= radius and distance >= min_distance:
			return point
	return Vector3.INF


## A point on a road segment near a position, at least `min_distance` away. Used to place
## traffic and police cars exactly on a lane rather than on a pavement.
func point_on_road_near(
	position: Vector3,
	min_distance: float,
	max_distance: float,
	generator: RandomNumberGenerator
) -> Vector3:
	if not is_valid():
		return position
	for _attempt in 24:
		var id := generator.randi_range(0, graph.get_point_count() - 1)
		var point := graph.get_point_position(id)
		var distance := point.distance_to(position)
		if distance < min_distance or distance > max_distance:
			continue
		# Slide along one of the connected segments so cars do not all sit on crossroads.
		var connections := graph.get_point_connections(id)
		if connections.is_empty():
			return point
		var other := graph.get_point_position(connections[generator.randi_range(0, connections.size() - 1)])
		var direction := other - point
		if direction.length_squared() < 0.01:
			return point
		var t := generator.randf_range(0.15, 0.75)
		var candidate := point + direction * t
		if candidate.distance_to(position) >= min_distance:
			return candidate
	return Vector3.INF


## Direction (unit vector) of a road at a position. The traffic spawner uses it to align a
## car with the lane it is standing on.
func road_direction_at(position: Vector3, generator: RandomNumberGenerator) -> Vector3:
	if not is_valid():
		return Vector3.FORWARD
	var id := nearest_node_id(position)
	var connections := graph.get_point_connections(id)
	if connections.is_empty():
		return Vector3.FORWARD
	var other := graph.get_point_position(connections[generator.randi_range(0, connections.size() - 1)])
	var direction := other - graph.get_point_position(id)
	if direction.length_squared() < 0.01:
		return Vector3.FORWARD
	return direction.normalized()


## True when a position is close to an intersection (used by the arrest system to decide
## whether the police can block a junction).
func is_near_intersection(position: Vector3, tolerance: float = 18.0) -> bool:
	if not is_valid():
		return false
	var id := nearest_node_id(position)
	return graph.get_point_position(id).distance_to(position) <= tolerance


## Number of nodes and connections, for the test report.
func statistics() -> Dictionary:
	return {
		"nodes": graph.get_point_count(),
		"grid": grid_size,
		"pitch": pitch,
		"average_connections": _average_connections(),
	}


func _average_connections() -> float:
	if graph.get_point_count() == 0:
		return 0.0
	var total := 0
	for id in graph.get_point_ids():
		total += graph.get_point_connections(id).size()
	return float(total) / float(graph.get_point_count())


## Length of the path between two positions in metres (used by the AI to compare routes).
func path_length(points: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	return length
