class_name CameraController
extends Camera3D
## Камера от третьего лица: свободная орбита + автофрейминг + защита от стен.
##
## Поведение, которое требовалось и которое здесь реализовано явно:
##  1. Свободное вращение НЕ зависит от курса машины: yaw/pitch меняются только от пальца.
##     Работает и на парковке (автотест `camera_orbit_while_parked`).
##  2. Автодоворот к направлению движения — отдельная величина `yaw_follow`, и она
##     гаснет на малой скорости (иначе камера «уезжает» от машины на месте).
##  3. Стена/столб между машиной и камерой не должна прятать игрока: дистанция
##     укорачивается мгновенно (sweep сферой радиуса `collision_radius_m`) и
##     восстанавливается плавно со скоростью `collision_recover_speed`.
##  4. Высота и дистанция — настройки (Settings.*_offset), упираются в min/max из CameraConfig.
##  5. Тряска от ударов и от скорости: аддитивное смещение, НЕ влияющее на физику.
##
## Позиционирование — только `global_position`/`global_rotation`; камера никогда не
## «телепортируется» через трансформ цели и ничего не пишет в RigidBody3D.
##
## Вся математика вынесена в статические функции, чтобы автотесты проверяли её,
## а не «похоже ли на экране» (см. tests/run_tests.gd: `camera_*`).

signal framing_changed(distance: float, height: float, fov: float)

var config: CameraConfig = null
var target: Node3D = null
var physics: Node = null
## Углы орбиты. yaw — вокруг мировой вертикали (0 = смотрим вдоль -Z), pitch — наклон.
var yaw: float = 0.0
var pitch_deg: float = -6.0
var distance: float = 8.0
var desired_distance: float = 8.0
var blocked: bool = false
var blocked_distance: float = 0.0
var speed_kmh: float = 0.0
var shake_amount: float = 0.0
var shake_time: float = 0.0
var look_ahead: float = 0.0
var pivot: Vector3 = Vector3.ZERO
var pivot_velocity: Vector3 = Vector3.ZERO
var _pending_orbit_px: Vector2 = Vector2.ZERO
var _pending_zoom: float = 0.0
var _fov_now: float = 68.0
var _last_probe_hits: int = 0

func _ready() -> void:
	if config == null:
		config = GameSetup.get_config("camera") as CameraConfig
	if config != null:
		pitch_deg = 0.5 * (config.pitch_min_deg + config.pitch_max_deg)
		desired_distance = _base_distance()
		distance = desired_distance
		fov = _base_fov()
		_fov_now = fov
	make_current()

## Привязка к машине. `physics` нужен только для скорости/крена (опционально).
func set_target(node: Node3D, p_physics: Node = null) -> void:
	target = node
	physics = p_physics
	if target != null:
		var lift := config.pivot_offset.y if config != null else 1.3
		pivot = target.global_position + Vector3(0.0, lift, 0.0)
		global_position = pivot + orbit_direction(yaw, pitch_deg) * distance

func apply_config(cfg: CameraConfig) -> void:
	config = cfg
	if config != null:
		desired_distance = _base_distance()

# ------------------------------------------------------------------ ввод с UI

## Палец по свободной зоне экрана: смещение в пикселях.
func add_orbit_pixels(delta_px: Vector2) -> void:
	_pending_orbit_px += delta_px

## Щипок/колесо: + = отдалить.
func add_zoom(delta: float) -> void:
	_pending_zoom += delta

func add_shake(amount: float) -> void:
	shake_amount = minf(shake_amount + clampf(amount, 0.0, 1.5), 1.0)

## Камера «заглядывает» вперёд по курсу машины (кнопка в UI / автотест).
func snap_behind_target() -> void:
	if target == null:
		return
	yaw = wrapf(target.global_rotation.y + PI, -PI, PI)

# ------------------------------------------------------------------ кадр

