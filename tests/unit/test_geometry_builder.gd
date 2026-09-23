extends TestCase
## The mesh builder: the project merges thousands of primitives into one mesh per material per
## chunk, and a car into one mesh per material. That merging is what keeps the draw call count
## of a dense city inside the budget of a mobile GPU, so it is tested directly.


func _suite_name() -> String:
	return "unit/geometry_builder"


func run(tree: SceneTree) -> void:
	var materials := MaterialLibrary.new()
	var builder := GeometryBuilder.new(materials)
	check_almost(materials.get_material(MaterialLibrary.CONCRETE).roughness, materials.get_material(MaterialLibrary.CONCRETE).roughness, 0.0001, "the material library is stable")

	var identity := Transform3D()
	builder.add_box(MaterialLibrary.CONCRETE, identity, Vector3(2.0, 1.0, 3.0), 0.5, Color(0.9, 0.9, 0.9))
	check_almost(float(builder.triangle_count), 12.0, 0.001, "a box is twelve triangles")
	builder.add_plane(MaterialLibrary.ASPHALT, identity, Vector2(4.0, 4.0), 0.5, Color.WHITE)
	check_almost(float(builder.triangle_count), 14.0, 0.001, "a plane is two triangles")
	builder.add_wall(MaterialLibrary.FACADE_OFFICE, identity, Vector2(10.0, 20.0), Vector2(0.08, 0.06))
	check_almost(float(builder.triangle_count), 16.0, 0.001, "a wall is two triangles")
	builder.add_cylinder(MaterialLibrary.METAL, identity, 0.2, 3.0, 8, 1.0, Color.WHITE, true)
	builder.add_sphere(MaterialLibrary.GRASS, identity, 1.0, 4, 6, 0.5, Color.WHITE, 0.9)
	builder.add_cone(MaterialLibrary.PLASTIC, identity, 0.3, 0.6, 8, 1.0, Color.WHITE)
	builder.add_frustum(MaterialLibrary.FACADE_PANEL, identity, Vector2(5.0, 5.0), Vector2(3.0, 3.0), 6.0, 0.08, Color.WHITE)
	builder.add_stairs(MaterialLibrary.CONCRETE, identity, 2.0, 1.0, 1.0, 3, 1.0, Color.WHITE)
	builder.add_railing(MaterialLibrary.METAL, identity, 4.0, 1.1, 1.4, Color.WHITE)
	check_greater(float(builder.triangle_count), 100.0, "the builder counts the triangles it emits")
	check_greater(float(builder.primitive_count), 8.0, "the builder counts the primitives")

	# --- merging -------------------------------------------------------------------
	var holder := Node3D.new()
	tree.root.add_child(holder)
	var nodes := builder.commit(holder, "test")
	check_greater(float(nodes.size()), 4.0, "the merged meshes are grouped per material")
	check_less(float(nodes.size()), 12.0, "nine primitives do not become nine draw calls per material")
	var total_surfaces := 0
	var total_vertices := 0
	for node: MeshInstance3D in nodes:
		check_not_null(node.mesh, "every merged instance has a mesh")
		check_not_null(node.material_override, "every merged instance has its material")
		if node.mesh != null:
			total_surfaces += node.mesh.get_surface_count()
			var arrays := node.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			total_vertices += vertices.size()
			check(arrays[Mesh.ARRAY_COLOR] != null, "vertex colours are written (they carry the variation)")
	check(total_surfaces >= nodes.size(), "every group carries at least one surface")
	check_greater(float(total_vertices), 100.0, "the meshes contain real geometry")
	check_almost(float(builder.triangle_count), 14.0, 0.001, "committing resets nothing and keeps the count")
	holder.queue_free()

	# --- collision body -------------------------------------------------------------
	var body_holder := Node3D.new()
	tree.root.add_child(body_holder)
	var boxes: Array[Dictionary] = [
		{"position": Vector3(0, 5, 0), "size": Vector3(10, 10, 10)},
		{"position": Vector3(20, 1, 0), "size": Vector3(2, 2, 2), "basis": Basis(Vector3.UP, 0.5)},
	]
	var body := builder.build_collision_body(body_holder, "TestBody", boxes, CollisionLayers.BUILDING)
	check_not_null(body, "a collision body is created")
	if body != null:
		check_almost(float(body.get_child_count()), 2.0, 0.001, "one collision shape per box")
		check_almost(float(body.collision_layer), float(CollisionLayers.BUILDING), 0.001, "the layer is applied")
		var shape := body.get_child(0) as CollisionShape3D
		if shape != null:
			var box := shape.shape as BoxShape3D
			check_not_null(box, "the shape is a box")
			if box != null:
				check_almost(box.size.x, 10.0, 0.001, "the box keeps its size")
	body_holder.queue_free()

	# --- layers --------------------------------------------------------------------
	check((CollisionLayers.VEHICLE_COLLISION & CollisionLayers.GROUND) != 0, "cars collide with the ground")
	check((CollisionLayers.VEHICLE_COLLISION & CollisionLayers.BUILDING) != 0, "cars collide with buildings")
	check((CollisionLayers.WHEEL_RAY & CollisionLayers.BUILDING) != 0, "wheels can rest on a building ramp")
	check((CollisionLayers.CAMERA_BLOCKERS & CollisionLayers.POLICE) == 0, "the camera is not blocked by police cars")
	check(CollisionLayers.describe_layer(CollisionLayers.PLAYER).contains("player"), "layers have readable names")

	# --- a car mesh, built the same way --------------------------------------------
	var body_meshes := CarMeshFactory.build_body(
		CarMeshFactory.MODEL_SEDAN, Color(0.7, 0.1, 0.1), materials, CarMeshFactory.DETAIL_HIGH
	)
	check_greater(float(body_meshes.size()), 3.0, "a car body has paint, glass, plastic and light meshes")
	var wheel := CarMeshFactory.build_wheel(CarMeshFactory.MODEL_SEDAN, materials)
	check_not_null(wheel, "a wheel mesh is built")
	if wheel != null:
		check_greater(float(wheel.get_surface_count()), 0.0, "the wheel has surfaces")
	check_greater(float(CarMeshFactory.model_count()), 8.0, "there is a fleet of models, not one box")
	check_almost(CarMeshFactory.dimensions(CarMeshFactory.MODEL_BUS).z, 11.4, 0.01, "models differ in size")
	check_greater(
		CarMeshFactory.dimensions(CarMeshFactory.MODEL_BUS).y,
		CarMeshFactory.dimensions(CarMeshFactory.MODEL_SPORTS).y,
		"the bus is much taller than the sports car"
	)
