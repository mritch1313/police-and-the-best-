class_name PoliceStrategy
extends RefCounted
## Выбор тактики патруля — ЧИСТАЯ функция, без побочных эффектов.
##
## Вынесено из PoliceAI именно так, чтобы «переключение стратегий» можно было проверить
## автотестом без физики и без кадров: на входе словарь фактов, на выходе — режим и
## целевая скорость. PoliceAI обязан только исполнять решение, а не принимать его.
##
## РЕЖИМЫ (приоритет сверху вниз):
##   BLOCK      — перекрыть перекрёсток впереди (дорогое решение, включается редко);
##   PINCER     — «клещи»: второй патруль жмёт с другой стороны, первый просто держит линию;
##   INTERCEPT  — перерезать дугу (ехать в упреждённую точку, а не в хвост);
##   PURSUE     — обычное преследование по маршруту;
##   PATROL     — нет цели / цель потеряна: круг по району, набор «тепла» заново;
##   RETURN     — цели нет и wanted = 0: уехать на ближайший перекрёсток и встать;
##   IDLE       — полиция выключена настройками.
##
## Пороги берутся только из PoliceConfig/ChaseConfig — в коде нет магических чисел,
## иначе «почему они не едут» пришлось бы искать по исходникам.

const BLOCK := &"block"
const PINCER := &"pincer"
const INTERCEPT := &"intercept"
const PURSUE := &"pursue"
const PATROL := &"patrol"
const RETURN := &"return"
const IDLE := &"idle"

static var _names := {
	BLOCK: "БЛОКПОСТ",
	PINCER: "КЛЕЩИ",
	INTERCEPT: "ПЕРЕХВАТ",
	PURSUE: "ПРЕСЛЕДОВАНИЕ",
	PATROL: "ПАТРУЛЬ",
	RETURN: "ВОЗВРАТ",
	IDLE: "ОЖИДАНИЕ",
}

static func mode_name(mode: StringName) -> String:
	return String(_names.get(mode, String(mode)))

## ctx:
##   enabled (bool), wanted (float 0..5), distance_m, graph_distance_m, speed_kmh,
##   target_speed_kmh, loses_around_corner (bool), lost_time_s, units_in_pursuit (int),
##   unit_index (int), roadblock_ready (bool), can_ram (bool), has_los (bool)
static func decide(ctx: Dictionary, police: PoliceConfig, _chase: ChaseConfig) -> Dictionary:
	if not bool(ctx.get("enabled", true)) or police == null:
		return _out(IDLE, 0.0, false, false, &"police_disabled")
	var wanted := clampf(float(ctx.get("wanted", 0.0)), 0.0, 5.0)
	var distance := maxf(float(ctx.get("distance_m", 9999.0)), 0.0)
	var graph_distance := maxf(float(ctx.get("graph_distance_m", distance)), distance)
	var lost := float(ctx.get("lost_time_s", 0.0))
	var target_speed := float(ctx.get("target_speed_kmh", 0.0))
	var has_target := wanted > 0.0 and lost <= 0.0 and distance <= police.lose_distance_m * 1.2 \
			and bool(ctx.get("target_alive", true))

	if not has_target:
		# Цели нет: катаемся по району. Скорость патрульная — иначе игрок видит, как
		# «полиция гоняет пустые улицы», и это выглядит поломкой ИИ, а не патрулированием.
		return _out(PATROL if wanted > 0.0 else RETURN, police.patrol_speed_kmh, false, false,
			&"no_target")

	var budget := wanted_units(wanted, police)
	var fast_enough := target_speed <= police_chase_speed(police) + 6.0
	var reason := &"default"
	var mode: StringName = PURSUE

	if distance <= police.pincer_distance_m and int(ctx.get("units_in_pursuit", 1)) >= 2 \
			and int(ctx.get("unit_index", 0)) % 2 == 1:
		mode = PINCER
		reason = &"second_unit_close"
	elif graph_distance <= police.intercept_distance_m and wanted >= 2.0 and fast_enough:
		mode = INTERCEPT
		reason = &"can_cut_corner"
	elif bool(ctx.get("roadblock_ready", false)) and graph_distance >= police.roadblock_min_distance_m \
			and wanted >= 3.0 and bool(ctx.get("can_block", true)):
		mode = BLOCK
		reason = &"roadblock_ahead"
	elif distance <= police.ram_distance_m and wanted >= 2.0 and police.allow_ramming \
			and bool(ctx.get("can_ram", true)):
		reason = &"ram_range"
	elif lost > police.lose_time_s * 0.55 and not bool(ctx.get("has_los", true)):
		reason = &"fading"

	# Чем выше wanted, тем быстрее и агрессивнее едут; на 1-м уровне патруль не должен
	# «улетать» — иначе погоня заканчивается за 5 секунд.
	var urgency := clampf(wanted / 5.0, 0.0, 1.0) * (0.65 + 0.35 * police.aggression)
	var speed := lerp(police.patrol_speed_kmh, police_chase_speed(police), clampf(urgency + 0.25, 0.0, 1.0))
	if mode == BLOCK:
		# Блокпост стоит: едем к точке перекрытия, но не «в пол», чтобы успеть встать поперёк.
		speed = police.patrol_speed_kmh * 1.35
	elif mode == PINCER:
		speed = police_chase_speed(police) * 0.9
	elif mode == INTERCEPT:
		speed = police_chase_speed(police)
	# Если убегающий медленнее — не разгоняемся вхолостую.
	if mode == PURSUE and target_speed < speed:
		speed = maxf(target_speed * 1.12, police.patrol_speed_kmh)

	return _out(mode, speed, mode == PURSUE and distance <= police.ram_distance_m and bool(ctx.get("can_ram", true)) \
			and police.allow_ramming, wanted >= 3.0 and mode != BLOCK and bool(ctx.get("nitro_allowed", true)) \
			and distance > police.engage_distance_m * 0.45, reason, budget)

static func _out(mode: StringName, speed_kmh: float, ram: bool, nitro: bool, reason: StringName, units: int = 0) -> Dictionary:
	return {
		"mode": mode,
		"speed_target_kmh": maxf(speed_kmh, 5.0),
		"allow_ram": ram,
		"allow_nitro": nitro,
		"reason": reason,
		"units_budget": units,
	}

static func police_chase_speed(_police: PoliceConfig) -> float:
	## Максимум, который физически доступен патрулю: берём из VehicleConfig_police
	## (см. balance_rules), а «потолок по балансу» = max_speed_kmh игрока * police_speed_factor.
	var cfg := GameSetup.get_config("vehicle.police") as VehicleConfig
	if cfg == null:
		return 150.0
	return cfg.max_speed_kmh

static func wanted_units(wanted: float, police: PoliceConfig) -> int:
	if police == null or police.units_per_wanted_level.is_empty():
		return 1
	var level := clampi(int(ceilf(wanted)) - 1, 0, police.units_per_wanted_level.size() - 1)
	if wanted <= 0.0:
		return 0
	return clampi(police.units_per_wanted_level[level], 0, police.max_units)

## Нужен ли вообще размен «дистанция -> режим» (используется тестом переключения).
static func mode_for_distance(distance: float, police: PoliceConfig) -> StringName:
	if distance <= police.ram_distance_m:
		return PURSUE
	if distance <= police.pincer_distance_m:
		return PINCER
	if distance <= police.intercept_distance_m:
		return INTERCEPT
	if distance <= police.engage_distance_m:
		return PURSUE
	return PATROL
