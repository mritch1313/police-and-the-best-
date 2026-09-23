class_name MeshBuilder
extends RefCounted
## Единый конструктор геометрии для всего проекта (мир, здания, малые формы, машины).
##
## Почему один: и город, и машина строятся из «квадов в метрических UV», и правила
## должны быть одни и те же — иначе где-нибудь разъедутся масштаб текстуры, направление
## нормали или сварка вершин. Это же единственная точка, где мы «варим» вершины и
## разворачиваем нормали наружу: отладка визуальных артефактов = один файл.
##
## КЛЮЧЕВЫЕ ПРАВИЛА:
##  * `ref_center` — опорная точка ориентации. Нормаль каждой грани разворачивается так,
##    чтобы она была направлена ОТ неё. Все детали (кузов, колесо, дом) звёздно-выпуклы
##    относительно своей опоры, поэтому порядок обхода вершин можно не контролировать.
##  * `weld` — вершины с совпадающей позицией (шаг WELD_STEP) схлопываются, а нормали
##    суммируются: получаем гладкое затенение без `generate_normals()` (тот variant flat).
##  * UV — в МЕТРАХ. Материал домножает их на `1/tile_meters`, поэтому «один тайл = N метров»
##    выполняется в мире автоматически и не зависит от размера объекта (дома разной высоты
##    получают ОДИН И ТОТ ЖЕ шаг этажей, а не растянутую текстуру).
##  * `commit()` добавляет ПОВЕРХНОСТЬ в существующий ArrayMesh: несколько вызовов на одном
##    меш-объекте = несколько материалов при одном инстансе (1 draw call на поверхность).
##
## Все методы молча игнорируют вырожденную геометрию (нулевая площадь) — генератор мира
## не обязан проверять каждый случай.

const WELD_STEP := 0.0005
const UV_AUTO := 0
const UV_PLANAR_XY := 1
const UV_PLANAR_ZX := 2
const UV_PLANAR_YZ := 3

var verts: PackedVector3Array = PackedVector3Array()
var norms: PackedVector3Array = PackedVector3Array()
var uvs: PackedVector2Array = PackedVector2Array()
var idx: PackedInt32Array = PackedInt32Array()
var ref_center: Vector3 = Vector3.ZERO
## Множитель «UV на метр»: 1.0 = текстура в метрах; 2.2 для машины (мелкая потёртость).
var uv_scale: float = 1.0
var uv_mode: int = UV_AUTO
## Смещение U по длине стены (для фасадных лент, чтобы окна совпадали со швами соседних домов).
var u_offset: float = 0.0

var _weld: Dictionary = {}
var surface_index: int = -1

func _init(center: Vector3 = Vector3.ZERO, p_uv_scale: float = 1.0) -> void:
	ref_center = center
	uv_scale = p_uv_scale

## Опорная точка ориентации граней. ЕЁ НУЖНО МЕНЯТЬ перед каждым выпуклым куском:
## для кузова машины это центр машины, для дома — центр пятна застройки, для коробки —
## её центр. (Поэтому add_box/add_box_raw делают это сами, а плоские/составные вещи — нет.)
func set_ref(v: Vector3) -> void:
	ref_center = v

func count() -> int:
	return idx.size() / 3

func vertex_count() -> int:
	return verts.size()

func has_geometry() -> bool:
	return not idx.is_empty()

func clear() -> void:
	verts.resize(0)
	norms.resize(0)
	uvs.resize(0)
	idx.resize(0)
	_weld.clear()

# ------------------------------------------------------------------ примитивы

func add_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	var mid := (a + b + c) * (1.0 / 3.0)
	if n.dot(mid - ref_center) < 0.0:
		var swap := b
		b = c
		c = swap
		n = -n
	n = n.normalized()
	var ia := _vertex(a, n, mid)
	var ib := _vertex(b, n, mid)
	var ic := _vertex(c, n, mid)
	if ia == ib or ib == ic or ia == ic:
		return
	idx.append(ia)
	idx.append(ib)
	idx.append(ic)

func add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	add_tri(a, b, c)
	add_tri(a, c, d)

