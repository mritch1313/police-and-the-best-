class_name VehicleMath
extends RefCounted
## Общая математика автомобиля — единственное место, где живут формулы.
##
## Физика ([VehiclePhysics]), ИИ полиции и автотесты вызывают ОДНИ И ТЕ ЖЕ функции,
## поэтому «что показал тест» и «что делает машина в игре» не может разойтись:
## тест, посчитавший разгон или предельную скорость, проверяет ровно тот код,
## который крутится в [method VehiclePhysics._integrate_forces].
##
## Никаких NodeTree, никаких трансформов — только чистые функции и числа.

const EPS: float = 0.0001
## Ниже какой скорости (км/ч) сопротивление качению плавно гасится в 0 (защита от «сползания»).
const ROLL_FADE_KMS: float = 1.0

## Кривая тяги привода: полка момента до `ref_ratio` доли лимита, затем спад в ноль.
## x = скорость / доступный предел скорости, ответ 0..1.
static func torque_shape(x: float, ref_ratio: float = 0.58) -> float:
	var t := clampf(x, 0.0, 1.0)
	if t <= ref_ratio:
		return 1.0
	var k := (t - ref_ratio) / maxf(1.0 - ref_ratio, EPS)
	return clampf(1.0 - k * k, 0.0, 1.0)

## Доступный предел скорости (км/ч) с учётом нитро-множителя.
static func speed_limit_kms(cfg: VehicleConfig, nitro_multiplier: float = 1.0) -> float:
	return cfg.max_speed_kms() * clampf(nitro_multiplier, 1.0, 4.0)

## Полная продольная сила привода (Н) по машине.
## throttle < 0 — передача «назад»: своя полка момента и свой предел.
static func drive_force(
	cfg: VehicleConfig,
	speed_kms: float,
	throttle: float,
	nitro_multiplier: float = 1.0,
	nitro_thrust: float = 1.0,
)-> float:
	var limit := speed_limit_kms(cfg, nitro_multiplier)
	var x := absf(speed_kms) / maxf(limit, EPS)
	var ref := clampf(cfg.throttle_ref_speed_kmh / maxf(cfg.max_speed_kmh, 1.0), 0.05, 0.95)
	var shape := torque_shape(x, ref)
	var base := cfg.engine_force_n * clampf(throttle, -1.0, 1.0) * shape
	if base < 0.0:
		base *= cfg.reverse_ratio
	elif nitro_multiplier > 1.0:
		base *= nitro_thrust
	return base

## То же, что [method drive_force], но с явным пределами скорости (км/ч):
## нужно [VehiclePhysics], когда потолок задан извне (нитро или «придержать патруль»).
static func drive_force_limited(
	cfg: VehicleConfig,
	speed_kms: float,
	throttle: float,
	limit_kms: float,
	nitro_thrust: float = 1.0,
)-> float:
	var ref := clampf(cfg.throttle_ref_speed_kmh / maxf(limit_kms * 3.6, 1.0), 0.05, 0.95)
	var shape := torque_shape(absf(speed_kms) / maxf(limit_kms, EPS), ref)
	var base := cfg.engine_force_n * clampf(throttle, -1.0, 1.0) * shape
	if base < 0.0:
		return base * cfg.reverse_ratio
	if limit_kms > cfg.max_speed_kms() + EPS:
		return base * nitro_thrust
	return base

## Сопротивление воздуха + качение (Н), всегда против движения.
static func resistance_force(cfg: VehicleConfig, speed_kms: float, drag_multiplier: float = 1.0) -> float:
	var v := absf(speed_kms)
	var aero := cfg.drag_coefficient * drag_multiplier * v * v
	var roll := cfg.rolling_resistance_n * clampf(v / ROLL_FADE_KMS, 0.0, 1.0)
	return aero + roll

## Прижимная сила (Н).
static func downforce(cfg: VehicleConfig, speed_kms: float) -> float:
	var v := absf(speed_kms)
	return cfg.downforce_k * v * v

## Нагрузка на одно колесо в покое (Н).
static func static_wheel_load(cfg: VehicleConfig, gravity: float = 9.8) -> float:
	return cfg.mass_kg * gravity / 4.0

