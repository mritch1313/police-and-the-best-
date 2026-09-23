extends RefCounted
class_name MeshFactory
## Procedural geometry primitives.
##
## Every static function appends triangles to a SurfaceTool. Because the whole city is
## built from a handful of primitives (boxes, planes, cylinders, cones, stairs, wedges),
## the same code produces a pavement, a skyscraper, a lamp post, a bench or a traffic
## light without a single imported model - and each primitive writes real UVs derived from
## its own size, so textures never stretch no matter how big the object is.
##
## Vertex colours are written for every primitive: that is where the colour variety of the
## city comes from (see MaterialLibrary).

## UV scale used when the caller does not care: one texture repeat per 2 metres.
const DEFAULT_UV_SCALE := 0.5


## Appends a quad (two triangles) with an explicit normal and explicit UVs.
static func append_quad(
	st: SurfaceTool,
	origin: Transform3D,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3,
	uv_scale: float,
	colour: Color,
	flip: bool = false
) -> void:
	var uvs := _quad_uvs(a, b, c, d, normal, uv_scale)
	var tangent := (b - a).normalized()
	if flip:
		_add_vertex(st, origin, a, normal, uvs[0], colour, tangent)
		_add_vertex(st, origin, c, normal, uvs[2], colour, tangent)
		_add_vertex(st, origin, b, normal, uvs[1], colour, tangent)
		_add_vertex(st, origin, a, normal, uvs[0], colour, tangent)
		_add_vertex(st, origin, d, normal, uvs[3], colour, tangent)
		_add_vertex(st, origin, c, normal, uvs[2], colour, tangent)
	else:
		_add_vertex(st, origin, a, normal, uvs[0], colour, tangent)
		_add_vertex(st, origin, b, normal, uvs[1], colour, tangent)
		_add_vertex(st, origin, c, normal, uvs[2], colour, tangent)
		_add_vertex(st, origin, a, normal, uvs[0], colour, tangent)
		_add_vertex(st, origin, c, normal, uvs[2], colour, tangent)
		_add_vertex(st, origin, d, normal, uvs[3], colour, tangent)


static func _add_vertex(
	st: SurfaceTool,
	origin: Transform3D,
	position: Vector3,
	normal: Vector3,
	uv: Vector2,
	colour: Color,
	tangent: Vector3 = Vector3.ZERO
) -> void:
	st.set_color(colour)
	st.set_normal((origin.basis * normal).normalized())
	st.set_uv(uv)
	if tangent != Vector3.ZERO:
		st.set_tangent((origin.basis * tangent).normalized())
	st.add_vertex(origin * position)


## Computes UVs for a quad by projecting its corners onto the face plane.
static func _quad_uvs(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, uv_scale: float) -> Array[Vector2]:
	var axis := normal.abs()
	var u_axis: Vector3
	var v_axis: Vector3
	if axis.x >= axis.y and axis.x >= axis.z:
		u_axis = Vector3(0.0, 0.0, 1.0)
		v_axis = Vector3(0.0, 1.0, 0.0)
	elif axis.y >= axis.x and axis.y >= axis.z:
		u_axis = Vector3(1.0, 0.0, 0.0)
		v_axis = Vector3(0.0, 0.0, 1.0)
	else:
		u_axis = Vector3(1.0, 0.0, 0.0)
		v_axis = Vector3(0.0, 1.0, 0.0)
	var origin := a
	return [
		Vector2(Vector3(b - origin).dot(u_axis), Vector3(b - origin).dot(v_axis)) * uv_scale,
		Vector2(Vector3(c - origin).dot(u_axis), Vector3(c - origin).dot(v_axis)) * uv_scale,
		Vector2(Vector3(d - origin).dot(u_axis), Vector3(d - origin).dot(v_axis)) * uv_scale,
		Vector2(Vector3(a - origin).dot(u_axis), Vector3(a - origin).dot(v_axis)) * uv_scale,
	]


