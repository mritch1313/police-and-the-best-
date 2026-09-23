extends RefCounted
class_name MaterialLibrary
## Every material of the world in one place.
##
## Materials are created once, shared by every chunk and every car, and addressed by name.
## Two rules make the city look varied without costing draw calls:
##
##   1. each surface has its own texture (asphalt, concrete, brick, four facades, glass,
##      metal, grass, dirt, gravel, wood, signs) - there is no single "grey wall" material
##   2. `vertex_color_use_as_albedo` is enabled everywhere, so the geometry itself can tint
##      every single building, pavement or prop with its own colour. That is where the
##      variety of the city comes from, and it is free at runtime.
##
## Replacing the look of the game therefore means replacing PNG files in ``assets/`` (or
## switching the material presets here) - never editing the generators.

const TEX_DIR := "res://assets/textures/"

## Material keys used by the world and by the vehicles.
const ASPHALT := &"asphalt"
const ASPHALT_WORN := &"asphalt_worn"
const CONCRETE := &"concrete"
const CONCRETE_PLAZA := &"concrete_plaza"
const SIDEWALK := &"sidewalk"
const KERB := &"kerb"
const GRASS := &"grass"
const DIRT := &"dirt"
const ROOF := &"roof_gravel"
const METAL := &"metal_panel"
const WOOD := &"wood_planks"
const BRICK := &"brick"
const FACADE_OFFICE := &"facade_office"
const FACADE_GLASS := &"facade_glass"
const FACADE_PANEL := &"facade_panel"
const FACADE_BRICK := &"facade_brick"
const FACADE_SHOP := &"facade_shop"
const SIGN_SHOP := &"sign_shop"
const SIGN_CAFE := &"sign_cafe"
const ROAD_PAINT := &"road_paint"
const GLASS := &"glass"
const CHROME := &"chrome"
const RUBBER := &"rubber"
const CAR_BODY := &"car_body"
const CAR_BODY_METALLIC := &"car_body_metallic"
const LIGHT_HEAD := &"light_head"
const LIGHT_TAIL := &"light_tail"
const LIGHT_EMERGENCY := &"light_emergency"
const PLASTIC := &"plastic"
const DIRT_TRACK := &"dirt_track"
const FABRIC_TENT := &"fabric_tent"
const WATER := &"water"

const FACADE_KEYS: Array[StringName] = [
	FACADE_OFFICE,
	FACADE_GLASS,
	FACADE_PANEL,
	FACADE_BRICK,
]

## Every texture based material, with its roughness, metallic value and UV scale.
## `uv_scale` is expressed in "texture repeats per metre" and is applied per mesh through
## the UVs themselves (see MeshFactory), so it is only a fallback here.
const DEFINITIONS := {
	ASPHALT: {"texture": "asphalt.png", "roughness": 0.93, "metallic": 0.0, "normal": 1.0},
	ASPHALT_WORN: {"texture": "asphalt_worn.png", "roughness": 0.95, "metallic": 0.0, "normal": 1.0},
	CONCRETE: {"texture": "concrete.png", "roughness": 0.9, "metallic": 0.0, "normal": 0.8},
	CONCRETE_PLAZA: {"texture": "concrete_plaza.png", "roughness": 0.88, "metallic": 0.0, "normal": 0.7},
	SIDEWALK: {"texture": "sidewalk.png", "roughness": 0.85, "metallic": 0.0, "normal": 0.9},
	KERB: {"texture": "kerb.png", "roughness": 0.82, "metallic": 0.0, "normal": 0.9},
	GRASS: {"texture": "grass.png", "roughness": 1.0, "metallic": 0.0, "normal": 1.0},
	DIRT: {"texture": "dirt.png", "roughness": 1.0, "metallic": 0.0, "normal": 1.0},
	DIRT_TRACK: {"texture": "dirt.png", "roughness": 1.0, "metallic": 0.0, "normal": 0.6},
	ROOF: {"texture": "roof_gravel.png", "roughness": 0.95, "metallic": 0.0, "normal": 1.0},
	METAL: {"texture": "metal_panel.png", "roughness": 0.45, "metallic": 0.6, "normal": 0.9},
	WOOD: {"texture": "wood_planks.png", "roughness": 0.8, "metallic": 0.0, "normal": 0.8},
	BRICK: {"texture": "brick.png", "roughness": 0.88, "metallic": 0.0, "normal": 1.0},
	FACADE_OFFICE: {"texture": "facade_office.png", "roughness": 0.55, "metallic": 0.1, "normal": 1.0},
	FACADE_GLASS: {"texture": "facade_glass.png", "roughness": 0.25, "metallic": 0.35, "normal": 0.8},
	FACADE_PANEL: {"texture": "facade_panel.png", "roughness": 0.62, "metallic": 0.05, "normal": 1.0},
	FACADE_BRICK: {"texture": "facade_brick.png", "roughness": 0.8, "metallic": 0.0, "normal": 1.0},
	FACADE_SHOP: {"texture": "facade_shop.png", "roughness": 0.4, "metallic": 0.1, "normal": 0.7},
	SIGN_SHOP: {"texture": "sign_shop.png", "roughness": 0.45, "metallic": 0.0, "normal": 0.4},
	SIGN_CAFE: {"texture": "sign_cafe.png", "roughness": 0.45, "metallic": 0.0, "normal": 0.4},
}

