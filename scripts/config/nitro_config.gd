class_name NitroConfig
extends ConfigResource
## Нитро — не мгновенный перенос и не правка Transform напрямую, а временное изменение физической тяги
## и доступного предела скорости. Расход/заряд/перезарядка и ограничение по времени
## удержания описаны здесь; вся логика — в [NitroSystem].

@export_group("Budget")
@export var enabled: bool = true
## Полная шкала заряда (условные единицы).
@export_range(10.0, 1000.0, 1.0) var max_charge: float = 100.0
## Расход в секунду активного буста.
@export_range(0.5, 200.0, 0.5) var drain_per_s: float = 26.0
## Восполнение заряда в секунду.
@export_range(0.1, 100.0, 0.5) var regen_per_s: float = 11.5
## Пауза после отпускания кнопки, прежде чем начнётся перезарядка.
@export_range(0.0, 5.0, 0.05) var regen_delay_s: float = 0.85
## Сколько заряда нужно, чтобы вообще начать буст.
@export_range(0.0, 100.0, 0.5) var min_to_start: float = 12.0
## Ниже этого уровня буст прерывается (защита от «мигания» на границе).
@export_range(0.0, 100.0, 0.5) var min_sustained: float = 6.0
## Максимум непрерывного буста, сек (0 = без ограничения).
@export_range(0.0, 30.0, 0.1) var max_burst_s: float = 4.2
## Штраф-кулдаун после удержания дольше max_burst_s, сек.
@export_range(0.0, 10.0, 0.1) var overheat_cooldown_s: float = 1.6

@export_group("Physical effect")
## Во сколько раз поднимается доступный максимум скорости.
## Подобрано так: player 165 * 1.273 = 210 км/ч при police 166.65 * 1.25 = 208.3 (см. BalanceRules).
@export_range(1.0, 2.0, 0.001) var max_speed_multiplier: float = 1.273
## Во сколько раз растёт доступная тяга привода.
@export_range(1.0, 3.0, 0.001) var thrust_multiplier: float = 1.62
## Небольшая прибавка сцепления, чтобы буст на выходе из поворота не размазывал машину.
@export_range(0.8, 1.3, 0.001) var grip_multiplier: float = 1.04
## Множитель сопротивления — на пределе скорости буст «упирается» плавнее.
@export_range(0.3, 2.0, 0.01) var drag_multiplier: float = 1.18

@export_group("Presentation")
@export var exhaust_flames: bool = true
## Насколько шире становится FOV камеры при бусте (градусы, плавно).
@export_range(0.0, 25.0, 0.1) var boost_fov_add: float = 7.5
@export_range(0.0, 4.0, 0.05) var presentation_smoothing: float = 1.4

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if max_speed_multiplier <= 1.0 and thrust_multiplier <= 1.0:
		problems.append(_problem("буст ничего не меняет: multiplier'ы = 1"))
	if min_to_start < min_sustained:
		problems.append(_problem("min_to_start меньше min_sustained — буст будет запускаться повторно на границе"))
	if drain_per_s <= 0.0:
		problems.append(_problem("drain_per_s = 0: шкала заряда бессмысленна"))
	if max_charge > 0.0 and max_charge / drain_per_s < 1.2:
		problems.append(_problem("полного заряда хватает меньше чем на 1.2 с буста"))
	return problems
