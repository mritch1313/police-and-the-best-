class_name ChaseConfig
extends ConfigResource
## Правила погони в целом: розыск, задержание, спавн/деспавн, побеги.

@export_group("Wanted level")
## Начальный уровень розыска (1..5). 0 = свободная езда без полиции.
@export_range(0.0, 5.0, 1.0) var initial_wanted_level: float = 1.0
## Как быстро растёт розыск, когда патрули висят на хвосте (единиц/сек).
@export_range(0.0, 5.0, 0.01) var wanted_gain_per_s: float = 0.055
## Как быстро розыск остывает без контакта (единиц/сек).
@export_range(0.0, 5.0, 0.01) var wanted_cool_per_s: float = 0.028
## Скорость игрока (км/ч), выше которой розыск начинает расти.
@export_range(0.0, 300.0, 1.0) var wanted_speed_threshold_kmh: float = 78.0
## Ближайший патруль дальше этого — розыск остывает (м).
@export_range(30.0, 1500.0, 10.0) var wanted_cool_distance_m: float = 260.0

@export_group("Arrest")
## Радиус задержания от кузова игрока до патруля (м).
@export_range(1.0, 20.0, 0.1) var arrest_distance_m: float = 3.6
## Нужно держать скорость ниже этого (км/ч), чтобы сдаваться.
@export_range(0.0, 80.0, 0.5) var arrest_max_speed_kmh: float = 13.0
## Сколько секунд подряд нужно простоять рядом (сек).
@export_range(0.2, 30.0, 0.1) var arrest_hold_s: float = 2.4
## Столкновения ускоряют задержание: вклад одного сильного удара (м/с по нормали).
@export_range(0.0, 20.0, 0.1) var arrest_impulse_speed_ms: float = 6.5
## После задержания: сколько секунд идёт «арест» до возврата в меню/свободную езду.
@export_range(0.5, 30.0, 0.5) var arrest_lock_time_s: float = 3.0

@export_group("Spawning")
## Кольцо спавна патрулей вокруг игрока (м).
@export_range(40.0, 900.0, 5.0) var spawn_radius_m: float = 165.0
## Дальше этого патруль десpawnится (м).
@export_range(120.0, 2000.0, 10.0) var despawn_radius_m: float = 470.0
## Пауза между попытками доспавна до нужного количества (сек).
@export_range(0.1, 30.0, 0.1) var spawn_interval_s: float = 1.6
## Игнорировать спавн, если нет свободной точки (м) — иначе патруль появится в здании.
@export_range(0.0, 40.0, 0.5) var spawn_clearance_m: float = 7.0

@export_group("Session")
## Раз в столько секунд обновлять статистику заезда в сейве.
@export_range(1.0, 300.0, 1.0) var session_flush_interval_s: float = 12.0
## Включать ли вообще полицию (для «просто покататься» из меню настроек).
@export var police_enabled: bool = true


func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if despawn_radius_m <= spawn_radius_m * 1.4:
		problems.append(_problem("despawn_radius_m (%.0f) должен заметно превышать spawn_radius_m (%.0f), иначе патрули будут мигать" % [despawn_radius_m, spawn_radius_m]))
	if arrest_distance_m < 1.0:
		problems.append(_problem("arrest_distance_m слишком мал — задержание невозможно поймать"))
	if arrest_max_speed_kmh <= 0.0 and arrest_hold_s > 0.5:
		problems.append(_problem("arrest_max_speed_kmh=0: задержание потребует полной остановки"))
	if arrest_lock_time_s <= 0.0:
		problems.append(_problem("arrest_lock_time_s = 0: арест не успеет отыграть"))
	return problems