## Плоский прямоугольник в XZ на высоте y (грунт, разметка, площадка).
func add_flat_rect(rect: Rect2, y: float, uv_align: bool = true) -> void:
	var a := Vector3(rect.position.x, y, rect.position.y)
	var b := Vector3(rect.end.x, y, rect.position.y)
	var c := Vector3(rect.end.x, y, rect.end.y)
	var d := Vector3(rect.position.x, y, rect.end.y)
	# Грунт смотрит вверх независимо от ref_center: у плоскостей «наружу» = +Y.
	add_quad_uv(Vector3(a.x, y, a.z), Vector3(b.x, y, b.z), Vector3(c.x, y, c.z), Vector3(d.x, y, d.z),
		Vector3.UP, rect.position * uv_scale if uv_align else Vector2.ZERO, rect.size)

## Стена по двум точкам в плане (её «вектор длины») + высота. UV: U вдоль стены, ровно то,
## что нужно для фасадной ленты с окнами.
## normal_hint — «наружу» (для стены дома это vector от центра пятна застройки к стене).
## Без подсказки нормаль берётся из ref_center (см. set_ref).
func add_wall(p0: Vector2, p1: Vector2, y0: float, y1: float, normal_hint: Vector3 = Vector3.ZERO) -> void:
	var length := p0.distance_to(p1)
	var a := Vector3(p0.x, y0, p0.y)
	var b := Vector3(p1.x, y0, p1.y)
	var c := Vector3(p1.x, y1, p1.y)
	var d := Vector3(p0.x, y1, p0.y)
	var n := normal_hint
	if n.length_squared() < 1e-8:
		var mid := (a + c) * 0.5
		var from_ref := mid - ref_center
		n = Vector3(from_ref.x, 0.0, from_ref.z)
		if n.length_squared() < 1e-8:
			n = Vector3.UP.cross((b - a).normalized())
		n = n.normalized()
	add_quad_uv(a, b, c, d, n, Vector2(u_offset, y0), Vector2(length, y1 - y0))

## Quad с явными UV (u0..u0+size) — используется там, где нужна «раскладка по метрам».
func add_quad_uv(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, uv_origin: Vector2, uv_size: Vector2) -> void:
	var n := normal.normalized() if normal.length_squared() > 1e-8 else Vector3.UP
	var ua := uv_origin
	var ub := uv_origin + Vector2(uv_size.x, 0.0)
	var uc := uv_origin + uv_size
	var ud := uv_origin + Vector2(0.0, uv_size.y)
	# Согласование обхода с нормалью: индексы разворачиваются, если геометрическая нормаль
	# смотрит в другую сторону. Иначе на мобильном рендере с CULL_BACK часть стен исчезнет.
	var geom := (b - a).cross(c - a)
	var flipped := geom.length_squared() > 1e-12 and geom.dot(n) < 0.0
	var ia := _vertex_with_uv(a, n, ua)
	var ib := _vertex_with_uv(b, n, ub)
	var ic := _vertex_with_uv(c, n, uc)
	var id := _vertex_with_uv(d, n, ud)
	if not flipped:
		if ia != ib and ib != ic and ia != ic:
			idx.append(ia)
			idx.append(ib)
			idx.append(ic)
		if ia != ic and ic != id and ia != id:
			idx.append(ia)
			idx.append(ic)
			idx.append(id)
	else:
		if ia != ic and ic != ib and ia != ib:
			idx.append(ia)
			idx.append(ic)
			idx.append(ib)
		if ia != id and id != ic and ia != ic:
			idx.append(ia)
			idx.append(id)
			idx.append(ic)

## «Выдавленная» призма-клин (крыша сарая, пандус, бордюрная грань):
## треугольник в плоскости XY, протянутый вдоль Z.
func add_wedge(p0: Vector2, p1: Vector2, y_base: float, y_peak: float, z0: float, z1: float) -> void:
	var a := Vector3(p0.x, y_base, z0)
	var b := Vector3(p1.x, y_base, z0)
	var c := Vector3(lerpf(p0.x, p1.x, 0.5), y_peak, z0)
	var d := Vector3(p0.x, y_base, z1)
	var e := Vector3(p1.x, y_base, z1)
	var f := Vector3(lerpf(p0.x, p1.x, 0.5), y_peak, z1)
	add_quad(a, b, e, d)
	add_quad(a, c, f, d)
	add_quad(b, e, f, c)
	add_tri(c, b, a)
	add_tri(f, e, d)

func add_box(center: Vector3, half: Vector3) -> void:
	var x := maxf(absf(half.x), 0.003)
	var y := maxf(absf(half.y), 0.003)
	var z := maxf(absf(half.z), 0.003)
	add_box_raw(center - Vector3(x, y, z), center + Vector3(x, y, z))

