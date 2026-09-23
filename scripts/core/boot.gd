extends Node
## The very first scene of the game.
##
## It does one thing: it asks the player for the screen orientation on the first launch and
## goes straight to the menu on every launch after that. A separate scene (instead of code in
## the menu) keeps the flow explicit and testable - the UI test asserts that a fresh profile
## lands on the orientation question and a used profile lands in the menu.

## When true the boot scene skips the question even on a fresh profile. Used by the CI smoke
## test, which must not be blocked by an interactive screen.
@export var skip_orientation_question: bool = false

var _routed: bool = false


func _ready() -> void:
	# Wait one frame so every autoload (and the settings file) is ready.
	await get_tree().process_frame
	route()


func route() -> void:
	if _routed:
		return
	_routed = true
	var screen_flow := get_node_or_null("/root/ScreenFlow")
	if screen_flow == null:
		push_error("Boot: ScreenFlow autoload is missing, cannot navigate")
		return
	var needs_question := SettingsManager.first_launch and not skip_orientation_question
	if needs_question:
		screen_flow.call("goto_orientation_select")
	else:
		SettingsManager.apply_orientation(false)
		screen_flow.call("goto_menu")


## True when the game is about to ask for the orientation.
func asks_orientation() -> bool:
	return SettingsManager.first_launch and not skip_orientation_question