var _materials: Dictionary = {}
var _textures: Dictionary = {}


## Returns (and lazily creates) the material for a key.
func get_material(key: StringName) -> Material:
	if _materials.has(key):
		return _materials[key]
	var material := _create_material(key)
	_materials[key] = material
	return material


## Returns the albedo texture of a key (may be null for the pure colour materials).
func get_texture(key: StringName) -> Texture2D:
	if _textures.has(key):
		return _textures[key]
	var texture: Texture2D = null
	if DEFINITIONS.has(key):
		var file_name: String = DEFINITIONS[key]["texture"]
		if ResourceLoader.exists(TEX_DIR + file_name):
			texture = load(TEX_DIR + file_name) as Texture2D
	_textures[key] = texture
	return texture


## True when the material key is a textured surface.
func is_textured(key: StringName) -> bool:
	return DEFINITIONS.has(key)


func _create_material(key: StringName) -> Material:
	match key:
		ROAD_PAINT:
			return _paint_material(Color(0.92, 0.92, 0.88), 0.6)
		GLASS:
			return _glass_material()
		CHROME:
			return _solid_material(Color(0.72, 0.74, 0.78), 0.18, 0.95)
		RUBBER:
			return _solid_material(Color(0.055, 0.055, 0.06), 0.85, 0.0)
		PLASTIC:
			return _solid_material(Color(0.16, 0.16, 0.18), 0.5, 0.0)
		FABRIC_TENT:
			return _solid_material(Color(0.8, 0.32, 0.28), 0.75, 0.0)
		WATER:
			return _solid_material(Color(0.24, 0.42, 0.5), 0.12, 0.1, false)
		CAR_BODY:
			return _solid_material(Color(1.0, 1.0, 1.0), 0.24, 0.35, true)
		CAR_BODY_METALLIC:
			return _solid_material(Color(1.0, 1.0, 1.0), 0.18, 0.85, true)
		LIGHT_HEAD:
			return _emissive_material(Color(0.94, 0.95, 1.0), Color(0.9, 0.93, 1.0), 1.6)
		LIGHT_TAIL:
			return _emissive_material(Color(0.55, 0.05, 0.05), Color(0.9, 0.1, 0.08), 1.2)
		LIGHT_EMERGENCY:
			return _emissive_material(Color(0.2, 0.3, 1.0), Color(0.25, 0.4, 1.0), 3.0)

	var definition: Dictionary = DEFINITIONS.get(key, {})
	var material := StandardMaterial3D.new()
	material.resource_name = "mat_%s" % key
	material.albedo_color = Color.WHITE
	material.roughness = float(definition.get("roughness", 0.8))
	material.metallic = float(definition.get("metallic", 0.0))
	material.vertex_color_use_as_albedo = true
	material.uv1_triplanar = false
	var texture := get_texture(key)
	if texture != null:
		material.albedo_texture = texture
	if definition.has("normal"):
		var normal_path := TEX_DIR + String(definition["texture"]).replace(".png", "_normal.png")
		if ResourceLoader.exists(normal_path):
			material.normal_enabled = true
			material.normal_texture = load(normal_path) as Texture2D
			material.normal_scale = float(definition["normal"])
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


## Flat colour material used for the car bodies, props and paint.
func _solid_material(colour: Color, roughness: float, metallic: float, clearcoat: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = roughness
	material.metallic = metallic
	material.vertex_color_use_as_albedo = true
	if clearcoat:
		material.clearcoat_enabled = true
		material.clearcoat = 0.35
		material.clearcoat_roughness = 0.25
	return material


func _paint_material(colour: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = roughness
	material.metallic = 0.0
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return material


func _glass_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.42, 0.5, 0.62)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.08
	material.metallic = 0.4
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.albedo_texture = null
	return material


## Emissive material used for the lights. Kept cheap: no shadow casting, no glow
## requirement, and the emission energy stays low enough for a mobile screen.
func _emissive_material(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = albedo
	material.roughness = 0.2
	material.metallic = 0.1
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	material.vertex_color_use_as_albedo = true
	return material


## Applies the texture filtering chosen in the graphics options to every material that
## already exists (the "низкое" preset turns anisotropic filtering off).
func apply_filtering(anisotropic: bool) -> void:
	var filter := (
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		if anisotropic
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	)
	for key: StringName in _materials.keys():
		var material: Material = _materials[key]
		if material is StandardMaterial3D:
			(material as StandardMaterial3D).texture_filter = filter


## Frees every generated material (used when a run ends and the world is rebuilt).
func clear() -> void:
	for material: Material in _materials.values():
		if material != null and material is StandardMaterial3D:
			pass
	_materials.clear()
	_textures.clear()
