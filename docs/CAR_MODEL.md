# Замена визуальной модели автомобиля (физика об этом не знает)

Это тот самый «запас на потом», который заложен в архитектуру: модель машины — **съёмная ветка**.
Можно поставить GLB-модель из магазина, не трогая физику, камеру, управление, полиции и тестов.

## 1. Как устроено разбиение

```
VehicleRig (Node3D)                      scripts/vehicle/vehicle_rig.gd
├── body: RigidBody3D                    физика (VehiclePhysics + VehicleController + WheelSystem)
│   ├── CollisionShape3D x2               строится из РАЗМЕРОВ конфига, а НЕ из меша
│   └── VisualModel (Node3D)              <-- съёмная ветка, ребёнок того же RigidBody3D
│       ├── BodyPivot/Body                MeshInstance3D (5 поверхностей)
│       ├── WheelPivot{i}/WheelSpin{i}/WheelMesh{i}
│       └── Headlights (OmniLight3D x2, только у игрока)
```

* `VehicleRig::assemble()` собирает всё кодом (в `.tscn` — только корень и скрипт), поэтому
  «сцены-заглушки» не могут разъехаться с кодом;
* **коллизия не берётся из визуальной модели**: два `BoxShape3D` считаются из
  `wheelbase_m`, `track_width_m`, `body_height_m`, `cabin_height_m` (`_build_collision`).
  Замена модели не меняет физику и наоборот;
* движение даёт только физика: `apply_impulse`/силы в `VehiclePhysics`, `Transform.position`
  не трогается никогда, кроме одного `place_at()` при спавне (автотест
  `no_vehicle_teleportation` следит именно за этим);
*visual читает состояние физики **один раз за кадр** (`sync_from_physics(delta)` из `_process`,
  не из `_physics_process`), поэтому 60 Гц и 120 Гц выглядят одинаково.

## 2. Контракт визуальной модели

Базовый класс — `VehicleVisualModel` (`scripts/vehicle/vehicle_visual_model.gd`).
Родитель вызывает методы **через `has_method()`**, то есть любой из них можно не реализовывать —
тогда просто не будет соответствующей детали (ни ошибки, ни предупреждения):

| Метод | Кто зовёт | Что должен сделать модель |
| --- | --- | --- |
| `setup(config: VehicleConfig, physics: Node, is_player: bool)` | `VehicleRig._build_visual()` | собрать/подхватить геометрию, запомнить ссылки, создать `body_pivot` |
| `sync_from_physics(delta: float)` | `VehicleRig._process` | повороты/вращение колёс, крен-клевёк по длинам стоек, спин колёс |
| `set_brake_intensity(v: float)` | `VehicleRig` | яркость стоп-сигналов |
| `set_nitro_intensity(v: float)` | `VehicleRig` | «языки» из выхлопа, эмиссия |
| `set_headlights(on: bool)` | `PlayerCar` / настройки | фары |
| `set_lightbar(on: bool, time: float)` | `PoliceCar` | мигалка: красный/синий по такту |
| `visual_aabb() -> AABB` | отладка, подсказки отсечения | габарит модели |
| `last_error() -> String` | `DebugConsole` | причина, если модель не собралась |

Поля базового класса, доступные модели: `config`, `physics`, `player_car`, `body_pivot`,
`brake_intensity`, `nitro_intensity`, `lightbar_enabled`, `lightbar_time`, `headlights_on`.

## 3. Системы координат и единицы (нарушишь — машина «смотрит» назад)

* 1 единица = 1 метр;
* начало координат модели = **плоскость ступиц колёс** под центром масс;
* **вперёд = −Z**, вправо = +X, вверх = +Y (Godot standard);
* земля в покое на `y = -ride_height_m`; днище на `y = floor_clearance_m - ride_height_m`;
* линия окон = `+body_height_m`, крыша = `+cabin_height_m` сверх неё;
* колёса — узлы, которые модель сама крутит/поворачивает; имена узлов для GLB:
  `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR` (и `Steer`/`Spin` — см. ниже).

Соглашение одно для `CarGeometry`, `WheelSystem` и физики — поэтому процедурная модель и
«принесённой» GLB-модели ведут себя одинаково.

## 4. Поставить свою модель: 3 шага

1. Положи файл в `res://assets/models/` (например `sedan.glb`). Импорт Godot сделает сам:
   `.import`-файлы в git не лежат, их генерирует `godot --headless --import` (это делает CI,
   см. `docs/CI.md`).
