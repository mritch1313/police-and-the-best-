class_name VehicleVisualModel
extends Node3D
## Контракт визуальной модели автомобиля.
##
## ФИЗИКА НЕ ЗНАЕТ НИЧЕГО ОБ ЭТОЙ ВЕТКЕ. `VehiclePhysics`/`VehicleController` живут на
## RigidBody3D и только выставляют состояние (колёса, педали, режимы). Визуал читает
## состояние один раз на кадр. Поэтому можно поставить вместо процедурной модели GLB-сцену
## (или наоборот) — достаточно реализовать эти методы, см. docs/CAR_MODEL.md.
##
## Узел вешается РЕБЁНКОМ на RigidBody3D, то есть уже находится в системе координат кузова
## (начало = плоскость ступиц, вперёд = -Z). Никаких заимствований глобального трансформанта.

## Узел, к которому крепится «тело»: лёгкий крен/клевёнок от работы подвески.
var body_pivot: Node3D = null
var config: VehicleConfig = null
var physics: Node = null
## Признак «игрок»: только ему включают фары-источники света (лимит динамических источников!).
var player_car: bool = false
var brake_intensity: float = 0.0
var nitro_intensity: float = 0.0
var lightbar_enabled: bool = false
var lightbar_time: float = 0.0
var headlights_on: bool = true

func setup(p_config: VehicleConfig, p_physics: Node, p_player: bool = false) -> void:
	config = p_config
	physics = p_physics
	player_car = p_player

## Вызывается из родителя каждый кадр (`_process`), а не из физики: визуал не должен
## дёргать физику, иначе на 60 Гц и 120 Гц машина «едет по-разному» на глаз.
func sync_from_physics(_delta: float) -> void:
	pass

func set_brake_intensity(value: float) -> void:
	brake_intensity = clampf(value, 0.0, 1.0)

func set_nitro_intensity(value: float) -> void:
	nitro_intensity = clampf(value, 0.0, 1.0)

func set_headlights(enabled: bool) -> void:
	headlights_on = enabled

func set_lightbar(enabled: bool, _time: float = 0.0) -> void:
	lightbar_enabled = enabled

## Габариты для отладки/фрустум-подсказок.
func visual_aabb() -> AABB:
	return AABB(Vector3(-0.95, -0.4, -2.2), Vector3(1.9, 1.4, 4.4))

## Что-то сломалось при сборке — родитель пишет в DebugConsole.
func last_error() -> String:
	return ""
