extends CanvasLayer
class_name MainMenu
## The main menu.
##
## Structure (exactly as the design asks):
##   * the background image fills the screen
##   * the top left corner carries "ВЕРСИЯ: 4.0.9 TEXT", the title follows under it
##   * two vertically stacked buttons sit centred under the text block: "Играть" and
##     "Разработчики"
##   * "Разработчики" opens a popup with the contact information; tapping it closes the popup
##   * "Играть" hides every menu element and shows **one** square map card with "TEST" under
##     it; tapping the card loads the game scene
##
## The background is a real file if the artist supplies one (`res://assets/menu/fon.jpg`),
## otherwise the generated background is used. Replacing the art is a file drop, no code.

const BACKGROUND_CANDIDATES := [
	"res://assets/menu/fon.jpg",
	"res://assets/menu/fon.png",
	"res://assets/menu/background.png",
	"res://assets/ui/logo.png",
]
const GAME_SCENE := "res://scenes/game/GameWorld.tscn"
const VERSION_TEXT := "ВЕРСИЯ: 4.0.9 TEXT"
const TITLE := "СИМУЛЯТОР УГОНА ОТ МУСОРОВ"
const DEVELOPER_LINES := [
	"тг бот для связи @connection9191_bot",
	"МАТАДОРА МАТАДОРА МАТАДАОРА",
]

var _background: TextureRect = null
var _gradient: ColorRect = null
var _version_label: Label = null
var _title_label: Label = null
var _play_button: Button = null
var _devs_button: Button = null
var _card_view: Control = null
var _card_panel: Panel = null
var _card_texture: TextureRect = null
var _card_label: Label = null
var _popup: Control = null
var _busy: bool = false
## Which background file was actually loaded (empty when none was found).
var background_path: String = ""


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.name = "MenuRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_gradient = ColorRect.new()
	_gradient.color = Color(0.08, 0.1, 0.14)
	_gradient.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_gradient)

	_background = TextureRect.new()
	_background.name = "Background"
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_background.texture = _load_background()
	root.add_child(_background)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	_build_text_block(root)
	_build_buttons(root)
	_build_card_view(root)
	_build_dev_popup(root)

	root.resized.connect(_relayout)
	_relayout()
	_show_card(false)


## Loads the first background that exists. If the artist drops "# фон.jpg" into
## res://assets/menu/, it is picked up automatically; otherwise the generated background is
## used. Nothing else in the menu depends on which one is present.
func _load_background() -> Texture2D:
	for path: String in BACKGROUND_CANDIDATES:
		if ResourceLoader.exists(path):
			var texture := load(path) as Texture2D
			if texture != null:
				background_path = path
				return texture
	return null


# --------------------------------------------------------------------------------------
# layout
# --------------------------------------------------------------------------------------
func _build_text_block(root: Control) -> void:
	_version_label = Label.new()
	_version_label.name = "VersionLabel"
	_version_label.text = VERSION_TEXT
	_version_label.add_theme_font_size_override("font_size", 22)
	_version_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.94))
	root.add_child(_version_label)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = TITLE
	_title_label.add_theme_font_size_override("font_size", 46)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85))
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_title_label)


func _build_buttons(root: Control) -> void:
	_play_button = _menu_button("Играть", _on_play)
	root.add_child(_play_button)
	_devs_button = _menu_button("Разработчики", _on_developers)
	root.add_child(_devs_button)


func _menu_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.name = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 38)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.16, 0.24, 0.9)
	style.corner_radius_top_left = 18
	style.corner_radius_top_right = 18
	style.corner_radius_bottom_left = 18
	style.corner_radius_bottom_right = 18
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.85, 0.7, 0.4, 0.6)
	button.add_theme_stylebox_override("normal", style)
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.28, 0.2, 0.12, 0.95)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover", pressed)
	button.pressed.connect(callback)
	return button


func _build_card_view(root: Control) -> void:
	_card_view = Control.new()
	_card_view.name = "CardView"
	_card_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_card_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_card_view)

	_card_panel = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.85)
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.corner_radius_bottom_left = 16
	style.corner_radius_bottom_right = 16
	style.border_width_left = 3
	style.border_width_top = 3
	style.border_width_right = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.9, 0.78, 0.45, 0.85)
	_card_panel.add_theme_stylebox_override("panel", style)
	_card_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_card_view.add_child(_card_panel)

	_card_texture = TextureRect.new()
	_card_texture.name = "MapCard"
	_card_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_texture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_card_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var map := load("res://assets/ui/map_test_district.png") as Texture2D
	if map == null:
		map = load("res://assets/ui/logo.png") as Texture2D
	_card_texture.texture = map
	_card_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_panel.add_child(_card_texture)

	_card_label = Label.new()
	_card_label.name = "CardLabel"
	_card_label.text = "TEST"
	_card_label.add_theme_font_size_override("font_size", 40)
	_card_label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.75))
	_card_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_view.add_child(_card_label)


