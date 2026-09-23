class_name ProceduralVehicleModel
extends VehicleVisualModel
## Процедурная модель машины: кузов/оптика/стёкла из `CarGeometry`, колёса на своих
## пирах (рыскание от руля + вращение от spin), подсветка стопов/мигалки/«языки» нитро.
##
## Что здесь действительно важно для «не прототип»:
##  * 5 поверхностей у кузова (краска, тёмный пластик, стёкла, фары, ПТФ) — разный PBR,
##    а не один материал на всю машину;
##  * свет — эмиссивные материалы + две фары-OmniLight3D ТОЛЬКО у игрока (лимит источников);
##  * колесо — полноценный узел: протектор, боковина, диск, спицы, тормозной диск, суппорт;
##  * корпус слегка кренится/клюёт по фактическим длинам стоек — машина «садится» при
##    разгоне и перекатывается в повороте, а не едет как приклеенная пластина;
##  * нитро — эмиссивные конусы из выхлопа, масштаб и яркость по `visual_intensity`.
##
## Никаких внешних ассетов: если в `assets/models/<имя>.glb` появится модель, достаточно
## переключить `visual_scene` в VehicleConfig — этот класс тогда не создаётся вовсе.

const WHEEL_COUNT := 4
const BOB_BLEND := 0.55
const FLAME_BASE_SCALE := Vector3(0.34, 0.16, 0.16)

var body_instance: MeshInstance3D = null
var wheel_pivots: Array[Node3D] = []
var wheel_spinners: Array[Node3D] = []
var wheel_instances: Array[MeshInstance3D] = []
var headlight_lights: Array[OmniLight3D] = []
var flame_instances: Array[MeshInstance3D] = []
var lightbar_mesh: MeshInstance3D = null
var paint_material: StandardMaterial3D = null
var head_material: StandardMaterial3D = null
var tail_material: StandardMaterial3D = null
var lightbar_red: StandardMaterial3D = null
var lightbar_blue: StandardMaterial3D = null
var geometry_info: Dictionary = {}
var _error: String = ""
var _pitch: float = 0.0
var _roll: float = 0.0

