class_name BuildingKit
extends RefCounted
## Детализация одного здания: цоколь, этажные ленты, карниз, парапет, вход с козырьком,
## витрина, балконы, «крыло» Г-образного корпуса, кровельная инженерка.
##
## Почему это выглядит городом, а не «серыми кубами»:
##  * Стены — по одному кваду на сторону, но UV в МЕТРАХ: лента окон из текстуры сама
##    совпадает с `floor_height_m`, поэтому и у 4-этажки, и у 17-этажки окна одной высоты
##    стоят по своим этажам. Никакого «растянутого фасада» — главного признака прототипа.
##  * Объём дают реальные выступы (цоколь +0.14, карниз +0.22, парапет, балконы, козырёк):
##    от них падают настоящие тени, что на мобильном рендере дешевле любого AO.
##  * Коллизия = 4 стены + кровля (10 треугольников на дом), окклюдер = приподнятый силуэт.
##
## ВАЖНО ПРО TYPED-МАССИВЫ: PackedVector3Array в GDScript — значение с copy-on-write,
## поэтому `append` внутри статической функции ДОХОДИТ ДО КОПИИ, а не до данных вызывающего.
## Весь «побочный вывод» (коллизия, окклюдеры) идёт через ссылочный объект `Sink`.

const PLINTH_HEIGHT_M := 1.05
const PLINTH_PROTRUDE_M := 0.14
const CORNICE_PROTRUDE_M := 0.22
const CORNICE_HEIGHT_M := 0.5
const WING_HEIGHT_RATIO := 0.72
const MAX_ROOF_UNITS := 3
const MAX_BALCONY_FLOORS := 8
const BALCONY_SPAN_M := 5.4

## Накопитель «побочных» геометрий одного чанка. Ссылочный — специально, см. шапку файла.
class Sink:
	extends RefCounted

	var collision: PackedVector3Array = PackedVector3Array()
	var occluder: PackedVector3Array = PackedVector3Array()
	## Сколько «полигонов-стен» ещё можно в окклюдер (квота на чанк из GraphicsConfig).
	var occluder_left: int = 0

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, into_collision: bool = true, into_occluder: bool = false) -> void:
		if into_collision:
			collision.append(a)
			collision.append(b)
			collision.append(c)
			collision.append(a)
			collision.append(c)
			collision.append(d)
		if into_occluder and occluder_left > 0:
			occluder_left -= 1
			occluder.append(a)
			occluder.append(b)
			occluder.append(c)
			occluder.append(a)
			occluder.append(c)
			occluder.append(d)

	## Стены дома для физики: ровно по пятну застройки (иначе машина отскакивала бы
	## от «воздуха» в 30 см от стены).
	func rect_walls(rect: Rect2, y0: float, y1: float) -> void:
		var p := rect.position
		var e := rect.end
		quad(Vector3(p.x, y0, p.y), Vector3(e.x, y0, p.y), Vector3(e.x, y1, p.y), Vector3(p.x, y1, p.y), true, false)
		quad(Vector3(e.x, y0, p.y), Vector3(e.x, y0, e.y), Vector3(e.x, y1, e.y), Vector3(e.x, y1, p.y), true, false)
		quad(Vector3(e.x, y0, e.y), Vector3(p.x, y0, e.y), Vector3(p.x, y1, e.y), Vector3(e.x, y1, e.y), true, false)
		quad(Vector3(p.x, y0, e.y), Vector3(p.x, y0, p.y), Vector3(p.x, y1, p.y), Vector3(p.x, y1, e.y), true, false)

	## Силуэт для окклюдера: rect с запасом, на всю высоту + парапет. Только occluder.
	func rect_silhouette(rect: Rect2, y0: float, y1: float) -> void:
		var p := rect.position
		var e := rect.end
		quad(Vector3(p.x, y0, p.y), Vector3(e.x, y0, p.y), Vector3(e.x, y1, p.y), Vector3(p.x, y1, p.y), false, true)
		quad(Vector3(e.x, y0, p.y), Vector3(e.x, y0, e.y), Vector3(e.x, y1, e.y), Vector3(e.x, y1, p.y), false, true)
		quad(Vector3(e.x, y0, e.y), Vector3(p.x, y0, e.y), Vector3(p.x, y1, e.y), Vector3(e.x, y1, e.y), false, true)
		quad(Vector3(p.x, y0, e.y), Vector3(p.x, y0, p.y), Vector3(p.x, y1, p.y), Vector3(p.x, y1, e.y), false, true)

	func rect_top(rect: Rect2, y: float) -> void:
		var p := rect.position
		var e := rect.end
		quad(Vector3(p.x, y, p.y), Vector3(e.x, y, p.y), Vector3(e.x, y, e.y), Vector3(p.x, y, e.y), true, false)

	func triangles() -> int:
		return collision.size() / 3

