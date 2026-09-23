class_name ChunkBuilder
extends RefCounted
## Планировка чанка -> готовые меш-ресурсы, коллизия, окклюдеры и экземпляры малых форм.
##
## Чанк = узел-родитель в мировой позиции (origin, 0, origin); ВСЯ геометрия локальная.
## Это даёт: (1) точность float32 рядом с камерой вместо «мерцания» на 500 м от нуля,
## (2) дешёвый AABB-фрустум-коллинг, (3) возможность собрать чанк заранее и не трогать
## трансформанты детей при стриминге.
##
## ТИРЫ ЛОДОВ (см. docs/WORLD.md):
##   near — асфальт/плиты/тротуары/бордюры + дома со всей детализацией + малые формы;
##   far  — силуэты домов (unshaded, 1 квад на грань) + грунт без разметки.
## Оба строятся за ОДИН проход по планировке: переключать LOD = менять видимость узлов,
## а не пересобирать геометрию (иначе при въезде в чанк был бы фриз на полсекунды).
##
## КОЛЛИЗИЯ: один ConcavePolygonShape3D на чанк (стены домов, бордюры, твёрдые малые формы)
## + одна «плита» BoxShape3D под всем. Никаких сотен StaticBody3D на деревья: на
## GodotPhysics broadphase от них дороже, чем выгода.
##
## РАЗМЕТКА рисуется ПОВЕРХ АСФАЛЬТА отдельной поверхностью на +5.6 см — с метрическими UV
## и собственной шероховатостью; при таком раскладе «краска по асфальту» выглядит как
## настоящая (асфальт под ней проступает микрорельефом через normal map разметки).

const GROUND_MATERIAL_BY_SURFACE := {
	&"road": "asphalt",
	&"concrete": "concrete",
	&"sidewalk": "sidewalk",
	&"lot": "asphalt_dark",
	&"yard": "asphalt_dark",
	&"park": "grass",
}
## Малые формы, в которые больно въезжать (получают треугольники коллизии).
const HARD_PROPS := ["tree", "dumpster", "barrier", "bench", "planter", "hydrant", "lamp", "fence", "bollard", "traffic_light",
	"rooftop_unit"]
## Что можно снести без последствий (конусы, урны) — только визуал.
const SOFT_PROPS := ["cone", "bin", "sign"]
const CAR_PAINT_PALETTE := [
	Color(0.72, 0.73, 0.75), Color(0.10, 0.11, 0.13), Color(0.30, 0.42, 0.60),
	Color(0.55, 0.07, 0.06), Color(0.08, 0.20, 0.36), Color(0.62, 0.60, 0.55),
	Color(0.13, 0.26, 0.16), Color(0.80, 0.66, 0.12), Color(0.35, 0.36, 0.40),
	Color(0.86, 0.86, 0.88), Color(0.20, 0.05, 0.05), Color(0.05, 0.06, 0.07),
]

