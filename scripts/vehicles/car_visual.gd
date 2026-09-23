extends Node3D
class_name CarVisual
## The visual half of a car: body meshes, glass, lights and wheels.
##
## The visual layer is deliberately separated from the physics (a hard requirement of this
## project: "the model must be replaceable without rewriting the vehicle"):
##
##   * the physics works on a RigidBody3D and a wheel model, and never looks at this node
##   * this node only *reads* the wheel state (suspension length, spin, steering) and places
##     the wheel meshes accordingly
##   * replacing the look of a car means replacing the meshes built here - or assigning a
##     real .glb model to `body_root` / `wheel_meshes` - and nothing else in the game notices
##
## It also owns the small visual feedback that makes driving feel alive: brake lights that
## light up, reversing lights, and the nitro flames.

const WHEEL_INSTANCE_NAMES := ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]

## The road wheel radius is taken from the physics; the visual wheel can be slightly larger
## so it visually touches the ground.
@export var wheel_visual_scale: float = 1.02
## Vertical offset applied to the whole car mesh so the body sits on the wheels.
@export var body_offset: Vector3 = Vector3.ZERO

var body_root: Node3D = null
var wheel_meshes: Array[Node3D] = []
var brake_material: StandardMaterial3D = null
var reverse_material: StandardMaterial3D = null
var headlight_material: StandardMaterial3D = null
var nitro_flames: Array[GPUParticles3D] = []

var model_id: int = CarMeshFactory.MODEL_SEDAN
var colour: Color = Color(0.72, 0.12, 0.12)
var detail: int = CarMeshFactory.DETAIL_HIGH

var _materials: MaterialLibrary = null
var _wheel_radius: float = 0.34
var _lights_on: bool = false
var _braking: bool = false
var _reversing: bool = false
var _boosting: bool = false
var _police_light_timer: float = 0.0
var _police_light_state: bool = false


## Builds the whole visual from data. Call once, after the configuration is known.
func build(p_model: int, p_colour: Color, config: VehicleConfig, p_materials: MaterialLibrary, p_detail: int = CarMeshFactory.DETAIL_HIGH) -> void:
	model_id = p_model
	colour = p_colour
	detail = p_detail
	_materials = p_materials if p_materials != null else MaterialLibrary.new()
	_wheel_radius = config.wheel_radius
	_clear()
	_build_body()
	_build_wheels()
	_apply_police_lights()


func _clear() -> void:
	for child in get_children():
		child.queue_free()
	body_root = null
	wheel_meshes.clear()
	nitro_flames.clear()


func _build_body() -> void:
	body_root = Node3D.new()
	body_root.name = "Body"
	body_root.position = body_offset
	add_child(body_root)
	var meshes := CarMeshFactory.build_body(model_id, colour, _materials, detail)
	for key: StringName in meshes.keys():
		var mesh: ArrayMesh = meshes[key]
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "Body_%s" % key
		instance.mesh = mesh
		var material := _materials.get_material(key)
		if material != null:
			# Lights get their own instances of the material so that this car can switch its
			# brake lights on without lighting up every other car in the city.
			if key == MaterialLibrary.LIGHT_TAIL or key == MaterialLibrary.LIGHT_EMERGENCY:
				var own := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
				instance.material_override = own
				if key == MaterialLibrary.LIGHT_TAIL:
					brake_material = own
				else:
					brake_material = brake_material if brake_material != null else own
			elif key == MaterialLibrary.LIGHT_HEAD:
				var own_head := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
				instance.material_override = own_head
				headlight_material = own_head
			else:
				instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		body_root.add_child(instance)
	# Reversing lights: a small white lens under the tail lights, hidden until reversing.
	reverse_material = (_materials.get_material(MaterialLibrary.LIGHT_HEAD) as StandardMaterial3D).duplicate() as StandardMaterial3D
	reverse_material.emission_energy_multiplier = 0.0
	var reverse_instance := MeshInstance3D.new()
	reverse_instance.name = "ReverseLights"
	reverse_instance.mesh = MeshFactory.box_mesh(Vector3(0.22, 0.06, 0.05), 2.0, Color(1, 1, 1))
	reverse_instance.material_override = reverse_material
	reverse_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body_root.add_child(reverse_instance)


func _build_wheels() -> void:
	var wheel_mesh := CarMeshFactory.build_wheel(model_id, _materials)
	var data: Dictionary = CarMeshFactory.MODELS.get(model_id, CarMeshFactory.MODELS[CarMeshFactory.MODEL_SEDAN])
	var track := float(data["track"])
	var axle_front := float(data["axle_front"])
	var axle_rear := float(data["axle_rear"])
	var positions := [
		Vector3(-track, _wheel_radius * wheel_visual_scale, -axle_front),
		Vector3(track, _wheel_radius * wheel_visual_scale, -axle_front),
		Vector3(-track, _wheel_radius * wheel_visual_scale, -axle_rear),
		Vector3(track, _wheel_radius * wheel_visual_scale, -axle_rear),
	]
	for index in positions.size():
		var holder := Node3D.new()
		holder.name = WHEEL_INSTANCE_NAMES[index]
		holder.position = positions[index]
		var instance := MeshInstance3D.new()
		instance.name = "Mesh"
		instance.mesh = wheel_mesh
		instance.material_override = _materials.get_material(MaterialLibrary.RUBBER)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		holder.add_child(instance)
		add_child(holder)
		wheel_meshes.append(holder)


