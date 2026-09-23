class_name WorldChunk
extends Node3D
## Один чанк мира: два меша (рядом/издалека), коллизия, окклюдер, толпа малых форм.
##
## Узел стоит в мировой позиции origin чанка, ВСЯ геометрия локальная — см. шапку
## ChunkBuilder. Поэтому при выгрузке достаточно `queue_free()`, а «переезд» чанка
## (например, после правки конфига) = перестановка `position`, без пересборки вершин.
##
## ЛОДЫ (переключаются стримером по дистанции, см. WorldStreamer.update_lods):
##   LOD_NEAR   — подробный меш + малые формы (MultiMesh) + коллизия мелочи;
##   LOD_MID    — подробный меш без малых форм (экономия на вершинах и state-переключениях);
##   LOD_FAR    — только силуэты (unshaded) — «город на горизонте» за 15-20 fps;
##   LOD_HIDDEN — ничего не рисуется, коллизия остаётся (машина не должна провалиться,
##                если игрок развернулся к чанку спиной).
## Переход рядом->издалека сглажен `visibility_range_*` + pixel-dither у инстансов:
## именно поэтому «появление домов» не выглядит щелчком.

const LOD_NEAR := 0
const LOD_MID := 1
const LOD_FAR := 2
const LOD_HIDDEN := 3

var index: Vector2i = Vector2i.ZERO
var origin: Vector3 = Vector3.ZERO
var size: float = 200.0
var lod: int = -1
var data: Dictionary = {}
var near_instance: MeshInstance3D = null
var far_instance: MeshInstance3D = null
var prop_instances: Array[MultiMeshInstance3D] = []
var body: StaticBody3D = null
var occluder_instance: OccluderInstance3D = null
var triangle_count: int = 0
var instance_count: int = 0
var built_ms: float = 0.0

## Собрать содержимое из результата ChunkBuilder.build().
func apply_data(p_data: Dictionary, cfg: WorldConfig) -> void:
	data = p_data
	index = p_data.get("chunk", Vector2i.ZERO)
	origin = p_data.get("origin", Vector3.ZERO)
	size = float(p_data.get("size", cfg.chunk_size_m))
	position = origin
	name = "Chunk_%d_%d" % [index.x, index.y]

	var stats: Dictionary = p_data.get("stats", {})
	# Основа: плоскость земли + физика.
	_build_collision(p_data, cfg)
	_build_occluder(p_data, cfg)
	near_instance = MeshInstance3D.new()
	near_instance.name = "Near"
	near_instance.mesh = p_data.get("near") as ArrayMesh
	near_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	near_instance.extra_cull_margin = 8.0
	add_child(near_instance)
	far_instance = MeshInstance3D.new()
	far_instance.name = "Far"
	far_instance.mesh = p_data.get("far") as ArrayMesh
	far_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	far_instance.extra_cull_margin = 24.0
	add_child(far_instance)
	_build_props(cfg)
	triangle_count = int(stats.get("collision_triangles", 0)) + _mesh_triangles(near_instance.mesh)
	instance_count = int(stats.get("prop_instances", 0))
	set_lod(LOD_NEAR)

