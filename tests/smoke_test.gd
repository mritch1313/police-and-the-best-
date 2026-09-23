extends Node
## Headless (and software-rendered) smoke test of the real game scene.
##
## This is the closest thing to running the game that a machine without a phone can do: it
## instantiates `res://scenes/game/GameWorld.tscn` - the exact scene the player gets when they
## tap the map card - lets it run for a few seconds, drives the car with synthetic input and
## reports what happened. The CI workflow runs it twice:
##
##   * `--headless`: the world is generated, the chunks are streamed, the physics runs, the
##     police and the traffic are created, and the run is measured.
##   * under Xvfb with the OpenGL compatibility renderer: the same, plus a real frame is read
##     back from the viewport and saved as a PNG, which is the visual evidence of the build.
##
## Usage:
##   godot --headless --path . res://tests/SmokeTest.tscn -- --frames 300 --seed 1234
##   xvfb-run -a godot --path . --rendering-driver opengl3 res://tests/SmokeTest.tscn -- \
##       --frames 300 --screenshot /abs/path/screenshot.png

const WORLD_SCENE := "res://scenes/game/GameWorld.tscn"

var frames: int = 300
var seed_value: int = 20240923
var screenshot_path: String = ""
var drive: bool = true
var verbose: bool = true

var _world: GameWorld = null
var _failures: Array[String] = []
var _started_ms: int = 0


func _ready() -> void:
	_parse_args()
	_started_ms = Time.get_ticks_msec()
	print("[SMOKE] godot %s, renderer=%s, driver=%s, display=%s" % [
		Engine.get_version_info().get("string", "?"),
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"),
		RenderingServer.get_video_adapter_name(),
		DisplayServer.get_name(),
	])
	await get_tree().process_frame
	await _run()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var arg: String = args[i]
		match arg:
			"--frames":
				if i + 1 < args.size():
					frames = int(args[i + 1])
			"--seed":
				if i + 1 < args.size():
					seed_value = int(args[i + 1])
			"--screenshot":
				if i + 1 < args.size():
					screenshot_path = args[i + 1]
			"--no-drive":
				drive = false
			"--quiet":
				verbose = false


func _run() -> void:
	var scene := load(WORLD_SCENE) as PackedScene
	if scene == null:
		_fail("the game scene could not be loaded: %s" % WORLD_SCENE)
		_finish()
		return
	_world = scene.instantiate() as GameWorld
	if _world == null:
		_fail("the game scene is not a GameWorld")
		_finish()
		return
	# A deterministic run: the same seed always produces the same city.
	_world.start_seed = seed_value
	_world.warmup_chunks = 0
	add_child(_world)
	await get_tree().process_frame
	print("[SMOKE] world generated: %s" % _world.world.debug_string())

	# --- run the game ---------------------------------------------------------------
	var second := 0
	var frames_done := 0
	var last_position := _world.player.global_position
	var travelled := 0.0
	while frames_done < frames:
		# Synthetic driver: full throttle, gentle steering so the car drives down the street,
		# which is what exercises the streaming, the AI and the HUD at the same time.
		if drive and _world.player != null:
			_world.player.drive_input.throttle = 1.0
			_world.player.drive_input.brake = 0.0
			_world.player.drive_input.steer = sin(float(frames_done) * 0.004) * 0.35
			_world.player.drive_input.source = &"smoke"
			_world.player.drive_input.nitro = frames_done % 420 > 300
		await get_tree().physics_frame
		frames_done += 1
		travelled += last_position.distance_to(_world.player.global_position)
		last_position = _world.player.global_position
		if frames_done % 60 == 0:
			second += 1
			if verbose:
				print("[SMOKE] t=%2ds %s | %s | %s" % [
					second,
					_world.player.describe(),
					_world.world.debug_string(),
					_world.police_manager.debug_string() if _world.police_manager != null else "police=off",
				])

	if screenshot_path != "":
		await _capture(screenshot_path)
	_verify(travelled)
	_finish()


## Reads the rendered frame back from the viewport and writes it to disk. Only possible when a
## real renderer is running (never in headless mode).
func _capture(path: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("[SMOKE] headless: skipping the screenshot (%s)" % path)
		return
	await RenderingServer.frame_post_draw
	var texture := get_viewport().get_texture()
	if texture == null:
		_fail("the viewport has no texture, the frame could not be captured")
		return
	var image := texture.get_image()
	if image == null:
		_fail("the viewport image is empty")
		return
	var target := path
	if target.begins_with("res://") or target.begins_with("user://"):
		pass
	elif not target.begins_with("/"):
		target = ProjectSettings.globalize_path("res://") + target
	var error := image.save_png(target)
	if error != OK:
		_fail("the screenshot could not be written to %s (error %d)" % [target, error])
	else:
		print("[SMOKE] screenshot written: %s (%dx%d)" % [target, image.get_width(), image.get_height()])


## The checks a build has to pass. They are deliberately about *the game running*, not about
## exact values, so they stay valid as the content grows.
func _verify(travelled: float) -> void:
	var streamer := _world.world.streamer
	var stats := streamer.statistics()
	print("[SMOKE] streaming: %s" % streamer.debug_string())
	print("[SMOKE] player: %s, travelled %.1f m" % [_world.player.describe(), travelled])
	_check(stats["resident"] > 0, "no chunk was streamed in")
	_check(stats["resident"] <= _world.world_config.max_resident_chunks + 8, "the chunk budget was exceeded")
	_check(stats["triangles"] > 5000, "the streamed world has almost no geometry")
	_check(stats["meshes"] > 0, "the streamed chunks produced no meshes")
	_check(streamer.collision_body_count() > 0, "no chunk near the player has collision")
	_check(_world.player.is_grounded(), "the player car is not standing on the ground")
	_check(_world.player.speed_kmh() > 5.0, "the player car did not move")
	_check(travelled > 20.0, "the player car did not travel any distance")
	_check(_world.player.max_speed_kmh() > 150.0, "the car cannot reach its designed top speed")
	_check(_world.world.road_graph.is_valid(), "the road graph is empty")
	_check(_world.camera_controller.current_distance > 0.5, "the camera did not follow the car")
	if _world.police_manager != null:
		var police := _world.police_manager.statistics()
		print("[SMOKE] police: %s" % str(police))
		_check(int(police["total"]) <= _world.police_config.max_active_units, "the police fleet exceeded its cap")
	if _world.traffic_manager != null:
		print("[SMOKE] traffic: %s" % str(_world.traffic_manager.statistics()))
	_check(_world.player.nitro_ratio() >= 0.0, "the nitro tank reported an invalid value")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	print("[SMOKE] FAIL: %s" % message)


func _finish() -> void:
	var elapsed := float(Time.get_ticks_msec() - _started_ms) / 1000.0
	print("[SMOKE] ----- result -----")
	print("[SMOKE] frames=%d elapsed=%.2fs fps=%.1f" % [frames, elapsed, Engine.get_frames_per_second()])
	if _failures.is_empty():
		print("[SMOKE] RESULT: OK")
	else:
		print("[SMOKE] RESULT: FAILED (%d problems)" % _failures.size())
	await get_tree().process_frame
	get_tree().quit(0 if _failures.is_empty() else 2)