func _process(delta: float) -> void:
	if config == null:
		return
	var step := maxf(delta, 0.0001)
	_apply_orbit_input(step)
	_update_speed()
	var pivot_target := _compute_pivot()
	_spring_pivot(pivot_target, step)
	desired_distance = clampf(
		_base_distance() + Settings.camera_distance_offset,
		config.distance_min_m, config.distance_max_m
	)
	var dir := orbit_direction(yaw, pitch_deg)
	var height := clampf(_base_height() + Settings.camera_height_offset, config.height_min_m, config.height_max_m)
	var allowed := probe_clear_distance(pivot, dir, height, step)
	blocked = allowed < desired_distance - 0.02
	blocked_distance = allowed
	# Укорочение мгновенное, возврат — с ограниченной скоростью (иначе камера «выпрыгивает»).
	if distance > allowed:
		distance = maxf(allowed, config.collision_min_distance_m)
	else:
		distance = minf(distance + config.collision_recover_speed * step, allowed)
	distance = clampf(distance, config.collision_min_distance_m, config.distance_max_m)
	# Высота — часть кадрирования: меняем pitch так, чтобы pivot + dir*distance дал нужную высоту,
	# если пользователь не тянет палец (иначе его угол важнее).
	if _pending_orbit_px == Vector2.ZERO:
		var wanted_pitch := rad_to_deg(asinf(clampf(height / maxf(distance, 0.5), -1.0, 1.0)))
		pitch_deg = clampf(lerpf(pitch_deg, wanted_pitch, minf(step * 2.2, 1.0)), config.pitch_min_deg, config.pitch_max_deg)
		dir = orbit_direction(yaw, pitch_deg)
	_align_yaw(step)
	var shake_offset := shake_offset_this_frame(step)
	global_position = pivot + dir * distance + shake_offset
	look_at_safe(pivot + Vector3(0.0, config.pivot_offset.y * 0.28, 0.0) + shake_offset * 0.35)
	var wanted_fov := clampf(_base_fov() + config.fov_speed_gain_deg * speed_fraction(), 20.0, 140.0)
	_fov_now = lerpf(_fov_now, wanted_fov, minf(step * 3.0, 1.0))
	fov = _fov_now
	framing_changed.emit(distance, height, fov)

func _apply_orbit_input(_step: float) -> void:
	if _pending_orbit_px != Vector2.ZERO:
		var sens := config.sensitivity_deg_per_px * Settings.camera_sensitivity
		yaw -= _pending_orbit_px.x * sens * PI / 180.0
		pitch_deg = clampf(pitch_deg + _pending_orbit_px.y * sens, config.pitch_min_deg, config.pitch_max_deg)
		yaw = wrapf(yaw, -PI, PI)
		_pending_orbit_px = Vector2.ZERO
	if not is_equal_approx(_pending_zoom, 0.0):
		distance = clampf(distance + _pending_zoom, config.distance_min_m, config.distance_max_m)
		_pending_zoom = 0.0

## Доля от максимальной скорости: используется для «растяжки» кадра и FOV.
func speed_fraction() -> float:
	var max_speed := 165.0
	if physics != null:
		var cfg = physics.config
		if cfg != null:
			max_speed = maxf(float(cfg.max_speed_kmh), 40.0)
	return clampf(speed_kmh / max_speed, 0.0, 1.0)

func _update_speed() -> void:
	if physics != null:
		speed_kmh = absf(physics.forward_speed_kms()) * 3.6
	elif target != null:
		speed_kmh = target.global_position.distance_to(_prev_pos) / 0.0166 * 3.6
	_prev_pos = target.global_position

var _prev_pos: Vector3 = Vector3.ZERO

func _compute_pivot() -> Vector3:
	if target == null:
		return pivot
	var base := target.global_position
	if config == null:
		return base
	var offset := config.pivot_offset
	# Смещение вперёд по направлению ВЗГЛЯДА (не курса машины): при свободной орбите
	# это единственный способ не «упирать» машину в край экрана.
	var dir := orbit_direction(yaw, pitch_deg)
	var fwd := Vector3(dir.x, 0.0, dir.z).normalized() if Vector2(dir.x, dir.z).length_squared() > 1e-6 else Vector3.FORWARD
	look_ahead = lerpf(look_ahead, offset.z * speed_fraction() * config.pivot_lead_gain, 0.12)
	var right := fwd.cross(Vector3.UP)
	return base + Vector3(0.0, offset.y, 0.0) - fwd * look_ahead + right * offset.x