## Коробка по AABB — основной примитив города (дома, блоки, шкафы, техника).
## Ориентацию граней builder получает из ЦЕНТРА коробки, поэтому вызывающему не нужно
## ничего выставлять: коробка корректна в любом месте чанка.
func add_box_raw(min_corner: Vector3, max_corner: Vector3) -> void:
	var a := min_corner
	var b := max_corner
	var saved := ref_center
	ref_center = (min_corner + max_corner) * 0.5
	var v: Array[Vector3] = [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	add_quad(v[1], v[0], v[3], v[2])
	add_quad(v[4], v[5], v[6], v[7])
	add_quad(v[5], v[1], v[2], v[6])
	add_quad(v[0], v[4], v[7], v[3])
	add_quad(v[0], v[1], v[5], v[4])
	add_quad(v[2], v[3], v[7], v[6])
	ref_center = saved

## Коробка по прямоугольнику в плане + высоте (стены + крыша, без «дна»).
func add_prism(rect: Rect2, y0: float, y1: float, with_roof: bool = true) -> void:
	var p := rect.position
	var e := rect.end
	add_wall(Vector2(p.x, p.y), Vector2(e.x, p.y), y0, y1)
	add_wall(Vector2(e.x, p.y), Vector2(e.x, p.y), y0, y1)
	add_wall(Vector2(e.x, p.y), Vector2(p.x, p.y), y0, y1)
	add_wall(Vector2(p.x, p.y), Vector2(p.x, e.y), y0, y1)
	add_wall(Vector2(p.x, e.y), Vector2(e.x, e.y), y0, y1)
	if with_roof:
		add_flat_rect(rect, y1, false)

## Лента вращения вокруг оси X (протектор/боковина колеса, труба, цилиндр).
func add_band(x0: float, x1: float, r0: float, r1: float, steps: int) -> void:
	for i in range(steps):
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		add_quad(
			Vector3(x0, r0 * sin(a0), r0 * cos(a0)),
			Vector3(x0, r0 * sin(a1), r0 * cos(a1)),
			Vector3(x1, r1 * sin(a1), r1 * cos(a1)),
			Vector3(x1, r1 * sin(a0), r1 * cos(a0)),
		)

## Диск-«тарелка» в плоскости YZ на x = x0.
func add_disc(x0: float, radius: float, steps: int, center_yz: Vector2 = Vector2.ZERO) -> void:
	for i in range(steps):
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		add_tri(
			Vector3(x0, center_yz.x, center_yz.y),
			Vector3(x0, center_yz.x + radius * sin(a1), center_yz.y + radius * cos(a1)),
			Vector3(x0, center_yz.x + radius * sin(a0), center_yz.y + radius * cos(a0)),
		)

## Вертикальный цилиндр вокруг точки (столб, дерево, труба, урна).
func add_cylinder(axis: Vector3, radius: float, height: float, steps: int) -> void:
	var base := axis
	for i in range(steps):
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		var p00 := base + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p01 := base + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		var p11 := p01 + Vector3(0.0, height, 0.0)
		var p10 := p00 + Vector3(0.0, height, 0.0)
		add_quad(p00, p01, p11, p10)
	add_disc_y(base, radius, steps)
	add_disc_y(base + Vector3(0.0, height, 0.0), radius, steps)

func add_disc_y(center: Vector3, radius: float, steps: int) -> void:
	for i in range(steps):
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		add_tri(
			center,
			center + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius),
			center + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius),
		)

## Арка: дуга в плоскости x = out_x, от внутреннего радиуса к наружному + «полка» внутрь.
func add_arch(center: Vector3, out_x: float, radius: float, depth: float) -> void:
	var steps := 10
	var sgn := signf(out_x) if absf(out_x) > 1e-6 else 1.0
	for i in range(steps):
		var a0 := PI * (0.06 + 0.88 * float(i) / float(steps))
		var a1 := PI * (0.06 + 0.88 * float(i + 1) / float(steps))
		var p0 := Vector3(out_x, center.y + sin(a0) * radius * 0.94, center.z + cos(a0) * radius * 0.94)
		var p1 := Vector3(out_x, center.y + sin(a1) * radius * 0.94, center.z + cos(a1) * radius * 0.94)
		var p2 := Vector3(out_x, center.y + sin(a1) * radius, center.z + cos(a1) * radius)
		var p3 := Vector3(out_x, center.y + sin(a0) * radius, center.z + cos(a0) * radius)
		add_quad(p0, p1, p2, p3)
		var q0 := p3 + Vector3(-depth * sgn, 0.0, 0.0)
		var q1 := p2 + Vector3(-depth * sgn, 0.0, 0.0)
		add_quad(p3, p2, q1, q0)

