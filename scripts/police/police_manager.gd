class_name PoliceManager
extends Node
## Пул патрулей: сколько их, где появляются, куда деться при «остывании» розыска.
##
## КТО ЧТО ДЕЛАЕТ (чтобы не было «бога-менеджера»):
##   ChaseManager  — решения «насколько плохо игроку» (wanted, потеря цели, арест);
##   PoliceManager — ресурс: создать/уничтожить PatrolCar и не превысить лимиты;
##   SpawnManager  — геометрия появления (кольцо + дорога + зазор);
##   PoliceAI      — вождение конкретного патруля.
##
## ВАЖНО ПРО ПЛАВНОСТЬ: создание RigidBody3D + генерация меша — дорогая операция
## (несколько мс). Поэтому:
##  * спавн не чаще, чем раз в `spawn_interval_s`;
##  * перед спавном проверяется, что чанк под точкой ПОСТРОЕН (иначе патруль родится
##    внутри дома и застрянет);
##  * меш кузова общий (кэш CarGeometry), поэтому 6 патрулей = 6 инстансов, а не 6 генераций.

signal unit_spawned(unit: PoliceCar)
signal unit_despawned(unit: PoliceCar)
signal pool_stats(stats: Dictionary)

var chase: ChaseManager = null
var world: Node = null
var config: ChaseConfig = null
var police_config: PoliceConfig = null
var world_config: WorldConfig = null
var spawner: SpawnManager = null
var container: Node3D = null
var units: Array[PoliceCar] = []
var spawn_timer: float = 0.0
var total_spawned: int = 0
var total_despawned: int = 0
var skipped_unbuilt: int = 0
var max_units_runtime: int = 6

func _ready() -> void:
	config = GameSetup.get_config("chase") as ChaseConfig
	police_config = GameSetup.get_config("police") as PoliceConfig
	world_config = GameSetup.get_config("world") as WorldConfig
	chase = get_parent().find_child("ChaseManager", true, false) as ChaseManager
	if chase == null:
		push_warning("PoliceManager: рядом нет ChaseManager — полиция будет пассивна")
	spawner = SpawnManager.new()
	spawner.configure(config, world_config, RoadGraph.for_config(world_config), 20260923)
	world = get_parent().find_child("WorldStreamer", true, false)
	var host := get_parent() as Node3D
	container = Node3D.new()
	container.name = "PoliceUnits"
	host.add_child(container)
	max_units_runtime = police_config.max_units if police_config != null else 6
	set_physics_process(chase != null and (config == null or config.police_enabled))

func attach(player: VehicleRig) -> void:
	if chase != null:
		chase.attach_target(player)

func desired_units() -> int:
	if police_config == null or config == null or not config.police_enabled:
		return 0
	var intensity := 1.0
	if Settings != null and Settings.has_method("police_intensity"):
		intensity = clampf(float(Settings.call("police_intensity")), 0.0, 2.0)
	var budget := PoliceStrategy.wanted_units(chase.wanted if chase != null else 0.0, police_config)
	return clampi(int(roundf(float(budget) * intensity)), 0, mini(max_units_runtime, police_config.max_units))

func _physics_process(delta: float) -> void:
	if chase == null:
		return
	var want := desired_units()
	var have := units.size()
	spawn_timer = maxf(spawn_timer - delta, 0.0)
	while have < want and spawn_timer <= 0.0:
		if not _try_spawn():
			break
		have = units.size()
		spawn_timer = config.spawn_interval_s
	if have > want:
		_trim(have - want)
	_update_units(want)

func _update_units(want: int) -> void:
	var player := chase.target if chase != null else null
	for i in range(units.size()):
		var unit := units[i]
		if unit == null or not is_instance_valid(unit):
			continue
		unit.set_ai_enabled(player != null and i < want + 2)

func _try_spawn() -> bool:
	if chase == null or chase.target == null:
		return false
	var occupied: Array = []
	for unit in units:
		if unit != null:
			occupied.append(unit.global_position)
	var player: Vector3 = chase.target.global_position
	var heading: float = chase.target.heading_rad()
	var request := spawner.request_spawn(player, heading, occupied, chase.wanted)
	if not bool(request.get("ok", false)):
		spawn_timer = maxf(config.spawn_interval_s * 0.5, 0.4)
		return false
	var position: Vector3 = request["position"]
	if not _ground_ready(position):
		# Чанк ещё не построен: спавн «в воздухе» или «в доме» — худший из возможных
		# вариантов, поэтому переносим попытку на следующий интервал.
		skipped_unbuilt += 1
		spawn_timer = maxf(config.spawn_interval_s * 0.5, 0.3)
		return false
	return _spawn_at(position, float(request["heading"]))

func _ground_ready(position: Vector3) -> bool:
	if world == null or not world.has_method("is_chunk_built"):
		return true
	return bool(world.call("is_chunk_built", position, world_config))

func _spawn_at(position: Vector3, heading: float) -> bool:
	var unit := PoliceCar.new()
	unit.name = "PoliceCar_%d" % total_spawned
	container.add_child(unit)
	var ground := world_config.ground_y_m if world_config != null else 0.0
	unit.assemble()
	unit.place_at(Vector3(position.x, ground, position.z), heading, ground)
	unit.set_process(true)
	units.append(unit)
	total_spawned += 1
	if chase != null:
		chase.register_unit(unit)
		unit.assign(chase, units.size() - 1)
	unit_spawned.emit(unit)
	DebugConsole.log_line("police", "спавн патруля №%d на (%.0f; %.0f)" % [units.size(), position.x, position.z])
	return true

func _trim(count: int) -> void:
	var player: Vector3 = chase.target.global_position if chase != null and chase.target != null else Vector3.ZERO
	var plan := spawner.despawn_plan(units.duplicate(), player, mini(desired_units(), units.size()))
	var removed := 0
	for entry in plan:
		if removed >= count:
			break
		_retire(entry as PoliceCar)
		removed += 1
	# Если план пуст (все далеко, но нужны), снимаем самого дального вручную.
	if removed < count:
		var farthest: PoliceCar = null
		var farthest_d := -1.0
		for unit in units:
			var d := unit.global_position.distance_to(player)
			if d > farthest_d:
				farthest_d = d
				farthest = unit
		if farthest != null:
			_retire(farthest)
			removed += 1

func _retire(unit: PoliceCar) -> void:
	if unit == null:
		return
	units.erase(unit)
	total_despawned += 1
	if chase != null:
		chase.unregister_unit(unit)
	unit_despawned.emit(unit)
	unit.queue_free()

func clear() -> void:
	for unit in units.duplicate():
		_retire(unit)
	units.clear()
	if chase != null:
		chase.detach_target()

func status_text() -> String:
	return "патрулей %d/%d (просьба %d), спавнов %d, выгрузок %d, пропусков %d" % [
		units.size(), desired_units(), 0, total_spawned, total_despawned, skipped_unbuilt,
	]

func stats() -> Dictionary:
	return {
		"units": units.size(),
		"desired": desired_units(),
		"spawned": total_spawned,
		"despawned": total_despawned,
		"skipped_unbuilt": skipped_unbuilt,
		"spawn": spawner.summary(),
	}

func debug_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for unit in units:
		if unit != null and is_instance_valid(unit):
			out.append(unit.debug_line())
	return out