## Высота парапта нужна ДО того, как мы его построили (для силуэта окклюдера).
static func parapet_estimate(entry: Dictionary) -> float:
	return maxf(float(entry.get("parapet", 0.5)), 0.0) + 0.3

static func material_for_style(style: String) -> String:
	match style:
		"office":
			return "facade_office"
		"brick":
			return "facade_brick"
		"industrial":
			return "metal_panel"
		"block":
			return "roadblock"
		"glass":
			return "facade_glass"
	return "facade_residential"

## entry — словарь из WorldGenerator.chunk_layout()["buildings"].
static func add_building(builders: Dictionary, entry: Dictionary, cfg: WorldConfig, sink: Sink, detail: bool) -> void:
	var walls := builders.get(material_for_style(String(entry.get("style", "residential")))) as MeshBuilder
	var trim := builders.get("curb") as MeshBuilder
	var roof := builders.get("roof_gravel") as MeshBuilder
	var dark := builders.get("metal_dark") as MeshBuilder
	var glass := builders.get("glass_sheet") as MeshBuilder
	var panel := builders.get("metal_panel") as MeshBuilder
	if walls == null or trim == null or roof == null:
		return
	var footprint: Rect2 = entry["footprint"]
	var height := maxf(float(entry.get("height", 6.0)), 1.2)
	var floors := int(entry.get("floors", 2))
	var floor_height := maxf(float(entry.get("floor_height", 3.25)), 2.2)
	var side := int(entry.get("side", 0))
	var want_collision := sink != null
	var occluder_ok := sink != null and sink.occluder_left > 0 and height >= cfg.occluder_min_height_m

	# 1) Стены + кровля.
	wall_ring(walls, footprint, 0.0, height)
	roof.add_flat_rect(footprint.grow(-0.05), height + 0.02, false)
	if want_collision:
		sink.rect_walls(footprint.grow(0.04), 0.0, height + 0.1)
	if occluder_ok:
		sink.rect_silhouette(footprint.grow(0.4), 0.0, height + parapet_estimate(entry) + 0.4)

	# 2) Цоколь, карниз, парапет.
	var plinth_top := minf(PLINTH_HEIGHT_M, height * 0.5)
	ring(trim, footprint.grow(PLINTH_PROTRUDE_M), 0.0, plinth_top)
	var cornice_top := height + 0.30
	ring(trim, footprint.grow(CORNICE_PROTRUDE_M), height - CORNICE_HEIGHT_M, cornice_top)
	var parapet := maxf(float(entry.get("parapet", 0.5)), 0.0)
	if parapet > 0.05:
		ring(trim, footprint.grow(0.06), cornice_top, cornice_top + parapet)

	# 3) Витрина, козырёк, вход (только в ближнем LOD — дальше их всё равно не видно).
	if bool(entry.get("shopfront", false)) and detail and height > floor_height * 1.6:
		var band_top := minf(floor_height * 0.92, height - 0.6)
		ring(glass, footprint.grow(-0.10), 0.55, band_top)
		ring(trim, footprint.grow(0.05), band_top, band_top + 0.16)
		var front_side := side == 0
		var awning_z := footprint.position.y - 0.85 if front_side else footprint.end.y + 0.85
		var awning_x := footprint.position.x + footprint.size.x * float(entry.get("entrance", 0.5))
		if dark != null:
			dark.add_box(Vector3(awning_x, band_top + 0.20, awning_z), Vector3(1.9, 0.055, 0.85))
			dark.add_box(Vector3(awning_x, 1.15, footprint.position.y - 0.02 if front_side else footprint.end.y + 0.02),
				Vector3(0.9, 1.15, 0.10))
		if panel != null:
			panel.add_box(Vector3(awning_x, band_top + 0.60, awning_z), Vector3(1.7, 0.28, 0.09))

	# 4) Балконы: жилая застройка, нижние этажи, одна сторона.
	if bool(entry.get("balconies", false)) and detail:
		var along_x := side < 2
		var front_coord := (footprint.position.y - 0.60) if side == 0 else (footprint.end.y + 0.60)
		if not along_x:
			front_coord = (footprint.position.x - 0.60) if side == 3 else (footprint.end.x + 0.60)
		var span := footprint.size.x if along_x else footprint.size.y
		var count := clampi(int(span / BALCONY_SPAN_M), 1, 4)
		for f in range(1, mini(floors, MAX_BALCONY_FLOORS)):
			var y := float(f) * floor_height
			for k in range(count):
				var t := (float(k) + 0.5) / float(count)
				var center := Vector3(lerpf(footprint.position.x, footprint.end.x, t), y, front_coord) if along_x \
					else Vector3(front_coord, y, lerpf(footprint.position.y, footprint.end.y, t))
				var half := Vector3(1.05, 0.07, 0.55) if along_x else Vector3(0.55, 0.07, 1.05)
				trim.add_box(center, half)
				var rail_offset := Vector3(0.0, 0.34, 0.50 * signf(center.z - footprint.get_center().z)) if along_x \
					else Vector3(0.50 * signf(center.x - footprint.get_center().x), 0.34, 0.0)
				trim.add_box(center + rail_offset, Vector3(half.x, 0.30, 0.05) if along_x else Vector3(0.05, 0.30, half.z))
				# Боковые щёки балкона: без них плита «висит» нечитаемой полосой.
				trim.add_box(center + Vector3(half.x * 0.94, 0.26, 0.0), Vector3(0.05, 0.26, half.z * 0.9))
				trim.add_box(center + Vector3(-half.x * 0.94, 0.26, 0.0), Vector3(0.05, 0.26, half.z * 0.9))

	# 5) «Крыло» Г-образного корпуса.
	if float(entry.get("wing", 0.0)) > 0.62 and footprint.size.x > 14.0 and footprint.size.y > 12.0:
		var wing_rect := Rect2(
			footprint.position + Vector2(footprint.size.x * 0.64, footprint.size.y * 0.52),
			Vector2(footprint.size.x * 0.30, footprint.size.y * 0.42)
		)
		wing_rect = wing_rect.intersection(footprint.grow(2.5))
		var wing_top := height * WING_HEIGHT_RATIO
		if wing_rect.size.x > 3.0 and wing_rect.size.y > 3.0:
			wall_ring(walls, wing_rect, 0.0, wing_top)
			roof.add_flat_rect(wing_rect.grow(-0.05), wing_top + 0.02, false)
			ring(trim, wing_rect.grow(CORNICE_PROTRUDE_M), wing_top - 0.35, wing_top + 0.12)
			if want_collision:
				sink.rect_walls(wing_rect, 0.0, wing_top + 0.1)

	# 6) Кровельная инженерка + шахта лифта.
	if bool(entry.get("roof_units", false)) and detail and panel != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = absi(int(footprint.position.x * 73.0) + int(footprint.position.y * 151.0) + int(height * 31.0))
		for i in range(rng.randi_range(1, MAX_ROOF_UNITS)):
			var pos := Vector3(
				footprint.position.x + footprint.size.x * rng.randf_range(0.15, 0.85),
				cornice_top + parapet + 0.55,
				footprint.position.y + footprint.size.y * rng.randf_range(0.15, 0.85)
			)
			panel.add_box(pos, Vector3(rng.randf_range(0.7, 1.5), 0.55, rng.randf_range(0.7, 1.3)))
			panel.add_box(pos + Vector3(0.0, 0.72, 0.0), Vector3(0.16, 0.18, 0.16))
		panel.add_box(Vector3(footprint.get_center().x, cornice_top + parapet + 1.2, footprint.get_center().y),
			Vector3(1.3, 1.2, 1.2))
		if want_collision:
			sink.rect_top(footprint, height + parapet + 0.1)

