extends Node3D
## Temporary CI probe scene: verifies that the project loads, that the GL Compatibility
## renderer is reachable, that the InputMap action from project.godot parsed and that a
## trivial frame renders. It is replaced by the real game entry point in the same branch.

func _ready() -> void:
	print("[PROBE] project booted")
	print("[PROBE] godot version      = ", Engine.get_version_info())
	print("[PROBE] rendering driver   = ", RenderingServer.get_video_adapter_name())
	print("[PROBE] renderer method    = ", ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	print("[PROBE] has probe_forward  = ", InputMap.has_action("probe_forward"))
	print("[PROBE] main scene         = ", ProjectSettings.get_setting("application/run/main_scene"))
	print("[PROBE] display size       = ", DisplayServer.window_get_size())
	await get_tree().process_frame
	print("[PROBE] first frame ok")
	get_tree().quit(0)
