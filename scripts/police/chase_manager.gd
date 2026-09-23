extends Node
class_name ChaseManager
## Turns the world state into "the player is wanted".
##
## This is the system that decides how hot the chase is: it watches whether any police unit
## can see the player, whether the player is driving fast or crashing into things, and it
## raises or lowers `GameState.heat` accordingly. Everything else (how many units, how they
## behave, when the arrest happens) reacts to that number, which keeps the escalation in one
## readable place.

signal escalation_changed(level: int, heat: float)
signal search_started()
signal search_ended()

## Heat added for hitting a police car (a ram is a loud, obvious crime).
const HEAT_PER_POLICE_CONTACT := 0.28
## Heat added for driving through a park or off the road for a second.
const HEAT_PER_OFFROAD_SECOND := 0.02
## Heat added per second at high speed (a speeding car attracts attention).
const HEAT_PER_FAST_SECOND := 0.03

var police_config: PoliceConfig
var player: CarBody = null
var manager: PoliceManager = null

var heat: float = 0.0
var level: int = 0
var seen_time: float = 0.0
var unseen_time: float = 0.0
var searching: bool = false
var escalation_paused: bool = false
var _offroad_timer: float = 0.0
var _last_level: int = 0


func setup(p_config: PoliceConfig, p_player: CarBody) -> void:
	police_config = p_config
	player = p_player
	heat = 0.0
	level = 0


func _physics_process(delta: float) -> void:
	if police_config == null or player == null or manager == null:
		return
	if escalation_paused:
		return
	var any_visible := false
	for unit: PoliceCar in manager.units:
		if not is_instance_valid(unit):
			continue
		var ai: PoliceAI = manager.ai_instances.get(unit.get_instance_id())
		if ai != null and ai.can_see_player():
			any_visible = true
			break
	if any_visible:
		seen_time += delta
		unseen_time = 0.0
		if searching:
			searching = false
			search_ended.emit()
		# Being seen while driving fast is what raises the level.
		if absf(player.forward_speed()) > police_config.max_speed * 0.5:
			_add_heat(HEAT_PER_FAST_SECOND * delta)
		_add_heat(police_config.heat_gain_per_second * delta)
	else:
		unseen_time += delta
		seen_time = 0.0
		if not searching and level >= 1 and unseen_time > 2.0:
			searching = true
			search_started.emit()
		if unseen_time > police_config.heat_decay_delay:
			_add_heat(-police_config.heat_decay_per_second * delta * 2.0)
	# Driving over a park (off the asphalt) attracts attention and slows the car down.
	if not player.is_grounded():
		pass
	elif _is_offroad():
		_offroad_timer += delta
		if _offroad_timer > 1.0:
			_offroad_timer = 0.0
			_add_heat(HEAT_PER_OFFROAD_SECOND)
	_sync_state()


## Called by the player car when it hits a police cruiser.
func register_police_contact() -> void:
	_add_heat(HEAT_PER_POLICE_CONTACT)


func _is_offroad() -> bool:
	# The road graph knows where the streets are; the player is off-road when they are
	# further than half a block from any road centre line.
	var world := player.get_world_3d()
	if world == null:
		return false
	var space := world.direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(
		player.global_position + Vector3.UP * 0.4,
		player.global_position - Vector3.UP * 0.4,
		CollisionLayers.GROUND
	)
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if collider is Node and (collider as Node).has_meta("surface_grip"):
		return false
	return true


func _add_heat(amount: float) -> void:
	if is_zero_approx(amount):
		return
	heat = clampf(heat + amount, 0.0, float(police_config.max_heat))
	var new_level := int(floor(heat))
	if new_level != level:
		var delta_level := new_level - level
		level = new_level
		_sync_state()
		escalation_changed.emit(level, heat)
		if delta_level > 0:
			_on_escalation()
	# Anything above heat 0 is a chase.
	if heat > 0.05 and level == 0:
		level = 1
		_sync_state()
		escalation_changed.emit(level, heat)


func _on_escalation() -> void:
	# Higher levels make the units more aggressive: the police config already scales the
	# number of units, this only shortens the spawn interval further so reinforcements arrive
	# almost immediately at heat 4 and 5.
	if manager != null:
		manager.spawn_timer = minf(manager.spawn_timer, police_config.spawn_interval_for_heat(level) * 0.5)


func _sync_state() -> void:
	var state := get_node_or_null("/root/GameState")
	if state == null:
		return
	state.set_heat(heat)
	if level != _last_level:
		_last_level = level


## Forces the heat to a value (used by the settings/debug screen and by the tests).
func set_level(value: int) -> void:
	level = clampi(value, 0, police_config.max_heat if police_config != null else 5)
	heat = float(level)
	_sync_state()
	escalation_changed.emit(level, heat)


func status() -> String:
	return "heat=%.2f level=%d %s unseen=%.1fs" % [
		heat,
		level,
		"searching" if searching else ("in sight" if seen_time > 0.0 else "cold"),
		unseen_time,
	]