## Appends an axis aligned box centred on the transform's origin.
static func append_box(
	st: SurfaceTool,
	origin: Transform3D,
	size: Vector3,
	uv_scale: float,
	colour: Color,
	skip: Array[StringName] = []
) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	if not skip.has(&"px"):
		append_quad(
			st, origin,
			Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz),
			Vector3.RIGHT, uv_scale, colour
		)
	if not skip.has(&"nx"):
		append_quad(
			st, origin,
			Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz),
			Vector3.LEFT, uv_scale, colour
		)
	if not skip.has(&"py"):
		append_quad(
			st, origin,
			Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz),
			Vector3.UP, uv_scale, colour
		)
	if not skip.has(&"ny"):
		append_quad(
			st, origin,
			Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz),
			Vector3.DOWN, uv_scale, colour
		)
	if not skip.has(&"pz"):
		append_quad(
			st, origin,
			Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz),
			Vector3.BACK, uv_scale, colour
		)
	if not skip.has(&"nz"):
		append_quad(
			st, origin,
			Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz),
			Vector3.FORWARD, uv_scale, colour
		)


## Appends a horizontal plane (facing up) of the given size.
static func append_plane(
	st: SurfaceTool,
	origin: Transform3D,
	size: Vector2,
	uv_scale: float,
	colour: Color,
	flip: bool = false
) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var normal := Vector3.DOWN if flip else Vector3.UP
	append_quad(
		st, origin,
		Vector3(-hx, 0.0, hz), Vector3(hx, 0.0, hz), Vector3(hx, 0.0, -hz), Vector3(-hx, 0.0, -hz),
		normal, uv_scale, colour, flip
	)


## Appends a wall with per-axis UV scaling.
##
## A building façade is metres wide and tens of metres tall; projecting it like a box would
## stretch the window texture. This primitive therefore takes the UV scale in "texture
## repeats per metre" separately for the horizontal and the vertical axis, which is exactly
## how a real façade is textured (one tile every few floors).
##
## The wall is built in the local XY plane facing local +Z; the caller passes a transform
## that rotates it onto the side of the building.
static func append_wall(
	st: SurfaceTool,
	origin: Transform3D,
	size: Vector2,
	uv_per_meter: Vector2,
	colour: Color
) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var normal := Vector3.BACK
	var u_scale := uv_per_meter.x
	var v_scale := uv_per_meter.y
	var a := Vector3(-hx, -hy, 0.0)
	var b := Vector3(hx, -hy, 0.0)
	var c := Vector3(hx, hy, 0.0)
	var d := Vector3(-hx, hy, 0.0)
	var uv_a := Vector2(0.0, 0.0)
	var uv_b := Vector2(size.x * u_scale, 0.0)
	var uv_c := Vector2(size.x * u_scale, size.y * v_scale)
	var uv_d := Vector2(0.0, size.y * v_scale)
	var tangent := Vector3(1.0, 0.0, 0.0)
	_add_vertex(st, origin, a, normal, uv_a, colour, tangent)
	_add_vertex(st, origin, b, normal, uv_b, colour, tangent)
	_add_vertex(st, origin, c, normal, uv_c, colour, tangent)
	_add_vertex(st, origin, a, normal, uv_a, colour, tangent)
	_add_vertex(st, origin, c, normal, uv_c, colour, tangent)
	_add_vertex(st, origin, d, normal, uv_d, colour, tangent)


## Appends a vertical quad facing +Z / -Z (used for road markings and signs).
static func append_wall_quad(
	st: SurfaceTool,
	origin: Transform3D,
	size: Vector2,
	uv_scale: float,
	colour: Color
) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	append_quad(
		st, origin,
		Vector3(-hx, -hy, 0.0), Vector3(hx, -hy, 0.0), Vector3(hx, hy, 0.0), Vector3(-hx, hy, 0.0),
		Vector3.BACK, uv_scale, colour
	)