func setup(p_config: VehicleConfig, p_physics: Node, p_player: bool = false) -> void:
	super(p_config, p_physics, p_player)
	if config == null:
		_error = "нет VehicleConfig"
		return
	var parts: Dictionary = CarGeometry.build(config)
	var body_mesh: ArrayMesh = parts.get("body") as ArrayMesh
	var wheel_mesh: ArrayMesh = parts.get("wheel") as ArrayMesh
	geometry_info = parts.get("info", {}) as Dictionary
	if body_mesh == null:
		_error = "CarGeometry вернул пустой кузов"
		return

	# ---- Кузов: один MeshInstance3D с 5 поверхностями; материалы — override'ы,
	# чтобы цвет краски был у каждого экземпляра своим (общий кэш не пачкается).
	body_instance = MeshInstance3D.new()
	body_instance.name = "Body"
	body_instance.mesh = body_mesh
	paint_material = MaterialLibrary.unique("car_paint")
	var trim_mat := MaterialLibrary.get_material("car_trim")
	var glass_mat := MaterialLibrary.get_material("car_glass")
	head_material = MaterialLibrary.unique("car_light")
	tail_material = MaterialLibrary.unique("car_tail")
	var mats: Array = [paint_material, trim_mat, glass_mat, head_material, tail_material]
	for i in range(mini(body_mesh.get_surface_count(), mats.size())):
		body_instance.set_surface_override_material(i, mats[i])
	body_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body_instance.custom_aabb = AABB(body_mesh.get_aabb().position - Vector3(0.1, 0.1, 0.1),
		body_mesh.get_aabb().size + Vector3(0.2, 0.2, 0.2))
	body_pivot = Node3D.new()
	body_pivot.name = "BodyPivot"
	body_pivot.add_child(body_instance)
	add_child(body_pivot)

	# ---- Колёса: pivot(рыскание) -> spinner(вращение) -> меш.
	if wheel_mesh != null:
		var tyre_mat := MaterialLibrary.get_material("car_tyre")
		var rim_mat := MaterialLibrary.get_material("car_rim")
		for i in range(WHEEL_COUNT):
			var pivot := Node3D.new()
			pivot.name = "WheelPivot%d" % i
			var spinner := Node3D.new()
			spinner.name = "WheelSpin%d" % i
			var mesh := MeshInstance3D.new()
			mesh.name = "WheelMesh%d" % i
			mesh.mesh = wheel_mesh
			mesh.set_surface_override_material(0, tyre_mat)
			mesh.set_surface_override_material(1, rim_mat)
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			spinner.add_child(mesh)
			pivot.add_child(spinner)
			add_child(pivot)
			wheel_pivots.append(pivot)
			wheel_spinners.append(spinner)
			wheel_instances.append(mesh)

	# ---- Свет. Только у игрока: на мобильном рендере каждый OmniLight3D — это проход
	# по всем объектам в радиусе, поэтому «фары у каждой из 6 машин» = -20 fps.
	if player_car:
		var hl_pos: Vector3 = geometry_info.get("headlight_pos", Vector3(
			config.body_width_m * 0.35, 0.0, -config.body_length_m * 0.5)) as Vector3
		for side in [-1.0, 1.0]:
			var lamp := OmniLight3D.new()
			lamp.name = "Headlight"
			lamp.position = Vector3(side * absf(hl_pos.x), hl_pos.y, hl_pos.z)
			lamp.light_energy = 1.35
			lamp.light_color = Color(0.86, 0.92, 1.0)
			lamp.omni_range = maxf(9.0, config.max_speed_kmh * 0.06)
			lamp.shadow_enabled = false
			lamp.omni_attenuation = 1.45
			lamp.visible = player_car
			add_child(lamp)
			headlight_lights.append(lamp)

	# ---- Нитро: эмиссивные конусы у земли за задним бампером (без частиц — Compatibility).
	var flame_mat := StandardMaterial3D.new()
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_mat.albedo_color = Color(0.45, 0.72, 1.0, 0.55)
	flame_mat.emission_enabled = true
	flame_mat.emission = Color(0.35, 0.65, 1.0)
	flame_mat.emission_energy_multiplier = 3.0
	var cone := ConeMesh.new()
	cone.radius = 0.085
	cone.height = 0.52
	cone.radial_segments = 10
	cone.rings = 2
	cone.material = flame_mat
	var rear_z: float = absf(float(geometry_info.get("half_length", config.body_length_m * 0.5)))
	for side in [-1.0, 1.0]:
		var flame := MeshInstance3D.new()
		flame.name = "NitroFlame"
		flame.mesh = cone
		flame.rotation_degrees = Vector3(90.0, 0.0, 0.0)  # ось конуса +Y -> +Z (пламя назад)
		flame.position = Vector3(side * config.track_width_m * 0.30, -config.ride_height_m + config.wheel_radius_m * 0.30, rear_z + 0.10)
		flame.visible = false
		add_child(flame)
		flame_instances.append(flame)

	# ---- Мигалка (только «перехватчик» ППС) + стоп-сигналы как отдельные поверхности.
	var bar_points: PackedVector3Array = geometry_info.get("lightbar", PackedVector3Array())
	if not bar_points.is_empty():
		lightbar_mesh = MeshInstance3D.new()
		lightbar_mesh.name = "Lightbar"
		var bar := BoxMesh.new()
		bar.size = Vector3(0.34, 0.075, 0.15)
		bar.material = MaterialLibrary.get_material("lightbar_red")
		lightbar_mesh.mesh = bar
		lightbar_mesh.position = bar_points[0]
		add_child(lightbar_mesh)
		lightbar_red = MaterialLibrary.unique("lightbar_red")
		lightbar_blue = MaterialLibrary.unique("lightbar_blue")
		var second := MeshInstance3D.new()
		second.name = "LightbarBlue"
		second.mesh = bar
		second.position = bar_points[1]
		second.set_surface_override_material(0, lightbar_blue)
		add_child(second)
		# Первая половина остаётся на материале меша, но нам нужен свой экземпляр и для неё.
		lightbar_mesh.set_surface_override_material(0, lightbar_red)

func set_paint_color(color: Color) -> void:
	if paint_material != null:
		paint_material.albedo_color = color

