class_name WheelSystem
extends RefCounted
## Четыре колеса: геометрия, лучи подвески, силы упругости/демпфирования, кинематика вращения.
##
## ГЕОМЕТРИЯ. Начало координат кузова = плоскость ступиц колёс. Для колеса:
##   d  — расстояние вниз от ступицы до точки касания дороги (результат луча),
##   L  — длина стойки = clampf(d, min_length, max_length),
##   L0 — длина в покое: `ride_height_m + static_sag`, подобрана так, чтобы под весом
##        машины стойка продавилась ровно до `ride_height_m` (заявленная высота
##        ступицы над дорогой — это равновесие, а не предел хода),
##   ход подвески = L0 ± suspension_travel_m/2, «на земле» пока d <= max_length.
## Сила пружины только толкает (стойка без демпфера растяжения): F = k * (L0 - L),
## плюс демпфер по скорости изменения L. Кузов визуально «сидит» над ступицами:
## днище на y = floor_clearance_m - ride_height_m (см. [CarGeometry]).

## ВРАЩЕНИЕ. Пробуксовка считается кинематически, а не интегрированием жёсткой ODE:
## при 60 Гц и продольной жёсткости шины ~70 000 Н/ед. явная интеграция угла колеса
## уходит в автоколебание. Колесо катится «без проскальзывания», а при превышении
## тягой предела сцепления уходит в контролируемый slip, пропорциональный избытку момента.
## Это стабильно на любом железе, даёт пробуксовку с места, блокировку ручником
## и корректную визуальную скорость вращения.
##
## Оси силы шины: X — вдоль покрышки вперёд (+), Y — вправо (+).

const WHEEL_FL := 0
const WHEEL_FR := 1
const WHEEL_RL := 2
const WHEEL_RR := 3
const WHEEL_COUNT := 4

class WheelState:
	## 0=FL 1=FR 2=RL 3=RR
	var index: int = 0
	var is_front: bool = false
	var is_left: bool = false
	var is_driven: bool = true
	## Точка крепления стойки в локальных координатах кузова (м).
	var attach_local: Vector3 = Vector3.ZERO
	## Длины стойки (м).
	var rest_length: float = 0.0
	var min_length: float = 0.02
	var max_length: float = 0.4
	var length: float = 0.0
	var compression: float = 0.0
	var compression_velocity: float = 0.0
	## Контакт.
	var grounded: bool = false
	var contact_global: Vector3 = Vector3.ZERO
	var normal_global: Vector3 = Vector3.UP
	var ground: Object = null
	var ray_distance: float = 0.0
	## Силы/нагрузки (Н).
	var load: float = 0.0
	var suspension_force: float = 0.0
	var tyre_force_local: Vector2 = Vector2.ZERO
	var force_world: Vector3 = Vector3.ZERO
	## Управление колесом.
	var steer_angle: float = 0.0
	var spin: float = 0.0
	var spin_visual: float = 0.0
	var slip_ratio: float = 0.0
	var slip_angle: float = 0.0
	var locked: bool = false
	var spin_slip: float = 0.0
	var mu: float = 1.0
	## Момент на колесе (Н·м) — нужно для расчёта пробуксовки и звука/анимации.
	var drive_torque: float = 0.0
	var brake_torque: float = 0.0

	## Загрузка шины силой: 0 = «едет как по рельсам», 1 = предел сцепления.
	func saturation() -> float:
		return minf(tyre_force_local.length() / maxf(mu * load, 1.0), 1.6)

	func is_rear() -> bool:
		return not is_front

var config: VehicleConfig
var wheels: Array[WheelState] = []
var gravity: float = 9.8
var ray_count: int = 0
var spring_rate: float = 1.0
var damper_rate: float = 1.0
var wheel_inertia: float = 1.0