## Appends a frustum: a box whose top and bottom faces can have different sizes and
## positions. This single primitive is what makes a car look like a car (tapered cabin,
## sloped hood, tapered lamp post) instead of a stack of cubes.
static func append_frustum(
	st: SurfaceTool,
	origin: Transform3D,
	bottom_size: Vector2,
	top_size: Vector2,
	height: float,
	uv_scale: float,
	colour: Color,
	top_offset: Vector3 = Vector3.ZERO,
	caps: bool = true
) -> void:
	var half := height * 0.5
	var bx := bottom_size.x * 0.5
	var bz := bottom_size.y * 0.5
	var tx := top_size.x * 0.5
	var tz := top_size.y * 0.5
	var o := top_offset
	var b0 := Vector3(-bx, -half, bz)
	var b1 := Vector3(bx, -half, bz)
	var b2 := Vector3(bx, -half, -bz)
	var b3 := Vector3(-bx, -half, -bz)
	var t0 := Vector3(-tx + o.x, half + o.y, tz + o.z)
	var t1 := Vector3(tx + o.x, half + o.y, tz + o.z)
	var t2 := Vector3(tx + o.x, half + o.y, -tz + o.z)
	var t3 := Vector3(-tx + o.x, half + o.y, -tz + o.z)
	append_quad(st, origin, b1, b0, t0, t1, Vector3.BACK, uv_scale, colour)
	append_quad(st, origin, b3, b2, t2, t3, Vector3.FORWARD, uv_scale, colour)
	append_quad(st, origin, b2, b1, t1, t2, Vector3.RIGHT, uv_scale, colour)
	append_quad(st, origin, b0, b3, t3, t0, Vector3.LEFT, uv_scale, colour)
	if caps:
		append_quad(st, origin, b0, b1, b2, b3, Vector3.DOWN, uv_scale, colour)
		append_quad(st, origin, t3, t2, t1, t0, Vector3.UP, uv_scale, colour)


## Appends a cylinder along +Y with optional caps.
static func append_cylinder(
	st: SurfaceTool,
	origin: Transform3D,
	radius: float,
	height: float,
	segments: int,
	uv_scale: float,
	colour: Color,
	caps: bool = true,
	top_radius: float = -1.0
) -> void:
	var segs := maxi(segments, 3)
	var r_top := radius if top_radius < 0.0 else top_radius
	var half := height * 0.5
	var previous := Vector3(radius, -half, 0.0)
	for i in range(1, segs + 1):
		var angle := TAU * float(i) / float(segs)
		var current := Vector3(cos(angle) * radius, -half, sin(angle) * radius)
		var current_top := Vector3(cos(angle) * r_top, half, sin(angle) * r_top)
		var previous_top := Vector3(previous.x / maxf(radius, 0.0001) * r_top, half, previous.z / maxf(radius, 0.0001) * r_top)
		var normal := Vector3(cos(angle - PI / float(segs)), 0.0, sin(angle - PI / float(segs)))
		var u0 := TAU * float(i - 1) / float(segs) * radius * uv_scale
		var u1 := TAU * float(i) / float(segs) * radius * uv_scale
		_add_vertex(st, origin, previous, normal, Vector2(u0, 0.0), colour)
		_add_vertex(st, origin, current, normal, Vector2(u1, 0.0), colour)
		_add_vertex(st, origin, current_top, normal, Vector2(u1, height * uv_scale), colour)
		_add_vertex(st, origin, previous, normal, Vector2(u0, 0.0), colour)
		_add_vertex(st, origin, current_top, normal, Vector2(u1, height * uv_scale), colour)
		_add_vertex(st, origin, previous_top, normal, Vector2(u0, height * uv_scale), colour)
		if caps and i > 1:
			append_quad(
				st, origin, Vector3(0.0, half, 0.0), previous_top, current_top, Vector3(0.0, half, 0.0),
				Vector3.UP, uv_scale, colour
			)
		previous = current
	if caps:
		var first := Vector3(radius, -half, 0.0)
		var last := Vector3(cos(TAU) * radius, -half, sin(TAU) * radius)
		append_quad(
			st, origin, Vector3(0.0, -half, 0.0), last, first, Vector3(0.0, -half, 0.0),
			Vector3.DOWN, uv_scale, colour
		)


## Appends a cone (or a pyramid when `segments` is small) pointing along +Y.
static func append_cone(
	st: SurfaceTool,
	origin: Transform3D,
	radius: float,
	height: float,
	segments: int,
	uv_scale: float,
	colour: Color
) -> void:
	append_cylinder(st, origin, radius, height, segments, uv_scale, colour, false, 0.02)


