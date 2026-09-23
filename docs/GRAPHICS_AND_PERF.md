# Графика и производительность под Infinix HOT 40i

Целевое железо: **MediaTek Helio G85 (2×Cortex-A75 + 6×A55) + Mali-G52 MC1, Android 13,
экран 720×1612**. Все решения ниже — из этого, а не из «среднего Mobile».

## 1. Рендерер: почему `gl_compatibility`

Выбор по железу, а не по моде:

| Кандидат | Вердикт для этой цели |
| --- | --- |
| `forward_plus` (Vulkan) | На Mali-G52/Mali-Gxx среднего сегмента Vulkan-путь нестабилен (драйверы, память), а Forward+ тянет за собой кластеры света и более дорогие шейдеры. Не для 720p-бюджета. |
| `mobile` (Vulkan) | То же: Vulkan + Mobile-конвейер (варп-шейдинг, deferred Decals) выгоден на тайловых GPU с быстрой DRAM-полосой; на G52 выигрыш не доказан, риск — есть. |
| **`gl_compatibility` (GLES 3.1)** | ✅ **выбран**. Зрелый GLES-драйвер Mali, самый дешёвый шейдер-путь, предсказуемое поведение на старье. Godot сам рекомендует Compatibility для low/mid Android. |

`project.godot`:

```ini
rendering/renderer/rendering_method="gl_compatibility"
rendering/renderer/rendering_method.mobile="gl_compatibility"
```

Оба значения одинаковы специально: чтобы картинка в редакторе (десктоп) и на телефоне
собиралась одним и тем же путём, и «в редакторе красиво, на устройстве серость» было
ловить не нужно. `config/features=PackedStringArray("4.7", "GLES 3.1")` — честная метка фич.

Хочешь попробовать Mobile/Vulkan — правь эти две строки; **всё остальное в проекте от
рендерера не зависит** (освещение, материалы и тени настраиваются кодом, не шейдерами).

## 2. Что сознательно НЕ включено

Запрет из ТЗ, и он же — единственное, что реально держит 60 fps на G52:

* ❌ volumetric fog / объёмный свет;
* ❌ SSR и любые screen-space reflections (вместо них — `env.reflected_light_source =
  REFLECTION_SOURCE_SKY`, т.е. один cubemap radiance 64);
* ❌ real-time GI (SDFGI/VoxelGI);
* ❌ много динамических источников: у игрока **≤ 2 Omni (фары) + 1 Directional (солнце)**,
  у патрулей света нет вообще — только мигалка эмиссией в материале;
* ❌ большие shadow-атласы: 512 (low) / 1024 (medium) / 2048 (high), 16-битные;
* ❌ частиц в проекте нет вообще (ни GPUParticles, ни CPUParticles): на Mali-G52 это типичный
  «первый источник просадки», а выигрыш в картинке тут дают другие вещи. Эффект нитро —
  эмиссивные конусы из выхлопа (`visual_intensity`), занос читается по крену корпуса, дуге
  и повороту колёс, стоп-сигналы — по материалу. Так же дёшево и без аллокаций в бою.
* ✅ glow есть, но только в `high` и с `glow_intensity` из пресета.

## 3. Три пресета = один класс `QualityTier`

`autoloads/graphics.cfg`: `[graphics]` (политика) + `[graphics.tier_low|medium|high]`
(три `QualityTier`). Ключевое: **у каждого ключа есть читатель** — иначе это не настройка, а декорация.

| Ключ пресета | low / medium / high | Кто читает |
| --- | --- | --- |
| `shadows_enabled` | false / true / true | `game.gd::_on_tier_changed` → `sun.shadow_enabled` |
| `shadow_atlas_size` | 512 / 1024 / 2048 | `PerformanceManager.apply_tier()` → `RenderingServer.directional_shadow_atlas_set_size()` |
| `shadow_distance_m` | 45 / 110 / 160 | `sun.directional_shadow_max_distance` |
| `shadow_bias` | 0.08 / 0.05 / 0.04 | `sun.shadow_bias` (bias едет в связке с размером атласа) |
| `rendering_scale` | 0.8 / 1.0 / 1.0 | `root.scaling_3d_mode` + `scaling_3d_scale` (bilinear, 0.8× = −36% пикселей) |
| `msaa_3d` | 0 / 0 / 1 | `root.msaa_3d` |
| `occlusion_culling` | true / true / true | `root.use_occlusion_culling` **и** `WorldChunk._build_occluder` |
| `lod_bias` | 0.72 / 1.0 / 1.35 | `WorldStreamer.update_lods()` (все пороги LOD) |
| `cull_distance_multiplier` | 0.7 / 1.0 / 1.4 | пороги отсечения + `visibility_range_end` малых форм |
| `prop_density` | 0.45 / 1.0 / 1.5 | `ChunkBuilder` (сколько малых форм кладёт чанк) |
| `max_chunks` | 6 / 9 / 16 | `WorldStreamer.max_active()` (только **сокращает**, кольцо не режет) |
| `fog_density_multiplier` | 1.45 / 1.0 / 0.85 | `env.fog_density` |
| `glow_enabled` | false / false / true | `env.glow_enabled` |
| `glow_intensity` | 0.0 / 0.25 / 0.4 | `env.glow_intensity` |
| `anisotropy`, `texture_filter` | 0:1 / 0:1 / 2:1 | `MaterialLibrary.set_texture_filter()` → `BaseMaterial3D.texture_filter` на всех материалах мира |
| `sky_realtime_update` | false / false / true | `Sky.process_mode` = `PROCESS_MODE_REALTIME`/`_INCREMENTAL` |
| `display_name` | — | HUD/отладка (`PerformanceManager.status_text()`) |

