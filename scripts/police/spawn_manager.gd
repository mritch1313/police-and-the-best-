class_name SpawnManager
extends RefCounted
## Где ставить патруль, чтобы он был «живым», а не телепортом в воздух.
##
## ПРАВИЛА СПАВНА (все параметры из ChaseConfig):
##  1) кольцо `spawn_radius_m` вокруг игрока: патруль не появляется «в поле» и не «в упор»;
##  2) позиция обязана лежать на дороге (узел RoadGraph рядом с кольцом) — иначе патруль
##     появляется «во дворе дома» и первый же кадр тратит на выезд;
##  3) не ближе `spawn_clearance_m` к уже активным патрулям (иначе два патруля спавнятся
##     в одном месте и слипаются в один);
##  4) направление — вдоль улицы к игроку;
##  5) высота: max(WorldConfig.spawn_height_m, земля + дорожный просвет) — см. VehicleRig.place_at.
##
## ВЫГРУЗКА: `should_despawn` — это НЕ «убить полицию», а освободить слот: игрок уехал на
## `despawn_radius_m`, дальше единица всё равно не участвует, а держать её в физике дорого.

var chase_config: ChaseConfig = null
var world_config: WorldConfig = null
var graph: RoadGraph = null
var _rng := RandomNumberGenerator.new()
var last_request: Dictionary = {}
var attempts: int = 0
var successes: int = 0

func configure(p_chase: ChaseConfig, p_world: WorldConfig, p_graph: RoadGraph, seed: int = 0) -> void:
	chase_config = p_chase
	world_config = p_world
	graph = p_graph
	_rng.seed = seed if seed != 0 else (Time.get_ticks_msec() ^ 0x5EED)

## Ключевой вход: `occupied` — позиции уже живых патрулей.
func request_spawn(player_position: Vector3, player_heading: float, occupied: Array, wanted: float) -> Dictionary:
	attempts += 1
	last_request = {}
	if chase_config == null:
		return {"ok": false, "why": &"no_config"}
	var radius := clampf(chase_config.spawn_radius_m, 40.0, maxf(chase_config.despawn_radius_m * 0.6, 60.0))
	var clearance := maxf(chase_config.spawn_clearance_m, 1.0)
	# Кандидаты: сектора вокруг игрока; приоритет — «впереди по курсу» (игрок чаще видит,
	# как патруль выезжает навстречу, чем «откуда-то сзади»).
	var spread := clampf(wanted / 5.0, 0.2, 1.0)
	var best: Dictionary = {}
	var best_score := -INF
	for i in range(12):
		var angle := TAU * float(i) / 12.0 + _rng.randf_range(-0.22, 0.22)
		var forward_bias := 1.0 + 0.6 * spread * cos(angle - player_heading)
		var candidate := player_position + Vector3(sin(angle), 0.0, -cos(angle)) * radius
		if world_config != null and candidate.length() > world_config.world_radius_m * 0.94:
			continue
		var too_close := false
		var min_occupied := INF
		for other in occupied:
			var other_position: Vector3 = other
			min_occupied = minf(min_occupied, other_position.distance_to(candidate))
		if min_occupied < clearance:
			too_close = true
		if too_close:
			continue
		var snapped := candidate
		var heading := atan2(-(player_position.x - candidate.x), -(player_position.z - candidate.z))
		if graph != null:
			var node := graph.nearest(candidate, maxf(radius * 0.6, 60.0))
			if node < 0:
				continue
			snapped = graph.node_position(node)
			var lane := graph.lane_position(node, 1.0, world_config) if world_config != null else snapped
			snapped = lane
			heading = _heading_towards(lane, player_position)
		var score := forward_bias * 10.0 - snapped.distance_to(player_position) * 0.01 \
				+ minf(min_occupied, 40.0) * 0.05
		if score > best_score:
			best_score = score
			best = {
				"ok": true,
				"position": Vector3(snapped.x, 0.0, snapped.z),
				"heading": heading,
				"distance_m": snapped.distance_to(player_position),
				"min_occupied_m": min_occupied,
			}
	last_request = best.duplicate()
	if bool(best.get("ok", false)):
		successes += 1
		return best
	return {"ok": false, "why": &"no_clear_spot", "attempts": attempts, "occupied": occupied.size()}

