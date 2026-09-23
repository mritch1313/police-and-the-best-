class_name ArrestSystem
extends RefCounted
## Задержание: «удержать игрока рядом и медленно» -> арест.
##
## Это единственная «победа» полиции в песочнице, поэтому правила вынесены в отдельный
## класс и полностью покрыты автотестами (ChaseConfig задаёт радиус, лимит скорости,
## время удержания и «штраф» за разрыв).
##
## ПОЧЕМУ «УДЕРЖАНИЕ», А НЕ МГНОВЕННЫЙ АРЕСТ: мгновенный арест при касании превращает игру
## в «один случайный бампер = поражение» и не даёт игроку шанс уехать. Поэтому прогресс
## копится, пока условие держится, и быстро тает, когда игрок вырвался (ratio затухает) —
## игрок физически чувствует «они меня почти взяли».

signal progress_changed(ratio: float)
signal arrest_started
signal arrest_cancelled(reason: StringName)
signal arrested

const DECAY_RATE := 0.85

var config: ChaseConfig = null
var hold_time: float = 0.0
var ratio: float = 0.0
var active: bool = false
var lock_time: float = 0.0
var arrests: int = 0
var last_reason: StringName = &"waiting"
var total_contact_time_s: float = 0.0

func configure(p_config: ChaseConfig) -> void:
	config = p_config
	reset(&"reconfigured")

func reset(reason: StringName = &"reset") -> void:
	active = false
	hold_time = 0.0
	ratio = 0.0
	last_reason = reason
	arrest_cancelled.emit(reason)

## Обновить состояние. Возвращает true в кадре свершённого ареста.
##   distance_m        — от ближайшего патруля до игрока;
##   player_speed_kmh  — скорость игрока;
##   units_in_range    — сколько патрулей в радиусе (их должно быть минимум `arrest_units_required`);
##   rammed            — игрок таранил патруль в этом кадре (сбрасывает прогресс: «отстрелялся»).
func update(delta: float, distance_m: float, player_speed_kmh: float, units_in_range: int, rammed: bool = false) -> bool:
	if config == null:
		return false
	lock_time = maxf(lock_time - delta, 0.0)
	if rammed:
		hold_time = maxf(hold_time - 1.2, 0.0)
		last_reason = &"rammed"
	var in_range := units_in_range >= arrest_units_required()
	var close := distance_m <= config.arrest_distance_m and in_range
	var slow := absf(player_speed_kmh) <= config.arrest_max_speed_kmh
	var allowed := config.arrest_hold_s > 0.0 and not is_locked()
	if close and slow and allowed:
		var was := active
		active = true
		hold_time += delta
		total_contact_time_s += delta
		if not was:
			arrest_started.emit()
		last_reason = &"holding"
	elif active and allowed:
		active = false
		hold_time = maxf(hold_time - delta * DECAY_RATE, 0.0)
		last_reason = &"lost_contact" if not close else &"too_fast"
	else:
		active = false
		hold_time = maxf(hold_time - delta * DECAY_RATE, 0.0)
	var target := clampf(hold_time / maxf(config.arrest_hold_s, 0.2), 0.0, 1.0)
	if absf(target - ratio) > 0.0005:
		ratio = target
		progress_changed.emit(ratio)
	if ratio >= 0.999 and allowed:
		arrests += 1
		lock_time = config.arrest_lock_time_s
		hold_time = 0.0
		ratio = 0.0
		arrested.emit()
		active = false
		return true
	return false

func arrest_units_required() -> int:
	## Требование «не один патруль» держит погоню живой: один патруль может только толкать,
	## но не арестовывать (иначе «врезался и всё»).
	return 2

func is_locked() -> bool:
	return lock_time > 0.0

func progress() -> float:
	return ratio

func state() -> Dictionary:
	return {
		"active": active,
		"ratio": ratio,
		"hold_time": hold_time,
		"need_s": config.arrest_hold_s if config != null else 0.0,
		"lock_time": lock_time,
		"arrests": arrests,
		"reason": String(last_reason),
		"contact_time_s": total_contact_time_s,
	}

func status_text() -> String:
	if ratio <= 0.001:
		return "задержание: нет контакта"
	return "задержание: %.0f%% (%s)" % [ratio * 100.0, String(last_reason)]

## Автопроверка без движка: накопление, сброс при разрыве, «нужно 2 патруля», лимит скорости.
static func self_check() -> PackedStringArray:
	var problems := PackedStringArray()
	var cfg := ChaseConfig.new()
	var arrest := ArrestSystem.new()
	arrest.configure(cfg)
	# 1) Удержание даёт прогресс, но не мгновенно.
	var arrested_now := arrest.update(0.5, cfg.arrest_distance_m * 0.5, 5.0, arrest.arrest_units_required())
	if arrested_now or arrest.progress() <= 0.0 or arrest.progress() >= 0.999:
		problems.append("арест: прогресс после 0.5 с = %.3f (ожидалось между 0 и 1)" % arrest.progress())
	# 2) На скорости выше лимита прогресс не копится.
	var before := arrest.progress()
	arrest.update(0.5, 1.0, cfg.arrest_max_speed_kmh + 25.0, 4)
	if arrest.progress() > before + 0.001:
		problems.append("арест: прогресс растёт на скорости выше arrest_max_speed_kmh")
	# 3) Разрыв контакта сбрасывает прогресс (decay).
	for i in range(12):
		arrest.update(0.5, 900.0, 40.0, 0)
	if arrest.progress() > 0.001:
		problems.append("арест: прогресс не затухает при потере контакта (%.3f)" % arrest.progress())
	# 4) Одного патруля мало.
	arrest.update(0.4, 1.0, 2.0, 1)
	if arrest.progress() > 0.001:
		problems.append("арест: один патруль в радиусе засчитывает удержание")
	# 5) Полное удержание -> сигнал arrested и локкирование.
	var st := ArrestSystem.new()
	st.configure(cfg)
	var fired := false
	var steps := int(ceilf(cfg.arrest_hold_s / 0.1)) + 2
	for i in range(steps):
		if st.update(0.1, 1.0, 3.0, 2):
			fired = true
			break
	if not fired:
		problems.append("арест: за %.1f с удержания не произошёл" % cfg.arrest_hold_s)
	if not st.is_locked():
		problems.append("арест: после задержания не включён lock_time")
	if st.arrests != 1:
		problems.append("арест: счётчик арестов = %d, ожидался 1" % st.arrests)
	return problems
