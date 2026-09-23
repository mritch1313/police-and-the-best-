class_name WorldConfig
extends ConfigResource
## Геометрия и плотность процедурного города.
##
## Игрок появляется на бетонной площадке; `world_radius_m` = 500 означает бетон
## на 500 метров во все стороны (полигон 1000x1000 м), как в требованиях.
## Сеть дорог — прямоугольная решётка: кварталы, набережные переулки, проспекты
## каждые `avenue_every` линий. Всё детерминировано по `seed`, поэтому чанк
## восстанавливается байт-в-байт после выгрузки.

@export_group("Streaming")
@export_range(48.0, 600.0, 1.0) var chunk_size_m: float = 200.0
## Радиус загрузки в чанках (1 = 3x3 вокруг игрока).
@export_range(0, 4, 1) var load_radius_chunks: int = 1
## Буфер до выгрузки (чтобы не дёргать генератор на границе).
@export_range(0.0, 4.0, 0.1) var unload_margin_chunks: float = 0.6
@export_range(1, 64, 1) var max_active_chunks: int = 12
## Бюджет генерации на кадр (мс) — защита от фризов при въезде в новый чанк.
@export_range(0.5, 40.0, 0.5) var chunk_build_budget_ms: float = 5.5
## Полудетерминированный сид генерации.
@export var seed: int = 20260923

@export_group("Extent and ground")
## Бетон вокруг спавна: 500 м в каждую сторону.
@export_range(120.0, 4000.0, 10.0) var world_radius_m: float = 500.0
## Плиты бетона: видимая сетка швов как на референсе.
@export_range(2.0, 20.0, 0.5) var concrete_slab_m: float = 6.0
@export var concrete_color: Color = Color(0.60, 0.60, 0.585, 1.0)
@export var concrete_joint_color: Color = Color(0.44, 0.45, 0.45, 1.0)
@export var concrete_slab_tint_variance: float = 0.045
@export var asphalt_color: Color = Color(0.145, 0.148, 0.155, 1.0)
@export var sidewalk_color: Color = Color(0.52, 0.52, 0.51, 1.0)
@export var ground_grain: float = 0.14
## Уровень «земли» (Y) для спавна машины.
## Слои физики: чанк (земля+дома) — «World», мягкая/твёрдая мелочь — «Prop».
## Камера и машины настраивают маски в camera.cfg / vehicle.cfg.
@export var collision_layer: int = 1
@export var prop_collision_layer: int = 4

@export var ground_y_m: float = 0.0
@export var spawn_height_m: float = 0.62

@export_group("Road grid")
@export_range(30.0, 220.0, 1.0) var block_pitch_m: float = 82.0
@export_range(7.0, 30.0, 0.5) var road_width_m: float = 15.0
@export_range(9.0, 40.0, 0.5) var avenue_width_m: float = 21.0
@export_range(2, 8, 1) var avenue_every: int = 3
@export_range(1.0, 12.0, 0.5) var sidewalk_width_m: float = 4.5
@export_range(0.05, 0.6, 0.01) var curb_height_m: float = 0.15
@export var road_markings: bool = true
@export_range(1.0, 12.0, 0.5) var dash_length_m: float = 3.0
@export_range(1.0, 20.0, 0.5) var dash_gap_m: float = 5.0
## Ширина парковочных карманов у кварталов.
@export_range(0.0, 6.0, 0.1) var parking_bay_m: float = 2.6

@export_group("Buildings")
@export_range(0.0, 1.0, 0.01) var building_density: float = 0.86
@export_range(1, 12, 1) var max_buildings_per_block: int = 4
@export_range(2, 30, 1) var min_floors: int = 2
@export_range(3, 60, 1) var max_floors: int = 17
@export_range(2.4, 5.0, 0.05) var floor_height_m: float = 3.25
## Шанс, что здание — «стеклянный офис» вместо бетона/кирпича.
@export_range(0.0, 1.0, 0.01) var office_share: float = 0.34
@export_range(0.0, 1.0, 0.01) var brick_share: float = 0.30
@export_range(0.0, 1.0, 0.01) var industrial_share: float = 0.14
@export_range(0.0, 1.0, 0.01) var balcony_share: float = 0.45
@export_range(0.0, 1.0, 0.01) var rooftop_props_share: float = 0.75
@export_range(0.0, 1.0, 0.01) var shopfront_share: float = 0.62
## Отступ здания от края квартала.
@export_range(0.5, 12.0, 0.5) var lot_inset_m: float = 3.0
## Максимум этажей в реальной геометрии; выше — упрощённый верх (дешёвая дальняя перспектива).
@export_range(4, 40, 1) var detailed_floors_max: int = 12

