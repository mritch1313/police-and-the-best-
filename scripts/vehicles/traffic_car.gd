extends CarBody
class_name TrafficCar
## Ambient traffic: a car that follows a route through the city at a civil speed.
##
## Traffic exists to make the world feel alive and to be an obstacle the player has to drive
## around (and can crash into). It is deliberately cheap: no pathfinding per frame, no
## raycasts, just a list of route points the car steers towards with a simple speed
## controller. The route comes from the RoadGraph, so traffic always stays on the roads the
## city actually has.

signal route_finished()

@export var cruise_speed: float = 11.0
@export var braking_distance: float = 14.0
@export var look_ahead: float = 9.0

var route: PackedVector3Array = PackedVector3Array()
var route_index: int = 0
var vehicle_model: int = CarMeshFactory.MODEL_SEDAN
var _blocked_time: float = 0.0
var _last_forward_position := Vector3.ZERO
var _last_speed := 0.0


func _ready() -> void:
	config_path = "res://resources/config/vehicles/traffic_sedan.tres"
	model_id = vehicle_model
	collision_layer_value = CollisionLayers.TRAFFIC
	collision_mask_value = CollisionLayers.VEHICLE_COLLISION
	detail_level = CarMeshFactory.DETAIL_MEDIUM
	super._ready()
	_last_forward_position = global_position


func _physics_process(delta: float) -> void:
	drive_input.reset()
	drive_input.source = &"ai"
	if route.size() > 1 and route_index < route.size():
		_follow_route(delta)
	else:
		# Without a route the car still behaves: it slows down and stops instead of driving
		# blindly into the traffic ahead.
		drive_input.brake = 0.4
	super._physics_process(delta)
	_check_progress(delta)


func _follow_route(delta: float) -> void:
	var target := route[route_index]
	var to_target := target - global_position
	to_target.y = 0.0
	if to_target.length() < 5.0:
		route_index += 1
		if route_index >= route.size():
			route_finished.emit()
			route_index = route.size()
		# The manager gives this car a new route or removes it.
		return
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x
	var local := Vector3(to_target.dot(right), 0.0, to_target.dot(forward))
	var steer := 0.0
	if local.z > 0.2:
		steer = clampf(local.x / maxf(local.z, 0.2), -1.0, 1.0)
	var desired := clampf(cruise_speed * (1.0 - absf(steer) * 0.35), 3.0, config.max_speed)
	var speed := forward_speed()
	var throttle := 0.0
	var brake := 0.0
	if speed < desired:
		throttle = clampf((desired - speed) / 4.0, 0.1, 0.85)
	elif speed > desired + 1.0:
		brake = clampf((speed - desired) / 6.0, 0.05, 0.6)
	drive_input.steer = steer * 0.55
	drive_input.throttle = throttle
	drive_input.brake = brake


## Traffic that cannot move for a while (crashed into a wall, stuck on a kerb) is recycled by
## the manager. Detecting that here keeps the manager free of per-car logic.
func _check_progress(delta: float) -> void:
	if _last_forward_position.distance_to(global_position) > 2.0:
		_last_forward_position = global_position
		_blocked_time = 0.0
		return
	_blocked_time += delta
	if _blocked_time > 6.0:
		_blocked_time = 0.0
		route_finished.emit()


func assign_route(points: PackedVector3Array) -> void:
	route = points
	route_index = 0


func progress_ratio() -> float:
	if route.size() <= 1:
		return 0.0
	return clampf(float(route_index) / float(route.size() - 1), 0.0, 1.0)
