extends TestCase
## The boot chain and the interface.
##
## The first half is the "does the game actually start" test: every scene the flow can navigate
## to must exist on disk, including the main scene named in project.godot. A missing scene is
## exactly the kind of mistake that turns a project into a collection of scripts that never
## boots, so it is checked here.
##
## The second half drives the real interface objects (menu, orientation question, HUD) and
## checks the structure the design asks for: the version line, the title, the two buttons, the
## single map card with TEST under it, the developer popup with both contact lines, and a HUD
## that shows speed and nitro without covering the screen.


func _suite_name() -> String:
	return "integration/scene_flow"


func run(tree: SceneTree) -> void:
	# --- 1. everything the flow needs exists -----------------------------------------
	var required_scenes := [
		"res://scenes/main/Main.tscn",
		"res://scenes/main/MainMenu.tscn",
		"res://scenes/main/OrientationSelect.tscn",
		"res://scenes/game/GameWorld.tscn",
		"res://scenes/vehicles/PlayerCar.tscn",
		"res://scenes/ui/PauseMenu.tscn",
		"res://scenes/ui/EndScreen.tscn",
		"res://tests/TestRunner.tscn",
	]
	for path: String in required_scenes:
		check(ResourceLoader.exists(path), "the scene exists: %s" % path)
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	check(main_scene != "", "project.godot names a main scene")
	check(ResourceLoader.exists(main_scene), "the main scene named in project.godot exists: %s" % main_scene)
	var icon_path := String(ProjectSettings.get_setting("application/config/icon", ""))
	check(icon_path != "", "the project names an icon")
	check(ResourceLoader.exists(icon_path), "the icon exists: %s" % icon_path)
	check(
		String(ProjectSettings.get_setting("application/config/name", "")).to_lower().contains("симулятор угона"),
		"the application name is the game"
	)
	check(String(ProjectSettings.get_setting("application/config/version", "")) == "4.0.9", "the version is 4.0.9")
	for scene_path: String in required_scenes:
		var scene := load(scene_path) as PackedScene
		if scene == null:
			continue
		var instance := scene.instantiate()
		check_not_null(instance, "%s instantiates" % scene_path)
		if instance != null:
			instance.free()

	# --- 2. the orientation question is asked once -----------------------------------
	var boot: Node = load("res://scripts/core/boot.gd").new()
	check_not_null(boot, "the boot script exists")
	if boot != null:
		SettingsManager.first_launch = true
		boot.set("skip_orientation_question", false)
		check(boot.call("asks_orientation"), "a fresh profile is asked for the orientation")
		boot.set("skip_orientation_question", true)
		check(not boot.call("asks_orientation"), "the CI smoke test can skip the question")
		boot.set("skip_orientation_question", false)
		SettingsManager.first_launch = false
		check(not boot.call("asks_orientation"), "an existing profile goes straight to the menu")
		boot.free()

	# --- 3. the orientation screen ---------------------------------------------------
	var orientation_screen := load("res://scenes/main/OrientationSelect.tscn").instantiate()
	tree.root.add_child(orientation_screen)
	await tree.process_frame
	var texts := _collect_text(orientation_screen)
	check(texts.any(func(line: String) -> bool: return line.contains("ОРИЕНТАЦИЮ")), "the orientation screen asks a question")
	check(texts.any(func(line: String) -> bool: return line.contains("ВЕРТИКАЛЬНО")), "there is a portrait button")
	check(texts.any(func(line: String) -> bool: return line.contains("ГОРИЗОНТАЛЬНО")), "there is a landscape button")
	SettingsManager.set_orientation(false)
	check(not SettingsManager.is_portrait(), "the landscape choice is stored")
	check(SettingsManager.orientation_name() == "ЛАНДШАФТ", "the landscape choice is named")
	SettingsManager.set_orientation(true)
	check(SettingsManager.is_portrait(), "the portrait choice is stored")
	check(SettingsManager.orientation_name() == "ПОРТРЕТ", "the portrait choice is named")
	check(
		int(ProjectSettings.get_setting("display/window/handheld/orientation", 1)) == 1,
		"the project defaults to a portrait window"
	)
	check(
		String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")) == "gl_compatibility",
		"the renderer is the mobile friendly one"
	)
	orientation_screen.queue_free()
	await tree.process_frame

	# --- 4. the main menu ------------------------------------------------------------
	var menu := load("res://scenes/main/MainMenu.tscn").instantiate()
	tree.root.add_child(menu)
	await tree.process_frame
	var version_label: Label = menu.get("_version_label")
	var title_label: Label = menu.get("_title_label")
	var play_button: Button = menu.get("_play_button")
	var devs_button: Button = menu.get("_devs_button")
	var card_view: Control = menu.get("_card_view")
	var card_panel: Panel = menu.get("_card_panel")
	var card_label: Label = menu.get("_card_label")
	check_not_null(version_label, "the menu has the version label")
	check_not_null(title_label, "the menu has the title label")
	check_not_null(play_button, "the menu has the play button")
	check_not_null(devs_button, "the menu has the developers button")
	if version_label != null:
		check(version_label.text == "ВЕРСИЯ: 4.0.9 TEXT", "the version line is exactly as designed")
		check(version_label.position.x < 200.0, "the version line is in the top left corner")
		check(version_label.position.y < 200.0, "the version line is at the top")
	if title_label != null:
		check(title_label.text == "СИМУЛЯТОР УГОНА ОТ МУСОРОВ", "the title is exactly as designed")
		check(title_label.position.y > version_label.position.y, "the title sits under the version line")
		check(title_label.position.x < 200.0, "the title starts on the left")
	if play_button != null and title_label != null:
		check(play_button.text == "Играть", "the first button is Играть")
		if devs_button != null:
			check(devs_button.text == "Разработчики", "the second button is Разработчики")
			check(devs_button.position.y > play_button.position.y, "the buttons are stacked vertically")
			check_almost(play_button.position.x, devs_button.position.x, 0.5, "the buttons are aligned with each other")
			var menu_width := tree.root.get_visible_rect().size.x
			var play_centre := play_button.position.x + play_button.size.x * 0.5
			check_between(play_centre, menu_width * 0.35, menu_width * 0.65, "the buttons are centred horizontally")
			check(play_button.position.y >= title_label.position.y, "the buttons sit under the title block")
	# The developer popup.
	var popup: Control = menu.get("_popup")
	check_not_null(popup, "the menu has the developer popup")
	if popup != null:
		check(not popup.visible, "the popup is hidden at start")
		menu.call("_on_developers")
		await tree.process_frame
		check(popup.visible, "the developers button opens the popup")
		var popup_text := _collect_text(popup)
		check(
			popup_text.any(func(line: String) -> bool: return line.contains("@connection9191_bot")),
			"the popup contains the telegram bot contact"
		)
		check(
			popup_text.any(func(line: String) -> bool: return line.contains("МАТАДОРА")),
			"the popup contains the second contact line"
		)
		menu.call("_hide_popup")
		await tree.process_frame
		check(not popup.visible, "the popup closes on a tap")

	# --- 5. the map card -------------------------------------------------------------
	var background: TextureRect = menu.get("_background")
	check_not_null(background, "the menu has a background")
	if background != null:
		check_not_null(background.texture, "the background image is loaded")
		check(background.size.x >= tree.root.get_visible_rect().size.x - 1.0, "the background covers the screen")
	if play_button != null:
		menu.call("simulate_play_pressed")
		await tree.process_frame
		check(menu.call("card_visible"), "pressing Играть shows the map card")
		check(not version_label.visible, "the version line is hidden on the map screen")
		check(not title_label.visible, "the title is hidden on the map screen")
		check(not play_button.visible, "the play button is hidden on the map screen")
		check(not devs_button.visible, "the developers button is hidden on the map screen")
		check_not_null(card_panel, "the map card exists")
		check_not_null(card_label, "the card has a label")
		if card_panel != null:
			check_almost(card_panel.size.x, card_panel.size.y, 0.5, "the map card is square")
			var card_texture: TextureRect = card_panel.get_child(0) as TextureRect
			check_not_null(card_texture, "the card holds an image")
			if card_texture != null:
				check_not_null(card_texture.texture, "the card image is loaded (a screenshot of the map)")
				check_almost(card_texture.size.x, card_panel.size.x, 0.5, "the image fills the card")
			var screen_centre := tree.root.get_visible_rect().size * 0.5
			var card_centre := card_panel.position + card_panel.size * 0.5
			check_less(card_centre.distance_to(screen_centre), 260.0, "the card is centred on the screen")
			check_greater(card_panel.size.x, 180.0, "the card is big enough to tap")
		if card_label != null:
			check(card_label.text == "TEST", "the card is labelled TEST")
			if card_panel != null:
				check(card_label.position.y > card_panel.position.y + card_panel.size.y, "the TEST label is under the card")
	menu.queue_free()
	await tree.process_frame

	# --- 6. the HUD ------------------------------------------------------------------
	var arena := TestArena.create(tree, 200.0, "HudArena")
	var car := TestArena.add_car(arena, "res://resources/config/vehicles/player_car.tres", Vector3.ZERO)
	var hud := GameHUD.new()
	hud.name = "TestHUD"
	hud.player = car
	tree.root.add_child(hud)
	await tree.process_frame
	await tree.physics_frame
	var speed_label: Label = hud.get("_speed_label")
	var nitro_bar: ProgressBar = hud.get("_nitro_bar")
	var arrest_panel: Panel = hud.get("_arrest_panel")
	check_not_null(speed_label, "the HUD shows a speed")
	check_not_null(nitro_bar, "the HUD shows the nitro tank")
	check_not_null(arrest_panel, "the HUD can warn about an arrest")
	if speed_label != null:
		check(speed_label.text == "0", "the speed starts at zero")
	if nitro_bar != null:
		check_almost(nitro_bar.value, 1.0, 0.001, "the nitro tank starts full")
	if arrest_panel != null:
		check(not arrest_panel.visible, "the arrest warning is hidden while driving freely")
	hud.call("set_arrest_progress", 0.5)
	await tree.process_frame
	if arrest_panel != null:
		check(arrest_panel.visible, "the arrest warning appears while the police close in")
	hud.queue_free()
	TestArena.destroy(arena)
	await tree.process_frame

	# --- 7. the pause and end screens ------------------------------------------------
	var pause := load("res://scenes/ui/PauseMenu.tscn").instantiate()
	tree.root.add_child(pause)
	await tree.process_frame
	var pause_texts := _collect_text(pause)
	check(pause_texts.any(func(line: String) -> bool: return line.contains("ПАУЗА")), "the pause screen says it is a pause")
	check(pause_texts.any(func(line: String) -> bool: return line.contains("ПРОДОЛЖИТЬ")), "the pause screen can be dismissed")
	pause.queue_free()
	await tree.process_frame

	var end := load("res://scenes/ui/EndScreen.tscn").instantiate()
	end.set("summary", {
		"reason": "arrested",
		"distance_m": 1500.0,
		"top_speed_kmh": 160.0,
		"time": 120.0,
		"heat": 3,
		"nitro_seconds": 6.0,
		"police_contact": 2,
		"air_time": 1.5,
		"money": 250,
	})
	tree.root.add_child(end)
	await tree.process_frame
	var end_texts := _collect_text(end)
	check(end_texts.any(func(line: String) -> bool: return line.contains("ЗАДЕРЖАЛИ")), "the end screen reports an arrest")
	check(end_texts.any(func(line: String) -> bool: return line.contains("1.50 км")), "the end screen reports the distance")
	check(end_texts.any(func(line: String) -> bool: return line.contains("160")), "the end screen reports the top speed")
	end.queue_free()
	await tree.process_frame


func _collect_text(root: Node) -> Array[String]:
	var result: Array[String] = []
	for child in root.get_children():
		if child is Label or child is Button:
			result.append((child as Control).get("text") as String)
		result.append_array(_collect_text(child))
	return result