func setup(p_config: VehicleConfig, p_gravity: float = 9.8) -> void:
	config = p_config
	gravity = maxf(p_gravity, 0.5)
	wheels.clear()
	spring_rate = config.spring_rate_n_per_m()
	damper_rate = config.damper_rate_n_s_per_m()
	wheel_inertia = maxf(0.5 * config.wheel_inertia_kg * config.wheel_radius_m * config.wheel_radius_m, 0.05)
	var half_track := config.track_width_m * 0.5
	var half_base := config.wheelbase_m * 0.5
	var travel_half := maxf(config.suspension_travel_m * 0.5, 0.01)
	# Провисание под весом: из него задаём «свободную» длину, чтобы равновесие
	# пришлось ровно на ride_height_m, а ход подвески был симметричен.
	var static_sag := clampf(
		config.mass_kg * gravity / (4.0 * maxf(spring_rate, 1.0)),
		travel_half * 0.2, travel_half * 0.9
	)
	var rest := maxf(config.ride_height_m, config.wheel_radius_m * 0.6) + static_sag
	var drive_rear := 1.0 - clampf(config.drive_bias_front, 0.0, 1.0)
	for i in range(WHEEL_COUNT):
		var w := WheelState.new()
		w.index = i
		w.is_front = i < 2
		w.is_left = (i % 2) == 0
		var share := drive_rear if not w.is_front else config.drive_bias_front
		w.is_driven = share > 0.001
		var x := -half_track if w.is_left else half_track
		var z := -half_base if w.is_front else half_base
		w.attach_local = Vector3(x, 0.0, z)
		w.rest_length = rest
		w.min_length = maxf(rest - travel_half, 0.02)
		w.max_length = rest + travel_half
		w.length = rest
		w.mu = config.grip_front_mu if w.is_front else config.grip_rear_mu
		wheels.append(w)

## Луч вниз от ступицы. Вызывать из `_physics_process`: внутри `_integrate_forces`
## space-state-запросы делать нельзя.
func cast_rays(space_state: PhysicsDirectSpaceState3D, body_xform: Transform3D, exclude: Array[RID], mask: int, dt: float) -> void:
	ray_count = 0
	var step := maxf(dt, 0.0005)
	var up := body_xform.basis.y
	var down := up * -1.0
	for w in wheels:
		var attach := body_xform * w.attach_local
		var prev_length := w.length
		if space_state == null:
			_drop_wheel(w, prev_length, step)
			continue
		var reach := w.max_length + config.wheel_radius_m + 0.5
		var query := PhysicsRayQueryParameters3D.create(attach, attach + down * reach, mask, exclude)
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.hit_from_inside = false
		var hit := space_state.intersect_ray(query)
		ray_count += 1
		if hit.is_empty():
			_drop_wheel(w, prev_length, step)
			continue
		var point: Vector3 = hit.get("position", attach + down * reach)
		# Протяжка вдоль вертикали кузова: на уклоне расстояние до точки > «высоты» стойки,
		# а для пружины важна именно вертикальная компонента.
		var measured := maxf((attach - point).dot(up), 0.0)
		w.ray_distance = attach.distance_to(point)
		w.contact_global = point
		w.normal_global = hit.get("normal", Vector3.UP)
		w.ground = hit.get("collider")
		w.grounded = measured <= w.max_length + config.wheel_radius_m * 0.08
		w.length = clampf(measured, w.min_length, w.max_length)
		w.compression_velocity = (w.length - prev_length) / step
		w.compression = (w.rest_length - w.length) / maxf(config.suspension_travel_m * 0.5, 0.01)

func _drop_wheel(w: WheelState, prev_length: float, step: float) -> void:
	w.grounded = false
	w.ground = null
	w.normal_global = Vector3.UP
	w.ray_distance = 0.0
	w.length = w.max_length
	w.compression_velocity = (w.length - prev_length) / step
	w.compression = (w.rest_length - w.length) / maxf(config.suspension_travel_m * 0.5, 0.01)

## Силы подвески по текущим длинам + стабилизаторы поперечной устойчивости.
func compute_suspension_forces(loads: PackedFloat32Array) -> void:
	for w in wheels:
		var deflection := w.rest_length - w.length
		var spring_force := deflection * spring_rate
		var damper_force := -w.compression_velocity * damper_rate
		var total := spring_force + damper_force
		w.suspension_force = clampf(total if w.grounded else 0.0, 0.0, config.suspension_max_force_n)
		w.load = maxf(loads[w.index], 10.0)
	_apply_anti_roll(true, config.anti_roll_front_n, WHEEL_FL, WHEEL_FR)
	_apply_anti_roll(false, config.anti_roll_rear_n, WHEEL_RL, WHEEL_RR)