# ------------------------------------------------------------------ переиспользуемое

## Четыре стены прямоугольника с корректной раскладкой UV (U идёт по периметру, поэтому
## окно не «перепрыгивает» угол дома).
static func wall_ring(builder: MeshBuilder, rect: Rect2, y0: float, y1: float) -> void:
	if builder == null or y1 <= y0:
		return
	var p := rect.position
	var e := rect.end
	# Ориентация стен — от центра пятна застройки: у всех четырёх сторон нормаль «наружу».
	builder.set_ref(Vector3(rect.get_center().x, (y0 + y1) * 0.5, rect.get_center().y))
	builder.u_offset = 0.0
	builder.add_wall(Vector2(p.x, p.y), Vector2(e.x, p.y), y0, y1)
	builder.u_offset = rect.size.x
	builder.add_wall(Vector2(e.x, p.y), Vector2(e.x, e.y), y0, y1)
	builder.u_offset = rect.size.x + rect.size.y
	builder.add_wall(Vector2(e.x, e.y), Vector2(p.x, e.y), y0, y1)
	builder.u_offset = rect.size.x + rect.size.y * 2.0
	builder.add_wall(Vector2(p.x, e.y), Vector2(p.x, p.y), y0, y1)
	builder.u_offset = 0.0

## «Ободок» вокруг rect: 4 стены + верхняя полка (цоколь, карниз, парапет).
static func ring(builder: MeshBuilder, rect: Rect2, y0: float, y1: float) -> void:
	if builder == null or y1 <= y0:
		return
	wall_ring(builder, rect, y0, y1)
	builder.add_flat_rect(rect, y1, false)
