extends RefCounted
class_name TrajectoryPrediction
## Where will the player be in a second and a half?
##
## The police use this for two things: interception (driving to a point the player has not
## reached yet, which is what makes a cruiser appear in front of the player) and ramming
## (aiming slightly ahead of a moving target instead of at its current position).
##
## The model is intentionally simple and stable: the current velocity is extrapolated with the
## measured acceleration and clamped by what the car can physically do. A complicated model
## would be wasted on a phone and would predict worse in the corners, where the AI mostly
## needs a point on the road.

## Highest acceleration considered in the prediction (m/s^2).
const MAX_ACCELERATION := 9.0
## Highest deceleration considered (m/s^2).
const MAX_DECELERATION := 14.0


## Predicts a position. `velocity` and `acceleration` are world space vectors.
static func predict_position(
	position: Vector3,
	velocity: Vector3,
	acceleration: Vector3,
	time: float
) -> Vector3:
	var clamped_acceleration := acceleration.limit_length(MAX_ACCELERATION)
	var smoothed_velocity := velocity + clamped_acceleration * minf(time, 0.4)
	return position + smoothed_velocity * time


## Predicts a position but keeps the result on the road, which is where the unit can actually
## drive. `graph` may be null (then the raw prediction is returned).
static func predict_on_road(
	position: Vector3,
	velocity: Vector3,
	time: float,
	graph: RoadGraph,
	minimum_distance: float = 25.0,
	maximum_distance: float = 220.0
) -> Vector3:
	var predicted := predict_position(position, velocity, Vector3.ZERO, time)
	if graph == null or not graph.is_valid():
		return predicted
	# The prediction is snapped onto a road node, but never closer than `minimum_distance`:
	# a police car that "intercepts" five metres in front of the player is just a wall.
	var direction := velocity
	direction.y = 0.0
	if direction.length_squared() < 0.5:
		direction = Vector3.FORWARD
	var wanted := predicted
	for attempt in 4:
		var target := wanted
		if attempt > 0:
			target = position + direction.normalized() * (minimum_distance + float(attempt) * 30.0)
		var distance := target.distance_to(position)
		if distance >= minimum_distance and distance <= maximum_distance:
			return graph.nearest_node_position(target) + Vector3(0.0, 0.0, 0.0)
	return position


## Time until two moving points meet, used to decide whether an interception is worth it.
## Returns INF when the chaser can never catch up.
static func intercept_time(
	chaser_position: Vector3,
	chaser_speed: float,
	target_position: Vector3,
	target_velocity: Vector3
) -> float:
	var to_target := target_position - chaser_position
	to_target.y = 0.0
	var distance := to_target.length()
	if distance < 0.001:
		return 0.0
	var closing := chaser_speed - target_velocity.dot(to_target.normalized())
	if closing <= 0.01:
		return INF
	return distance / closing


## True when a straight line between two points is clear. The AI uses it to decide whether a
## ram is a good idea (chasing around a corner is not).
static func has_line_of_sight(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	collision_mask: int = CollisionLayers.AI_VISION_BLOCKERS,
	exclude: Array[RID] = []
) -> bool:
	if space_state == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 1.2, to + Vector3.UP * 0.8, collision_mask, exclude)
	query.collide_with_areas = false
	var hit := space_state.intersect_ray(query)
	return hit.is_empty()


## A stable "steering quality" score: how much a unit gains by taking the interception path
## instead of following the player. Positive means "cut ahead".
static func interception_gain(distance: float, angle_degrees: float) -> float:
	var angle_factor := clampf(1.0 - absf(angle_degrees) / 120.0, 0.0, 1.0)
	var distance_factor := clampf(distance / 90.0, 0.0, 1.0)
	return angle_factor * distance_factor