## Вертикальные нагрузки четырёх колёс с переносом массы.
## `accel_long` > 0 — разгон вперёд, `accel_lat` > 0 — ускорение вправо (+X кузова).
## Порядок результата: [FL, FR, RL, RR]. При разгоне разгружается перед, при
## ускорении вправо — левый борт (правый «вжимается»).
static func weight_transfer(
	cfg: VehicleConfig,
	accel_long: float,
	accel_lat: float,
	extra_downforce: float = 0.0,
	gravity: float = 9.8,
)-> PackedFloat32Array:
	var total := cfg.mass_kg * gravity + maxf(extra_downforce, 0.0)
	var base := total / 4.0
	var h := maxf(cfg.center_of_mass_drop_m + cfg.ride_height_m, 0.15)
	var long_per_wheel := cfg.mass_kg * accel_long * h / (2.0 * maxf(cfg.wheelbase_m, 0.5))
	var lat_per_wheel := cfg.mass_kg * accel_lat * h / (2.0 * maxf(cfg.track_width_m, 0.5))
	var max_shift := base * 0.8
	long_per_wheel = clampf(long_per_wheel, -max_shift, max_shift)
	lat_per_wheel = clampf(lat_per_wheel, -max_shift, max_shift)
	var out := PackedFloat32Array()
	out.resize(4)
	out[0] = maxf(base - long_per_wheel - lat_per_wheel, 30.0)
	out[1] = maxf(base - long_per_wheel + lat_per_wheel, 30.0)
	out[2] = maxf(base + long_per_wheel - lat_per_wheel, 30.0)
	out[3] = maxf(base + long_per_wheel + lat_per_wheel, 30.0)
	return out

## Предельный угол руля (рад) по скорости.
static func steer_limit_rad(cfg: VehicleConfig, speed_kms: float) -> float:
	var max_a := deg_to_rad(cfg.max_steer_deg)
	var min_a := deg_to_rad(cfg.min_steer_deg)
	if cfg.steer_at_full_speed_kmh <= EPS:
		return max_a
	var t := clampf(absf(speed_kms) / cfg.steer_at_full_speed_kmh, 0.0, 1.0)
	return lerpf(max_a, min_a, t * (2.0 - t) * 0.5)

## Сила шины: линейная модель с мягким насыщением и кругом трения.
## Возвращает Vector2(F_продольная, F_боковая) в осях колеса (X — вперёд по покрышке, Y — влево).
static func tyre_force(load_n: float, mu: float, slip_ratio_value: float, slip_angle: float, cfg: VehicleConfig) -> Vector2:
	var cap := maxf(mu * load_n, 1.0)
	var fx_raw := -cfg.longitudinal_stiffness_n * slip_ratio_value
	var fy_raw := -cfg.corner_stiffness_n_per_rad * slip_angle
	# Мягкое насыщение по осям (tanh) — занос наступает прогрессивно, а не «стеной».
	var fx := cap * tanh(fx_raw / cap)
	var fy := cap * tanh(fy_raw / cap)
	var combined := Vector2(fx, fy)
	var mag := combined.length()
	if mag > cap:
		combined *= cap / mag
	return combined

## Продольная пробуксовка: (v - omega*r) / max(abs(v), abs(omega*r), floor).
## Отрицательная — колесо крутится быстрее машины (тяга), положительная — колесо тормозится шиной.
static func slip_ratio(omega_wheel: float, wheel_radius: float, long_velocity: float, floor_kms: float = 1.6) -> float:
	var surface := omega_wheel * wheel_radius
	var denom := maxf(maxf(absf(long_velocity), absf(surface)), floor_kms)
	return (long_velocity - surface) / denom

## Угол увода (рад). На месте (mgs малая продольная скорость) искусственно не растёт,
## иначе шину «размазывает» от любого бокового усилия.
static func slip_angle(lat_velocity: float, long_velocity: float, dead_kms: float = 1.0, max_rad: float = 1.15) -> float:
	var denom := maxf(absf(long_velocity), dead_kms)
	return clampf(atan2(lat_velocity, denom), -max_rad, max_rad)

## Тормозной момент (Н·м) колеса. Ограничен тем, что шина ещё может передать, —
## иначе любое «крепкое» нажатие мгновенно блокирует колесо.
static func brake_torque(cfg: VehicleConfig, load_n: float, mu: float, brake_strength: float, handbrake: bool = false) -> float:
	var requested := cfg.brake_torque_nm(handbrake) * clampf(brake_strength, 0.0, 1.0)
	var grip_limit := mu * load_n * cfg.wheel_radius_m
	return minf(requested, grip_limit)

## Торможение двигателем (Н·м на колесо), растёт с оборотами.
static func engine_brake_torque(cfg: VehicleConfig, rpm: float) -> float:
	var revs := clampf((rpm - cfg.idle_rpm) / maxf(cfg.redline_rpm - cfg.idle_rpm, 1.0), 0.0, 1.0)
	return cfg.engine_brake_torque_nm * (0.65 + 0.8 * revs)

## Обороты двигателя для текущей передачи.
static func engine_rpm(cfg: VehicleConfig, speed_kms: float, gear_index: int) -> float:
	var omega_wheel := absf(speed_kms) / maxf(cfg.wheel_radius_m, EPS)
	var gear: float = 1.0
	if gear_index >= 0 and gear_index < cfg.gear_ratios.size():
		gear = cfg.gear_ratios[gear_index]
	var rpm := omega_wheel * gear * cfg.final_drive * 60.0 / TAU
	return clampf(rpm, cfg.idle_rpm, cfg.redline_rpm)

