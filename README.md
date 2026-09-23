# Police Chase: Open World — «Симулятор угона от мусоров»

**Один** целостный 3D-проект на **Godot 4.7.2-stable** под **Android (arm64-v8a, портрет)**:
процедурный город, тяжёлая физика машины, погоня с ИИ, нитро, мобильный тач-HUD,
конфиги в тексте, автотесты и CI, который собирает **настоящий APK**.

Целевое устройство: **Infinix HOT 40i** — Android 13, 720×1612, MediaTek Helio G85 + Mali-G52 MC1,
ARM64. Всё (рендерер, тени, дальность, LOD, плотность, размер кнопок) подбиралось под него.

## Статус: что проверено, а что нет

| Часть | Состояние | Чем доказано |
| --- | --- | --- |
| Архитектура, сцены, конфиги, UI, физика, мир, ИИ, нитро | ✅ **написаны и статически проверены** | `gdparse`, `gdlint`, `tools/validate_project.py`, `tools/check_cfg_parity.py` — все зелёные (локально) |
| Имена API Godot (никаких выдуманных методов) | ✅ **проверено по доке 4.7.2** | `tools/api_check.py`: 254 записи, 0 отсутствующих. Проверка уже поймала 2 реальных бага (`ArrayOccluder3D.create_from_points`, `MeshInstance3D.set_surface_material_override`) — исправлено |
| Автотесты (39 штук) | ⚠️ **написаны, движком ещё не выполнены** | первый реальный прогон = CI `HEADLESS TESTS` (в песочнице нет Godot-бинарника: нет GPU/X11/места) |
| Кадр сцены (мир собирается в картинку) | ⚠️ проверяется только в CI | `xvfb-run` + llvmpipe, 720×1280; артефакт `godot-test-reports` |
| APK | ⚠️ собирается в CI | `ANDROID BUILD`: размер, содержимое (`lib/arm64-v8a/libgodot_android.so`, манифест), `apksigner verify`; артефакт `police-chase-android-arm64-apk` |
| Запуск на Infinix HOT 40i | ❌ **не проверялось и проверить нельзя** | физического устройства в окружении нет |
| Графический редактор Godot (глазами) | ❌ не запускался | нет X11/GPU в песочнице; GUI-редактор тут не поднять |

Потолок честности этого проекта: **`BUILD VERIFIED / DEVICE RUNTIME NOT VERIFIED`**.
Никаких «на телефоне летает» — этого никто не измерял.

## Быстрый старт

### В редакторе (нужен ровно Godot 4.7.2-stable)

```bash
git clone https://github.com/mritch1313/police-and-the-best-
# Открыть проект: Editor → Import → project.godot, затем F5 (главная сцена OrientationGate)
```

1. **первый запуск** спрашивает ориентацию (горизонталь/вертикаль) → выбор сохраняется и больше
   не показывается;
2. **главное меню**: фон `assets/ui/фон.jpg`, слева вверху `ВЕРСИЯ: 4.0.9 TEXT` и под ней
   `СИМУЛЯТОР УГОНА ОТ МУСОРОВ`, по центру левой половины — кнопки `1 Играть` и `2 Разработчики`;
3. `2 Разработчики` — попап с `тг бот для связи @connection9191_bot` и `МАТАДОРА МАТАДОРА МАТАДАОРА`;
   тап по окну закрывает его;
4. `1 Играть` — одна карта-квадрат с картинкой карты и подписью `TEST`; тап = загрузка игры;
5. спавн — на бетоне, 500 м во все стороны, дальше — город с кварталами.

### Управление (для отладки с клавиатуры)

| Действие | Клавиша | На телефоне |
| --- | --- | --- |
| Газ | `W` / `↑` | `ГАЗ` |
| Тормоз / назад | `S` / `↓` | `ТОРМОЗ` |
| Руль | `A` `D` / `←` `→` | виртуальный стик (левая нижняя зона) |
| Ручник (занос) | `Space` | `РУЧНИК` |
| Реверс-режим | `R` | `НАЗАД` |
| Нитро | `Shift` (удерживать) | `NITRO` |
| Камера: орбита | ЛКМ-драг по верхней зоне | драг одним пальцем по верхней зоне |
| Камера: дистанция | колесо мыши | щипок двумя пальцами |
| Пауза | `Esc` | `ПАУЗА` (правый верхний угол) |
| Сменить пресет качества | `F1` | меню настроек |

### В консоли (headless, без редактора)

