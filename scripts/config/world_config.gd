extends Resource
class_name WorldConfig
## Layout of the open world. The world is a fixed-size city district standing on one huge
## concrete slab: the player always spawns at the centre and concrete extends
## `concrete_radius` metres in every direction (500 m by default).
##
## Every value here is procedural input: change it and the whole city, its roads, its
## props, the road graph and the streaming layout follow automatically.

@export_group("Extent")
## Side of the square world in metres. Roads and buildings are generated inside it.
@export_range(200.0, 4000.0, 10.0) var world_size: float = 1000.0
## Radius of the concrete slab around the spawn point, in metres (500 m in all
## directions).
@export_range(50.0, 2000.0, 10.0) var concrete_radius: float = 500.0
## Side of one streamed chunk in metres. Must divide the world evenly for a tidy grid.
@export_range(20.0, 500.0, 5.0) var chunk_size: float = 125.0
## Height of the concrete ground surface. Roads sit exactly on top of it.
@export_range(-20.0, 20.0, 0.01) var ground_height: float = 0.0
## Extra grid outside the playable area used for the distant skyline impostors.
@export_range(0, 4, 1) var skyline_rings: int = 2

@export_group("Streets")
## Distance between two road centre lines, in metres.
@export_range(40.0, 400.0, 5.0) var block_pitch: float = 125.0
## Width of a street including both directions.
@export_range(6.0, 40.0, 0.5) var road_width: float = 13.0
## Width of a pavement running along every street.
@export_range(0.5, 12.0, 0.25) var sidewalk_width: float = 4.0
## Height of the kerb above the road.
@export_range(0.0, 0.6, 0.01) var kerb_height: float = 0.15
## Number of painted lanes per direction.
@export_range(1, 4, 1) var lanes_per_direction: int = 2

@export_group("Buildings")
## Inner margin kept free between the pavement and the first façade.
@export_range(0.0, 20.0, 0.5) var building_margin: float = 1.5
## Minimum number of floors of a generated building.
@export_range(1, 30, 1) var min_floors: int = 2
## Maximum number of floors of a generated building.
@export_range(1, 60, 1) var max_floors: int = 14
## Height of one floor in metres.
@export_range(2.0, 6.0, 0.05) var floor_height: float = 3.35
## Chance (0..1) that a city block is a park instead of buildings.
@export_range(0.0, 0.5, 0.01) var park_chance: float = 0.12
## Chance (0..1) that a city block is a parking lot / industrial yard.
@export_range(0.0, 0.5, 0.01) var yard_chance: float = 0.1
## Chance (0..1) that a block corner gets a ground-floor shop with an awning.
@export_range(0.0, 1.0, 0.02) var shop_chance: float = 0.55

@export_group("Detail density")
## Overall multiplier for props (lamps, benches, trees, bins, barriers...).
@export_range(0.0, 3.0, 0.05) var prop_density: float = 1.0
## Distance between two street lamps along a road.
@export_range(8.0, 120.0, 1.0) var lamp_spacing: float = 26.0
## Chance that a street tree is placed on a pavement segment.
@export_range(0.0, 1.0, 0.02) var tree_chance: float = 0.28
## Number of parked cars per block, scaled by prop_density.
@export_range(0, 40, 1) var parked_cars_per_block: int = 6
## Enable/disable small props entirely (useful for the low graphics preset).
@export var enable_small_props: bool = true

@export_group("Streaming")
## Radius in metres around the player in which chunks are fully generated.
@export_range(100.0, 2000.0, 10.0) var stream_radius: float = 560.0
## Radius in metres in which chunks keep collision and physics bodies.
@export_range(50.0, 1000.0, 10.0) var collision_radius: float = 300.0
## Number of chunks that may be generated per frame (budget per frame).
@export_range(1, 16, 1) var build_budget_per_frame: int = 2
## Seconds a chunk stays alive after the player left the stream radius.
@export_range(0.0, 60.0, 0.5) var chunk_keep_alive_time: float = 6.0
## Maximum number of chunks kept in memory at the same time.
@export_range(9, 400, 1) var max_resident_chunks: int = 160

@export_group("Level of detail")
## Distance (m) up to which the highest detail meshes are used.
@export_range(20.0, 600.0, 5.0) var lod0_distance: float = 165.0
## Distance (m) up to which the medium detail meshes are used.
@export_range(40.0, 1200.0, 5.0) var lod1_distance: float = 400.0
## Distance (m) up to which the cheap silhouette meshes are used. Everything further away
## is represented by the skyline impostor ring and the fog.
@export_range(60.0, 4000.0, 10.0) var lod2_distance: float = 900.0
## Extra multiplier applied by the PerformanceManager when the frame rate drops.
@export_range(0.3, 1.5, 0.05) var lod_bias: float = 1.0
## Distance at which the fog fully hides the ground plane.
@export_range(100.0, 4000.0, 10.0) var fog_distance: float = 760.0
## Height above the ground at which the distant skyline blocks are placed.
@export_range(0.0, 200.0, 1.0) var skyline_distance: float = 1150.0

@export_group("Traffic")
## Maximum number of ambient traffic cars alive at once.
@export_range(0, 60, 1) var max_traffic_cars: int = 14
## Radius around the player in which traffic is allowed to exist.
@export_range(50.0, 800.0, 10.0) var traffic_radius: float = 260.0
## Seconds between two traffic spawn attempts.
@export_range(0.2, 20.0, 0.1) var traffic_spawn_interval: float = 1.4


## World size in chunks (x and z).
func chunk_count() -> int:
	return int(round(world_size / chunk_size))


## World centre (the spawn point).
func world_center() -> Vector3:
	return Vector3(0.0, ground_height, 0.0)


## Number of blocks along one axis.
func block_count() -> int:
	return int(round(world_size / block_pitch))


## The concrete slab never extends beyond this radius regardless of the world size.
func effective_concrete_radius() -> float:
	return minf(concrete_radius, world_size * 0.5 + chunk_size)


## Converts a world position into chunk coordinates.
func chunk_coords(world_pos: Vector3) -> Vector2i:
	var cx := int(floor(world_pos.x / chunk_size + float(chunk_count()) * 0.5))
	var cz := int(floor(world_pos.z / chunk_size + float(chunk_count()) * 0.5))
	return Vector2i(cx, cz)


## Centre of the chunk at the given coordinates.
func chunk_origin(coords: Vector2i) -> Vector3:
	var half := float(chunk_count()) * 0.5
	return Vector3(
		(float(coords.x) - half + 0.5) * chunk_size,
		ground_height,
		(float(coords.y) - half + 0.5) * chunk_size
	)


## True when the chunk coordinates are inside the played area.
func is_inside_world(coords: Vector2i) -> bool:
	var n := chunk_count()
	return coords.x >= 0 and coords.y >= 0 and coords.x < n and coords.y < n


## True when the given world position is inside the played area.
func contains_position(world_pos: Vector3) -> bool:
	var limit := world_size * 0.5
	return absf(world_pos.x) <= limit and absf(world_pos.z) <= limit