## Передача для скорости: первая, на которой обороты ещё не упёрлись в отсечку.
static func gear_for_speed(cfg: VehicleConfig, speed_kms: float) -> int:
	if cfg.gear_ratios.is_empty():
		return 0
	var omega_wheel := absf(speed_kms) / maxf(cfg.wheel_radius_m, EPS)
	for i in range(cfg.gear_ratios.size()):
		var gear: float = cfg.gear_ratios[i]
		var rpm := omega_wheel * gear * cfg.final_drive * 60.0 / TAU
		if rpm < cfg.redline_rpm * 0.985:
			return i
	return cfg.gear_ratios.size() - 1

## Предельная скорость (км/ч): числовое равновесие тяги и сопротивления.
## Именно это значение покажет HUD, а не «красивое» число из конфига.
static func terminal_speed_kms(
	cfg: VehicleConfig,
	nitro_multiplier: float = 1.0,
	nitro_thrust: float = 1.0,
	step: float = 0.05,
)-> float:
	var limit := speed_limit_kms(cfg, nitro_multiplier)
	var v := limit
	while v > 0.5:
		var f := drive_force(cfg, v, 1.0, nitro_multiplier, nitro_thrust) - resistance_force(cfg, v, nitro_multiplier)
		if f > 0.0:
			return minf(v + step, limit)
		v -= step
	return v

## Время разгона 0 -> target_kms с учётом лимита по сцеплению (RWD: задняя ось тянет полмассы).
static func estimate_accel_time(
	cfg: VehicleConfig,
	target_kms: float = 100.0 / 3.6,
	nitro_multiplier: float = 1.0,
	nitro_thrust: float = 1.0,
	dt: float = 0.02,
)-> float:
	var mass := maxf(cfg.mass_kg, 1.0)
	var v := 0.0
	var t := 0.0
	var grip_accel_cap := cfg.grip_rear_mu * 9.8 * (0.5 + 0.5 * clampf(cfg.drive_bias_front, 0.0, 1.0))
	while v < target_kms and t < 60.0:
		var f := drive_force(cfg, v, 1.0, nitro_multiplier, nitro_thrust) - resistance_force(cfg, v)
		var a := clampf(f / mass, -grip_accel_cap, grip_accel_cap)
		v = maxf(v + a * dt, 0.0)
		t += dt
	return t

## Тормозной путь (м) с from_kms до остановки.
static func estimate_braking_distance(cfg: VehicleConfig, from_kms: float = 100.0 / 3.6, dt: float = 0.02) -> float:
	var mass := maxf(cfg.mass_kg, 1.0)
	var grip := (cfg.grip_front_mu + cfg.grip_rear_mu) * 0.5
	var decel_cap := grip * 9.8
	var v := absf(from_kms)
	var dist := 0.0
	while v > 0.4 and dist < 4000.0:
		var a := minf(cfg.brake_force_n * 4.0 / mass, decel_cap)
		dist += v * dt
		v = maxf(v - a * dt, 0.0)
	return dist

## Насколько машина боком (0 = едет прямо, 0.6 = глубокий занос).
static func drift_magnitude(lat_kms: float, long_kms: float) -> float:
	return absf(lat_kms) / maxf(absf(long_kms), 3.0)

## Срыв колеса в пробуксовку/блокировку (0..1).
static func wheelspin_magnitude(slip_ratio_value: float) -> float:
	return clampf(absf(slip_ratio_value), 0.0, 1.0)

## Момент, гасящий паразитное вращение рыскания (Н·м).
## `ratio` — доля инерции кузова, «схлопывающаяся» в секунду.
static func yaw_damping_torque(cfg: VehicleConfig, yaw_rate: float, ratio: float = 0.85) -> float:
	var inertia := cfg.mass_kg * (cfg.wheelbase_m * cfg.wheelbase_m + cfg.track_width_m * cfg.track_width_m) / 12.0
	return -yaw_rate * maxf(inertia, 100.0) * ratio

## Желаемое направление движения (для ИИ): нормаль к точке, куда целимся, с учётом тормозного пути.
static func lookahead_point(from: Vector3, direction: Vector3, speed_kms: float, base_m: float = 9.0) -> Vector3:
	var dist := base_m + speed_kms * 0.34
	return from + direction.normalized() * dist if direction.length_squared() > EPS else from

## Максимальная скорость ВХОДА в поворот/торможение длиной `distance_m` — ответ в КМ/Ч
## (такая же единица, как во всех конфигах; внутри формула в м/с, поэтому *3.6).
static func speed_for_distance(cfg: VehicleConfig, distance_m: float) -> float:
	var d := maxf(distance_m, 0.5)
	var grip := (cfg.grip_front_mu + cfg.grip_rear_mu) * 0.5 * 9.8
	return minf(sqrtf(2.0 * grip * d) * 3.6, cfg.max_speed_kmh)