func _heading_towards(from: Vector3, towards: Vector3) -> float:
	var to := towards - from
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return 0.0
	return atan2(-to.x, -to.z)

func should_despawn(unit_position: Vector3, player_position: Vector3) -> bool:
	if chase_config == null:
		return false
	return unit_position.distance_to(player_position) > maxf(chase_config.despawn_radius_m, 80.0)

## Кого выгрузить: самых дальних, но не больше `freeable`, и никогда не ниже «минимума в
## радиусе перехвата» — иначе погония обнуляется ровно в тот момент, когда игрок вернулся.
func despawn_plan(units: Array, player_position: Vector3, keep_min: int) -> Array:
	if chase_config == null:
		return []
	var scored: Array = []
	for unit in units:
		if unit == null:
			continue
		var position: Vector3 = unit.global_position
		scored.append({
			"unit": unit,
			"distance_m": position.distance_to(player_position),
			"far": should_despawn(position, player_position),
		})
	scored.sort_custom(_by_distance_desc)
	var out: Array = []
	for entry in scored:
		if out.size() + keep_min >= units.size() and not bool(entry["far"]):
			break
		if bool(entry["far"]):
			out.append(entry["unit"])
	return out

static func _by_distance_desc(a: Dictionary, b: Dictionary) -> bool:
	return float(a["distance_m"]) > float(b["distance_m"])

func summary() -> String:
	return "спавн: запросов %d, успешно %d (радиус %.0f м, зазор %.1f м)" % [
		attempts, successes,
		chase_config.spawn_radius_m if chase_config != null else 0.0,
		chase_config.spawn_clearance_m if chase_config != null else 0.0,
	]

## Автотест: дистанция спавна в пределах кольца, запрет на коллизию с занятыми местами,
## «дальние» уходят первыми, `despawn_radius_m > spawn_radius_m` соблюдается.
static func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	var chase := ChaseConfig.new()
	var world := WorldConfig.new()
	chase.spawn_radius_m = 165.0
	chase.despawn_radius_m = 470.0
	chase.spawn_clearance_m = 7.0
	var manager := SpawnManager.new()
	manager.configure(chase, world, null, 12345)
	if chase.despawn_radius_m <= chase.spawn_radius_m:
		problems.append("spawn: despawn_radius_m <= spawn_radius_m — патрули будут спавниться за пределами выгрузки")
	var player := Vector3.ZERO
	var used: Array = []
	for i in range(6):
		var request := manager.request_spawn(player, TAU * float(i) / 6.0, used, 3.0)
		if not bool(request.get("ok", false)):
			problems.append("spawn: попытка %d не нашла место (%s)" % [i, String(request.get("why", "?"))])
			break
		var position: Vector3 = request["position"]
		var distance := position.distance_to(player)
		if distance < chase.spawn_radius_m * 0.5 or distance > chase.spawn_radius_m * 1.75:
			problems.append("spawn: дистанция %.1f м вне кольца %.0f м" % [distance, chase.spawn_radius_m])
		for other in used:
			if (other as Vector3).distance_to(position) < chase.spawn_clearance_m - 0.01:
				problems.append("spawn: новый патруль в %.1f м от существующего (зазор %.1f м)" % [
					(other as Vector3).distance_to(position), chase.spawn_clearance_m])
		used.append(position)
	# Детерминизм при одинаковом seed.
	var again := SpawnManager.new()
	again.configure(chase, world, null, 12345)
	var first_a := manager.request_spawn(player, 0.4, [], 2.0)
	var first_b := again.request_spawn(player, 0.4, [], 2.0)
	if first_a.get("position", Vector3.INF) != first_b.get("position", Vector3.INF):
		problems.append("spawn: при одинаковом seed позиции разные — детерминизм сломан")
	# План выгрузки: дальний уходит первым.
	var near := FakeUnit.new()
	near.global_position = Vector3(10.0, 0.0, 0.0)
	var far := FakeUnit.new()
	far.global_position = Vector3(chase.despawn_radius_m + 60.0, 0.0, 0.0)
	var plan := manager.despawn_plan([near, far], player, 1)
	if plan.size() != 1 or plan[0] != far:
		problems.append("spawn: план выгрузки должен содержать только дальний патруль")
	return problems

class FakeUnit:
	extends RefCounted
	var global_position: Vector3 = Vector3.ZERO
