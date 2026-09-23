extends Node3D
class_name WorldGenerator
## Creates the world: sun and sky, the concrete slab, the streamed city, the road graph and
## the skyline impostors.
##
## This is the only node the game scene needs. It is also the place where the world seed
## enters the game, which is what makes a run reproducible: the same seed produces the same
## city, the same prop layout and the same parking spots, on a phone and in a headless test.

signal world_ready(seed_value: int, statistics: Dictionary)

## Distance at which the shadow of the sun stops being drawn. A phone cannot afford a big
## shadow atlas, so the sun is a "near" light: everything further away gets its grounding
## from the ambient occlusion-like contact shadow of the car and from the fog.
const SHADOW_MAX_DISTANCE := 62.0

var seed_value: int = 20240923
var world_config: WorldConfig
var graphics_config: GraphicsConfig
var materials: MaterialLibrary
var layout: DistrictLayout
var road_graph: RoadGraph
var streamer: WorldStreamer
var environment_node: WorldEnvironment
var sun: DirectionalLight3D

var _skyline_nodes: int = 0
var _ready_emitted: bool = false


func _ready() -> void:
	if world_config == null:
		world_config = load("res://resources/config/world_config.tres") as WorldConfig
	if world_config == null:
		world_config = WorldConfig.new()
	if graphics_config == null:
		graphics_config = load("res://resources/config/graphics_config.tres") as GraphicsConfig
	if graphics_config == null:
		graphics_config = GraphicsConfig.new()
	# The player's choice wins over the project default when the settings autoload exists.
	var settings := get_node_or_null("/root/SettingsManager")
	if settings != null and settings.graphics is GraphicsConfig:
		graphics_config = settings.graphics


## Builds everything. `seed_override` 0 means "use the configured seed".
func generate(seed_override: int = 0) -> Dictionary:
	if seed_override != 0:
		seed_value = seed_override
	materials = MaterialLibrary.new()
	layout = DistrictLayout.new(seed_value, world_config)
	road_graph = RoadGraph.new()
	road_graph.build(layout, world_config)

	_build_environment()

	streamer = WorldStreamer.new()
	streamer.name = "WorldStreamer"
	add_child(streamer)
	streamer.setup(layout, materials, world_config)
	_skyline_nodes = streamer.build_skyline()

	var statistics := {
		"seed": seed_value,
		"chunk_size": world_config.chunk_size,
		"chunks": world_config.chunk_count(),
		"concrete_radius": world_config.effective_concrete_radius(),
		"skyline_blocks": _skyline_nodes,
		"road_nodes": road_graph.graph.get_point_count(),
		"blocks": world_config.block_count(),
	}
	if not _ready_emitted:
		_ready_emitted = true
		world_ready.emit(seed_value, statistics)
	return statistics


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	# A slightly hazy noon sky reads well on a phone screen: bright enough to show the
	# shapes, flat enough that the fog blends into it.
	sky_material.sky_top_color = Color(0.29, 0.46, 0.72)
	sky_material.sky_horizon_color = Color(0.72, 0.78, 0.84)
	sky_material.ground_bottom_color = Color(0.24, 0.25, 0.26)
	sky_material.ground_horizon_color = Color(0.6, 0.62, 0.62)
	sky_material.sun_angle_max = 12.0
	sky_material.sun_curve = 0.12
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = graphics_config.ambient_energy
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Fog is the cheapest possible LOD trick: it hides the transition to the skyline ring.
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.72, 0.77, 0.82)
	environment.fog_light_energy = 1.0
	environment.fog_density = graphics_config.fog_density
	environment.fog_sky_affect = 0.35
	# A faint tonemap keeps the bright concrete from clipping without costing a post pass.
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_white = 4.0
	environment.adjustment_enabled = true
	environment.adjustment_contrast = 1.04
	environment.adjustment_saturation = 1.05

	environment_node = WorldEnvironment.new()
	environment_node.name = "WorldEnvironment"
	environment_node.environment = environment
	add_child(environment_node)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = graphics_config.shadows_enabled
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = minf(graphics_config.shadow_distance_for_preset(), SHADOW_MAX_DISTANCE)
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.4
	# Late morning sun, angled so that the streets get long shadows and the façades get a
	# readable light/shadow split.
	sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	add_child(sun)


## Applies a graphics preset at runtime (the settings screen calls this).
func apply_graphics(graphics: GraphicsConfig) -> void:
	graphics_config = graphics
	if sun != null:
		sun.shadow_enabled = graphics.shadows_enabled
		sun.directional_shadow_max_distance = minf(
			graphics.shadow_distance_for_preset(), SHADOW_MAX_DISTANCE
		)
	if environment_node != null and environment_node.environment != null:
		environment_node.environment.fog_density = graphics.fog_density
		environment_node.environment.ambient_light_energy = graphics.ambient_energy
	if streamer != null:
		streamer.lod_manager.lod_bias = graphics.lod_bias_for_preset()
		streamer.prop_density = graphics.prop_density_for_preset() * world_config.prop_density
		streamer.max_resident = graphics.chunks_for_preset()
		streamer.reflow_all()


## Player spawn transform.
func spawn_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, layout.spawn_rotation()), layout.spawn_position())


## Streaming entry point used by the game world every frame.
func update_streaming(center: Vector3, delta: float) -> void:
	if streamer != null:
		streamer.update_streaming(center, delta)


func debug_string() -> String:
	if streamer == null:
		return "world not generated"
	return (
		"seed=%d blocks=%d %s" % [seed_value, world_config.block_count(), streamer.debug_string()]
	)