```bash
GODOT=./Godot_v4.7.2-stable_linux.x86_64
$GODOT --headless --path . --import                 # сгенерировать .godot (нужен для экспорта)
$GODOT --headless --path . res://tests/run_tests.tscn          # автотесты (код выхода 0/1)
$GODOT --path . res://scenes/game/Game.tscn -- \
     --capture-map --capture-out=res://assets/ui/map_card.png  # кадр карты для меню-карточки
$GODOT --headless --path . --export-debug "Android" build/game.apk
```

## Структура

```
project.godot            рендерер (gl_compatibility), 720×1280, portrait, физика 60 Гц, 8 автозагрузок, input map
export_presets.cfg       пресет "Android": arm64-v8a, min_sdk 24, target_sdk 34, com.racing.chase, без разрешений
scenes/
  menu/OrientationGate.tscn, menu/MainMenu.tscn, game/Game.tscn     сцены тонкие: корень + скрипт, всё собирается кодом
autoloads/*.cfg          ВСЕ игровые числа (8 файлов, 14 секций) — см. docs/CONFIG.md
scripts/
  core/       config, game_setup, app_state, save_manager, settings_manager, performance_manager, balance_rules, screen_flow
  config/     10 классов Resource: vehicle, police, chase, world, camera, nitro, ui, graphics, quality_tier, config_resource
  vehicle/    rig, physics, controller, wheel_system, car_geometry, procedural_vehicle_model, vehicle_visual_model, nitro_system, drive_input, vehicle_math
  camera/     camera_controller (орбита, защита от стен, возврат дистанции)
  police/     manager, car, ai, strategy, chase_manager, spawn_manager, navigation_manager, route..., arrest_system, trajectory_prediction
  world/      world_generator (данные), chunk_builder (геометрия), world_chunk, world_streamer, building_kit, prop_meshes, road_graph, route_planner
  render/     material_library, texture_library, mesh_builder
  ui/         hud, mobile_controls, ui_manager, settings_menu
  menu/       orientation_gate, main_menu, main_menu_background, map_preview
  game/game.gd, debug/debug_console.gd
assets/ui/    фон.jpg (фон меню), map_card.png (скриншот карты из CI)
assets/models/, assets/textures/   пустые: сюда кладут GLB-машину и PNG-текстуры (README внутри папок)
tests/run_tests.{gd,tscn}          39 автотестов + отчёт в ci-reports/tests.txt
tools/        validate_project.py, check_cfg_parity.py, api_check.py, engine_classes.txt, requirements-lint.txt
docs/         CONFIG.md, WORLD.md, GRAPHICS_AND_PERF.md, CAR_MODEL.md, CI.md
.github/workflows/ci.yml           FAST VALIDATION / HEADLESS TESTS / ANDROID BUILD
```

## Настройка (не трогая код)

Всё — текстом в `autoloads/*.cfg`, с переопределением в `res://override_cfg/` и `user://override_cfg/`
(неизвестный ключ не роняет игру: он уходит в `Config.warnings`).

| Хочу | Куда смотреть | Ключи |
| --- | --- | --- |
| скорость/разгон/торможение/дрифт | `docs/CONFIG.md`, `vehicle.cfg` | `max_speed_kmh`, `engine_force_n`, `mass_kg`, `brake_force_n`, `grip_*_mu`, `handbrake_force_n`, `yaw_damping` |
| чтобы полиция была медленнее/быстрее | `vehicle.cfg [vehicle.police]` | `max_speed_kmh` (дефолт 166.65 = 1,01 × игрока; инвариант держит автотест) |
| сколько патрулей и как они умнее | `chase.cfg [police]`, `[chase]` | `max_units`, `units_per_wanted_level`, `aggression`, `reaction_time_s`, `roadblock_chance` |
| нитро (заряд, расход, потолок) | `nitro.cfg` | `max_charge`, `drain_per_s`, `regen_per_s`, `max_burst_s`, `max_speed_multiplier`, `thrust_multiplier` |
| размер мира / стриминг / LOD | `docs/WORLD.md`, `world.cfg` | `world_radius_m`, `chunk_size_m`, `load_radius_chunks`, `max_active_chunks`, `*_distance_m`, `seed` |
| плотность застройки и реквизита | `world.cfg` | `building_density`, `trees_per_chunk`, `parked_cars_per_chunk`, `prop_density` в пресетах |
| графика и FPS-политика | `docs/GRAPHICS_AND_PERF.md`, `graphics.cfg` | `auto_tier`, `forced_tier`, `fps_target`, `downgrade_fps`, пресеты `graphics.tier_*` |
| другая машина (GLB) | `docs/CAR_MODEL.md` | `visual_scene = "res://assets/models/foo.glb"` + размеры кузова |
| тексты меню, карты, размер кнопок | `ui.cfg` | `project_version`, `subtitle`, `maps`, `min_touch_target_px`, `joystick_radius_px` |
| ориентация/полный экран/пакет | `project.godot`, `export_presets.cfg` | `display/window/handheld/orientation`, `package/unique_name` |