## Полоса (уплотнитель окна, стойка, зазор между панелями).
func add_strip(a: Vector3, b: Vector3, offset: Vector3) -> void:
	add_quad(a, b, b + offset, a + offset)

func connect_rings(a: PackedVector3Array, b: PackedVector3Array) -> void:
	var n := mini(a.size(), b.size())
	for i in range(n):
		var j := (i + 1) % n
		add_quad(a[i], a[j], b[j], b[i])

func cap_ring(ring: PackedVector3Array, dir: Vector3) -> void:
	if ring.is_empty():
		return
	var center := Vector3.ZERO
	for p in ring:
		center += p
	center = center / float(ring.size()) + dir * 0.06
	for i in range(ring.size()):
		var j := (i + 1) % ring.size()
		if dir.z < 0.0:
			add_tri(center, ring[j], ring[i])
		else:
			add_tri(center, ring[i], ring[j])

## Вставка готового массива вершин (PrimitiveMesh.create_arrays()) с трансформантом.
## Так из «коробок/цилиндров» движка собираются составные малые формы, оставаясь одним мешем.
func merge_arrays(arrays: Array, xform: Transform3D) -> void:
	if arrays.size() < Mesh.ARRAY_MAX:
		return
	var src_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if src_verts.is_empty():
		return
	var src_norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var src_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var base := verts.size()
	for i in range(src_verts.size()):
		verts.append(xform * src_verts[i])
		var n := src_norms[i] if i < src_norms.size() else Vector3.UP
		var face_mid := xform * src_verts[i]
		if n.dot(face_mid - ref_center) < 0.0:
			n = -n
		norms.append(n.normalized())
		uvs.append(src_uvs[i] if i < src_uvs.size() else Vector2.ZERO)
	var src_idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if src_idx.is_empty():
		for i in range(src_verts.size() / 3):
			idx.append(base + i * 3)
			idx.append(base + i * 3 + 1)
			idx.append(base + i * 3 + 2)
	else:
		for i in range(src_idx.size()):
			idx.append(base + src_idx[i])

# ------------------------------------------------------------------ внутреннее

func _uv_for(p: Vector3, n: Vector3) -> Vector2:
	match uv_mode:
		UV_PLANAR_XY:
			return Vector2(p.x, p.y) * uv_scale
		UV_PLANAR_ZX:
			return Vector2(p.z, p.x) * uv_scale
		UV_PLANAR_YZ:
			return Vector2(p.z, p.y) * uv_scale
	var ax := absf(n.x)
	var ay := absf(n.y)
	var az := absf(n.z)
	# Автовыбор проекции по НОРМАЛИ грани: пол/потолок -> (x, z), стена «вдоль X» -> (z, y),
	# стена «вдоль Z» -> (x, y). Так тайл текстуры одинаков на всех поверхностях.
	if ay >= ax and ay >= az:
		return Vector2(p.x, p.z) * uv_scale
	if ax >= az:
		return Vector2(p.z, p.y) * uv_scale
	return Vector2(p.x, p.y) * uv_scale

func _vertex(p: Vector3, n: Vector3, _mid: Vector3) -> int:
	return _vertex_with_uv(p, n, _uv_for(p, n))

func _vertex_with_uv(p: Vector3, n: Vector3, uv: Vector2) -> int:
	var key := "%d|%d|%d" % [
		int(round(p.x / WELD_STEP)), int(round(p.y / WELD_STEP)), int(round(p.z / WELD_STEP)),
	]
	if _weld.has(key):
		var existing: int = _weld[key]
		norms[existing] += n
		return existing
	var i := verts.size()
	verts.append(p)
	norms.append(n)
	uvs.append(uv)
	_weld[key] = i
	return i

## Итог: добавить поверхность в ArrayMesh (или создать новый меш, если mesh == null).
func commit(mesh: ArrayMesh = null) -> ArrayMesh:
	if not has_geometry():
		return mesh
	for i in range(norms.size()):
		var n := norms[i]
		norms[i] = n.normalized() if n.length_squared() > 1e-8 else Vector3.UP
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var target := mesh
	if target == null:
		target = ArrayMesh.new()
	target.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	surface_index = target.get_surface_count() - 1
	return target