## Appends a low polygon sphere (trees, bushes, fountains).
static func append_sphere(
	st: SurfaceTool,
	origin: Transform3D,
	radius: float,
	rings: int,
	segments: int,
	uv_scale: float,
	colour: Color,
	flatten: float = 1.0
) -> void:
	var ring_count := maxi(rings, 2)
	var seg_count := maxi(segments, 3)
	for ring in range(ring_count):
		var phi0 := PI * float(ring) / float(ring_count)
		var phi1 := PI * float(ring + 1) / float(ring_count)
		for segment in range(seg_count):
			var theta0 := TAU * float(segment) / float(seg_count)
			var theta1 := TAU * float(segment + 1) / float(seg_count)
			var p00 := _sphere_point(radius, phi0, theta0, flatten)
			var p01 := _sphere_point(radius, phi0, theta1, flatten)
			var p10 := _sphere_point(radius, phi1, theta0, flatten)
			var p11 := _sphere_point(radius, phi1, theta1, flatten)
			var n00 := p00.normalized()
			var n01 := p01.normalized()
			var n10 := p10.normalized()
			var n11 := p11.normalized()
			_add_vertex(st, origin, p00, n00, Vector2(theta0 / TAU, phi0 / PI) * radius * uv_scale * 6.0, colour)
			_add_vertex(st, origin, p10, n10, Vector2(theta0 / TAU, phi1 / PI) * radius * uv_scale * 6.0, colour)
			_add_vertex(st, origin, p11, n11, Vector2(theta1 / TAU, phi1 / PI) * radius * uv_scale * 6.0, colour)
			_add_vertex(st, origin, p00, n00, Vector2(theta0 / TAU, phi0 / PI) * radius * uv_scale * 6.0, colour)
			_add_vertex(st, origin, p11, n11, Vector2(theta1 / TAU, phi1 / PI) * radius * uv_scale * 6.0, colour)
			_add_vertex(st, origin, p01, n01, Vector2(theta1 / TAU, phi0 / PI) * radius * uv_scale * 6.0, colour)


static func _sphere_point(radius: float, phi: float, theta: float, flatten: float) -> Vector3:
	var x := sin(phi) * cos(theta)
	var y := cos(phi)
	var z := sin(phi) * sin(theta)
	return Vector3(x, y * flatten, z) * radius


## Appends a staircase (used for building entrances and park steps).
static func append_stairs(
	st: SurfaceTool,
	origin: Transform3D,
	width: float,
	height: float,
	depth: float,
	steps: int,
	uv_scale: float,
	colour: Color
) -> void:
	var count := maxi(steps, 1)
	var step_h := height / float(count)
	var step_d := depth / float(count)
	for i in count:
		var y := step_h * float(i) + step_h * 0.5
		var z := depth * 0.5 - step_d * (float(i) + 0.5)
		append_box(st, origin * Transform3D(Basis(), Vector3(0.0, y, z)), Vector3(width, step_h, step_d), uv_scale, colour)


## Appends a simple railing (a bar plus posts) along +X.
static func append_railing(
	st: SurfaceTool,
	origin: Transform3D,
	length: float,
	height: float,
	uv_scale: float,
	colour: Color
) -> void:
	append_box(st, origin * Transform3D(Basis(), Vector3(0.0, height, 0.0)), Vector3(length, 0.06, 0.06), uv_scale, colour)
	var posts := maxi(int(length / 2.4), 2)
	for i in posts:
		var x := -length * 0.5 + length * float(i) / float(maxi(posts - 1, 1))
		append_box(st, origin * Transform3D(Basis(), Vector3(x, height * 0.5, 0.0)), Vector3(0.06, height, 0.06), uv_scale, colour)


## Builds a mesh out of a list of "boxes" (used for the car bodies where a package of
## simple shapes reads much better than a single box).
static func build_from_parts(parts: Array[Dictionary]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part: Dictionary in parts:
		var transform: Transform3D = part.get("transform", Transform3D())
		var size: Vector3 = part.get("size", Vector3.ONE)
		var colour: Color = part.get("colour", Color.WHITE)
		var uv_scale: float = part.get("uv_scale", DEFAULT_UV_SCALE)
		match String(part.get("shape", "box")):
			"cylinder":
				append_cylinder(st, transform, size.x, size.y, int(part.get("segments", 8)), uv_scale, colour)
			"cone":
				append_cone(st, transform, size.x, size.y, int(part.get("segments", 8)), uv_scale, colour)
			"sphere":
				append_sphere(st, transform, size.x, int(part.get("rings", 6)), int(part.get("segments", 10)), uv_scale, colour)
			"plane":
				append_plane(st, transform, Vector2(size.x, size.z), uv_scale, colour)
			_:
				append_box(st, transform, size, uv_scale, colour)
	return st.commit()


## Convenience: a single box as a finished mesh (used for tiny one-off objects).
static func box_mesh(size: Vector3, uv_scale: float = DEFAULT_UV_SCALE, colour: Color = Color.WHITE) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	append_box(st, Transform3D(), size, uv_scale, colour)
	return st.commit()