## Nitro flames: two small GPU particle emitters behind the car, off by default. They are
## cheap (a handful of particles, no shadows, no collision) and are the only particle system
## the game uses while driving.
func _build_nitro_flames() -> void:
	if not nitro_flames.is_empty():
		return
	var data: Dictionary = CarMeshFactory.MODELS.get(model_id, CarMeshFactory.MODELS[CarMeshFactory.MODEL_SEDAN])
	var length := float(data["length"])
	var width := float(data["width"])
	for side in [-1.0, 1.0]:
		var particles := GPUParticles3D.new()
		particles.name = "NitroFlame%s" % ("L" if side < 0.0 else "R")
		particles.amount = 24
		particles.lifetime = 0.35
		particles.emitting = false
		particles.position = Vector3(side * width * 0.22, 0.28, -length * 0.5 - 0.1)
		particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var process := ParticleProcessMaterial.new()
		process.direction = Vector3(0.0, 0.0, -1.0)
		process.spread = 12.0
		process.initial_velocity_min = 6.0
		process.initial_velocity_max = 12.0
		process.gravity = Vector3(0.0, 1.2, 0.0)
		process.scale_min = 0.5
		process.scale_max = 1.1
		process.color = Color(0.45, 0.72, 1.0, 0.9)
		particles.process_material = process
		var quad := QuadMesh.new()
		quad.size = Vector2(0.34, 0.34)
		var flame_material := StandardMaterial3D.new()
		flame_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flame_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		flame_material.albedo_color = Color(0.5, 0.75, 1.0, 0.85)
		flame_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		flame_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		quad.material = flame_material
		particles.draw_pass_1 = quad
		add_child(particles)
		nitro_flames.append(particles)


func _apply_police_lights() -> void:
	if model_id != CarMeshFactory.MODEL_POLICE:
		return
	_build_nitro_flames()


## Called every frame with the wheel state from the physics.
func sync_wheels(wheels: WheelSystem, delta: float, wheel_radius: float) -> void:
	if wheels == null:
		return
	for i in mini(wheels.wheels.size(), wheel_meshes.size()):
		var wheel: VehicleWheel = wheels.wheels[i]
		var holder := wheel_meshes[i]
		holder.position = wheel.visual_position + Vector3(0.0, wheel_radius * wheel_visual_scale, 0.0)
		holder.basis = wheel.visual_basis
		# Wheels are visible from the outside only: hiding the far side saves a few draw
		# calls on a phone without ever being noticeable.
		holder.visible = true


## Lights and effects. Everything here is cosmetic: no physics, no gameplay effect.
func update_lights(
	delta: float,
	braking: bool,
	reversing: bool,
	boosting: bool,
	speed: float,
	is_police: bool = false
) -> void:
	if brake_material != null:
		var brake_energy := 2.6 if braking else 1.0
		brake_material.emission_energy_multiplier = brake_energy
	if reverse_material != null:
		reverse_material.emission_energy_multiplier = 3.0 if reversing else 0.0
	if is_police:
		_police_light_timer += delta
		if _police_light_timer > 0.32:
			_police_light_timer = 0.0
			_police_light_state = not _police_light_state
		var emergency := _materials.get_material(MaterialLibrary.LIGHT_EMERGENCY) as StandardMaterial3D
		if emergency != null:
			emergency.emission = Color(1.0, 0.2, 0.15) if _police_light_state else Color(0.2, 0.4, 1.0)
	if boosting == _boosting:
		return
	_boosting = boosting
	if boosting and nitro_flames.is_empty():
		_build_nitro_flames()
	for flame: GPUParticles3D in nitro_flames:
		flame.emitting = boosting


func set_headlights_on(enabled: bool) -> void:
	if headlight_material == null or enabled == _lights_on:
		return
	_lights_on = enabled
	headlight_material.emission_energy_multiplier = 2.2 if enabled else 1.6


## Replaces the whole visual with an external model (a .glb scene placed under
## `res://assets/models/`). This is the documented upgrade path for the art: the game calls
## it when `model_scene` is set in the vehicle configuration.
func use_external_model(scene: PackedScene) -> bool:
	if scene == null:
		return false
	var instance := scene.instantiate()
	if instance == null:
		return false
	_clear()
	body_root = Node3D.new()
	body_root.name = "ExternalModel"
	add_child(body_root)
	body_root.add_child(instance)
	# Wheels of an external model are found by name, which keeps the contract explicit.
	for name in WHEEL_INSTANCE_NAMES:
		var node := body_root.find_child(name, true, false)
		if node is Node3D:
			wheel_meshes.append(node as Node3D)
	return true


func wheel_count() -> int:
	return wheel_meshes.size()


func describe() -> String:
	return "CarVisual(model=%s wheels=%d detail=%d colour=%s)" % [
		CarMeshFactory.model_name(model_id),
		wheel_meshes.size(),
		detail,
		colour.to_html(false),
	]