func _build_dev_popup(root: Control) -> void:
	_popup = Control.new()
	_popup.name = "DevelopersPopup"
	_popup.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup.visible = false
	root.add_child(_popup)

	# Any tap closes the popup: the whole screen is the button.
	var catcher := Button.new()
	catcher.name = "CloseCatcher"
	catcher.flat = true
	catcher.focus_mode = Control.FOCUS_NONE
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.pressed.connect(_hide_popup)
	_popup.add_child(catcher)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.04, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup.add_child(dim)

	var panel := Panel.new()
	panel.name = "PopupPanel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.18, 0.97)
	style.corner_radius_top_left = 20
	style.corner_radius_top_right = 20
	style.corner_radius_bottom_left = 20
	style.corner_radius_bottom_right = 20
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	style.content_margin_top = 22.0
	style.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup.add_child(panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)
	var title := Label.new()
	title.text = "РАЗРАБОТЧИКИ"
	title.add_theme_font_size_override("font_size", 38)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)
	for line: String in DEVELOPER_LINES:
		var label := Label.new()
		label.text = line
		label.add_theme_font_size_override("font_size", 30)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(label)
	var hint := Label.new()
	hint.text = "НАЖМИТЕ ЧТОБЫ ЗАКРЫТЬ"
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(hint)


## Re-lays out everything for the current viewport. Works in portrait and in landscape, which
## is required because the orientation is a player choice at first launch.
func _relayout() -> void:
	var size := get_viewport().get_visible_rect().size
	var margin := 22.0
	var portrait := size.y >= size.x
	# Text block: top left.
	var text_width := size.x - margin * 2.0
	_version_label.position = Vector2(margin, margin)
	_version_label.size = Vector2(text_width, 30)
	_title_label.position = Vector2(margin, margin + 34.0)
	_title_label.size = Vector2(text_width, 120 if portrait else 80)
	# Buttons: centred under the text block.
	var button_width := minf(size.x - margin * 4.0, 420.0)
	var button_height := 96.0 if portrait else 78.0
	var first_y := margin + 34.0 + (132.0 if portrait else 90.0)
	_play_button.size = Vector2(button_width, button_height)
	_play_button.position = Vector2((size.x - button_width) * 0.5, first_y)
	_devs_button.size = Vector2(button_width, button_height)
	_devs_button.position = Vector2((size.x - button_width) * 0.5, first_y + button_height + 18.0)
	# Map card: one square card, centred, with "TEST" under it.
	var card_size := minf(minf(size.x, size.y) - margin * 3.0, 430.0)
	_card_panel.size = Vector2(card_size, card_size)
	_card_panel.position = Vector2((size.x - card_size) * 0.5, (size.y - card_size) * 0.5 - 26.0)
	_card_texture.size = _card_panel.size
	_card_label.size = Vector2(size.x, 56)
	_card_label.position = Vector2(0, _card_panel.position.y + card_size + 10.0)
	# Popup.
	var popup := _popup.get_node_or_null("PopupPanel") as Panel
	if popup != null:
		popup.size = Vector2(minf(size.x - 40.0, 520.0), 0.0)
		popup.position = Vector2((size.x - popup.size.x) * 0.5, size.y * 0.3)
		popup.size = Vector2(popup.size.x, popup.get_combined_minimum_size().y)


# --------------------------------------------------------------------------------------
# actions
# --------------------------------------------------------------------------------------
func _show_card(show: bool) -> void:
	_version_label.visible = not show
	_title_label.visible = not show
	_play_button.visible = not show
	_devs_button.visible = not show
	_card_view.visible = show


func _on_play() -> void:
	if _busy:
		return
	_busy = true
	_show_card(true)
	# The card is the only thing on screen; tapping it loads the game.
	_card_panel.gui_input.connect(_on_card_input)


func _on_card_input(event: InputEvent) -> void:
	if _busy == false:
		return
	var pressed := false
	if event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		pressed = mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT
	if pressed:
		_start_game()


func _start_game() -> void:
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow != null and screen_flow.has_method("goto_world"):
		screen_flow.call("goto_world")
		return
	# Fallback: load the game scene directly.
	if ResourceLoader.exists(GAME_SCENE):
		get_tree().change_scene_to_file(GAME_SCENE)


func _on_developers() -> void:
	_popup.visible = true
	_relayout()


func _hide_popup() -> void:
	_popup.visible = false


func card_visible() -> bool:
	return _card_view != null and _card_view.visible


## Test hook: the automated UI test uses this instead of synthesising touches.
func simulate_play_pressed() -> void:
	if _play_button != null:
		_play_button.pressed.emit()
