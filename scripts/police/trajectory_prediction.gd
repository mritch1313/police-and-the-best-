class_name TrajectoryPrediction
extends RefCounted
## Предсказание траектории убегающей машины (упреждение для перехвата и «прогноз поворота»).
##
## МОДЕЛЬ: велосипедная, шаг `dt`, без колёсной физики — нам не нужен точный дрифт, нужен
## «куда он приедет через секунду». Интегрируем курс от скорости поворота:
##   curvature = tan(steer * max_steer) / wheelbase
##   yaw_rate  = speed * curvature
## Это та же формула, что даёт VehicleMath.steer_limit_rad + радиус поворота, поэтому
## предсказание и реальная траектория не «разъезжаются» на гладу.
##
## ПРЕДЕЛ ЧЕСТНОСТИ: дольше `max_horizon_s` не предсказываем — игрок за 3 секунды делает
## что хочет, и «уверенный» прогноз на 5 секунд был бы враньём (патруль уезжал бы в точку,
## где игрока никогда не будет).

const MAX_HORIZON_S := 2.6
const DEFAULT_SAMPLES := 8

static func yaw_rate_rad_s(speed_kms: float, steer: float, cfg: VehicleConfig) -> float:
	if cfg == null:
		return 0.0
	var max_steer := deg_to_rad(clampf(cfg.max_steer_deg, 1.0, 60.0))
	var curvature := tan(clampf(steer, -1.0, 1.0) * max_steer) / maxf(cfg.wheelbase_m, 1.0)
	## Знак: steer > 0 = право = отрицательный yaw вокруг +Y в Godot.
	return -speed_kms * curvature

static func predict(position: Vector3, heading: float, speed_kms: float, steer: float,
		cfg: VehicleConfig, horizon_s: float = 1.6, dt: float = 0.1) -> PackedVector3Array:
	var out := PackedVector3Array()
	var limit := clampf(horizon_s, 0.1, MAX_HORIZON_S)
	var step := clampf(dt, 0.02, 0.5)
	var pos := position
	var yaw := heading
	var speed := absf(speed_kms) / 3.6
	var t := 0.0
	while t < limit - 0.0001:
		var omega := yaw_rate_rad_s(speed, steer, cfg)
		yaw += omega * step
		var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
		pos += forward * speed * step
		out.append(pos)
		t += step
	return out

## Упрощённый прогноз по текущей скорости (без знания угла руля): прямолинейно-криволинейный
## «конверт» — используется, когда у патруля нет данных об управлении игрока (normal case).
static func coast(position: Vector3, velocity: Vector3, horizon_s: float, samples: int = DEFAULT_SAMPLES) -> PackedVector3Array:
	var out := PackedVector3Array()
	var count := clampi(samples, 2, 24)
	var limit := clampf(horizon_s, 0.1, MAX_HORIZON_S)
	for i in range(1, count + 1):
		var t := limit * float(i) / float(count)
		out.append(position + velocity * t)
	return out

## Точка предсказания, ближе всего к охотнику (и когда в неё лучше вклиниться).
static func closest_approach(hunter_position: Vector3, prediction: PackedVector3Array,
		hunter_speed_kms: float, dt: float = 0.1) -> Dictionary:
	if prediction.is_empty():
		return {"ok": false}
	var best_index := 0
	var best_score := INF
	var speed := maxf(hunter_speed_kms / 3.6, 1.0)
	for i in range(prediction.size()):
		var distance := hunter_position.distance_to(prediction[i])
		var eta := float(i + 1) * dt
		## Считаем не «минимум расстояния», а минимум |расстояние - путь за eta|: иначе
		## патруль всегда выбирает точку, в которую физически не успеет.
		var reachable := speed * eta
		var score := absf(distance - reachable)
		if score < best_score:
			best_score = score
			best_index = i
	var point: Vector3 = prediction[best_index]
	return {
		"ok": true,
		"point": point,
		"index": best_index,
		"time_s": float(best_index + 1) * dt,
		"distance_m": hunter_position.distance_to(point),
		"lead_distance_m": hunter_position.distance_to(prediction[prediction.size() - 1]),
	}

## Скорость, с которой стоит входить в ближайший поворот предсказанной траектории
## (используется, чтобы патруль не «улетал» в дома на скользком асфальте).
static func corner_speed(points: PackedVector3Array, cfg: VehicleConfig, look_ahead: int = 2) -> float:
	if cfg == null or points.size() < 3:
		return INF
	var a := points[0]
	var b := points[min(look_ahead, points.size() - 1)]
	var c := points[min(look_ahead + 1, points.size() - 1)]
	var ab := b - a
	var bc := c - b
	if ab.length_squared() < 0.01 or bc.length_squared() < 0.01:
		return INF
	ab.y = 0.0
	bc.y = 0.0
	var turn := absf(ab.normalized().signed_angle_to(bc.normalized(), Vector3.UP))
	var chord := a.distance_to(c)
	if turn < 0.02:
		return cfg.max_speed_kmh
	var radius := maxf(chord / (2.0 * sin(turn * 0.5)), 4.0)
	return VehicleMath.speed_for_distance(cfg, radius * 0.9)

## Ошибка модели (для автотеста): предсказание по постоянной скорости не должно «уезжать»
## от прямой больше, чем на 1e-6, и должно расти монотонно по времени.
static func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	var cfg := VehicleConfig.new()
	var straight := predict(Vector3.ZERO, 0.0, 60.0, 0.0, cfg, 1.0, 0.1)
	if straight.size() < 8:
		problems.append("предсказание: мало точек (%d)" % straight.size())
		return problems
	var expected_per_step := 60.0 / 3.6 * 0.1
	for i in range(1, straight.size()):
		var step_length := straight[i].distance_to(straight[i - 1])
		if absf(step_length - expected_per_step) > 0.001:
			problems.append("предсказание: шаг %d = %.4f м, ожидалось %.4f м" % [i, step_length, expected_per_step])
			break
		if absf(straight[i].x) > 0.0001 or absf(straight[i].y) > 0.0001:
			problems.append("предсказание: прямая поехала вбок (x=%.4f y=%.4f)" % [straight[i].x, straight[i].y])
			break
	var turning := predict(Vector3.ZERO, 0.0, 60.0, 1.0, cfg, 1.0, 0.1)
	# Руль вправо при движении в -Z = смещение в +X (правая сторона экрана в портрете).
	if turning.size() < 2 or turning[turning.size() - 1].x < 0.05:
		problems.append("предсказание: руль вправо не увёл траекторию в +X")
	var horizon := predict(Vector3.ZERO, 0.0, 60.0, 0.0, cfg, 30.0, 0.1)
	if float(horizon.size()) * 0.1 > MAX_HORIZON_S + 0.21:
		problems.append("предсказание: горизонт не ограничен MAX_HORIZON_S (%d точек)" % horizon.size())
	return problems
