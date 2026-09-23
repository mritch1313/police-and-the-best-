class_name MaterialLibrary
extends RefCounted
## Кэш материалов: один `StandardMaterial3D` на тип поверхности, а не на объект.
##
## Почему так: на мобильном GPU (Mali-G52 в Infinix HOT 40i) цена имеет (1) количество
## разных шейдерных вариантов — каждый новый вариант = компиляция пайплайна и просадка
## в момент появления объекта на экране, и (2) переключения состояния. Мир из ~150 чанков
## использует ~20 материалов, а не 5000.
##
## Всё, что меняется на ходу (цвет краски, мигалка, стоп-сигналы), делается либо
## `set_surface_override_material` на конкретном MeshInstance3D, либо вершинным цветом
## + `vertex_color_use_as_albedo` для MultiMesh-массы (припаркованные машины, заборы).
##
## Имена свойств сверены с doc/classes/BaseMaterial3D.xml дерева 4.7.2 (`tools/api_check.py`):
## здесь нет `roughness_enabled` (текстура шероховатости включается самим фактом
## `roughness_texture`), нет `normal_depth` (есть `normal_scale`), нет `receive_shadows_enabled`
## (тени принимаются всегда, см. `GeometryInstance3D.cast_shadow`).

const CAR_PAINT_DEFAULT := Color(0.30, 0.42, 0.60)

static var _cache: Dictionary = {}
## Режим фильтрации текстур из пресета качества (-1 = оставить дефолт материала).
## Значения = BaseMaterial3D.TextureFilter: 0 NEAREST, 1 LINEAR, 2/3 MIPMAPS,
## 4/5 ANISOTROPIC (5 = линейный + анизотропная фильтрация).
static var texture_filter_mode: int = -1

static func get_material(type: String) -> StandardMaterial3D:
	if _cache.has(type):
		return _cache[type] as StandardMaterial3D
	var mat := _build(type)
	apply_texture_filter(mat)
	_cache[type] = mat
	return mat

## Применяет выбранный режим к уже собранным и ко всем будущим материалам.
## Присваивание через set(): enum-свойства движка безопаснее задавать числом.
static func set_texture_filter(mode: int) -> void:
	texture_filter_mode = clampi(mode, 0, 5)
	for type in _cache.keys():
		apply_texture_filter(_cache[type] as StandardMaterial3D)

static func apply_texture_filter(mat: StandardMaterial3D) -> void:
	if mat == null or texture_filter_mode < 0:
		return
	mat.set("texture_filter", texture_filter_mode)

static func types() -> PackedStringArray:
	return PackedStringArray([
		"asphalt", "asphalt_dark", "concrete", "sidewalk", "road_marking", "curb",
		"facade_office", "facade_brick", "facade_glass", "facade_residential",
		"roof_gravel", "metal_panel", "brick", "soil", "foliage", "glass_sheet",
		"metal_dark", "roadblock", "cone_orange",
		"car_paint", "car_paint_dark", "car_glass", "car_light", "car_light_off",
		"car_tail", "car_tail_off", "car_tyre", "car_rim", "car_trim", "police_body",
		"lightbar_red", "lightbar_blue",
		"bark", "wood", "grass", "signal_red", "signal_amber", "signal_green",
		"far_building", "far_roof",
	])

static func has_type(type: String) -> bool:
	return type in types()

static func reset() -> void:
	_cache = {}

## Копия материала с правками: для машин (свой цвет/эмиссия) — общий кэш не трогается.
static func unique(type: String) -> StandardMaterial3D:
	var src := get_material(type)
	var mat: StandardMaterial3D = src.duplicate() as StandardMaterial3D
	return mat

# ------------------------------------------------------------------ сборка

