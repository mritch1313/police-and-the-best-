extends RefCounted
class_name PoliceAI
## The driver of one police cruiser.
##
## Each physics tick the AI does four things:
##   1. looks at the world (how far is the player, is there a line of sight, is the unit stuck)
##   2. asks `PoliceStrategy` what to do
##   3. turns that decision into a target point (behind the player, ahead of them, at a
##      junction in front of them)
##   4. steers towards that point through the road graph and writes the pedals into the car
##
## The AI never teleports a unit and never writes to a transform. A cruiser that is boxed in
## reports itself as blocked and the manager recycles it - the same rule the player plays by.

## How far ahead the tracker looks when no route is available (metres).
const DIRECT_LOOKAHEAD := 14.0

var car: PoliceCar = null
var config: PoliceConfig = null
var graph: RoadGraph = null
var player: Node3D = null

var strategy: int = PoliceStrategy.Strategy.SPAWN
var time_in_strategy: float = 0.0
var target_point: Vector3 = Vector3.ZERO
var last_known_player_position: Vector3 = Vector3.ZERO
var time_since_player_seen: float = 999.0
var sees_player: bool = false
var has_line_of_sight: bool = false
var route: PackedVector3Array = PackedVector3Array()
var route_index: int = 0
var route_refresh_timer: float = 0.0

var _space_state: PhysicsDirectSpaceState3D = null
var _generator := RandomNumberGenerator.new()
var _situation := PoliceStrategy.Situation.new()


func setup(p_car: PoliceCar, p_config: PoliceConfig, p_graph: RoadGraph, p_player: Node3D, unit_index: int) -> void:
	car = p_car
	config = p_config
	graph = p_graph
	player = p_player
	_situation.unit_index = unit_index
	_generator.seed = 1000 + unit_index * 977


## One decision + one control step.
func update(delta: float) -> void:
	if car == null or config == null or player == null:
		return
	time_in_strategy += delta
	_fill_situation(delta)
	var chosen := PoliceStrategy.choose(_situation, config, strategy, time_in_strategy)
	if chosen != strategy:
		strategy = chosen
		time_in_strategy = 0.0
		route.clear()
		route_index = 0
	_update_target(delta)
	_drive(delta)


## Observes the world. Cheap: one raycast and a handful of vector operations.
func _fill_situation(delta: float) -> void:
	var player_car := player as CarBody
	var player_position := player.global_position
	var distance := car.global_position.distance_to(player_position)
	var world := car.get_world_3d()
	_space_state = world.direct_space_state if world != null else null
	has_line_of_sight = TrajectoryPrediction.has_line_of_sight(
		_space_state, car.global_position, player_position, CollisionLayers.AI_VISION_BLOCKERS, [car.get_rid()]
	)
	sees_player = has_line_of_sight and distance < config.despawn_distance
	if sees_player:
		time_since_player_seen = 0.0
		last_known_player_position = player_position
	else:
		time_since_player_seen += delta
	_situation.distance_to_player = distance
	var player_speed := 0.0
	if player_car != null:
		player_speed = absf(player_car.forward_speed())
	_situation.player_speed = player_speed
	_situation.own_speed = car.speed_kmh() / 3.6
	_situation.has_line_of_sight = has_line_of_sight
	_situation.sees_player = sees_player
	_situation.heat_level = car.get_meta("heat_level", 0)
	_situation.active_units = car.get_meta("active_units", 1)
	_situation.time_since_seen = time_since_player_seen
	_situation.player_on_road = graph == null or graph.is_valid()
	_situation.blocked = car.state == PoliceCar.State.BLOCKED
	_situation.near_intersection = graph != null and graph.is_near_intersection(car.global_position, 22.0)


