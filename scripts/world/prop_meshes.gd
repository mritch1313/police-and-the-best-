class_name PropMeshes
extends RefCounted
## Малые формы города: фонари, деревья, урны, конусы, барьеры, скамейки, заборы,
## светофоры, контейнеры, припаркованные машины.
##
## КЛЮЧЕВАЯ ИДЕЯ: проп — это НЕ «один примитив», а НЕСКОЛЬКО примитивов движка, склеенных
## в один меш по материалам (`PrimitiveMesh.create_arrays()` + `MeshBuilder.merge_arrays`).
## Так «дерево» = ствол + 3 шапки листвы, «фонарь» = основание + столб + кронштейн + лампа,
## а рисуется при этом одним MultiMesh-инстансом. «Одними кубиками» здесь и не пахнет:
## примитивы — только детали составных моделей (см. раздел «Архитектура» в README).
##
## Почему MultiMesh, а не отдельные сцены: 34 припаркованные машины + 26 фонарей + 22 дерева
## на чанк = ~200 объектов. Как узлы это 200 draw call'ов и 200 записей в дереве; как
## MultiMesh — 2-6 вызовов отрисовки на чанк. На Mali-G52 разница буквально в разы.
##
## Кэш статический и глобальный: меш генерируется ОДИН раз на тип, чанки его только
## инстансируют. Меши не содержат трансформации — позиция/поворот/масштаб живут в
## MultiMesh, поэтому один и тот же меш годится для любого чанка.

const CACHE_KEY_PREFIX := "prop:"

static var _cache: Dictionary = {}

static func reset() -> void:
	_cache = {}

static func kinds() -> PackedStringArray:
	return PackedStringArray([
		"lamp", "tree", "bin", "dumpster", "cone", "barrier", "bench", "traffic_light",
		"fence", "rooftop_unit", "bollard", "planter", "hydrant", "sign", "parked_car",
	])

## Части пропа: [{part_name, material, mesh, tint, color_kind}].
## `color_kind` == "car" -> инстансы красятся случайным цветом краски (MultiMesh.use_colors).
static func parts(kind: String) -> Array:
	var key := CACHE_KEY_PREFIX + kind
	if _cache.has(key):
		return _cache[key]
	var built := _build(kind)
	_cache[key] = built
	return built

static func cached_count() -> int:
	return _cache.size()

# ------------------------------------------------------------------ конструктор

## spec: [{p: тип примитива, s: size/радиусы, t: позиция, r: поворот (град), m: материал, c: тонировка}]
static func _mesh_from_spec(spec: Array) -> Array:
	var by_material: Dictionary = {}
	for part in spec:
		var material := String(part.get("m", "metal_dark"))
		if not by_material.has(material):
			by_material[material] = MeshBuilder.new(Vector3.ZERO, 1.0)
		var builder: MeshBuilder = by_material[material]
		var mesh := _primitive(String(part.get("p", "box")), part)
		if mesh == null:
			continue
		# Поворот в градусах: так специ-prop'ов читаются глазами («наклонить спинку на -12°»).
		var rot_deg: Vector3 = part.get("r", Vector3.ZERO)
		var xform := Transform3D(
			Basis.from_euler(rot_deg * 0.017453292519943295),
			part.get("t", Vector3.ZERO) as Vector3
		)
		builder.merge_arrays(mesh.create_arrays(true), xform)
	var out: Array = []
	var materials: Array = by_material.keys()
	# Сортировка: порядок поверхностей должен быть одинаков на всех платформах
	# (иначе скриншоты CI и отладочные отчёты «плывут» между запусками).
	materials.sort()
	for material in materials:
		var mesh := (by_material[material] as MeshBuilder).commit(null) as ArrayMesh
		if mesh != null:
			mesh.surface_set_material(0, MaterialLibrary.get_material(String(material)))
			out.append({"part_name": String(material), "material": String(material), "mesh": mesh})
	return out

