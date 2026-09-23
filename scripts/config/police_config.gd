class_name PoliceConfig
extends ConfigResource
## Параметры ИИ полиции: сколько машин, как далеко, какую стратегию выбирать.
## Физика патруля описана в [VehicleConfig] (секция `vehicle.police`) — ИИ использует те же силы.

@export_group("Pursuit rules")
## Абсолютный максимум активных патрулей (ещё ограничен бюджетом производительности).
@export_range(0, 24, 1) var max_units: int = 6
## Сколько машин соответствует уровням розыска 1..5.
@export var units_per_wanted_level: Array[int] = [1, 2, 3, 4, 6]
## Дальность, с которой патруль замечает игрока и входит в погоню.
@export_range(30.0, 900.0, 5.0) var engage_distance_m: float = 210.0
## Дистанция «слишком далеко» — патруль прекращает преследование.
@export_range(120.0, 2000.0, 10.0) var lose_distance_m: float = 430.0
## Сколько секунд без видимости/близости нужно, чтобы цель считалась потерянной.
@export_range(1.0, 60.0, 0.5) var lose_time_s: float = 9.0
## Период перестроения маршрута (сек). Реже = дешевле, чаще = умнее.
@export_range(0.05, 3.0, 0.05) var repath_interval_s: float = 0.45
## Реакция на манёвры игрока (сек) — добавляется в желаемое направление.
@export_range(0.0, 2.0, 0.01) var reaction_time_s: float = 0.22

@export_group("Driving")
## Скорость патрулирования в отсутствие погони (км/ч).
@export_range(10.0, 200.0, 1.0) var patrol_speed_kmh: float = 58.0
## Запас к целевой скорости при таране/блокировке (доля от максимальной).
@export_range(0.0, 1.0, 0.01) var aggression: float = 0.42
## Разрешить таран (боковое смещение маршрута к игроку).
@export var allow_ramming: bool = true
## Боковое смещение при подрезании (м).
@export_range(0.0, 12.0, 0.1) var ram_offset_m: float = 2.2
## Точность следования по маршруту: меньше = резче руль.
@export_range(0.2, 4.0, 0.05) var steering_sharpness: float = 1.55
## Скорость, ниже которой патруль считает себя застрявшим.
@export_range(0.2, 20.0, 0.1) var stuck_speed_kms: float = 2.4
## Сколько секунд без движения = застревание (тогда разворот и новый маршрут).
@export_range(0.5, 20.0, 0.1) var stuck_time_s: float = 2.6

@export_group("Strategies")
## Дистанции переключения стратегий (м): перехват впереди, блокировка с фланга, таран.
@export_range(20.0, 400.0, 1.0) var intercept_distance_m: float = 120.0
@export_range(10.0, 400.0, 1.0) var pincer_distance_m: float = 74.0
@export_range(6.0, 200.0, 1.0) var ram_distance_m: float = 34.0
## Вероятность выставить блок-пост на пути побега (0..1) при уровне розыска >= 3.
@export_range(0.0, 1.0, 0.01) var roadblock_chance: float = 0.45
## Минимальная дистанция до игрока, на которой блок-пост имеет смысл.
@export_range(40.0, 800.0, 5.0) var roadblock_min_distance_m: float = 110.0
## Сколько секунд блок-пост живёт, если игрок рядом так и не оказался.
@export_range(2.0, 120.0, 1.0) var roadblock_lifetime_s: float = 26.0

func units_for_wanted(level: int) -> int:
	if level < 1:
		return 0
	if level - 1 < units_per_wanted_level.size():
		return int(units_per_wanted_level[level - 1])
	return int(units_per_wanted_level[units_per_wanted_level.size() - 1])

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if lose_distance_m <= engage_distance_m:
		problems.append(_problem("lose_distance_m должна быть больше engage_distance_m, иначе патрули не отцепляются"))
	if ram_distance_m > pincer_distance_m or pincer_distance_m > intercept_distance_m:
		problems.append(_problem("дистанции стратегий должны быть упорядочены: ram < pincer < intercept"))
	if units_per_wanted_level.is_empty():
		problems.append(_problem("units_per_wanted_level пуст"))
	if units_for_wanted(units_per_wanted_level.size()) > max_units:
		problems.append(_problem("уровень розыска требует %d машин, а max_units=%d" % [units_for_wanted(units_per_wanted_level.size()),
			max_units]))
	if repath_interval_s <= 0.0:
		problems.append(_problem("repath_interval_s = 0: ИИ будет перестраивать маршрут каждый кадр"))
	return problems