## Turns the strategy into a point the car should drive to.
func _update_target(delta: float) -> void:
	var player_car := player as CarBody
	var player_position := player.global_position
	var player_velocity := player_car.linear_velocity if player_car != null else Vector3.ZERO
	match strategy:
		PoliceStrategy.Strategy.PURSUE:
			# Aim for a point behind the player: a cruiser that aims at the player's centre
			# pushes them, while one that aims behind them follows like a real pursuit.
			var behind := Vector3.ZERO
			if player_car != null:
				# A point behind the player: a cruiser that aims at the player's centre pushes
				# them, one that aims behind them follows like a real pursuit.
				behind = player_car.global_transform.basis.z * config.follow_distance
			target_point = player_position + behind
		PoliceStrategy.Strategy.RAM:
			target_point = TrajectoryPrediction.predict_position(
				player_position, player_velocity, Vector3.ZERO, 0.35
			)
		PoliceStrategy.Strategy.BOX_IN:
			# Pull alongside: offset perpendicular to the player's heading.
			var side := Vector3(3.6, 0.0, 0.0)
			if player_car != null:
				side = player_car.global_transform.basis.x * 3.6
				target_point = player_position + side + player_car.global_transform.basis.z * 1.5
			else:
				target_point = player_position + side
		PoliceStrategy.Strategy.INTERCEPT:
			route_refresh_timer -= delta
			if route_refresh_timer <= 0.0 or route.is_empty():
				route_refresh_timer = 2.4
				var predicted := TrajectoryPrediction.predict_position(
					player_position, player_velocity, Vector3.ZERO, config.prediction_time * 2.0
				)
				route = _route_to(predicted)
			target_point = _next_route_point()
		PoliceStrategy.Strategy.BLOCK_ROAD:
			target_point = graph.nearest_node_position(player_position) if graph != null else player_position
		PoliceStrategy.Strategy.SEARCH:
			route_refresh_timer -= delta
			if route_refresh_timer <= 0.0 or route.is_empty():
				route_refresh_timer = 3.0
				route = _route_to(last_known_player_position)
			target_point = _next_route_point()
		PoliceStrategy.Strategy.PATROL:
			route_refresh_timer -= delta
			if route_refresh_timer <= 0.0 or route.is_empty():
				route_refresh_timer = 6.0
				var destination := graph.random_node_near(car.global_position, 260.0, _generator, 60.0) if graph != null else Vector3.INF
				route = _route_to(destination if destination != Vector3.INF else car.global_position)
			target_point = _next_route_point()
		_:
			target_point = player_position


func _route_to(destination: Vector3) -> PackedVector3Array:
	if graph == null or not graph.is_valid():
		return PackedVector3Array([destination])
	return graph.path_between(car.global_position, destination)


func _next_route_point() -> Vector3:
	if route.is_empty():
		return last_known_player_position
	while route_index < route.size() and car.global_position.distance_to(route[route_index]) < 12.0:
		route_index += 1
	if route_index >= route.size():
		return route[route.size() - 1]
	return route[route_index]


## Steering and pedals. The physics of the car is not touched: the AI only presses buttons,
## exactly like the player does.
func _drive(delta: float) -> void:
	if car.state == PoliceCar.State.WRECKED:
		return
	var to_target := target_point - car.global_position
	to_target.y = 0.0
	var forward := -car.global_transform.basis.z
	var right := car.global_transform.basis.x
	var local_x := to_target.dot(right)
	var local_z := to_target.dot(forward)
	var steer := 0.0
	if to_target.length() > 0.5:
		steer = clampf(local_x / maxf(local_z, 3.0), -1.0, 1.0)
	# A blocked unit steers hard away instead of pushing into the obstacle.
	if car.state == PoliceCar.State.BLOCKED:
		steer = clampf(steer + (1.0 if local_x > 0.0 else -1.0), -1.0, 1.0)
	var wanted_speed := PoliceStrategy.target_speed(strategy, config, _situation.distance_to_player)
	var throttle_cap := PoliceStrategy.throttle_for(strategy)
	var speed := car.forward_speed()
	var throttle := 0.0
	var brake := 0.0
	if speed < wanted_speed - 1.0:
		throttle = throttle_cap
	elif speed > wanted_speed + 2.5:
		brake = clampf((speed - wanted_speed) / 8.0, 0.1, 0.7)
	# Do not rear-end a stationary player at full speed: brake when very close and closing.
	if _situation.distance_to_player < config.follow_distance * 0.55 and local_z > 0.0 and speed > 6.0:
		brake = maxf(brake, 0.55)
	# Damage avoidance: a wrecker should still be able to stop before a wall.
	if not has_line_of_sight and _situation.distance_to_player < 12.0:
		brake = maxf(brake, 0.4)
	car.drive_input.steer = steer * config.steering_aggression
	car.drive_input.throttle = throttle
	car.drive_input.brake = brake
	car.drive_input.handbrake = false
	car.drive_input.nitro = false
	car.drive_input.source = &"police_ai"


## Percent of the fleet that currently has a line of sight (used by the chase manager).
func can_see_player() -> bool:
	return sees_player


func strategy_name() -> String:
	return PoliceStrategy.name_of(strategy)


func describe() -> String:
	return "AI[%s] dist=%.1f los=%s seen=%.1fs target=(%.0f,%.0f)" % [
		strategy_name(),
		_situation.distance_to_player,
		str(has_line_of_sight),
		time_since_player_seen,
		target_point.x,
		target_point.z,
	]
