class_name CameraConfig
extends ConfigResource
## Камера от третьего лица: дистанция, высота, свободное вращение, избегание стен.
## Значения разделены для портрета и ландшафта, потому что вертикальный экран
## «съедает» высоту и требует более близкой камеры.

@export_group("Framing — portrait")
@export_range(2.0, 24.0, 0.1) var portrait_distance_m: float = 7.6
@export_range(0.6, 12.0, 0.05) var portrait_height_m: float = 2.85
@export_range(20.0, 140.0, 0.5) var portrait_fov_deg: float = 68.0

@export_group("Framing — landscape")
@export_range(2.0, 24.0, 0.1) var landscape_distance_m: float = 8.4
@export_range(0.6, 12.0, 0.05) var landscape_height_m: float = 2.5
@export_range(20.0, 140.0, 0.5) var landscape_fov_deg: float = 72.0

@export_group("Limits and feel")
## Диапазон дистанции для слайдера настроек (м).
@export_range(1.0, 30.0, 0.1) var distance_min_m: float = 4.0
@export_range(1.0, 40.0, 0.1) var distance_max_m: float = 16.0
@export_range(-4.0, 12.0, 0.05) var height_min_m: float = 0.9
@export_range(-4.0, 16.0, 0.05) var height_max_m: float = 7.0
@export_range(-89.0, -5.0, 0.5) var pitch_min_deg: float = -26.0
@export_range(5.0, 89.0, 0.5) var pitch_max_deg: float = 46.0
## Чувствительность свайпа (градусов на пиксель при 720 px по ширине).
@export_range(0.01, 1.0, 0.001) var sensitivity_deg_per_px: float = 0.19
## Смещение точки съёмки относительно кузова (м): x вбок, y вверх, z назад.
@export var pivot_offset: Vector3 = Vector3(0.0, 1.35, 0.35)
## Пружина, с которой камера возвращается к желаемой позиции (Гц-подобный коэффициент).
@export_range(1.0, 40.0, 0.1) var follow_stiffness: float = 13.0
@export_range(0.0, 2.0, 0.01) var follow_damping: float = 0.85
## Автодоворот камеры вслед за движением машины (0 = полной свободный обзор).
@export_range(0.0, 1.0, 0.01) var yaw_follow: float = 0.22
## Скорость, с которой камера «выравнивается» (рад/сек).
@export_range(0.1, 12.0, 0.05) var yaw_align_speed: float = 1.9
## Выравнивание включается выше этой скорости (км/ч) и гаснет ниже `yaw_align_fade_kmh`.
@export_range(0.0, 120.0, 0.5) var yaw_align_speed_kmh: float = 14.0
@export_range(0.0, 120.0, 0.5) var yaw_align_fade_kmh: float = 6.0

@export_group("Collision avoidance")
## Радиус защитного сфер-теста вокруг камеры (м).
@export_range(0.1, 4.0, 0.05) var collision_radius_m: float = 0.42
## Минимальная дистанция, до которой камера может быть прижата к машине (м).
@export_range(0.4, 8.0, 0.1) var collision_min_distance_m: float = 1.7
## Скорость возврата потерянной дистанции (1/сек).
@export_range(0.2, 20.0, 0.1) var collision_recover_speed: float = 3.4
## Сколько лучей используется для поиска чистой позиции (веер вверх/вниз).
@export_range(0, 6, 1) var collision_probe_count: int = 2
## Смещение лучей вверх (м) — чтобы не прятаться за низкими бордюрами.
@export_range(0.0, 2.0, 0.05) var collision_probe_lift_m: float = 0.35

@export_group("Effects")
## Тряска от скорости/ударов (0 = выключено).
@export_range(0.0, 3.0, 0.01) var shake_gain: float = 0.5
@export_range(0.0, 2.0, 0.01) var shake_decay: float = 3.6
## Скорость, на которой появляется лёгкое «дыхание» камеры (км/ч).
@export_range(20.0, 400.0, 5.0) var shake_speed_kmh: float = 120.0


func desired_distance(for_landscape: bool) -> float:
	return landscape_distance_m if for_landscape else portrait_distance_m


func desired_height(for_landscape: bool) -> float:
	return landscape_height_m if for_landscape else portrait_height_m


func desired_fov(for_landscape: bool) -> float:
	return landscape_fov_deg if for_landscape else portrait_fov_deg


func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if distance_min_m >= distance_max_m:
		problems.append(_problem("distance_min_m >= distance_max_m"))
	if distance_min_m > portrait_distance_m or portrait_distance_m > distance_max_m:
		problems.append(_problem("portrait_distance_m (%.1f) вне диапазона настроек [%.1f..%.1f]" % [portrait_distance_m, distance_min_m, distance_max_m]))
	if landscape_distance_m < distance_min_m or landscape_distance_m > distance_max_m:
		problems.append(_problem("landscape_distance_m (%.1f) вне диапазона настроек" % landscape_distance_m))
	if pitch_min_deg >= pitch_max_deg:
		problems.append(_problem("pitch_min_deg должен быть меньше pitch_max_deg"))
	if collision_min_distance_m >= portrait_distance_m:
		problems.append(_problem("collision_min_distance_m не меньше рабочей дистанции — камера всегда упирается"))
	return problems
