class_name VehicleRig
extends RigidBody3D
## Каркас машины: физика + контроллер + нитро + визуальная модель, собранные кодом.
##
## ЗАЧЕМ ЭТОТ КЛАСС: и игрок, и патрули состоят из одних и тех же подсистем
## (VehiclePhysics / VehicleController / NitroSystem / VehicleVisualModel). Если бы каждый
## вариант собирался в своём .tscn, правка «добавить узел» ушла бы в 7 сцен. Поэтому
## сцена машины — ОДИН корневой узел с этим скриптом, а всё остальное создаётся в
## `assemble()`: сцена остаётся читаемой, а состав подсистем — единым для всех.
##
## ПОРЯДОК ИНИЦИАЛИЗАЦИИ ВАЖЕН: `VehiclePhysics` и `NitroSystem` ищут настройки в
## `_ready()`, а дочерние узлы готовятся РАНЬШЕ родителя — значит конфиг обязан быть
## назначен ДО `add_child(...)`. Это сделано через `get_vehicle_config()`: физика поднимается
## по родителям и спрашивает конфиг у карказа.
##
## ДВИЖЕНИЕ: только физика (`_integrate_forces` в VehiclePhysics). Здесь нет ни одного
## `position +=` — `place_at()` телепортирует ТОЛЬКО при спавне/респавне, и это
## задокументировано отдельно (не «движение», а «установка»).

signal rig_ready(rig: VehicleRig)
signal crashed(impact_speed_ms: float, rig: VehicleRig)
signal speed_updated(speed_kmh: float)

const SPAWN_SETTLE_S := 0.25
const SPAWN_CLEARANCE_M := 0.06

@export var config_section: String = "vehicle.player":
	set(value):
		config_section = value
		if config == null:
			config = GameSetup.get_config(value) as VehicleConfig
@export var is_player: bool = false
@export var wants_nitro: bool = false
@export var auto_assemble: bool = true
## Замена визуальной модели без правки физики (docs/CAR_MODEL.md): инстанс VehicleVisualModel.
@export var visual_override: Node = null

var config: VehicleConfig = null
var physics: VehiclePhysics = null
var controller: VehicleController = null
var nitro: NitroSystem = null
var visual: Node = null
var paint_color: Color = Color(0.72, 0.05, 0.07)
var settle_time: float = 0.0
var _speed_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _travelled_m: float = 0.0

func _ready() -> void:
	if auto_assemble:
		assemble()

## Собрать подсистемы. Идемпотентно: повторный вызов ничего не дублирует.
func assemble() -> void:
	if physics != null:
		return
	if config == null:
		config = GameSetup.get_config(config_section) as VehicleConfig
	if config == null:
		config = VehicleConfig.new()
		push_warning("VehicleRig: секция '%s' не найдена — взяты дефолты VehicleConfig" % config_section)
	name = config.display_name
	# Пауза останавливает и игрока, и патрулей (PROCESS_MODE_PAUSABLE у родителя-сцены),
	# но не останавливает меню — см. AppState/ScreenFlow.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	max_contacts_reported = 8
	contact_monitor = true
	_build_collision()
	physics = VehiclePhysics.new()
	physics.name = "VehiclePhysics"
	add_child(physics)
	physics.config = config
	controller = VehicleController.new()
	controller.name = "VehicleController"
	controller.allow_keyboard = is_player
	add_child(controller)
	controller.physics = physics
	if wants_nitro:
		nitro = NitroSystem.new()
		nitro.name = "NitroSystem"
		nitro.allowed = true
		add_child(nitro)
		controller.nitro = nitro
	_build_visual()
	physics.apply_config(config)
	_last_position = global_position
	rig_ready.emit(self)
	if physics.crashed.get_connections().is_empty():
		physics.crashed.connect(_on_crashed)

func _build_collision() -> void:
	## Два бокса: кузов и «низ» с колёсами. Нижняя коробка делает машину «сидящей на
	## колёсах» (забирается на бордюр, а не цепляет юбкой), верхняя — отвечает за боковые
	## контакты и кувырок при ударе о стену.
	var h := CarGeometry.heights(config)
	var half_l: float = h["half_length"]
	var half_w: float = h["half_width"]
	var wheel_bottom := -config.ride_height_m
	var upper := CollisionShape3D.new()
	upper.name = "BodyShape"
	var upper_box := BoxShape3D.new()
	var belt := float(h["belt_y"])
	var roof := float(h["roof_y"])
	upper_box.size = Vector3(half_w * 2.0 - 0.04, maxf(roof - belt + 0.18, 0.3), half_l * 2.0 - 0.04)
	upper.shape = upper_box
	upper.position = Vector3(0.0, (belt + roof) * 0.5, 0.0)
	add_child(upper)
	var lower := CollisionShape3D.new()
	lower.name = "ChassisShape"
	var lower_box := BoxShape3D.new()
	lower_box.size = Vector3(config.track_width_m + config.wheel_width_m, maxf(belt - wheel_bottom, 0.2), half_l * 2.0 - 0.1)
	lower.shape = lower_box
	lower.position = Vector3(0.0, (wheel_bottom + belt) * 0.5, 0.0)
	add_child(lower)