func _mesh_triangles(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(i)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		total += indices.size() / 3 if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size() / 3
	return total

func _build_collision(p_data: Dictionary, cfg: WorldConfig) -> void:
	body = StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = maxi(cfg.collision_layer, 1)
	body.collision_mask = 0
	add_child(body)
	# Плита под чанком: тонкая, но не нулевая — иначе вывернутые лучи «сквозь пол».
	var plate := CollisionShape3D.new()
	plate.name = "Plate"
	var box := BoxShape3D.new()
	var aabb: AABB = p_data.get("plate_aabb", AABB(Vector3(0.0, -1.0, 0.0), Vector3(size, 1.0, size)))
	box.size = Vector3(maxf(aabb.size.x, 1.0), maxf(aabb.size.y, 0.5), maxf(aabb.size.z, 1.0))
	plate.shape = box
	plate.position = aabb.get_center() + Vector3(0.0, 0.25, 0.0)
	body.add_child(plate)
	var triangles: PackedVector3Array = p_data.get("collision_triangles", PackedVector3Array())
	if triangles.size() >= 3:
		var walls := CollisionShape3D.new()
		walls.name = "Walls"
		var concave := ConcavePolygonShape3D.new()
		concave.data = triangles
		concave.backface_collision = false
		walls.shape = concave
		body.add_child(walls)
	# Малые формы — отдельное тело на слое «Prop»: тогда у камеры и машин можно
	# включать/выключать реакцию на столбы и деревья одной маской в конфиге.
	var prop_triangles: PackedVector3Array = p_data.get("prop_collision_triangles", PackedVector3Array())
	if prop_triangles.size() >= 3:
		var prop_body := StaticBody3D.new()
		prop_body.name = "Props"
		prop_body.collision_layer = maxi(cfg.prop_collision_layer, 1)
		prop_body.collision_mask = 0
		add_child(prop_body)
		var prop_shape := CollisionShape3D.new()
		prop_shape.name = "PropShapes"
		var prop_concave := ConcavePolygonShape3D.new()
		prop_concave.data = prop_triangles
		prop_concave.backface_collision = false
		prop_shape.shape = prop_concave
		prop_body.add_child(prop_shape)

func _build_occluder(p_data: Dictionary, cfg: WorldConfig) -> void:
	if not cfg.build_occluders or not PerformanceManager.occluders_enabled():
		return
	var points: PackedVector3Array = p_data.get("occluder_points", PackedVector3Array())
	# BuildingKit складывает в окклюдер готовые треугольники (3 вершины на полигон).
	var tri_count: int = int(points.size() / 3)
	if tri_count <= 0:
		return
	var verts: PackedVector3Array = points.slice(0, tri_count * 3)
	var idx: PackedInt32Array = PackedInt32Array()
	idx.resize(verts.size())
	for i in verts.size():
		idx[i] = i
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	occluder_instance = OccluderInstance3D.new()
	occluder_instance.name = "Occluder"
	occluder_instance.occluder = occ
	add_child(occluder_instance)

func _build_props(cfg: WorldConfig) -> void:
	var props: Dictionary = data.get("prop_instances", {})
	for kind in props.keys():
		var bucket: Dictionary = props[kind]
		var parts: Array = PropMeshes.parts(String(kind))
		if parts.is_empty():
			continue
		var transforms: Array = bucket.get("transforms", [])
		var part_transforms: Dictionary = bucket.get("part_transforms", {})
		var colors: PackedColorArray = bucket.get("colors", PackedColorArray())
		for part in parts:
			var part_name := String(part.get("part_name", ""))
			var source: Array = part_transforms.get(part_name, transforms)
			if source.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = not colors.is_empty() and String(part.get("material", "")) == "car_paint"
			mm.use_custom_data = false
			mm.instance_count = source.size()
			for i in range(source.size()):
				mm.set_instance_transform(i, source[i] as Transform3D)
				if mm.use_colors and i < colors.size():
					mm.set_instance_color(i, colors[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Props_%s_%s" % [kind, part_name]
			mmi.multimesh = mm
			mmi.mesh = part.get("mesh") as Mesh
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			# Плавное исчезновение мелочи на пределе «подробной» дистанции: dither, а не pop-in.
			mmi.visibility_range_end = maxf(cfg.detail_distance_m * PerformanceManager.cull_distance_multiplier(), 60.0)
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_MODE_PIXEL_DITHER
			mmi.visibility_range_hysteresis = 0.15
			add_child(mmi)
			prop_instances.append(mmi)

func set_lod(value: int) -> void:
	if value == lod:
		return
	lod = clampi(value, LOD_NEAR, LOD_HIDDEN)
	if near_instance != null:
		near_instance.visible = lod == LOD_NEAR or lod == LOD_MID
	if far_instance != null:
		far_instance.visible = lod == LOD_FAR
	for mmi in prop_instances:
		mmi.visible = lod == LOD_NEAR
		if lod != LOD_NEAR:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func is_built() -> bool:
	return near_instance != null

func distance_to_point(point: Vector3) -> float:
	var local := point - global_position
	var clamped := Vector3(
		clampf(local.x, 0.0, size), 0.0, clampf(local.z, 0.0, size)
	)
	return local.distance_to(clamped)

## Полная выгрузка: меш-ресурсы общие (кэш PropMeshes/CarGeometry), удаляем только узлы.
func unload() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	near_instance = null
	far_instance = null
	prop_instances.clear()
	body = null
	occluder_instance = null
	lod = -1
	data = {}

func status_line() -> String:
	return "чанк[%d,%d] lod=%d tris=%d инстансов=%d build=%.1fмс" % [index.x, index.y, lod, triangle_count, instance_count, built_ms]
