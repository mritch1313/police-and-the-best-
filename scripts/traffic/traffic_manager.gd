extends Node3D
class_name TrafficManager
## Spawns and recycles the ambient traffic.
##
## Traffic is what makes the city feel inhabited and what gives the player something to
## overtake. It is kept strictly outside the chase systems: a traffic car never reacts to the
## player, it just drives its route. The manager keeps the population stable around the player
## and recycles a car as soon as it wandered too far away or got stuck.

signal car_spawned(car: TrafficCar)
signal car_removed(car: TrafficCar)

## Body shapes available to the traffic, with the configuration each one loads and the
## speed it cruises at. A function instead of a constant so the list is evaluated at runtime
## (and therefore cannot depend on load order).
static func fleet() -> Array[Dictionary]:
	return [
		{"model": CarMeshFactory.MODEL_SEDAN, "config": "res://resources/config/vehicles/traffic_sedan.tres", "cruise": 12.0},
		{"model": CarMeshFactory.MODEL_HATCHBACK, "config": "res://resources/config/vehicles/traffic_hatchback.tres", "cruise": 11.0},
		{"model": CarMeshFactory.MODEL_SUV, "config": "res://resources/config/vehicles/traffic_suv.tres", "cruise": 12.5},
		{"model": CarMeshFactory.MODEL_VAN, "config": "res://resources/config/vehicles/traffic_van.tres", "cruise": 10.0},
		{"model": CarMeshFactory.MODEL_PICKUP, "config": "res://resources/config/vehicles/traffic_sedan.tres", "cruise": 11.5},
		{"model": CarMeshFactory.MODEL_TRUCK, "config": "res://resources/config/vehicles/traffic_truck.tres", "cruise": 8.0},
		{"model": CarMeshFactory.MODEL_BUS, "config": "res://resources/config/vehicles/traffic_bus.tres", "cruise": 7.5},
	]


var world_config: WorldConfig
var graph: RoadGraph
var player: Node3D = null
var max_cars: int = 14

var cars: Array[TrafficCar] = []
var spawn_timer: float = 0.0
var spawned_total: int = 0

var _generator := RandomNumberGenerator.new()
var _enabled: bool = true


func setup(p_world_config: WorldConfig, p_graph: RoadGraph, p_player: Node3D) -> void:
	world_config = p_world_config
	graph = p_graph
	player = p_player
	max_cars = world_config.max_traffic_cars
	_generator.seed = 90210


func set_enabled(value: bool) -> void:
	_enabled = value
	if not value:
		for car: TrafficCar in cars:
			if is_instance_valid(car):
				car.queue_free()
		cars.clear()


func _physics_process(delta: float) -> void:
	if not _enabled or graph == null or player == null or not graph.is_valid():
		return
	spawn_timer -= delta
	if spawn_timer <= 0.0 and cars.size() < max_cars:
		spawn_timer = world_config.traffic_spawn_interval
		_spawn_car()
	_recycle_far_cars()


func _spawn_car() -> void:
	if player == null:
		return
	var position := graph.point_on_road_near(
		player.global_position, 55.0, world_config.traffic_radius, _generator
	)
	if position == Vector3.INF or position.distance_to(player.global_position) < 45.0:
		return
	var fleet := fleet()
	var entry: Dictionary = fleet[_generator.randi_range(0, fleet.size() - 1)]
	var car := TrafficCar.new()
	car.name = "Traffic%d" % spawned_total
	car.vehicle_model = int(entry["model"])
	car.config_path = String(entry["config"])
	car.cruise_speed = float(entry["cruise"]) * _generator.randf_range(0.85, 1.2)
	car.body_colour = _random_traffic_colour()
	car.detail_level = CarMeshFactory.DETAIL_MEDIUM
	add_child(car)
	var forward := graph.road_direction_at(position, _generator)
	# Traffic drives on the right hand side of the road, like the reference city.
	var right := forward.cross(Vector3.UP).normalized() * 3.0
	var spawn_position := position + right + Vector3.UP * 0.5
	car.reset_to(Transform3D(Basis().looking_at(-forward, Vector3.UP), spawn_position))
	var destination := graph.random_node_near(position, 260.0, _generator, 90.0)
	if destination != Vector3.INF:
		car.assign_route(graph.path_between(position, destination))
	car.route_finished.connect(_on_route_finished.bind(car))
	cars.append(car)
	spawned_total += 1
	car_spawned.emit(car)


## Traffic colours: mostly dull, occasionally bright. A row of identical grey cars would look
## worse than no cars at all, so the palette has a wide but dark-biased distribution.
func _random_traffic_colour() -> Color:
	var roll := _generator.randf()
	if roll < 0.34:
		var grey := _generator.randf_range(0.25, 0.85)
		return Color(grey, grey, grey * 1.02)
	if roll < 0.5:
		return Color(0.1, 0.1, 0.12)
	if roll < 0.68:
		return Color(0.5 + _generator.randf() * 0.3, 0.16, 0.12)
	if roll < 0.8:
		return Color(0.12, 0.24, 0.46 + _generator.randf() * 0.2)
	if roll < 0.9:
		return Color(0.72, 0.72, 0.75)
	return Color.from_hsv(_generator.randf(), _generator.randf_range(0.2, 0.6), _generator.randf_range(0.4, 0.8))


func _on_route_finished(car: TrafficCar) -> void:
	if not is_instance_valid(car):
		return
	# Give the car a new route so the player sees a living city instead of a field of parked
	# cars; only recycle it when it is far away.
	if car.global_position.distance_to(player.global_position) < world_config.traffic_radius * 0.8:
		var destination := graph.random_node_near(car.global_position, 200.0, _generator, 70.0)
		if destination != Vector3.INF:
			car.assign_route(graph.path_between(car.global_position, destination))
			return
	_remove_car(car)


func _recycle_far_cars() -> void:
	var to_remove: Array[TrafficCar] = []
	for car: TrafficCar in cars:
		if not is_instance_valid(car):
			to_remove.append(car)
			continue
		if car.global_position.distance_to(player.global_position) > world_config.traffic_radius * 1.6:
			to_remove.append(car)
	for car: TrafficCar in to_remove:
		_remove_car(car)


func _remove_car(car: TrafficCar) -> void:
	cars.erase(car)
	car_removed.emit(car)
	if is_instance_valid(car):
		car.queue_free()


func statistics() -> Dictionary:
	return {
		"alive": cars.size(),
		"max": max_cars,
		"spawned_total": spawned_total,
	}


func debug_string() -> String:
	return "traffic=%d/%d" % [cars.size(), max_cars]