## Пружина с критическим демпфированием: камера «догоняет» цель без дрожания.
func _spring_pivot(wanted: Vector3, delta: float) -> void:
	var stiffness := config.follow_stiffness
	var damping := 2.0 * sqrtf(stiffness) * clampf(config.follow_damping, 0.05, 2.0)
	var to_target := wanted - pivot
	pivot_velocity += (to_target * stiffness - pivot_velocity * damping) * delta
	pivot += pivot_velocity * delta
	if pivot_velocity.length_squared() < 1e-6:
		pivot_velocity = Vector3.ZERO

## Автодоворот за курсом машины. Полностью выключается на малой скорости (тест).
## Вес автодоворота по скорости: 0 = камера стоит там, где её оставил палец (парковка),
## 1 = полностью следует за курсом. Вынесено в static, потому что именно это поведение
## требовалось «свободная орбита работает и на месте» — и это можно проверить без рендера.
static func follow_gain(speed_kmh_value: float, cfg: CameraConfig) -> float:
	if cfg == null or cfg.yaw_follow <= 0.001:
		return 0.0
	var fade := clampf((speed_kmh_value - cfg.yaw_align_speed_kmh) / maxf(cfg.yaw_align_fade_kmh, 0.5), 0.0, 1.0)
	return fade * cfg.yaw_follow


func _align_yaw(delta: float) -> void:
	if target == null:
		return
	var fade := clampf((speed_kmh - config.yaw_align_speed_kmh) / maxf(config.yaw_align_fade_kmh, 0.5), 0.0, 1.0)
	if fade <= 0.001 or _pending_orbit_px != Vector2.ZERO:
		return
	var wanted := wrapf(target.global_rotation.y + PI, -PI, PI)
	var diff := wrapf(wanted - yaw, -PI, PI)
	yaw += diff * config.yaw_align_speed * fade * config.yaw_follow * delta
	yaw = wrapf(yaw, -PI, PI)

func shake_offset_this_frame(delta: float) -> Vector3:
	if shake_amount <= 0.0005:
		return Vector3.ZERO
	shake_time += delta
	shake_amount = maxf(shake_amount - config.shake_decay * delta, 0.0)
	var gain := shake_amount * config.shake_gain * (0.35 + speed_fraction())
	# Детерминированный «шум» из синусов несоизмеримых частот: дёшево и без аллокаций.
	var t := shake_time * 34.0
	return Vector3(sin(t * 1.13) + sin(t * 2.71) * 0.5, cos(t * 1.61) * 0.8, sin(t * 2.03) * 0.5) * gain * 0.09

# ------------------------------------------------------------------ математика (тестируется напрямую)

## Направление от цели к камере для заданных углов орбиты.
static func orbit_direction(yaw_rad: float, pitch_deg_value: float) -> Vector3:
	var pitch := deg_to_rad(clampf(pitch_deg_value, -89.0, 89.0))
	var horiz := cos(pitch)
	return Vector3(sin(yaw_rad) * horiz, sin(pitch), cos(yaw_rad) * horiz).normalized()

static func clamp_pitch_deg(pitch: float, cfg: CameraConfig) -> float:
	if cfg == null:
		return clampf(pitch, -89.0, 89.0)
	return clampf(pitch, cfg.pitch_min_deg, cfg.pitch_max_deg)

