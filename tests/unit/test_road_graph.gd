extends TestCase
## The road graph: the police, the traffic and the spawn manager all navigate on it, so it has
## to be connected, correct and cheap enough to be queried every frame.


func _suite_name() -> String:
	return "unit/road_graph"


func run(_tree: SceneTree) -> void:
	var config := load("res://resources/config/world_config.tres") as WorldConfig
	check_not_null(config, "world_config.tres must load")
	if config == null:
		return
	var layout := DistrictLayout.new(20240923, config)
	var graph := RoadGraph.new()
	graph.build(layout, config)

	check(graph.is_valid(), "the graph builds")
	check_greater(float(graph.graph.get_point_count()), 8.0, "the graph has intersections")
	var stats := graph.statistics()
	check_greater(float(stats["average_connections"]), 1.5, "the intersections are connected")
	note("graph: %s" % str(stats))

	# --- every intersection is on a road -------------------------------------------
	var on_road := 0
	var total := 0
	for id in graph.graph.get_point_ids():
		total += 1
		if layout.is_on_road(graph.graph.get_point_position(id)):
			on_road += 1
	check(total > 0, "there are nodes to check")
	check_almost(float(on_road), float(total), 0.5, "every node is on a road")

	# --- pathfinding ---------------------------------------------------------------
	var from := graph.graph.get_point_position(0)
	var to := graph.graph.get_point_position(graph.graph.get_point_count() - 1)
	var path := graph.path_between(from, to)
	check_greater(float(path.size()), 2.0, "a path between two distant nodes has segments")
	if path.size() > 1:
		var length := graph.path_length(path)
		check_greater(length, from.distance_to(to), "a road path is never shorter than the direct line")
		var first := path[0]
		check_less(first.distance_to(from), 1.0, "the path starts at the nearest node")
		var last := path[path.size() - 1]
		check_less(last.distance_to(to), config.block_pitch * 0.75, "the path ends near the destination")

	# --- nearest node --------------------------------------------------------------
	var probe := Vector3(config.block_pitch * 0.5, 0.0, config.block_pitch * 0.5)
	var nearest := graph.nearest_node_position(probe)
	check_less(nearest.distance_to(probe), config.block_pitch * 0.8, "the nearest node is close by")
	check_almost(nearest.y, config.ground_height, 0.5, "nodes sit at ground level")

	# --- random placement ----------------------------------------------------------
	var generator := RandomNumberGenerator.new()
	generator.seed = 1234
	var centre := Vector3(0.0, 0.0, 0.0)
	var found := 0
	var far_enough := true
	for _i in 30:
		var candidate := graph.point_on_road_near(centre, 100.0, 300.0, generator)
		if candidate == Vector3.INF:
			continue
		found += 1
		if candidate.distance_to(centre) < 99.0:
			far_enough = false
	check_greater(float(found), 4.0, "points on the road can be found near the origin")
	check(far_enough, "spawn points respect the minimum distance")
	var random_point := graph.random_node_near(centre, 400.0, generator)
	check(random_point != Vector3.INF, "a random node near the player exists")
	check_less(random_point.length(), 400.0, "the random node is inside the requested radius")
	var direction := graph.road_direction_at(Vector3(0.0, 0.0, 0.0), generator)
	check_almost(direction.length(), 1.0, 0.01, "the road direction is normalised")
	check_almost(direction.y, 0.0, 0.01, "roads are flat")
	check(graph.is_near_intersection(graph.graph.get_point_position(3), 1.0), "an intersection is recognised")
	check(not graph.is_near_intersection(Vector3(1000.0, 0.0, 1000.0), 1.0), "the middle of nowhere is not an intersection")

	# --- an empty graph must not crash ---------------------------------------------
	var empty := RoadGraph.new()
	check(not empty.is_valid(), "an unbuilt graph reports itself as invalid")
	check(empty.path_between(Vector3.ZERO, Vector3.ONE).size() >= 1, "an unbuilt graph still returns the destination")
	check(empty.point_on_road_near(Vector3.ZERO, 1.0, 10.0, generator) == Vector3.INF, "an unbuilt graph cannot place cars")
