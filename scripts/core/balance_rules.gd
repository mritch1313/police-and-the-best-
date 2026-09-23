class_name BalanceRules
extends RefCounted
## Правила баланса, зафиксированные в требованиях игры.
##
##   Полиция не медленнее игрока, но ровно на ~1%:  police_max ≈ player_max * 1.01
##   Игрок на нитро:                                player_max * nitro_mult ≈ police_max * 1.25
##
## Возвращаемый список пуст — значит конфиг сбалансирован. [method dump] даёт человекочитаемое
## описание текущих чисел (его печатает DebugConsole и проверяет тест `test_balance`).

static var police_vs_player_ratio: float = 1.01
static var nitro_vs_police_ratio: float = 1.25
## Допуск: 3% на police, 6% на нитро (конфиг правится руками, идеальное совпадение не нужно).
static var police_tolerance: float = 0.03
static var nitro_tolerance: float = 0.06

static func check(player: VehicleConfig, police: VehicleConfig, nitro: NitroConfig) -> PackedStringArray:
	var problems := PackedStringArray()
	if player == null or police == null or nitro == null:
		return PackedStringArray(["BalanceRules: не переданы конфиги"])
	if police.max_speed_kmh < player.max_speed_kmh - 0.001:
		problems.append("полицейский максимум %.1f км/ч ниже игрового %.1f км/ч" % [police.max_speed_kmh, player.max_speed_kmh])
	var expected_police := player.max_speed_kmh * police_vs_player_ratio
	if absf(police.max_speed_kmh - expected_police) > expected_police * police_tolerance:
		problems.append("полицейский максимум %.1f км/ч должен быть ~%.1f км/ч (player*%.2f ±%.0f%%)" % [
			police.max_speed_kmh, expected_police, police_vs_player_ratio, police_tolerance * 100.0,
		])
	var player_with_nitro := player.max_speed_kmh * nitro.max_speed_multiplier
	var expected_nitro := police.max_speed_kmh * nitro_vs_police_ratio
	if absf(player_with_nitro - expected_nitro) > expected_nitro * nitro_tolerance:
		problems.append("нитро даёт %.1f км/ч, ожидается ~%.1f км/ч (police*%.2f ±%.0f%%)" % [
			player_with_nitro, expected_nitro, nitro_vs_police_ratio, nitro_tolerance * 100.0,
		])
	return problems

static func describe(player: VehicleConfig, police: VehicleConfig, nitro: NitroConfig) -> String:
	if player == null or police == null or nitro == null:
		return "BalanceRules: нет данных"
	var top := VehicleMath.terminal_speed_kms(player, 1.0)
	var nitro_top := VehicleMath.terminal_speed_kms(player, nitro.max_speed_multiplier)
	var police_top := VehicleMath.terminal_speed_kms(police, 1.0)
	return "player %.1f км/ч (конфиг %.1f) | police %.1f км/ч (конфиг %.1f) | nitro %.1f км/ч (конфиг %.1f) | ratio %.3f / %.3f" % [
		top * 3.6, player.max_speed_kmh,
		police_top * 3.6, police.max_speed_kmh,
		nitro_top * 3.6, player.max_speed_kmh * nitro.max_speed_multiplier,
		police.max_speed_kmh / maxf(player.max_speed_kmh, 0.001),
		nitro_top / maxf(police_top, 0.001),
	]
