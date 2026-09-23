extends Node
## Runs every test suite of the project inside a real (headless) engine instance and exits
## with a non-zero code when something failed.
##
## Usage:
##   godot --headless --path . res://tests/TestRunner.tscn -- --quick
##
## The runner is a scene (not a `--script` main loop) on purpose: the game's autoloads
## (SettingsManager, InputManager, GameState, ...) only exist in a normal scene run, and the
## tests must exercise the same code paths the game does.

## Suites that need physics time (driving a car, streaming the city). Skipped with --quick.
const HEAVY_SUITES := [
	"res://tests/integration/test_vehicle_behaviour.gd",
	"res://tests/integration/test_world_streaming.gd",
	"res://tests/integration/test_scene_flow.gd",
	"res://tests/integration/test_police_chase.gd",
]

const LIGHT_SUITES := [
	"res://tests/unit/test_vehicle_math.gd",
	"res://tests/unit/test_drive_input.gd",
	"res://tests/unit/test_nitro_system.gd",
	"res://tests/unit/test_police_strategy.gd",
	"res://tests/unit/test_config_balance.gd",
	"res://tests/unit/test_district_layout.gd",
	"res://tests/unit/test_road_graph.gd",
	"res://tests/unit/test_lod_manager.gd",
	"res://tests/unit/test_geometry_builder.gd",
]

var _quick: bool = false
var _total_checks: int = 0
var _total_failures: int = 0
var _suite_count: int = 0


func _ready() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	_quick = args.has("--quick")
	print("[TEST] ===== СИМУЛЯТОР УГОНА ОТ МУСОРОВ test run =====")
	print("[TEST] godot=%s mode=%s" % [Engine.get_version_info().get("string", "?"), "quick" if _quick else "full"])
	await _run_suites(LIGHT_SUITES)
	if not _quick:
		await _run_suites(HEAVY_SUITES)
	print("[TEST] ----- summary -----")
	print("[TEST] suites=%d checks=%d failures=%d" % [_suite_count, _total_checks, _total_failures])
	if _total_failures == 0:
		print("[TEST] RESULT: PASS")
	else:
		print("[TEST] RESULT: FAIL")
	# Give the engine a frame to flush the output before quitting.
	await get_tree().process_frame
	get_tree().quit(0 if _total_failures == 0 else 1)


func _run_suites(paths: Array) -> void:
	for path: String in paths:
		if not ResourceLoader.exists(path):
			print("[TEST] MISSING SUITE %s" % path)
			_total_failures += 1
			continue
		var script := load(path) as GDScript
		if script == null:
			print("[TEST] FAILED TO LOAD %s" % path)
			_total_failures += 1
			continue
		var test: TestCase = script.new()
		var started := Time.get_ticks_msec()
		await test.run(get_tree())
		var elapsed := Time.get_ticks_msec() - started
		_suite_count += 1
		_total_checks += test.checks
		_total_failures += test.failures.size()
		print("%s (%d ms)" % [test.summary_line(), elapsed])
		for failure: String in test.failures:
			print("[TEST]   FAIL: %s" % failure)
		for note_line: String in test.notes:
			print("[TEST]   note: %s" % note_line)