static func _surface(_type: String, albedo_name: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var pack: Dictionary = TextureLibrary.get_pack(albedo_name)
	var tile: Vector2 = pack.get("tile", Vector2(2.0, 2.0))
	mat.albedo_texture = pack.get("albedo") as Texture2D
	# UV мира измеряются в метрах -> масштаб 1/tile даёт ровно один тайл на tile метров.
	mat.uv1_scale = Vector3(1.0 / maxf(tile.x, 0.01), 1.0 / maxf(tile.y, 0.01), 1.0)
	var normal: Texture2D = pack.get("normal") as Texture2D
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = 0.85
	var rough: Texture2D = pack.get("rough") as Texture2D
	if rough != null:
		mat.roughness_texture = rough
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.roughness = 1.0
	else:
		mat.roughness = 0.85
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	return mat

static func _flat(_type: String, color: Color, rough: float, metal: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = clampf(rough, 0.02, 1.0)
	mat.metallic = clampf(metal, 0.0, 1.0)
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	return mat

static func _emissive(color: Color, energy: float, albedo: Color) -> StandardMaterial3D:
	var mat := _flat("emissive", albedo, 0.16)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat

static func _build(type: String) -> StandardMaterial3D:
	match type:
		"asphalt":
			return _surface(type, "asphalt")
		"asphalt_dark":
			var dark := _surface(type, "asphalt")
			dark.albedo_color = Color(0.55, 0.55, 0.58)
			return dark
		"concrete":
			return _surface(type, "concrete")
		"sidewalk":
			return _surface(type, "sidewalk")
		"curb":
			var curb := _surface(type, "concrete")
			curb.albedo_color = Color(0.80, 0.80, 0.78)
			return curb
		"road_marking":
			var marking := _surface(type, "road_marking")
			marking.roughness = 0.5
			# Немного собственного свечения: разметка должна читаться ночью без «огней на асфальте».
			marking.emission_enabled = true
			marking.emission = Color(0.22, 0.22, 0.20)
			marking.emission_energy_multiplier = 1.0
			return marking
		"facade_office", "facade_brick", "facade_glass", "facade_residential", "roof_gravel", "soil", "brick":
			return _surface(type, type)
		"foliage":
			var leaves := _surface(type, "soil")
			leaves.albedo_color = Color(0.20, 0.34, 0.16)
			leaves.roughness = 0.9
			return leaves
		"metal_panel":
			var panel := _surface(type, "metal_panel")
			panel.metallic = 0.4
			return panel
		"glass_sheet":
			var sheet := _surface(type, "glass_sheet")
			sheet.metallic = 0.2
			sheet.roughness = 0.1
			return sheet
		"metal_dark":
			return _flat(type, Color(0.13, 0.14, 0.15), 0.45, 0.7)
		"roadblock":
			var block := _surface(type, "concrete")
			block.albedo_color = Color(0.88, 0.86, 0.82)
			return block
		"cone_orange":
			var cone := _flat(type, Color(0.92, 0.34, 0.05), 0.7)
			cone.emission_enabled = true
			cone.emission = Color(0.30, 0.09, 0.01)
			cone.emission_energy_multiplier = 0.9
			return cone
		"car_paint":
			var paint := _flat(type, CAR_PAINT_DEFAULT, 0.26, 0.55)
			paint.clearcoat_enabled = true
			paint.clearcoat = 0.55
			paint.clearcoat_roughness = 0.06
			var wear: Texture2D = TextureLibrary.get_rough("paint_wear")
			if wear != null:
				paint.roughness_texture = wear
				paint.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
				paint.roughness = 0.42
				paint.uv1_scale = Vector3(0.45, 0.45, 0.45)
			return paint
		"car_paint_dark":
			var dark_paint := _flat(type, Color(0.055, 0.06, 0.07), 0.34, 0.5)
			dark_paint.clearcoat_enabled = true
			dark_paint.clearcoat = 0.4
			return dark_paint
		"car_glass":
			var glass := _flat(type, Color(0.07, 0.10, 0.13, 0.55), 0.04, 0.1)
			glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			glass.cull_mode = BaseMaterial3D.CULL_DISABLED
			# «Отражения» дешёвым способом: сильный specular при низкой шероховатости.
			glass.metallic_specular = 0.9
			return glass
		"car_light":
			return _emissive(Color(0.92, 0.95, 1.0), 4.0, Color(0.92, 0.93, 0.90))
		"car_light_off":
			return _flat(type, Color(0.72, 0.73, 0.70), 0.12)
		"car_tail":
			return _emissive(Color(0.95, 0.05, 0.04), 2.6, Color(0.35, 0.03, 0.03))
		"car_tail_off":
			return _flat(type, Color(0.28, 0.03, 0.03), 0.3)
		"car_tyre":
			return _surface(type, "tyre_rubber")
		"car_rim":
			var rim := _surface(type, "rim_metal")
			rim.metallic = 0.9
			rim.roughness = 0.22
			return rim
		"car_trim":
			return _flat(type, Color(0.075, 0.08, 0.085), 0.62, 0.15)
		"police_body":
			var police := _flat(type, Color(0.90, 0.91, 0.93), 0.3, 0.25)
			police.vertex_color_use_as_albedo = true
			police.vertex_color_is_srgb = true
			return police
		"lightbar_red":
			return _emissive(Color(1.0, 0.06, 0.05), 6.0, Color(0.5, 0.04, 0.04))
		"lightbar_blue":
			return _emissive(Color(0.06, 0.24, 1.0), 6.0, Color(0.04, 0.10, 0.5))
	return _flat(type, Color(0.5, 0.5, 0.52), 0.8)

## Прогон для тестов/отладки: возвращает список типов, которые не удалось собрать
## (должен быть пустым — это реальная проверка, а не «проверили, что вызов не упал»).
static func self_check() -> PackedStringArray:
	var broken := PackedStringArray()
	for type in types():
		var mat := get_material(type)
		if mat == null:
			broken.append(type + " = null")
		elif mat.albedo_texture == null and mat.albedo_color.a <= 0.001:
			broken.append(type + " без текстуры и с прозрачным albedo")
	return broken