## Основной вход.
static func build(chunk: Vector2i, cfg: WorldConfig, include_props: bool) -> Dictionary:
	var layout := WorldGenerator.chunk_layout(chunk, cfg)
	var ground_y := cfg.ground_y_m
	var builders := _builders({})
	var far_builders := _builders({"far_building": {}, "concrete": {}})
	var sink := BuildingKit.Sink.new()
	sink.occluder_left = int(cfg.occluders_per_chunk_max) if (cfg.build_occluders and PerformanceManager.occluders_enabled()) else 0
	## Коллизия малых форм — отдельное тело на слое «Prop».
	var prop_sink := BuildingKit.Sink.new()
	var tri_count := 0

	# 1) Грунт: прямоугольники поверхностей, разметка, бордюры.
	var ground: Array = layout["ground"]
	for entry in ground:
		var rect: Rect2 = entry["rect"]
		var y := ground_y + float(entry["y"])
		var surface := StringName(entry["surface"])
		var material := String(GROUND_MATERIAL_BY_SURFACE.get(surface, "asphalt_dark"))
		var builder := _b(builders, material)
		builder.add_flat_rect(rect, y, true)
		if surface == &"sidewalk":
			# Бордюр: 4 стенки от асфальта до тротуара + коллизия (на него можно наехать).
			var curb := _b(builders, "curb")
			var top := ground_y + cfg.curb_height_m
			curb.add_flat_rect(rect, top + 0.001, true)
			_add_curb_walls(curb, sink, rect, ground_y, cfg.curb_height_m)
			_far_box(far_builders, rect, ground_y, top)
	# Разметка.
	var markings: Array = layout["markings"]
	var marking_builder := _b(builders, "road_marking")
	for entry in markings:
		var rect: Rect2 = entry["rect"]
		var y := ground_y + float(entry.get("y", 0.05))
		var rot := float(entry.get("rot", 0.0))
		if absf(rot) < 0.0005:
			marking_builder.add_flat_rect(rect, y, true)
		else:
			_rotated_flat(marking_builder, rect, y, rot)

	# 2) Здания: ближний LOD — полностью, дальний — силуэт.
	var buildings: Array = layout["buildings"]
	for entry in buildings:
		BuildingKit.add_building(builders, entry, cfg, sink, true)
		var footprint: Rect2 = entry["footprint"]
		var height := maxf(float(entry.get("height", 6.0)), 1.2)
		_far_box(far_builders, footprint, ground_y, ground_y + height + 0.35)
		tri_count += 10

	# 3) Малые формы -> MultiMesh-экземпляры.
	var prop_instances := {}
	if include_props:
		prop_instances = _collect_props(layout["props"] as Array, ground_y, prop_sink, cfg)

	# 4) Сборка мешей.
	var near_mesh := ArrayMesh.new()
	var near_materials := PackedStringArray()
	for material in _sorted_keys(builders):
		var builder: MeshBuilder = builders[material]
		if builder.has_geometry():
			builder.commit(near_mesh)
			near_materials.append(material)
	var far_mesh := ArrayMesh.new()
	var far_materials := PackedStringArray()
	for material in _sorted_keys(far_builders):
		var builder: MeshBuilder = far_builders[material]
		if builder.has_geometry():
			builder.commit(far_mesh)
			far_materials.append(material)

	var size: float = layout["size"]
	var origin_v3: Vector3 = layout["origin"]
	return {
		"chunk": chunk,
		"origin": origin_v3,
		"size": size,
		"near": near_mesh,
		"near_materials": near_materials,
		"far": far_mesh,
		"far_materials": far_materials,
		"collision_triangles": sink.collision,
		"prop_collision_triangles": prop_sink.collision,
		"occluder_points": sink.occluder,
		"prop_instances": prop_instances,
		"plate_aabb": AABB(Vector3(0.0, ground_y - 1.0, 0.0), Vector3(size, 1.0, size)),
		"aabb": AABB(Vector3(0.0, ground_y - 1.0, 0.0), Vector3(size, 260.0, size)),
		"stats": {
			"buildings": buildings.size(),
			"ground_quads": ground.size(),
			"markings": markings.size(),
			"collision_triangles": sink.collision.size() / 3 + prop_sink.collision.size() / 3,
			"occluder_triangles": sink.occluder.size() / 3,
			"prop_instances": _count_instances(prop_instances),
			"near_surfaces": near_materials.size(),
			"far_surfaces": far_materials.size(),
		},
	}

static func _count_instances(prop_instances) -> int:
	var total := 0
	if prop_instances is Dictionary:
		for kind in prop_instances.keys():
			total += int((prop_instances[kind] as Dictionary).get("count", 0))
	return total

# ------------------------------------------------------------------ вспомогательное

static func _builders(seed: Dictionary) -> Dictionary:
	var out := {}
	for material in seed.keys():
		out[material] = null
	return out

static func _b(builders: Dictionary, material: String) -> MeshBuilder:
	if not builders.has(material):
		var builder := MeshBuilder.new(Vector3.ZERO, 1.0)
		builders[material] = builder
		return builder
	var existing = builders[material]
	if existing == null:
		existing = MeshBuilder.new(Vector3.ZERO, 1.0)
		builders[material] = existing
	return existing

static func _sorted_keys(builders: Dictionary) -> Array:
	var keys: Array = []
	for key in builders.keys():
		if builders[key] != null and (builders[key] as MeshBuilder).has_geometry():
			keys.append(key)
	keys.sort()
	return keys