@export_group("Props and clutter")
@export_range(0, 80, 1) var street_lamps_per_chunk: int = 26
@export_range(0, 80, 1) var trees_per_chunk: int = 22
@export_range(0, 60, 1) var bins_per_chunk: int = 12
@export_range(0, 80, 1) var cones_per_chunk: int = 14
@export_range(0, 40, 1) var barriers_per_chunk: int = 7
@export_range(0, 60, 1) var dumpsters_per_chunk: int = 6
@export_range(0, 40, 1) var traffic_lights_per_chunk: int = 8
@export_range(0, 120, 1) var parked_cars_per_chunk: int = 34
@export_range(0.0, 1.0, 0.01) var props_for_small_buildings: float = 0.6

@export_group("Distance budget")
## Полная видимость с деталями (м).
@export_range(40.0, 900.0, 5.0) var detail_distance_m: float = 165.0
## После этого включается упрощённый LOD, ещё дальше — «неболин»-объёмки.
@export_range(60.0, 2000.0, 5.0) var lod1_distance_m: float = 300.0
@export_range(100.0, 4000.0, 10.0) var lod2_distance_m: float = 560.0
## Дальность отсечки (fog + culling).
@export_range(200.0, 6000.0, 20.0) var cull_distance_m: float = 900.0
## Дальнее кольцо силуэта города за пределами полигона (м).
@export_range(0.0, 4000.0, 10.0) var skyline_ring_start_m: float = 640.0
@export_range(0.0, 6000.0, 10.0) var skyline_ring_end_m: float = 2200.0
@export_range(0, 1200, 10) var skyline_instances: int = 300
## Плотность тумана на дальней границе (0 = выключен).
@export_range(0.0, 0.05, 0.0005) var fog_density: float = 0.0016
@export var fog_color: Color = Color(0.66, 0.72, 0.80, 1.0)

@export_group("Navigation and occlusion")
@export var build_occluders: bool = true
## Только здания выше этого создают окклюдер (дешёвый BVH).
@export_range(3.0, 60.0, 0.5) var occluder_min_height_m: float = 11.0
## Максимум окклюдеров на чанк.
@export_range(0, 256, 1) var occluders_per_chunk_max: int = 28
## Шаг узлов дорожного графа (м) — по нему считается навигация и маршрут полиции.
@export_range(6.0, 80.0, 1.0) var nav_node_spacing_m: float = 18.0
## Допуск привязки машины к ближайшему узлу (м).
@export_range(1.0, 60.0, 0.5) var nav_snap_tolerance_m: float = 26.0

@export_group("Dev")
## Высота, с которой CI делает скриншот карты сверху (для иконки карты в меню).
@export_range(60.0, 4000.0, 10.0) var topdown_shot_height_m: float = 780.0

func grid_lines_across(radius: float) -> int:
	return int(floor(radius * 2.0 / block_pitch_m))

func is_avenue(index: int) -> bool:
	if avenue_every < 2:
		return true
	var v := absi(index) % avenue_every
	return v == 0

func road_half_width_for(index: int) -> float:
	return (avenue_width_m if is_avenue(index) else road_width_m) * 0.5

func chunk_span_count() -> int:
	return int(ceil(world_radius_m * 2.0 / chunk_size_m))

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if block_pitch_m <= road_width_m + sidewalk_width_m * 2.0:
		problems.append(_problem("квартал %.1f м не помещает дорогу %.1f м и тротуары" % [block_pitch_m, road_width_m]))
	if lod1_distance_m >= lod2_distance_m or detail_distance_m >= lod1_distance_m:
		problems.append(_problem("LOD-дистанции должны расти: detail < lod1 < lod2"))
	if cull_distance_m < lod2_distance_m:
		problems.append(_problem("cull_distance_m меньше lod2_distance_m — упрощённый LOD не будет виден"))
	if world_radius_m < chunk_size_m:
		problems.append(_problem("мир меньше одного чанка — стриминг теряет смысл"))
	if detailed_floors_max < min_floors:
		problems.append(_problem("detailed_floors_max меньше min_floors"))
	if max_buildings_per_block * floor_height_m * min_floors <= 0.0:
		problems.append(_problem("нулевая плотность застройки"))
	return problems