func _apply_anti_roll(_is_front: bool, stiffness: float, left_index: int, right_index: int) -> void:
	if stiffness <= 0.0:
		return
	var left: WheelState = wheels[left_index]
	var right: WheelState = wheels[right_index]
	var travel := maxf(config.suspension_travel_m, 0.01)
	# Разница хода стоек -> стабилизатор перераспределяет силу (меньше крены, больше сцепления).
	var diff := (left.rest_length - left.length) - (right.rest_length - right.length)
	var transfer := clampf(stiffness * diff / travel, -left.load * 0.9, right.load * 0.9)
	left.suspension_force = clampf(left.suspension_force - transfer, 0.0, config.suspension_max_force_n)
	right.suspension_force = clampf(right.suspension_force + transfer, 0.0, config.suspension_max_force_n)

## Кинематика вращения колеса: пробуксовка от избытка тяги, блокировка от тормоза.
## `force_limit` — предел силы шины (Н) при текущем сцеплении.
func update_wheel_spin(
	w: WheelState,
	drive_torque: float,
	brake_torque: float,
	long_velocity: float,
	force_limit: float,
	dt: float,
)-> void:
	var radius := maxf(config.wheel_radius_m, 0.05)
	var step := maxf(dt, 0.0005)
	var free_roll_spin := long_velocity / radius
	w.drive_torque = drive_torque
	w.brake_torque = brake_torque
	# Блокировка: тормозной момент сильнее того, что шина может «дотащить».
	if brake_torque > force_limit * radius and absf(long_velocity) < 12.0 and drive_torque < force_limit * radius:
		w.locked = true
	elif brake_torque < force_limit * radius * 0.75:
		w.locked = false
	var target_spin := free_roll_spin
	if not w.locked and absf(drive_torque) > force_limit * radius:
		# Избыток момента -> проскальзывание. Растёт как корень, чтобы не «взлетало».
		var excess := (absf(drive_torque) - force_limit * radius) / maxf(force_limit * radius, 1.0)
		w.spin_slip = lerpf(w.spin_slip, clampf(sqrtf(excess) * 1.15, 0.0, 2.2), minf(step * 8.0, 1.0))
		target_spin = free_roll_spin * (1.0 + signf(drive_torque) * w.spin_slip)
	elif not w.locked:
		w.spin_slip = lerpf(w.spin_slip, 0.0, minf(step * 3.5, 1.0))
	if w.locked:
		target_spin = 0.0
	w.spin = lerpf(w.spin, target_spin, minf(step * (14.0 if w.locked else 9.0), 1.0))
	# Визуальное вращение сглаживаем сильнее — иначе на 60 Гц видно «стробирование».
	w.spin_visual = lerpf(w.spin_visual, w.spin, minf(step * 22.0, 1.0))
	w.slip_ratio = VehicleMath.slip_ratio(w.spin, radius, long_velocity)

func grounded_count() -> int:
	var n := 0
	for w in wheels:
		if w.grounded:
			n += 1
	return n

func is_any_grounded() -> bool:
	for w in wheels:
		if w.grounded:
			return true
	return false

func total_suspension_force() -> float:
	var f := 0.0
	for w in wheels:
		f += w.suspension_force
	return f

## Среднее нормаль поверхности под машиной (для ориентации на уклоне и телеметрии).
func average_normal() -> Vector3:
	var n := Vector3.ZERO
	var count := 0
	for w in wheels:
		if w.grounded:
			n += w.normal_global
			count += 1
	if count == 0 or n.length_squared() < 0.0001:
		return Vector3.UP
	return n.normalized()

func max_saturation() -> float:
	var best := 0.0
	for w in wheels:
		best = maxf(best, w.saturation())
	return best

func total_slip_energy() -> float:
	var e := 0.0
	for w in wheels:
		e += absf(w.slip_ratio) * maxf(w.load, 0.0)
	return e

## Точки крепления — используются камерой (адаптивная высота) и отладкой.
func attach_positions_global(body_xform: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for w in wheels:
		out.append(body_xform * w.attach_local)
	return out

func wheel_index(is_front: bool, is_left: bool) -> int:
	if is_front:
		return WHEEL_FL if is_left else WHEEL_FR
	return WHEEL_RL if is_left else WHEEL_RR