2. Пропиши путь в конфиге — **текстом, без редактора**:

   ```ini
   ; autoloads/vehicle.cfg (или res://override_cfg/vehicle.cfg, user://override_cfg/vehicle.cfg)
   [vehicle.player]
   visual_scene = "res://assets/models/sedan.glb"
   ```

   `Config` умеет грузить ресурс по пути в `TYPE_OBJECT`-свойство
   (`Config.load_resource_path()`): путь не нашёлся или тип не тот — в `Config.warnings`
   попадёт запись, а `visual_scene` останется `null`, то есть **запустится процедурная модель**
   и игра не сломается. Проверка живёт в автотесте `visual_scene_swap_from_cfg`.
3. Подгони размеры под новую модель, чтобы коллизия совпадала с кузовом:
   `wheelbase_m`, `track_width_m`, `body_length_m`, `body_width_m`, `body_height_m`,
   `cabin_height_m`, `wheel_radius_m`, `ride_height_m` — тот же `[vehicle.player]`.

Было/стало видно без запуска на телефоне: CI делает кадры (см. `docs/CI.md`).

### Вариант «из кода» (для отладки/двойной модели)

```gdscript
rig.visual_override = load("res://assets/models/prototype.glb")  # до add_child в дерево
```

`visual_override` имеет приоритет над `config.visual_scene` (`_build_visual()`), а если пусто и
там и там — включается `ProceduralVehicleModel`.

## 5. Требования к мешу (чтобы не убить мобильный FPS)

* **≤ 5–6 поверхностей** (материалов). Каждый материал = отдельный draw call: 6 — потолок для
  машины, 2 — для колеса;
* суммарно ≤ ~12k треугольников на машину; сколько реально у процедурной — печатает
  `ProceduralVehicleModel.debug_summary()` (в отладочной панели HUD и в CI-отчёте), а не то,
  что кто-то вспомнил на глаз;
* тени: `cast_shadow = ON` на кузов и колёса, **никаких дополнительных источников света**:
  бюджет — 2 `OmniLight3D` (фары) на игрока и 1 `DirectionalLight3D` на сцену;
* прозрачное (стёкла) — `transparency = TRANSPARENCY_ALPHA` + `cull_mode = CULL_BACK` и
  **по возможности 1 слой**, иначе на Mali начинается overdraw;
* не тащи в сцену lights/cameras/audios — только меш + узлы;
* `custom_aabb` на `MeshInstance3D` полезен, если у модели «выпирающие» зеркала (иначе
  лишние перерисовки при отсечении).

## 6. Материалы: как поменять «краску», не трогая меш

```gdscript
var mat := MaterialLibrary.unique("car_paint")   # копия из общего кэша, правим смело
mat.albedo_color = Color(0.9, 0.2, 0.15)
mesh_instance.set_surface_override_material(0, mat)
```

* `MaterialLibrary.unique(type)` — копия (общий кэш не пачкается),
  `MaterialLibrary.get_material(type)` — общий экземпляр;
* список типов: `MaterialLibrary.types()` (`car_paint`, `car_glass`, `car_light`, `car_tail`,
  `car_tyre`, `car_rim`, `car_trim`, `police_body`, `lightbar_red/blue`, ...);
* текстуры: `TextureLibrary` использует `res://assets/textures/<имя>.png`, если файл лежит
  рядом (иначе генерирует процедурный паттерн), см. `assets/textures/README.md`;
* `ProceduralVehicleModel.set_paint_color(color)` — быстрый способ перекрасить игрока.

## 7. Процедурная модель и её пропорции

Если `visual_scene` пуст, кузов строит `CarGeometry.build(config)` (`scripts/vehicle/car_geometry.gd`):
loft-кузов («суперэллипс»-сечение, обтянутое по длине, сваренные вершины, непрерывный блик),
5 поверхностей (краска / тёмный пластик / стёкла / фары / ПТФ), зеркала, арки, пороги, спойлер,
решётка, мигалка, колесо с протектором, боковиной, диском, спицами, тормозным диском и суппортом.
Всё параметризуется числами из `VehicleConfig`:

| Ключ | На что влияет |
| --- | --- |
| `body_length_m`, `body_width_m` | габарит кузова |
| `body_height_m`, `cabin_height_m` | «линия окон» и крыша |
| `windshield_start_ratio`, `cabin_end_ratio` | где начинается лобовое и где заканчивается кабина |
| `floor_clearance_m`, `ride_height_m` | просвет (коллизия + посадка) |
| `wheel_radius_m`, `wheel_width_m` | колёса (и физика, и визуал берут одни и те же числа) |
| `body_style` (0..3) | седан / купе / хэтчбэк / внедорожник |

Результат кэшируется по форме: 20 припаркованных машин + 6 патрульных = одна генерация
(`CarGeometry.reset_cache()` — только для тестов). Именно поэтому «другая машина» в этом проекте
— это в первую очередь **другие цифры**, а не другой меш.
