extends Node3D
class_name GameWorld
## The playable scene: it assembles the world, the player, the camera, the interface and the
## police, and it is the only node that knows about all of them.
##
## Everything else in the project is a system that can be tested on its own (the vehicle model
## has no idea it is in a game, the police AI only sees a target, the streamer only sees a
## position). This node is the place where those systems meet, which keeps the coupling in one
## readable file instead of spreading it over twenty.
##
## The scene is loaded by `ScreenFlow` from the main menu. It starts the run, streams the
## world around the player, and shows the end-of-run screen when the player is arrested or
## chooses to stop.

signal run_ready(statistics: Dictionary)
signal run_finished(reason: StringName, summary: Dictionary)

const PLAYER_SCENE := "res://scenes/vehicles/PlayerCar.tscn"
const PAUSE_SCENE := "res://scenes/ui/PauseMenu.tscn"
const END_SCENE := "res://scenes/ui/EndScreen.tscn"

@export var auto_start: bool = true
@export var start_seed: int = 0
@export var spawn_police: bool = true
@export var spawn_traffic: bool = true
## Extra waits for chunk generation before the game is handed to the player (0 = straight in).
@export var warmup_chunks: int = 12

var world: WorldGenerator = null
var player: PlayerCar = null
var camera_controller: CameraController = null
var controls: MobileControls = null
var hud: GameHUD = null
var police_manager: PoliceManager = null
var chase_manager: ChaseManager = null
var traffic_manager: TrafficManager = null
var police_config: PoliceConfig = null
var world_config: WorldConfig = null

var started: bool = false
var statistics: Dictionary = {}
var _pause_instance: Node = null
var _end_instance: Node = null
var _elapsed: float = 0.0
var _stats_report_timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_load_configs()
	_build_world()
	_build_player()
	_build_camera()
	_build_ui()
	if spawn_police:
		_build_police()
	if spawn_traffic:
		_build_traffic()
	if auto_start:
		start_run(start_seed)


func _load_configs() -> void:
	world_config = load("res://resources/config/world_config.tres") as WorldConfig
	if world_config == null:
		world_config = WorldConfig.new()
	police_config = load("res://resources/config/police_config.tres") as PoliceConfig
	if police_config == null:
		police_config = PoliceConfig.new()


func _build_world() -> void:
	world = WorldGenerator.new()
	world.name = "World"
	world.world_config = world_config
	add_child(world)
	statistics = world.generate(start_seed)


func _build_player() -> void:
	var scene := load(PLAYER_SCENE) as PackedScene
	if scene != null:
		player = scene.instantiate() as PlayerCar
	if player == null:
		player = PlayerCar.new()
	player.name = "PlayerCar"
	add_child(player)
	var spawn := world.spawn_transform()
	player.reset_to(spawn)
	player.impact.connect(_on_player_impact)
	player.landed.connect(_on_player_landed)


func _build_camera() -> void:
	camera_controller = CameraController.new()
	camera_controller.name = "CameraController"
	add_child(camera_controller)
	camera_controller.setup(player)


func _build_ui() -> void:
	hud = GameHUD.new()
	hud.name = "HUD"
	hud.player = player
	hud.world_streamer = world.streamer
	var performance := get_node_or_null("/root/PerformanceManager")
	if performance != null:
		hud.performance = performance
	add_child(hud)
	controls = MobileControls.new()
	controls.name = "MobileControls"
	add_child(controls)


func _build_police() -> void:
	police_manager = PoliceManager.new()
	police_manager.name = "Police"
	add_child(police_manager)
	police_manager.setup(police_config, world.road_graph, player, world.materials, world_config)
	police_manager.arrest_progress.connect(_on_arrest_progress)
	police_manager.player_arrested.connect(_on_player_arrested)
	police_manager.chase_escaped.connect(_on_chase_escaped)
	police_manager.unit_wrecked.connect(_on_unit_wrecked)
	chase_manager = ChaseManager.new()
	chase_manager.name = "ChaseManager"
	add_child(chase_manager)
	chase_manager.setup(police_config, player)
	chase_manager.manager = police_manager
	chase_manager.escalation_changed.connect(_on_escalation)
	hud.police_manager = police_manager
	hud.chase_manager = chase_manager
	player.impact.connect(_on_player_impact_for_chase)


