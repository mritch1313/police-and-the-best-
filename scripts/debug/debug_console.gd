extends Node
## DebugConsole — кольцевой журнал + машинно-читаемый отчёт прогона.
##
## Зачем именно так: в этой среде нет GPU, а скачивание логов GitHub Actions
## заблокировано сетью песочницы. Поэтому игра сама пишет развёрнутый отчёт
## (текст + JSON), а CI коммитит его обратно в репозиторий: «что реально
## проверено» остаётся фактом в репозитории, а не обещанием в сообщении коммита.
##
## Движковые предупреждения/ошибки (потерянные ресурсы, битые пути, SCRIPT ERROR)
## перехватываются через `Logger` + `OS.add_logger` — единственный легальный способ
## в 4.7 (сигналов `Engine.print_*` больше нет). Попадают в тот же отчёт и валяют
## CI-джобу, а не тонут в потоке stdout.
##
## ВАЖНО ПРО Потоки: виртуальные методы `Logger` вызываются из потока физики и из
## рендера, поэтому захватчик складывает строки в защищённый `Mutex` массив, а
## DebugConsole забирает их в `_process` на главном потоке.

const CAPACITY_DEFAULT := 600
## Logger.ErrorType (core/io/logger.h): ERR_ERROR=0, ERR_WARNING=1, ERR_SCRIPT=2, ERR_SHADER=3.
const TYPE_ERROR := 0
const TYPE_WARNING := 1
const TYPE_SCRIPT := 2
const TYPE_SHADER := 3

## Захватчик потока вывода движка. Только складывает строки — ничего не трогает из дерева сцены.
class MessageCapture:
	extends Logger

	var mutex: Mutex = Mutex.new()
	var pending: Array = []

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_backtraces: Array,
	)-> void:
		var where := file if not file.is_empty() else function
		var detail := code if not code.is_empty() else rationale
		mutex.lock()
		pending.append({"type": error_type, "text": "%s:%d %s (%s)" % [where, line, detail, function]})
		mutex.unlock()

	func _log_message(message: String, error: bool) -> void:
		mutex.lock()
		pending.append({"type": TYPE_ERROR if error else TYPE_WARNING, "text": message.strip_edges()})
		mutex.unlock()

	func take() -> Array:
		mutex.lock()
		var out := pending.duplicate()
		pending.clear()
		mutex.unlock()
		return out

signal line_logged(topic: String, text: String)

var lines: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
var errors: PackedStringArray = PackedStringArray()
var exceptions: PackedStringArray = PackedStringArray()
var capacity: int = CAPACITY_DEFAULT
var verbose: bool = true
var started_ms: int = 0
## Произвольные секции отчёта: telemetry / screenshots / counters / тесты.
var sections: Dictionary = {}
var counters: Dictionary = {}
## Куда писать отчёт (пусто — не писать). Задаётся в [dev] `report_path`.
var report_path: String = ""
var capture: MessageCapture = null
## Сколько раз отчёт уже записан (для «не спамить на каждый кадр»).
var writes: int = 0
var drained: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	started_ms = Time.get_ticks_msec()
	capture = MessageCapture.new()
	var logger_added := OS.add_logger(capture)
	if logger_added != OK:
		push_warning("DebugConsole: OS.add_logger вернул %s" % error_string(logger_added))
	report_path = Config.str_value("dev", "report_path", "")
	capacity = int(Config.num("dev", "log_capacity", float(CAPACITY_DEFAULT)))
	# GODOT_REPORT_PATH позволяет CI перенаправить отчёт, не трогая .cfg.
	var env_report := OS.get_environment("GODOT_REPORT_PATH")
	if not env_report.is_empty():
		report_path = env_report

## Основная запись. `topic` — подсистема (vehicle/world/police/ui/…).
func log_line(topic: String, text: String) -> void:
	var stamp := float(Time.get_ticks_msec() - started_ms) / 1000.0
	var entry := "[%8.3f] %-9s %s" % [stamp, topic, text]
	lines.append(entry)
	if lines.size() > capacity:
		lines.remove_at(0)
	if verbose:
		print("[GAME] %s" % entry)
	line_logged.emit(topic, text)

func info(topic: String, text: String) -> void:
	log_line(topic, text)

func warn(topic: String, text: String) -> void:
	warnings.append(text)
	log_line(topic, "ПРЕДУПРЕЖДЕНИЕ: %s" % text)

func error(topic: String, text: String) -> void:
	errors.append(text)
	log_line(topic, "ОШИБКА: %s" % text)

func set_section(name: String, value: Variant) -> void:
	sections[name] = value

func add_section_line(name: String, text: String) -> void:
	if not sections.has(name):
		sections[name] = PackedStringArray()
	(sections[name] as PackedStringArray).append(text)

