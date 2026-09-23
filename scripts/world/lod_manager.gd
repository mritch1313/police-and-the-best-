extends RefCounted
class_name LODManager
## Decides how much detail every chunk gets.
##
## The rules are deliberately simple and predictable, because a cheap rule that is applied
## consistently looks better than a clever one that flickers:
##
##   * the LOD of a chunk is a function of the distance from the camera to the *nearest
##     point* of the chunk, not to its centre (a big chunk next to the player must not be
##     treated as far away because its centre is far)
##   * the thresholds come from the world configuration and are scaled by the quality bias
##     (low preset = shorter distances, high preset = longer ones)
##   * a chunk keeps its level until the distance leaves a 12 % hysteresis band, so a car
##     driving along a boundary does not rebuild geometry every frame
##   * the level of a chunk only ever changes by one step at a time, which keeps the cost of
##     a rebuild bounded

## Hysteresis: how far past a threshold an object has to be before it switches.
const HYSTERESIS := 1.12

var config: WorldConfig
var lod_bias: float = 1.0


func _init(p_config: WorldConfig = null) -> void:
	config = p_config if p_config != null else WorldConfig.new()


## Distance from `point` to the nearest corner of a chunk.
func distance_to_chunk(origin: Vector3, point: Vector3) -> float:
	var half := config.chunk_size * 0.5
	var dx := maxf(absf(point.x - origin.x) - half, 0.0)
	var dz := maxf(absf(point.z - origin.z) - half, 0.0)
	return sqrt(dx * dx + dz * dz)


## LOD level for a chunk at `distance`, given the level it currently has.
func level_for_distance(distance: float, current_level: int) -> int:
	var scale := maxf(lod_bias, 0.05)
	var near := config.lod0_distance * scale
	var medium := config.lod1_distance * scale
	var far := config.lod2_distance * scale
	var level := ChunkBuilder.LOD_FAR
	if distance <= near:
		level = ChunkBuilder.LOD_NEAR
	elif distance <= medium:
		level = ChunkBuilder.LOD_MEDIUM
	else:
		level = ChunkBuilder.LOD_FAR
	# Hysteresis: only switch when the distance clearly left the band of the current level.
	if current_level != ChunkBuilder.LOD_FAR and level > current_level:
		var band := near if current_level == ChunkBuilder.LOD_NEAR else medium
		if distance < band * HYSTERESIS:
			level = current_level
	elif current_level > ChunkBuilder.LOD_NEAR and level < current_level:
		var band := near if level == ChunkBuilder.LOD_NEAR else medium
		if distance > band / HYSTERESIS:
			level = current_level
	# One step at a time keeps a rebuild cheap and the transition smooth.
	return clampi(level, current_level - 1, current_level + 1) if current_level >= 0 else level


## True when a chunk at this distance should have collision.
func collision_for_distance(distance: float) -> bool:
	return distance <= config.collision_radius * maxf(lod_bias, 0.4)


## True when a chunk at this distance should be resident at all.
func resident_for_distance(distance: float) -> bool:
	return distance <= config.stream_radius * maxf(lod_bias, 0.4)


## Threshold in metres for a level (used by the tests and by the debug overlay).
func threshold_for_level(level: int) -> float:
	var scale := maxf(lod_bias, 0.05)
	match level:
		ChunkBuilder.LOD_NEAR:
			return config.lod0_distance * scale
		ChunkBuilder.LOD_MEDIUM:
			return config.lod1_distance * scale
		_:
			return config.lod2_distance * scale


## Estimated draw distance in metres (the far plane of the fog).
func draw_distance() -> float:
	return config.fog_distance