func _build_traffic() -> void:
	traffic_manager = TrafficManager.new()
	traffic_manager.name = "Traffic"
	add_child(traffic_manager)
	traffic_manager.setup(world_config, world.road_graph, player)
	traffic_manager.max_cars = int(
		_min_positive([
			float(world_config.max_traffic_cars),
			float(_performance_value("traffic_cars", world_config.max_traffic_cars)),
		])
	)


## Starts a run: the state system is told, the world is streamed around the player and the
## interface is switched on.
func start_run(seed_value: int = 0) -> void:
	if seed_value != 0 and world != null:
		# A different seed means a different city: rebuild the world.
		world.queue_free()
		_build_world()
		var spawn := world.spawn_transform()
		player.reset_to(spawn)
		if traffic_manager != null and world.road_graph != null:
			traffic_manager.graph = world.road_graph
		if police_manager != null:
			police_manager.graph = world.road_graph
	var state := get_node_or_null("/root/GameState")
	if state != null:
		state.start_run(seed_value if seed_value != 0 else world.seed_value)
	started = true
	_elapsed = 0.0
	if hud != null:
		hud.show_message("ПОЕХАЛИ!", 2.0, Color(0.7, 0.95, 0.7))
	run_ready.emit(statistics)


func _physics_process(delta: float) -> void:
	if not started:
		return
	_elapsed += delta
	# 1. stream the city around the player.
	world.update_streaming(player.global_position, delta)
	# 2. camera: free look is fed by the touch controls through the input manager.
	if camera_controller != null:
		var look := InputManager.drive_input.look_delta
		if look != Vector2.ZERO:
			camera_controller.apply_look(look)
		if InputManager.drive_input.camera_reset:
			camera_controller.reset_behind_car()
		camera_controller.update_camera(delta)
	# 3. the chase only exists while there is heat.
	if chase_manager != null:
		chase_manager.escalation_paused = not started


func _process(delta: float) -> void:
	if not started:
		return
	if Input.is_action_just_pressed(InputManager.ACTION_PAUSE):
		toggle_pause()
	_stats_report_timer += delta
	if _stats_report_timer > 2.0:
		_stats_report_timer = 0.0
		_report_statistics()


## Publishes the live statistics to the debug overlay and to the smoke test.
func _report_statistics() -> void:
	if world == null:
		return
	statistics["streaming"] = world.streamer.statistics() if world.streamer != null else {}
	statistics["player"] = player.telemetry() if player != null else {}
	statistics["police"] = police_manager.statistics() if police_manager != null else {}
	statistics["traffic"] = traffic_manager.statistics() if traffic_manager != null else {}
	if camera_controller != null:
		statistics["camera"] = {
			"distance": camera_controller.current_distance,
			"yaw": camera_controller.yaw,
			"fov": camera_controller.fov,
		}


func toggle_pause() -> void:
	var state := get_node_or_null("/root/GameState")
	var paused := state.paused if state != null else false
	_set_paused(not paused)


func _set_paused(value: bool) -> void:
	var state := get_node_or_null("/root/GameState")
	if state != null:
		state.set_paused(value)
	if value:
		if controls != null:
			controls.release_all()
		if _pause_instance == null:
			var scene := load(PAUSE_SCENE) as PackedScene
			if scene != null:
				_pause_instance = scene.instantiate()
				_pause_instance.set("game_world", self)
				add_child(_pause_instance)
	elif _pause_instance != null:
		_pause_instance.queue_free()
		_pause_instance = null


func resume() -> void:
	_set_paused(false)