## Прямоугольник в силуэт дальнего LOD: 5 граней (без дна).
static func _far_box(builders: Dictionary, rect: Rect2, y0: float, y1: float) -> void:
	var builder := _b(builders, "far_building")
	builder.set_ref(Vector3(rect.get_center().x, (y0 + y1) * 0.5, rect.get_center().y))
	var p := rect.position
	var e := rect.end
	var a := Vector3(p.x, y0, p.y)
	var b := Vector3(e.x, y0, p.y)
	var c := Vector3(e.x, y1, p.y)
	var d := Vector3(p.x, y1, p.y)
	var a2 := Vector3(p.x, y0, e.y)
	var b2 := Vector3(e.x, y0, e.y)
	var c2 := Vector3(e.x, y1, e.y)
	var d2 := Vector3(p.x, y1, e.y)
	builder.add_quad(a, b, c, d)
	builder.add_quad(b2, a2, d2, c2)
	builder.add_quad(b2, b, c, c2)
	builder.add_quad(a2, d, c2, d2)  # нормаль развернёт ref_center
	builder.add_quad(a2, a, d, d2)
	var roof := _b(builders, "concrete")
	roof.add_flat_rect(rect, y1 + 0.02, false)

## Бордюр: 4 стенки + коллизия. Двойные стенки на соседних тротуарах слипаются —
## это нормально (z-buffer решает), а вот пропускать «внутреннюю» грань нельзя:
## машина должна упираться в бордюр со стороны дороги.
static func _add_curb_walls(builder: MeshBuilder, sink: BuildingKit.Sink, rect: Rect2, y0: float, height: float) -> void:
	if height <= 0.02:
		return
	var p := rect.position
	var e := rect.end
	var y1 := y0 + height
	builder.set_ref(Vector3(rect.get_center().x, (y0 + y1) * 0.5, rect.get_center().y))
	var corners: Array[Vector3] = [
		Vector3(p.x, y0, p.y), Vector3(e.x, y0, p.y), Vector3(e.x, y0, e.y), Vector3(p.x, y0, e.y),
	]
	for i in range(4):
		var j := (i + 1) % 4
		var lo := corners[i]
		var hi := corners[j]
		builder.add_quad(Vector3(lo.x, y0, lo.z), Vector3(hi.x, y0, hi.z), Vector3(hi.x, y1, hi.z), Vector3(lo.x, y1, lo.z))
		sink.collision.append(Vector3(lo.x, y0, lo.z))
		sink.collision.append(Vector3(hi.x, y0, hi.z))
		sink.collision.append(Vector3(hi.x, y1, hi.z))
		sink.collision.append(Vector3(lo.x, y0, lo.z))
		sink.collision.append(Vector3(hi.x, y1, hi.z))
		sink.collision.append(Vector3(lo.x, y1, lo.z))

## Повёрнутая плоская разметка (дуги «полигона», косые карманы).
static func _rotated_flat(builder: MeshBuilder, rect: Rect2, y: float, rot: float) -> void:
	var center := rect.get_center()
	var half := rect.size * 0.5
	var ca := cos(rot)
	var sa := sin(rot)
	var pts: Array[Vector2] = []
	for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		pts.append(center + Vector2(corner.x * ca - corner.y * sa, corner.x * sa + corner.y * ca))
	var v0 := Vector3(pts[0].x, y, pts[0].y)
	var v1 := Vector3(pts[1].x, y, pts[1].y)
	var v2 := Vector3(pts[2].x, y, pts[2].y)
	var v3 := Vector3(pts[3].x, y, pts[3].y)
	builder.add_quad_uv(v0, v1, v2, v3, Vector3.UP, rect.position, rect.size)