> Из `graphics.cfg` удалены два ключа-обманки: `half_res_effects` (в Compatibility нет
> доступного из скриптов «полуразрешённого» прохода для эффектов) и `low_battery_safe_mode`
> (нет API уровня батареи). Правило проекта: у каждого ключа конфига должен быть читатель —
> это проверяет `tools/validate_project.py` (паритет ключ↔поле класса) и `check_cfg_parity.py`.

## 4. Авто-политика качества

`[graphics]`:

```ini
auto_tier = true
forced_tier = -1          ; 0 low, 1 medium, 2 high, -1 = авто
fps_target = 60.0
downgrade_fps = 42.0
upgrade_fps = 57.0
check_window_s = 3.0
confirmations = 2
initial_tier_for_low_ram = 0
```

Механика (`scripts/core/performance_manager.gd`):

1. при старте — `_device_hint()`: мобильная ОС и/или `< 5000` МБ RAM → стартуем с `low`
   (`initial_tier_for_low_ram`), а не с medium;
2. скользящее окно `check_window_s` (3 с) считает средний `fps`;
3. `fps < downgrade_fps` (42) → вниз, `fps > upgrade_fps` (57) → вверх, но только после
   `confirmations = 2` подряд подтверждённых окон — иначе телефон «дышит» туда-сюда каждые 3 секунды;
4. «энергосбережение» не эмулируется: в Godot 4.7 нет API уровня батареи для скриптов,
   а дергать BatteryManager через JNI-плагин ради одного флага — лишний внешний модуль
   (запрещён правилами проекта). Ключ `low_battery_safe_mode` из конфига поэтому УДАЛЁН,
   а не «забыт»: висячий ключ, который ни на что не влияет, хуже отсутствующего.
5. ручная смена (меню настроек) ставит `manual_override` и пишет выбор в `user://settings.cfg`
   (`SaveManager`), авто больше не спорит с игроком; `forced_tier = -1` возвращает авто;
6. переключение качества — это `set_tier()` → `apply_tier()` → сигнал `tier_changed(index, tier)`;
   мир **не пересобирается** (LOD-пороги и `prop_density` применяются к новым чанкам, а
   не к готовым мешам) — переключение стоит ~1 кадр.

Горячая проверка в бою: `F1`/`cycle_graphics_tier` (action в `project.godot`) листает пресеты,
`DebugConsole` печатает `PerformanceManager.status_text()`.

## 5. Бюджеты (потолок, за который код не выпускает)

| Что | Значение | Где держится |
| --- | --- | --- |
| геометрия чанка | 1 near-`ArrayMesh` + 1 far, поверхностей = числу материалов | `ChunkBuilder.build()` |
| коллизия чанка | 1 `ConcavePolygonShape3D` + 1 «плита» + 1 тело для «твёрдой» мелочи | `WorldChunk._build_collision()` |
| окклюдеры | ≤ `occluders_per_chunk_max = 28`, только здания ≥ `occluder_min_height_m = 11` | `BuildingKit.Sink.occluder_left` |
| сборка | ≤ 5.5 мс и 1 чанк за кадр | `WorldStreamer._build_within_budget()` |
| живые чанки | ≤ `max_active()`, 1..64 | `WorldStreamer.max_active()` |
| динамический свет | ≤ 2 Omni + 1 Directional, только у игрока | `procedural_vehicle_model.gd`, `game.gd` |
| физика | 60 Гц, 10 итераций солвера, спящий режим тел включён | `project.godot [physics]` |
| текстуры | ETC2/ASTC при импорте, mipmap bias −0.4, анизотропия выкл по умолчанию | `rendering/textures/vram_compression/import_etc2_astc=true` |

## 6. Разрешение и растяжка кадра

```ini
display/window/size/viewport_width=720
display/window/size/viewport_height=1280
display/window/stretch/mode="canvas_items"
display/window/stretch/aspect="expand"
```

`canvas_items` — потому что HUD обязан оставаться чётким (3D-часть масштабируется отдельно
через `scaling_3d_scale`), а `expand` — потому что «челка»/соотношение 20:9 у HOT 40i
съедает ~50 пикселей по высоте: фиксированный `keep` обрезал бы кнопки.

## 7. Замерить, а не угадать

Локально проверить рендер нельзя (в песочнице нет GPU/X11). Реальные кадры даёт CI:
`xvfb-run` + llvmpipe, 720×1280, скриншоты в артефакте `godot-test-reports`
(`ci-reports/screenshots/`), плюс `--capture-map` для квадратика карты в меню.
См. `docs/CI.md`.