func bump(key: String, amount: int = 1) -> int:
	counters[key] = int(counters.get(key, 0)) + amount
	return counters[key]

func _process(_delta: float) -> void:
	drain_capture()

## Забрать накопленное из захватчика (вызывается на главном потоке).
func drain_capture() -> void:
	if capture == null:
		return
	for entry in capture.take():
		drained += 1
		var type: int = int(entry.get("type", TYPE_ERROR))
		var text := String(entry.get("text", ""))
		match type:
			TYPE_WARNING:
				if not warnings.has(text):
					warnings.append(text)
			TYPE_SCRIPT:
				exceptions.append(text)
				errors.append("SCRIPT ERROR: %s" % text)
			TYPE_SHADER:
				errors.append("SHADER ERROR: %s" % text)
			_:
				if text.begins_with("WARNING"):
					warnings.append(text)
				else:
					errors.append(text)

## Есть ли смысл валить CI: ошибки движка/исключения или предупреждения конфига.
func has_fatal_output() -> bool:
	return not errors.is_empty() or not exceptions.is_empty()

func report_text() -> String:
	var info: Dictionary = Engine.get_version_info()
	var out := PackedStringArray()
	out.append("=== RUNTIME REPORT ===")
	out.append("godot: %s" % info.get("string", "?"))
	out.append("os: %s | display server: %s | renderer: %s | adapter: %s" % [
		OS.get_name(), DisplayServer.get_name(),
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name(),
	])
	out.append("viewport: %s | fps: %.1f" % [Vector2i(get_viewport_rect().size), Engine.get_frames_per_second()])
	out.append("фаза: %s | ориентация: %s" % [AppState.phase_name(), AppState.orientation_name()])
	out.append("warnings: %d | errors: %d | exceptions: %d" % [warnings.size(), errors.size(), exceptions.size()])
	var cw: PackedStringArray = Config.warnings
	if not cw.is_empty():
		out.append("--- config warnings (%d) ---" % cw.size())
		for w in cw:
			out.append("  ! %s" % w)
	for name in sections.keys():
		var value: Variant = sections[name]
		out.append("--- %s ---" % name)
		if value is PackedStringArray or value is Array:
			for line in value:
				out.append("  %s" % line)
		elif value is Dictionary:
			var dict: Dictionary = value
			for key in dict.keys():
				out.append("  %s = %s" % [key, dict[key]])
		else:
			out.append("  %s" % value)
	if not counters.is_empty():
		out.append("--- counters ---")
		var keys: Array = counters.keys()
		keys.sort()
		for key in keys:
			out.append("  %s = %d" % [key, counters[key]])
	if not lines.is_empty():
		out.append("--- log (%d строк) ---" % lines.size())
		for line in lines:
			out.append("  %s" % line)
	if not errors.is_empty():
		out.append("--- engine errors ---")
		for e in errors:
			out.append("  E %s" % e)
	if not warnings.is_empty():
		out.append("--- engine warnings ---")
		for w in warnings:
			out.append("  W %s" % w)
	return "\n".join(out) + "\n"

func report_json() -> String:
	var payload := {
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"display_server": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"phase": AppState.phase_name(),
		"fps": Engine.get_frames_per_second(),
		"config_warnings": Array(Config.warnings),
		"warnings": Array(warnings),
		"errors": Array(errors),
		"exceptions": Array(exceptions),
		"counters": counters,
		"session": AppState.stats(),
		"logs": Array(lines),
	}
	for name in sections.keys():
		var value: Variant = sections[name]
		if value is PackedStringArray:
			payload[name] = Array(value)
		else:
			payload[name] = value
	return JSON.stringify(payload, "  ")

## Записать отчёт (и .json рядом). Возвращает путь или "" если писать некуда.
func write_report(path: String = "") -> String:
	var target := path if not path.is_empty() else report_path
	if target.is_empty():
		return ""
	var dir := target.get_base_dir()
	if not dir.is_empty():
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK and err != ERR_ALREADY_EXISTS:
			push_warning("DebugConsole: не удалось создать каталог %s" % dir)
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		push_warning("DebugConsole: не удалось открыть %s (%s)" % [target, error_string(FileAccess.get_open_error())])
		return ""
	file.store_string(report_text())
	file.close()
	var json_path := target.get_basename() + ".json"
	var jf := FileAccess.open(json_path, FileAccess.WRITE)
	if jf != null:
		jf.store_string(report_json())
		jf.close()
	log_line("report", "отчёт записан: %s (+ .json)" % target)
	return target

func dump_to_stdout() -> void:
	print("<<<REPORT_BEGIN>>>\n%s<<<REPORT_END>>>" % report_text())

func get_viewport_rect() -> Rect2:
	var vp := get_viewport()
	if vp == null:
		return Rect2()
	return Rect2(vp.size)