static func _collect_props(props: Array, ground_y: float, sink: BuildingKit.Sink, _cfg: WorldConfig) -> Dictionary:
	var out := {}
	for entry in props:
		var kind := String(entry["type"])
		if kind.is_empty():
			continue
		var pos: Vector3 = entry["pos"]
		var rot := float(entry.get("rot", 0.0))
		var prop_scale := float(entry.get("scale", 1.0))
		var base := Vector3(pos.x, ground_y + absf(pos.y) if kind != "rooftop_unit" else pos.y, pos.z)
		var xform := Transform3D(Basis.from_euler(Vector3(0.0, rot, 0.0)) * Basis.from_scale(Vector3.ONE * prop_scale), base)
		var bucket: Dictionary = out.get(kind, {"transforms": [], "part_transforms": {}, "colors": PackedColorArray(), "count": 0})
		(bucket["transforms"] as Array).append(xform)
		bucket["count"] = int(bucket["count"]) + 1
		var tint := clampf(float(entry.get("tint", 0.5)), 0.0, 0.9999)
		if kind == "parked_car":
			bucket["colors"] = (bucket["colors"] as PackedColorArray) + [CAR_PAINT_PALETTE[int(tint * float(CAR_PAINT_PALETTE.size())) % CAR_PAINT_PALETTE.size()]]  # gdlint: ignore=max-line-length
			# Колёса припаркованной машины — отдельный «part» со своими 4 инстансами.
			var wheels: Array = bucket["part_transforms"].get("wheel", [])
			for offset in PropMeshes.parked_car_wheel_offsets():
				var rotated := Basis.from_euler(Vector3(0.0, rot, 0.0)) * (offset * prop_scale)
				wheels.append(Transform3D(Basis.from_euler(Vector3(0.0, rot, 0.0)) * Basis.from_scale(Vector3.ONE * prop_scale),
					base + rotated))
			bucket["part_transforms"]["wheel"] = wheels
		out[kind] = bucket
		if kind in HARD_PROPS:
			var half := _prop_half_extents(kind, prop_scale)
			if half != Vector3.ZERO:
				_box_to_sink(sink, base + Vector3(0.0, half.y, 0.0), half)
	return out

static func _prop_half_extents(kind: String, scale: float) -> Vector3:
	match kind:
		"tree":
			return Vector3(0.55, 2.0, 0.55) * scale
		"lamp":
			return Vector3(0.32, 3.1, 0.6) * scale
		"dumpster":
			return Vector3(1.3, 0.72, 0.7) * scale
		"barrier":
			return Vector3(1.05, 0.48, 0.2) * scale
		"bench":
			return Vector3(0.85, 0.35, 0.3) * scale
		"planter":
			return Vector3(0.7, 0.3, 0.7) * scale
		"hydrant":
			return Vector3(0.25, 0.4, 0.25) * scale
		"fence":
			return Vector3(1.25, 0.7, 0.1) * scale
		"bollard":
			return Vector3(0.15, 0.42, 0.15) * scale
		"traffic_light":
			return Vector3(0.3, 2.0, 0.3) * scale
	return Vector3.ZERO

static func _box_to_sink(sink: BuildingKit.Sink, center: Vector3, half: Vector3) -> void:
	# 12 треугольников: коробка без «дна». Дешевле отдельного StaticBody3D на каждый объект.
	var a := center - half
	var b := center + half
	var v: Array[Vector3] = [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	sink.quad(v[1], v[0], v[3], v[2])
	sink.quad(v[4], v[5], v[6], v[7])
	sink.quad(v[5], v[1], v[2], v[6])
	sink.quad(v[0], v[4], v[7], v[3])
	sink.quad(v[2], v[3], v[7], v[6])

## Отчёт для автотестов/отладки: ничего не должно быть нулевым в «городском» чанке.
static func self_check(chunk: Vector2i, cfg: WorldConfig) -> PackedStringArray:
	var problems := PackedStringArray()
	var data := build(chunk, cfg, true)
	var stats: Dictionary = data["stats"]
	if (data["near"] as ArrayMesh) == null:
		problems.append("чанк %s: нет ближнего меша" % chunk)
	elif (data["near"] as ArrayMesh).get_surface_count() < 3:
		problems.append("чанк %s: слишком мало поверхностей (%d)" % [chunk, (data["near"] as ArrayMesh).get_surface_count()])
	if int(stats.get("collision_triangles", 0)) <= 0:
		problems.append("чанк %s: нет коллизии" % chunk)
	if int(stats.get("buildings", 0)) <= 0:
		problems.append("чанк %s: нет застройки — похоже на пустой прототип" % chunk)
	if int(stats.get("prop_instances", 0)) <= 0:
		problems.append("чанк %s: нет малых форм" % chunk)
	return problems