## Основной кадр: читаем состояние подвески/колёс и приводим в порядок узлы.
func sync_from_physics(delta: float) -> void:
	if physics == null or config == null:
		return
	var wheels_node = physics.wheels
	if wheels_node == null:
		return
	var wheels: Array = wheels_node.wheels
	var rest := float(wheels[0].rest_length) if not wheels.is_empty() else config.ride_height_m
	for i in range(mini(wheel_pivots.size(), wheels.size())):
		var w = wheels[i]
		var attach: Vector3 = w.attach_local
		var length: float = w.length
		# Центр колеса = ступица минус (длина стойки - радиус): «выглядит» как реальный ход подвески.
		var center := attach + Vector3(0.0, -(length - config.wheel_radius_m), 0.0)
		wheel_pivots[i].position = center
		wheel_pivots[i].rotation.y = float(w.steer_angle) if w.is_front else 0.0
		wheel_spinners[i].rotation.x = float(w.spin_angle)
	# Крен/клевёнок кузова по разнице длин стоек.
	if not wheels.is_empty() and body_pivot != null:
		var front_len := 0.0
		var rear_len := 0.0
		var left := 0.0
		var right := 0.0
		var nf := 0
		var nr := 0
		for w in wheels:
			if w.is_front:
				front_len += w.length
				nf += 1
			else:
				rear_len += w.length
				nr += 1
			if w.is_left:
				left += w.length
			else:
				right += w.length
		if nf > 0 and nr > 0:
			front_len /= float(nf)
			rear_len /= float(nr)
			var target_pitch := clampf((rear_len - front_len) * BOB_BLEND / maxf(config.suspension_travel_m, 0.02), -0.09, 0.09)
			# (left - right) уже даёт и величину, и знак переката: доп. «знак от руля» не нужен.
			var target_roll := clampf((left - right) * 0.5 * BOB_BLEND / maxf(config.suspension_travel_m, 0.02), -0.11, 0.11)
			_pitch = lerpf(_pitch, target_pitch, minf(delta * 9.0, 1.0))
			_roll = lerpf(_roll, target_roll, minf(delta * 9.0, 1.0))
			body_pivot.rotation.x = _pitch
			body_pivot.rotation.z = -_roll
			body_pivot.position.y = lerpf(body_pivot.position.y, (front_len + rear_len) * 0.5 - rest, minf(delta * 8.0, 1.0))
	_apply_light_state()

func _apply_light_state() -> void:
	if head_material != null:
		var energy := 0.0 if not headlights_on else 3.4
		head_material.emission_energy_multiplier = energy
		head_material.albedo_color = Color(0.9, 0.91, 0.88) if headlights_on else Color(0.42, 0.43, 0.44)
	if tail_material != null:
		# Торможение: яркость ПТФ растёт, но «габариты» не гаснут полностью.
		tail_material.emission_energy_multiplier = lerpf(0.55, 3.4, brake_intensity)
	for lamp in headlight_lights:
		lamp.light_energy = 1.35 if headlights_on else 0.0
	if not flame_instances.is_empty():
		var k := nitro_intensity
		for flame in flame_instances:
			flame.visible = k > 0.02
			if flame.visible:
				var s := lerpf(0.25, 1.0, k)
				flame.scale = Vector3(FLAME_BASE_SCALE.x * (0.8 + k), FLAME_BASE_SCALE.y * (0.8 + k), s)
				var mat: StandardMaterial3D = flame.mesh.material as StandardMaterial3D
				if mat != null:
					mat.emission_energy_multiplier = lerpf(0.6, 4.2, k)
					mat.albedo_color.a = lerpf(0.22, 0.72, k)
	if lightbar_enabled and lightbar_mesh != null:
		var phase := fmod(lightbar_time * 3.4, 2.0)
		var red_on := phase < 1.0
		if lightbar_red != null:
			lightbar_red.emission_energy_multiplier = 8.0 if red_on else 0.15
		if lightbar_blue != null:
			lightbar_blue.emission_energy_multiplier = 0.15 if red_on else 8.0
	elif lightbar_mesh != null and not lightbar_enabled:
		if lightbar_red != null:
			lightbar_red.emission_energy_multiplier = 0.4
		if lightbar_blue != null:
			lightbar_blue.emission_energy_multiplier = 0.4

func set_lightbar(enabled: bool, time: float) -> void:
	lightbar_enabled = enabled
	lightbar_time = time
	if lightbar_mesh != null:
		lightbar_mesh.visible = true

func set_headlights(enabled: bool) -> void:
	headlights_on = enabled

## Для отладочной панели/скриншотов: сколько геометрии реально собрано.
func debug_summary() -> String:
	var tris: int = 0
	if body_instance != null and body_instance.mesh != null:
		for s in range(body_instance.mesh.get_surface_count()):
			tris += body_instance.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3
	return "Поверхности кузова: %d, треугольников: %d, колёс: %d, фар-источников: %d, ошибок: %s" % [
		0 if body_instance == null or body_instance.mesh == null else body_instance.mesh.get_surface_count(),
		tris, wheel_instances.size(), headlight_lights.size(), _error if not _error.is_empty() else "нет",
	]

func last_error() -> String:
	return _error

func visual_aabb() -> AABB:
	if body_instance != null and body_instance.mesh != null:
		return body_instance.mesh.get_aabb()
	return super.visual_aabb()