static func _primitive(kind: String, part: Dictionary) -> PrimitiveMesh:
	match kind:
		"box":
			var box := BoxMesh.new()
			box.size = part.get("s", Vector3.ONE) as Vector3
			box.subdivide_width = int(part.get("sw", 0))
			box.subdivide_height = int(part.get("sh", 0))
			box.subdivide_depth = int(part.get("sd", 0))
			return box
		"cylinder":
			var cyl := CylinderMesh.new()
			var radii: Vector2 = part.get("s", Vector2(0.2, 0.2))
			cyl.top_radius = radii.x
			cyl.bottom_radius = radii.y
			cyl.height = float(part.get("h", 1.0))
			cyl.radial_segments = int(part.get("seg", 10))
			cyl.rings = int(part.get("rings", 1))
			return cyl
		"sphere":
			var ball := SphereMesh.new()
			var size: Vector2 = part.get("s", Vector2(0.5, 0.5))
			ball.radius = size.x
			ball.height = size.y
			ball.radial_segments = int(part.get("seg", 10))
			ball.rings = int(part.get("rings", 6))
			return ball
		"prism":
			var prism := PrismMesh.new()
			prism.size = part.get("s", Vector3.ONE) as Vector3
			return prism
		"torus":
			var torus := TorusMesh.new()
			torus.inner_radius = float(part.get("ri", 0.3))
			torus.outer_radius = float(part.get("ro", 0.5))
			torus.rings = int(part.get("rings", 6))
			torus.ring_segments = int(part.get("seg", 12))
			return torus
	return null

# ------------------------------------------------------------------ определения