Документация: [docs/CONFIG.md](docs/CONFIG.md) ·
[docs/WORLD.md](docs/WORLD.md) ·
[docs/GRAPHICS_AND_PERF.md](docs/GRAPHICS_AND_PERF.md) ·
[docs/CAR_MODEL.md](docs/CAR_MODEL.md) ·
[docs/CI.md](docs/CI.md)

## Сборка APK

### Вариант A — через CI (рекомендуется, ничего не надо ставить)

1. пуш в ветку → Actions → джоба **ANDROID BUILD**;
2. артефакт `police-chase-android-arm64-apk` → распаковать →
   `adb install -r police-chase-arm64.apk`;
3. в логе видно: размер, содержимое APK, результат `apksigner verify`, версия Godot.

### Вариант B — локально

Нужны: Godot **4.7.2-stable**, экспорт-шаблоны **4.7.2.stable**
(`Godot_v4.7.2-stable_export_templates.tpz` → распаковать в
`~/.local/share/godot/export_templates/4.7.2.stable/`), JDK 17 (для `apksigner`/`keytool`).

```bash
keytool -genkeypair -keystore ~/.local/share/godot/keystores/debug.keystore \
  -storepass android -keypass android -alias androiddebugkey \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
godot --headless --path . --import
godot --headless --path . --export-debug "Android" build/police-chase-arm64.apk
```

Gradle-сборка **выключена** (`gradle_build/use_gradle_build=false`): разрешения не нужны,
aar-плагины не используются, APK получается простым упаковыванием. Нужен gradle-плагин
(реклама/сохранения в Google Play) — включи флаг и добавь `build/` по инструкции Godot.

Подпись релиза: пустые `keystore/release*` в пресете — заполни своими (или через
`GODOT_ANDROID_KEYSTORE_RELEASE_*`), `--export-release`.

## Проверки перед пушем (30 секунд вместо 12 минут)

```bash
export PATH="$HOME/.local/bin:$PATH"
pip install -r tools/requirements-lint.txt
gdlint scripts tests
python3 tools/validate_project.py     # структура проекта + ссылки + .cfg
python3 tools/check_cfg_parity.py     # ключ конфига = поле класса
python3 tools/api_check.py ~/.src/godot-4.7.2-stable tools/api_surface.txt
```

## Что важно знать, если будешь править

* **движение только через физику.** `Transform.position` не трогаем нигде, кроме `place_at()`
  при спавне; за этим следит автотест `no_vehicle_teleportation`;
* **визуал машины съёмный**: `VehicleVisualModel` + `visual_scene`, физика о модели не знает;
* **мило к мобильному GPU**: никаких SSR/volumetrics/real-time GI, ≤ 2 Omni-света (только у
  игрока), один merged-меш на чанк, коллизия — одно тело на чанк;
* **у каждого ключа конфига есть читатель**: «висячие» ключи (`half_res_effects`,
  `low_battery_safe_mode`) удалены, а не оставлены «на потом»;
* **тексты меню — ровно те, что в ТЗ** (`ВЕРСИЯ: 4.0.9 TEXT`, `СИМУЛЯТОР УГОНА ОТ МУСОРОВ`,
  `TEST`, попап разработчиков): их проверяет автотест `menu_strings_exact`;
* `.import`-файлы не в git → перед любым экспортом/тестом обязателен `--import`.

## Лицензии ассетов

Внешних библиотек и плагинов в проекте нет. Все модели, текстуры и звуки генерируются кодом
(`CarGeometry`, `TextureLibrary`, `BuildingKit`), поэтому правообладателей тащить не нужно.
`assets/ui/фон.jpg` — свободное фото-изображение для фона меню (можно заменить своим: файл
читается как `res://assets/ui/фон.jpg` в `main_menu_background.gd`). При добавлении своих
ассетов — клади рядом `LICENSE.txt`, архитектура это позволяет (см. `docs/CAR_MODEL.md`).