func _build_visual() -> void:
	if visual != null:
		return
	if visual_override != null:
		visual = visual_override
		add_child(visual)
	elif config.visual_scene != null:
		visual = config.visual_scene.instantiate()
		add_child(visual)
	else:
		var model := ProceduralVehicleModel.new()
		model.name = "VisualModel"
		add_child(model)
		visual = model
	if visual != null and visual.has_method("setup"):
		visual.call("setup", config, physics, is_player)
	if visual is ProceduralVehicleModel:
		(visual as ProceduralVehicleModel).set_paint_color(paint_color)

# ------------------------------------------------------------------ управление

## Источник управления для мобильного UI (у игрока). Патрули используют автопилот.
func set_controls(node: Node) -> void:
	if controller != null:
		controller.controls = node

func set_autopilot(input: DriveInput) -> void:
	if controller != null:
		controller.set_autopilot(input)

## Спавн/респавн: единственное место, где позиция задаётся напрямую (и только на 1 кадр).
## y = max(высота спавна, земля + дорожный просвет), иначе машина «влипает» в асфальт и
## физика выталкивает её рывком.
func place_at(position: Vector3, heading: float, ground_y: float = 0.0, cfg: WorldConfig = null) -> void:
	var world := cfg if cfg != null else (GameSetup.get_config("world") as WorldConfig)
	var floor_y := maxf(ground_y, world.ground_y_m) if world != null else ground_y
	var ride := config.ride_height_m + SPAWN_CLEARANCE_M
	var from_ground := floor_y + ride
	var configured := world.spawn_height_m if world != null else 0.0
	# max() принципиален: spawn_height_m — «гарантированный» верх, но если земля поднята
	# (будущие холмы), спавн обязан считаться от земли, иначе машина стартует в асфальте.
	var spawn_y := maxf(maxf(position.y, from_ground), configured)
	global_transform = Transform3D(
		Basis(Vector3.UP, heading), Vector3(position.x, spawn_y, position.z)
	)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# Первые кадры после спавна кузов «устаивается» на подвеске: визуал моргаем не
	# синхронизировать, иначе игрок видит щелчок по высоте.
	settle_time = SPAWN_SETTLE_S
	_last_position = global_position
	if controller != null:
		controller.reset()
	if nitro != null:
		nitro.refill()

func _physics_process(delta: float) -> void:
	if settle_time > 0.0:
		settle_time = maxf(settle_time - delta, 0.0)
		return
	_speed_timer -= delta
	if _speed_timer <= 0.0:
		_speed_timer = 0.1
		speed_updated.emit(ground_speed_kmh())
	_travelled_m += maxf(_last_position.distance_to(global_position), 0.0)
	_last_position = global_position

func _on_crashed(impact_speed_ms: float, _other: Object) -> void:
	crashed.emit(impact_speed_ms, self)

# ------------------------------------------------------------------ состояние

func get_vehicle_config() -> VehicleConfig:
	return config

func ground_speed_kmh() -> float:
	if physics != null:
		return absf(physics.forward_speed_kms) * 3.6
	return linear_velocity.length() * 3.6

func absolute_speed_kmh() -> float:
	return linear_velocity.length() * 3.6

func is_drifting() -> bool:
	return physics != null and physics.drift_ratio > 0.35

func travelled_m() -> float:
	return _travelled_m

func forward_direction() -> Vector3:
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD

func heading_rad() -> float:
	var fwd := forward_direction()
	return atan2(-fwd.x, -fwd.z)

func set_physics_enabled(on: bool) -> void:
	if physics != null:
		physics.set_enabled(on)

func snapshot() -> Dictionary:
	var data: Dictionary = {
		"name": name,
		"speed_kmh": ground_speed_kmh(),
		"position": global_position,
		"heading": heading_rad(),
		"travelled_m": _travelled_m,
		"is_player": is_player,
	}
	if physics != null:
		data["physics"] = physics.snapshot()
	if nitro != null:
		data["nitro_charge"] = nitro.charge_ratio()
		data["nitro_active"] = nitro.active
	if controller != null:
		data["blocked"] = controller.is_blocked
	return data

func status_line() -> String:
	var parts := PackedStringArray()
	parts.append("скорость %.0f км/ч" % ground_speed_kmh())
	if physics != null:
		parts.append("пробуксовка %.0f%%" % (physics.drift_ratio * 100.0))
		parts.append("колесо %d/%d на земле" % [physics.grounded_count, 4])
	if nitro != null:
		parts.append("нитро %.0f%%" % (nitro.charge_ratio() * 100.0))
	if controller != null and controller.is_blocked:
		parts.append("ЗАБЛОКИРОВАНА")
	return " | ".join(parts)

## Визуал живёт в кадре отрисовки, физика - в своём тике. Разделение нужно, чтобы на
## 90/120 Гц экране подвеска и вращение колёс не «дёргались» на 60 Гц физики.
func _process(delta: float) -> void:
	if visual != null and visual.has_method("sync_from_physics"):
		visual.call("sync_from_physics", delta)

func set_process_visual(on: bool) -> void:
	set_physics_process(on)
	set_process(on)
