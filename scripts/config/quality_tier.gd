class_name QualityTier
extends ConfigResource
## Один пресет качества. Три штуки (low/medium/high) собираются в [GraphicsConfig]
## и применяются [PerformanceManager]-ом. Всё, что дорого на мобильной GPU,
## выключается именно здесь: тени, масштаб рендера, дальность, плотность реквизита.

@export var display_name: String = "medium"
@export var shadows_enabled: bool = true
@export_range(256, 8192, 1) var shadow_atlas_size: int = 1024
@export_range(20.0, 400.0, 5.0) var shadow_distance_m: float = 110.0
@export_range(0.0, 5.0, 0.05) var shadow_bias: float = 0.05
@export_range(0.15, 2.0, 0.05) var rendering_scale: float = 1.0
@export_range(0, 3, 1) var msaa_3d: int = 0
@export var occlusion_culling: bool = true
@export_range(0.3, 2.0, 0.05) var lod_bias: float = 1.0
@export_range(0.05, 2.0, 0.05) var prop_density: float = 1.0
@export_range(0.2, 3.0, 0.05) var cull_distance_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var fog_density_multiplier: float = 1.0
@export var glow_enabled: bool = false
@export_range(0.0, 2.0, 0.05) var glow_intensity: float = 0.25
@export_range(0, 8, 1) var anisotropy: int = 0
@export_range(0, 4, 1) var texture_filter: int = 1
@export var sky_realtime_update: bool = false
## Сколько чанков держать в памяти (верхний предел для бюджета).
@export_range(1, 64, 1) var max_chunks: int = 9

func describe() -> String:
	return "shadows=%s(%dpx) scale=%.2f lod=%.2f props=%.2f cull=%.2f chunks=%d" % [
		display_name, shadow_atlas_size if shadows_enabled else 0, rendering_scale,
		lod_bias, prop_density, cull_distance_multiplier, max_chunks,
	]

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if rendering_scale < 0.3:
		problems.append(_problem("rendering_scale %.2f сделает картинку кашей" % rendering_scale))
	if shadow_atlas_size < 256 and shadows_enabled:
		problems.append(_problem("shadow_atlas_size слишком мал при включённых тенях"))
	if max_chunks < 4:
		problems.append(_problem("max_chunks < 4: город будет распадаться на глазах"))
	return problems
