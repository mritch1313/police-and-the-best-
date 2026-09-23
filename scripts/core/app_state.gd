extends Node
## AppState — фазовый автомат всей игры и счётчики заезда.
##
## UI, физика, полиция и меню синхронизируются только через него: никто не «спрашивает
## сцену», всё смотрят в `phase`. Это же точка входа для паузы и для «игрок задержан».

enum Phase { BOOT, MENU, LOADING, PLAYING, PAUSED, ARRESTED, DESTROYED }

signal phase_changed(previous: int, current: int)
signal session_updated(stats: Dictionary)

var phase: int = Phase.BOOT
## Ориентация, выбранная игроком в первый запуск: 0 = landscape, 1 = portrait.
var orientation: int = 1
## Активная карта/экран (для заголовка и статистики).
var current_map_title: String = ""
var current_scene_path: String = ""
## Нужен ли экран выбора ориентации (решает MainMenu по сейву).
var orientation_choice_pending: bool = false

# --- статистика заезда ---
var distance_m: float = 0.0
var top_speed_kms: float = 0.0
var boost_time_s: float = 0.0
var arrests_survived: int = 0
var session_time_s: float = 0.0
var max_wanted_level: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func set_phase(next_phase: int) -> void:
	if next_phase == phase:
		return
	var previous := phase
	phase = next_phase
	phase_changed.emit(previous, next_phase)
	DebugConsole.log_line("state", "фаза: %s -> %s" % [phase_name(previous), phase_name(next_phase)])

func phase_name(value: int = -1) -> String:
	var v := phase if value < 0 else value
	match v:
		Phase.BOOT: return "boot"
		Phase.MENU: return "menu"
		Phase.LOADING: return "loading"
		Phase.PLAYING: return "playing"
		Phase.PAUSED: return "paused"
		Phase.ARRESTED: return "arrested"
		Phase.DESTROYED: return "destroyed"
	return "unknown(%d)" % v

func is_playing() -> bool:
	return phase == Phase.PLAYING

func is_paused() -> bool:
	return phase == Phase.PAUSED

func is_in_game() -> bool:
	return phase in [Phase.PLAYING, Phase.PAUSED, Phase.ARRESTED, Phase.DESTROYED]

func can_use_nitro() -> bool:
	return phase == Phase.PLAYING

func accepts_gameplay_input() -> bool:
	return phase == Phase.PLAYING

func toggle_pause() -> void:
	if phase == Phase.PLAYING:
		set_phase(Phase.PAUSED)
	elif phase == Phase.PAUSED:
		set_phase(Phase.PLAYING)

func begin_session(map_title: String) -> void:
	current_map_title = map_title
	distance_m = 0.0
	top_speed_kms = 0.0
	boost_time_s = 0.0
	session_time_s = 0.0
	max_wanted_level = 0
	arrests_survived = 0

func end_session() -> void:
	session_updated.emit(stats())

func stats() -> Dictionary:
	return {
		"distance_m": distance_m,
		"top_speed_kms": top_speed_kms,
		"boost_time_s": boost_time_s,
		"session_time_s": session_time_s,
		"arrests_survived": arrests_survived,
		"max_wanted_level": max_wanted_level,
		"map": current_map_title,
	}

func add_distance(delta_m: float) -> void:
	distance_m = maxf(distance_m + maxf(delta_m, 0.0), 0.0)

func update_speed_record(speed_kms: float) -> void:
	if speed_kms > top_speed_kms:
		top_speed_kms = speed_kms

func update_wanted(level: int) -> void:
	if level > max_wanted_level:
		max_wanted_level = level

func record_arrest_survived() -> void:
	arrests_survived += 1

func orientation_name(value: int = -1) -> String:
	var v := orientation if value < 0 else value
	return "landscape" if v == 0 else "portrait"

func is_landscape() -> bool:
	return orientation == 0