static func _build(kind: String) -> Array:
	match kind:
		"lamp":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.24, 0.3), "h": 0.36, "t": Vector3(0.0, 0.18, 0.0), "m": "concrete", "seg": 8},
				{"p": "cylinder", "s": Vector2(0.10, 0.13), "h": 6.1, "t": Vector3(0.0, 3.2, 0.0), "m": "metal_dark", "seg": 8},
				{"p": "box", "s": Vector3(0.16, 0.16, 1.1), "t": Vector3(0.0, 6.16, 0.55), "m": "metal_dark"},
				{"p": "box", "s": Vector3(0.34, 0.2, 1.5), "t": Vector3(0.0, 6.02, 1.05), "m": "metal_panel"},
				{"p": "box", "s": Vector3(0.3, 0.09, 1.32), "t": Vector3(0.0, 5.9, 1.05), "m": "car_light"},
			])
		"tree":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.16, 0.3), "h": 2.5, "t": Vector3(0.0, 1.25, 0.0), "m": "bark", "seg": 7},
				{"p": "sphere", "s": Vector2(1.55, 1.75), "t": Vector3(0.0, 3.2, 0.0), "m": "foliage", "seg": 10, "rings": 6},
				{"p": "sphere", "s": Vector2(1.15, 1.25), "t": Vector3(0.75, 3.95, 0.25), "m": "foliage", "seg": 9, "rings": 5},
				{"p": "sphere", "s": Vector2(0.95, 1.0), "t": Vector3(-0.7, 3.75, -0.35), "m": "foliage", "seg": 8, "rings": 5},
			])
		"bin":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.31, 0.36), "h": 0.9, "t": Vector3(0.0, 0.45, 0.0), "m": "metal_dark", "seg": 10},
				{"p": "cylinder", "s": Vector2(0.37, 0.37), "h": 0.1, "t": Vector3(0.0, 0.95, 0.0), "m": "metal_panel", "seg": 10},
			])
		"dumpster":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(2.5, 1.2, 1.35), "t": Vector3(0.0, 0.72, 0.0), "m": "metal_panel"},
				{"p": "box", "s": Vector3(2.56, 0.14, 1.4), "t": Vector3(0.0, 1.39, 0.0), "m": "metal_dark"},
				{"p": "box", "s": Vector3(2.4, 0.16, 0.1), "t": Vector3(0.0, 0.28, 0.7), "m": "curb"},
			])
		"cone":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(0.5, 0.06, 0.5), "t": Vector3(0.0, 0.03, 0.0), "m": "cone_orange"},
				{"p": "cylinder", "s": Vector2(0.055, 0.2), "h": 0.66, "t": Vector3(0.0, 0.39, 0.0), "m": "cone_orange", "seg": 9},
				{"p": "cylinder", "s": Vector2(0.135, 0.155), "h": 0.11, "t": Vector3(0.0, 0.44, 0.0), "m": "road_marking", "seg": 9},
			])
		"barrier":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(0.3, 0.72, 0.34), "t": Vector3(-0.85, 0.36, 0.0), "m": "curb"},
				{"p": "box", "s": Vector3(0.3, 0.72, 0.34), "t": Vector3(0.85, 0.36, 0.0), "m": "curb"},
				{"p": "box", "s": Vector3(2.05, 0.3, 0.22), "t": Vector3(0.0, 0.62, 0.0), "m": "road_marking"},
				{"p": "box", "s": Vector3(2.05, 0.12, 0.24), "t": Vector3(0.0, 0.84, 0.0), "m": "cone_orange"},
			])
		"bench":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(1.65, 0.09, 0.46), "t": Vector3(0.0, 0.44, 0.0), "m": "wood"},
				{"p": "box", "s": Vector3(1.65, 0.4, 0.08), "t": Vector3(0.0, 0.68, -0.2), "m": "wood", "r": Vector3(-12.0, 0.0, 0.0)},
				{"p": "box", "s": Vector3(0.1, 0.42, 0.42), "t": Vector3(-0.72, 0.21, 0.0), "m": "metal_dark"},
				{"p": "box", "s": Vector3(0.1, 0.42, 0.42), "t": Vector3(0.72, 0.21, 0.0), "m": "metal_dark"},
			])
		"traffic_light":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.13, 0.16), "h": 3.4, "t": Vector3(0.0, 1.7, 0.0), "m": "metal_dark", "seg": 8},
				{"p": "box", "s": Vector3(0.42, 1.12, 0.36), "t": Vector3(0.0, 3.9, 0.0), "m": "metal_dark"},
				{"p": "box", "s": Vector3(0.5, 0.12, 0.26), "t": Vector3(0.06, 4.32, 0.0), "m": "metal_dark"},
			]) + _light_lenses()
		"fence":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(0.1, 1.35, 0.1), "t": Vector3(-1.2, 0.67, 0.0), "m": "metal_dark"},
				{"p": "box", "s": Vector3(0.1, 1.35, 0.1), "t": Vector3(1.2, 0.67, 0.0), "m": "metal_dark"},
				{"p": "box", "s": Vector3(2.5, 0.08, 0.06), "t": Vector3(0.0, 1.2, 0.0), "m": "metal_panel"},
				{"p": "box", "s": Vector3(2.5, 0.08, 0.06), "t": Vector3(0.0, 0.72, 0.0), "m": "metal_panel"},
				{"p": "box", "s": Vector3(2.5, 0.08, 0.06), "t": Vector3(0.0, 0.26, 0.0), "m": "metal_panel"},
			])
		"rooftop_unit":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(1.6, 0.9, 1.3), "t": Vector3(0.0, 0.45, 0.0), "m": "metal_panel"},
				{"p": "cylinder", "s": Vector2(0.45, 0.45), "h": 0.12, "t": Vector3(0.0, 0.95, 0.0), "m": "metal_dark", "seg": 10},
				{"p": "box", "s": Vector3(0.5, 0.5, 0.5), "t": Vector3(0.9, 0.25, 0.0), "m": "metal_dark"},
			])
		"bollard":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.11, 0.13), "h": 0.78, "t": Vector3(0.0, 0.39, 0.0), "m": "curb", "seg": 8},
				{"p": "cylinder", "s": Vector2(0.115, 0.115), "h": 0.1, "t": Vector3(0.0, 0.6, 0.0), "m": "road_marking", "seg": 8},
			])
		"planter":
			return _mesh_from_spec([
				{"p": "box", "s": Vector3(1.4, 0.52, 1.4), "t": Vector3(0.0, 0.26, 0.0), "m": "curb"},
				{"p": "box", "s": Vector3(1.18, 0.1, 1.18), "t": Vector3(0.0, 0.5, 0.0), "m": "soil"},
				{"p": "sphere", "s": Vector2(0.5, 0.42), "t": Vector3(0.0, 0.78, 0.0), "m": "foliage", "seg": 8, "rings": 4},
			])
		"hydrant":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.19, 0.23), "h": 0.62, "t": Vector3(0.0, 0.31, 0.0), "m": "cone_orange", "seg": 8},
				{"p": "sphere", "s": Vector2(0.2, 0.22), "t": Vector3(0.0, 0.68, 0.0), "m": "cone_orange", "seg": 8, "rings": 4},
			])
		"sign":
			return _mesh_from_spec([
				{"p": "cylinder", "s": Vector2(0.07, 0.09), "h": 2.6, "t": Vector3(0.0, 1.3, 0.0), "m": "metal_dark", "seg": 6},
				{"p": "box", "s": Vector3(1.15, 0.75, 0.06), "t": Vector3(0.0, 2.5, 0.0), "m": "metal_panel"},
				{"p": "box", "s": Vector3(0.95, 0.55, 0.02), "t": Vector3(0.0, 2.5, 0.04), "m": "road_marking"},
			])
		"parked_car":
			return _parked_car_parts()
	return _mesh_from_spec([
		{"p": "box", "s": Vector3(0.8, 0.8, 0.8), "t": Vector3(0.0, 0.4, 0.0), "m": "metal_dark"},
	])

