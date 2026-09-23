class_name PoliceCar
extends VehicleRig
## Патрульная машина = тот же каркас, что и у игрока, плюс ИИ, маячок и «засветка» ремонта.
##
## СОЗНАТЕЛЬНО НЕ ИМЕЕТ: собственного движения (всё в VehiclePhysics + автопилоте),
## собственных решений (PoliceStrategy), собственного спавна (SpawnManager). Здесь только
## «тело»: палитра, мигалка, служебные сигналы и состояние для HUD.

signal unit_captured(unit: PoliceCar)

const LIGHTBAR_INTERVAL_S := 0.08

var ai: PoliceAI = null
var lightbar_time: float = 0.0
var _lightbar_timer: float = 0.0
var spawn_time_s: float = 0.0
var assigned_wanted: int = 0
var ram_count: int = 0

func _ready() -> void:
	is_player = false
	wants_nitro = false
	config_section = "vehicle.police"
	assemble()
	ai = PoliceAI.new()
	ai.name = "PoliceAI"
	add_child(ai)
	if visual != null and visual.has_method("set_lightbar"):
		visual.call("set_lightbar", true, 0.0)

func assign(chase: Node, index: int) -> void:
	if ai != null:
		ai.configure(chase, index)
	assigned_wanted = int(chase.call("wanted_level")) if chase != null and chase.has_method("wanted_level") else 0

func spawn(position: Vector3, heading: float, ground_y: float = 0.0) -> void:
	spawn_time_s = Time.get_ticks_msec() / 1000.0
	place_at(position, heading, ground_y)
	if ai != null:
		ai.nav.reset()
		ai.lost_time_s = 0.0

func _process(delta: float) -> void:
	# Мигалка — смена emissive-материала с фиксированным шагом, БЕЗ источников света:
	# на мобильном рендере это ~0 стоимости, а «погоня» читается мгновенно.
	_lightbar_timer -= delta
	if _lightbar_timer <= 0.0 and visual != null and visual.has_method("set_lightbar"):
		_lightbar_timer = LIGHTBAR_INTERVAL_S
		lightbar_time += LIGHTBAR_INTERVAL_S
		visual.call("set_lightbar", true, lightbar_time)

func set_ai_enabled(on: bool) -> void:
	if ai != null:
		ai.set_enabled(on)

func mode_name() -> String:
	return String(ai.mode) if ai != null else "нет ИИ"

func distance_to_player(player: Node) -> float:
	if player == null or not is_instance_valid(player):
		return INF
	return global_position.distance_to(player.global_position)

func debug_line() -> String:
	var tail := ai.debug_line() if ai != null else ""
	return "патруль[%d] %s | %s" % [assigned_wanted, status_line(), tail]

func state() -> Dictionary:
	var data := snapshot()
	data["police"] = ai.state() if ai != null else {}
	data["spawn_age_s"] = Time.get_ticks_msec() / 1000.0 - spawn_time_s
	return data