## Проверка «не в стену»: несколько протяжек сферой вдоль луча камеры.
## `space == null` (headless-тест, нет мира) -> возвращаем desired без изменений.
static func probe_clear_distance_static(
	space: PhysicsDirectSpaceState3D,
	from: Vector3,
	dir: Vector3,
	desired: float,
	radius: float,
	lift: float,
	probe_count: int,
	mask: int = 0xFFFFFFFF,
	exclude: Array[RID] = []
) -> float:
	if space == null:
		return desired
	var count := clampi(probe_count, 1, 6)
	var sphere := PhysicsSphereShape3D.new()
	sphere.radius = maxf(radius, 0.05)
	for i in range(count):
		var t := float(i + 1) / float(count)
		# Верхние пробы поднимаем (lift), нижний — ровно по лучу: иначе камера «влезает»
		# углом в карниз или в крышу соседнего дома.
		var origin := from + Vector3(0.0, lift * (1.0 - t), 0.0)
		var point := origin + dir * maxf(desired * t, 0.2)
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = sphere
		query.transform = Transform3D(Basis.IDENTITY, point)
		query.collision_mask = mask
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.exclude = exclude
		if not space.intersect_shape(query, 1).is_empty():
			# Безопасная дистанция — между предыдущей и текущей пробой.
			return maxf(desired * (t - 1.0 / float(count)), 0.0)
	return desired

func probe_clear_distance(from: Vector3, dir: Vector3, _height: float, _delta: float) -> float:
	var world := get_world_3d()
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	var result := probe_clear_distance_static(
		space, from, dir, desired_distance, config.collision_radius_m,
		config.collision_probe_lift_m, config.collision_probe_count,
		_collision_mask(), _exclude_rids()
	)
	_last_probe_hits = 0 if space == null else 1
	# Дополнительно: если камера ушла в землю, чуть поднимаем дистанцию (сплошная
	# «земля-полотно» в этом проекте — единственный частый случай).
	if result < config.collision_min_distance_m:
		result = config.collision_min_distance_m
	return result

func _collision_mask() -> int:
	return config.collision_mask if config != null and config.collision_mask > 0 else 5

## Свой корпус камеры не должны видеть: иначе на парковке дистанция схлопывается.
func _exclude_rids() -> Array[RID]:
	var out: Array[RID] = []
	if target is CollisionObject3D:
		out.append((target as CollisionObject3D).get_rid())
	if physics is CollisionObject3D:
		out.append((physics as CollisionObject3D).get_rid())
	return out

func desired_height() -> float:
	if config == null:
		return 2.6
	return clampf(_base_height() + Settings.camera_height_offset, config.height_min_m, config.height_max_m)

## Кадрирование под ориентацию экрана: portrait — ближе и выше (узкий экран), landscape — дальше.
func _base_distance() -> float:
	if config == null:
		return 8.0
	var value := config.landscape_distance_m if Settings.is_landscape() else config.portrait_distance_m
	var stretch := config.distance_speed_gain_m * speed_fraction()
	# Растяжка включается только в движении (см. `speed_fraction`): на парковке кадр статичен.
	return value + stretch

func _base_height() -> float:
	if config == null:
		return 2.6
	return config.landscape_height_m if Settings.is_landscape() else config.portrait_height_m

func _base_fov() -> float:
	if config == null:
		return 68.0
	return config.landscape_fov_deg if Settings.is_landscape() else config.portrait_fov_deg

## look_at с защитой от вырожденного направления (камера точно над целью).
func look_at_safe(point: Vector3) -> void:
	var diff := point - global_position
	if diff.length_squared() < 1e-6:
		return
	# Почти вертикальный луч ломает look_at (up параллельн направлению) — чуть разводим.
	if Vector2(diff.x, diff.z).length_squared() < 1e-5:
		point += Vector3(0.002, 0.0, 0.002)
		look_at(point, Vector3.UP if pitch_deg >= 0.0 else Vector3.DOWN)
		return
	look_at(point, Vector3.UP)

func debug_state() -> Dictionary:
	return {
		"yaw_deg": rad_to_deg(yaw),
		"pitch_deg": pitch_deg,
		"distance": distance,
		"desired_distance": desired_distance,
		"height": desired_height(),
		"blocked": blocked,
		"pivot": pivot,
		"shake": shake_amount,
		"fov": fov,
	}