## Линзы светофора — отдельная «светящаяся» часть (свой материал = свой surface).
static func _light_lenses() -> Array:
	var spec: Array = [
		{"p": "sphere", "s": Vector2(0.11, 0.11), "t": Vector3(0.0, 4.32, 0.19), "m": "signal_red", "seg": 8, "rings": 4},
		{"p": "sphere", "s": Vector2(0.11, 0.11), "t": Vector3(0.0, 3.9, 0.19), "m": "signal_amber", "seg": 8, "rings": 4},
		{"p": "sphere", "s": Vector2(0.11, 0.11), "t": Vector3(0.0, 3.48, 0.19), "m": "signal_green", "seg": 8, "rings": 4},
	]
	return _mesh_from_spec(spec)

## Припаркованная машина = та же процедурная модель, что и у игрока (один меш на все
## чанки), но без салона-стёкол как отдельной заботы: поверхности уже разделены.
static func _parked_car_parts() -> Array:
	# Отдельный «дефолтный» конфиг, НЕ конфиг игрока: припаркованные машины не должны
	# наследовать тюнинг полиции/балансные правки — только пропорции кузова.
	var cfg := VehicleConfig.new()
	var parts: Dictionary = CarGeometry.build(cfg)
	var out: Array = []
	var body: ArrayMesh = parts.get("body") as ArrayMesh
	var wheel: ArrayMesh = parts.get("wheel") as ArrayMesh
	if body != null:
		CarGeometry.set_surface_materials(body, PackedStringArray(["car_paint", "car_trim", "car_glass", "car_light", "car_tail"]))
		out.append({"part_name": "body", "material": "car_paint", "mesh": body, "per_surface": PackedStringArray([
			"car_paint", "car_trim", "car_glass", "car_light", "car_tail"])})
	if wheel != null:
		CarGeometry.set_surface_materials(wheel, PackedStringArray(["car_tyre", "car_rim"]))
		out.append({"part_name": "wheel", "material": "car_tyre", "mesh": wheel, "per_surface": PackedStringArray([
			"car_tyre", "car_rim"])})
	return out

## Смещения колёс припаркованной машины относительно её кузова (для MultiMesh колёс).
static func parked_car_wheel_offsets() -> PackedVector3Array:
	var cfg := VehicleConfig.new()
	var out := PackedVector3Array()
	var half_track := cfg.track_width_m * 0.5
	var half_base := cfg.wheelbase_m * 0.5
	var y := -cfg.ride_height_m + cfg.wheel_radius_m
	for x in [-half_track, half_track]:
		for z in [-half_base, half_base]:
			out.append(Vector3(x, y, z))
	return out

static func car_length() -> float:
	return float(VehicleConfig.new().body_length_m)