func _on_player_impact(speed: float, _position: Vector3) -> void:
	if camera_controller != null:
		camera_controller.add_shake(speed * 0.012)
	if hud != null and speed > 18.0:
		hud.show_message("АВАРИЯ", 1.0, Color(1.0, 0.5, 0.4))


func _on_player_impact_for_chase(speed: float, position: Vector3) -> void:
	if chase_manager == null or speed < 6.0:
		return
	# Ramming a cruiser is a loud crime: the heat reacts to it (the car itself reports the
	# contact to the game state, this is the escalation part).
	for unit: PoliceCar in police_manager.units if police_manager != null else []:
		if is_instance_valid(unit) and unit.global_position.distance_to(position) < 6.0:
			chase_manager.register_police_contact()
			break


func _on_player_landed(vertical_speed: float) -> void:
	if camera_controller != null and vertical_speed > 4.0:
		camera_controller.add_shake(vertical_speed * 0.02)


func _on_arrest_progress(ratio: float) -> void:
	if hud != null:
		hud.set_arrest_progress(ratio)


func _on_player_arrested() -> void:
	if hud != null:
		hud.show_message("ВАС ЗАДЕРЖАЛИ", 3.0, Color(1.0, 0.4, 0.3))
	if camera_controller != null:
		camera_controller.add_shake(0.4)
	finish_run(GameState.REASON_ARRESTED)


func _on_chase_escaped() -> void:
	if hud != null:
		hud.show_message("ВЫ ОТОРВАЛИСЬ!", 3.0, Color(0.6, 1.0, 0.6))


func _on_unit_wrecked(_unit: PoliceCar) -> void:
	if hud != null:
		hud.show_message("ПОЛИЦИЯ РАЗБИТА", 2.0, Color(1.0, 0.8, 0.4))


func _on_escalation(level: int, _heat: float) -> void:
	if hud == null:
		return
	match level:
		1:
			hud.show_message("ВАС ЗАМЕТИЛИ", 2.2, Color(1.0, 0.75, 0.35))
		2:
			hud.show_message("ПОГОНЯ НАЧАЛАСЬ", 2.2, Color(1.0, 0.6, 0.3))
		3:
			hud.show_message("ПОДКРЕПЛЕНИЕ ВЫЗВАНО", 2.2, Color(1.0, 0.45, 0.25))
		4:
			hud.show_message("ПОЛИЦИЯ В ЯРОСТИ", 2.2, Color(1.0, 0.35, 0.2))
		5:
			hud.show_message("ОБЛАВА!", 2.5, Color(1.0, 0.25, 0.2))


## Ends the run and shows the summary screen.
func finish_run(reason: StringName) -> void:
	if not started:
		return
	started = false
	var state := get_node_or_null("/root/GameState")
	var summary := state.summary() if state != null else {}
	summary["reason"] = reason
	summary["world"] = statistics
	run_finished.emit(reason, summary)
	if _end_instance == null:
		var scene := load(END_SCENE) as PackedScene
		if scene != null:
			_end_instance = scene.instantiate()
			_end_instance.set("summary", summary)
			_end_instance.set("game_world", self)
			add_child(_end_instance)
	if camera_controller != null:
		camera_controller.auto_recenter_enabled = false


func _performance_value(key: String, fallback: int) -> int:
	var performance := get_node_or_null("/root/PerformanceManager")
	if performance == null:
		return fallback
	var value: Variant = performance.get(key)
	if value == null:
		return fallback
	return int(value)


func _min_positive(values: Array) -> float:
	var result := INF
	for value: float in values:
		if value > 0.0:
			result = minf(result, value)
	return result if result < INF else 0.0


## Full state of the running game: used by the smoke test to assert that everything is alive.
func runtime_report() -> Dictionary:
	_report_statistics()
	var report := statistics.duplicate()
	report["started"] = started
	report["elapsed"] = _elapsed
	report["player_position"] = player.global_position if player != null else Vector3.ZERO
	report["police_phase"] = police_manager.phase if police_manager != null else -1
	report["world_debug"] = world.debug_string() if world != null else ""
	return report
