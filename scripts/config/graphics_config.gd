extends Resource
class_name GraphicsConfig
## Quality presets for a low-end mobile GPU (target: Mali-G52 class, 720x1612).
##
## The game ships three presets. The PerformanceManager can drop the preset at runtime
## when the frame rate falls below the target, and raise it again when there is headroom.
## Nothing in this resource switches on heavy features: no GI, no volumetric fog, no
## screen space reflections. Everything is tuned for a fill-rate limited phone GPU.

@export_enum("Low", "Medium", "High") var preset: int = 1

@export_group("Medium preset (default on the target device)")
@export_range(0.3, 1.5, 0.05) var medium_lod_bias: float = 1.0
@export_range(0.0, 1.0, 0.02) var medium_prop_density: float = 0.85
@export_range(0, 1, 1) var medium_shadow_quality: int = 1
@export_range(0.0, 200.0, 1.0) var medium_shadow_distance: float = 58.0

@export_group("Low preset")
@export_range(0.3, 1.5, 0.05) var low_lod_bias: float = 0.62
@export_range(0.0, 1.0, 0.02) var low_prop_density: float = 0.45
@export_range(0, 1, 1) var low_shadow_quality: int = 0
@export_range(0.0, 200.0, 1.0) var low_shadow_distance: float = 34.0

@export_group("High preset")
@export_range(0.3, 2.0, 0.05) var high_lod_bias: float = 1.35
@export_range(0.0, 1.5, 0.02) var high_prop_density: float = 1.0
@export_range(0, 2, 1) var high_shadow_quality: int = 2
@export_range(0.0, 300.0, 1.0) var high_shadow_distance: float = 92.0

@export_group("Shadows")
@export_range(512, 8192, 128) var shadow_atlas_size_low: int = 1024
@export_range(512, 8192, 128) var shadow_atlas_size_medium: int = 2048
@export_range(512, 8192, 128) var shadow_atlas_size_high: int = 4096
## Only the directional light casts shadows: every additional shadow-casting light costs a
## full shadow pass on a tile based mobile GPU.
@export var shadows_enabled: bool = true
## Contact shadows are cheap on GL Compatibility and help the car feel grounded.
@export var contact_shadows: bool = true

@export_group("Materials and textures")
## Anisotropic filtering level: 0 = disabled (mobile default), 1..4 = 2x..16x.
@export_range(0, 4, 1) var anisotropic_level: int = 1
@export var nearest_mipmap_filter: bool = false
## Texture size cap applied to the generated textures (0 = no cap).
@export_range(0, 2048, 64) var max_texture_size: int = 512
@export var use_vertex_colour_variation: bool = true

@export_group("Post processing")
@export var glow_enabled: bool = false
@export_range(0.0, 4.0, 0.05) var glow_intensity: float = 0.55
@export var screen_space_aa: bool = false
@export_range(0, 4, 1) var msaa_3d: int = 0
@export var fxaa: bool = true

@export_group("Environment")
@export_range(0.0, 2.0, 0.01) var fog_density: float = 0.0022
@export_range(0.0, 4.0, 0.05) var sky_energy: float = 1.0
@export_range(0.05, 4.0, 0.05) var ambient_energy: float = 0.72
@export_range(0.0, 1.0, 0.01) var shadow_opacity: float = 0.62
@export var time_of_day: float = 10.5

@export_group("Budgets")
## Maximum number of chunks the streamer may keep resident; scaled by the preset.
@export_range(16, 400, 1) var max_resident_chunks_medium: int = 160
@export_range(16, 400, 1) var max_resident_chunks_low: int = 96
@export_range(16, 400, 1) var max_resident_chunks_high: int = 220
## Maximum number of traffic cars; scaled by the preset.
@export_range(0, 60, 1) var traffic_cars_low: int = 6
@export_range(0, 60, 1) var traffic_cars_medium: int = 14
@export_range(0, 60, 1) var traffic_cars_high: int = 20


## LOD bias of the active preset.
func lod_bias_for_preset() -> float:
	match preset:
		0:
			return low_lod_bias
		2:
			return high_lod_bias
		_:
			return medium_lod_bias


## Prop density of the active preset.
func prop_density_for_preset() -> float:
	match preset:
		0:
			return low_prop_density
		2:
			return high_prop_density
		_:
			return medium_prop_density


## Shadow atlas size of the active preset.
func shadow_size_for_preset() -> int:
	match preset:
		0:
			return shadow_atlas_size_low
		2:
			return shadow_atlas_size_high
		_:
			return shadow_atlas_size_medium


## Shadow distance of the active preset.
func shadow_distance_for_preset() -> float:
	match preset:
		0:
			return low_shadow_distance
		2:
			return high_shadow_distance
		_:
			return medium_shadow_distance


## Number of traffic cars of the active preset.
func traffic_for_preset() -> int:
	match preset:
		0:
			return traffic_cars_low
		2:
			return traffic_cars_high
		_:
			return traffic_cars_medium


## Maximum resident chunks of the active preset.
func chunks_for_preset() -> int:
	match preset:
		0:
			return max_resident_chunks_low
		2:
			return max_resident_chunks_high
		_:
			return max_resident_chunks_medium


## Human readable preset name (used by the settings UI).
func preset_name() -> String:
	match preset:
		0:
			return "НИЗКОЕ"
		2:
			return "ВЫСОКОЕ"
		_:
			return "СРЕДНЕЕ"


## Pushes the active preset into the engine. Safe to call at runtime.
func apply_to_engine() -> void:
	var lod_bias := lod_bias_for_preset()
	RenderingServer.directional_shadow_atlas_set_size(shadow_size_for_preset(), false)
	ProjectSettings.set_setting("rendering/textures/default_filters/anisotropic_filtering_level", anisotropic_level)
	ProjectSettings.set_setting("rendering/textures/default_filters/use_nearest_mipmap_filter", nearest_mipmap_filter)
	var viewport := Engine.get_main_loop() as SceneTree
	if viewport and viewport.root:
		viewport.root.msaa_3d = msaa_3d
		viewport.root.screen_space_aa = (
			Viewport.SCREEN_SPACE_AA_FXAA if (screen_space_aa or fxaa) else Viewport.SCREEN_SPACE_AA_DISABLED
		)
		viewport.root.use_taa = false
		viewport.root.positional_shadow_atlas_size = shadow_size_for_preset()
		viewport.root.positional_shadow_atlas_16_bits = true
	# The LOD bias is consumed by the LODManager and the streamer through this project
	# setting so that both of them read a single source of truth.
	ProjectSettings.set_setting("game/quality/lod_bias", lod_bias)
	ProjectSettings.set_setting("game/quality/prop_density", prop_density_for_preset())


## Serialises the preset to be stored in the settings file.
func to_dictionary() -> Dictionary:
	return {
		"preset": preset,
		"lod_bias": lod_bias_for_preset(),
		"shadows": shadows_enabled,
		"glow": glow_enabled,
		"traffic": traffic_for_preset(),
		"chunks": chunks_for_preset(),
	}


## Restores a preset from the settings file. Unknown keys are ignored.
func from_dictionary(data: Dictionary) -> void:
	if data.has("preset"):
		preset = clampi(int(data["preset"]), 0, 2)
	if data.has("shadows"):
		shadows_enabled = bool(data["shadows"])
	if data.has("glow"):
		glow_enabled = bool(data["glow"])
