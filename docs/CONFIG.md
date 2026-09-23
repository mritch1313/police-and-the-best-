# Конфигурация: где живут все числа

Проект построен вокруг одного правила: **в скриптах нет игровых констант**. Скорость,
масса, число патрулей, радиусы, LOD, качество графики, тексты меню — всё это текстовые
файлы `res://autoloads/*.cfg`, которые загружаются в типизированные Resource-классы
`res://scripts/config/*.gd`.

## 1. Цепочка загрузки

```
res://autoloads/<имя>.cfg            базовые значения (в git)
        ->  res://override_cfg/<имя>.cfg     переопределения сборки (в git, поключево)
        ->  user://override_cfg/<имя>.cfg    переопределения пользователя/CI (не в git)
```

Собирает это автономный синглтон `Config` (`scripts/core/config.gd`):

| API | Зачем |
| --- | --- |
| `Config.build("vehicle.player", VehicleConfig)` | собрать ресурс из секции, клампы по `@export_range` включены |
| `Config.reload() -> int` | перечитать всё с нуля (возвращает число файлов) |
| `Config.warnings` | проблемы: неизвестный ключ, несовпадение типа, выход за диапазон |
| `Config.num / integer / flag / str_value / arr / vec3(section, key, fallback)` | прямое чтение без класса (используют `DebugConsole`, `game.cfg`) |
| `Config.snapshot()` | полный снимок для отчётов и автотестов |

Значения пишутся как **литералы Godot**, поэтому в `.cfg` можно писать `Color(0.6, 0.6, 0.585, 1.0)`,
`[1, 2, 3, 4, 6]` и `{ "title": "TEST", ... }` прямо в тексте. Комментарии — `;` или `#`.

### Правила синтаксиса (нарушение = тихо сломанный конфиг)

* только **пробелы** вокруг `=`;
* **никаких табов** в строках значений — `ConfigFile` их не переваривает;
* секция в квадратных скобках, ключи без запятой в конце последней строки;
* имя секции = имя класса конфига (см. таблицу ниже), иначе секция игнорируется.

Неизвестный ключ **не роняет игру**: он отбрасывается, а в `Config.warnings` попадает запись
(`autotest` в `[world]` — пример намеренно неверного ключа в автотесте `_test_config_clamps`).
Значение вне `@export_range` клампится с предупреждением. Проверить конфиг статически:

```bash
python3 tools/validate_project.py     # структура проекта, сцены, ссылки, синтаксис .cfg + паритет ключей
python3 tools/check_cfg_parity.py     # каждый ключ .cfg реально существует у класса
```

## 2. Файлы и секции

| Файл | Секции | Класс | О чём |
| --- | --- | --- | --- |
| `autoloads/vehicle.cfg` | `vehicle.player`, `vehicle.police` | `VehicleConfig` | масса, база, колея, двигатель, тормоза, шины, подвеска, руль, габариты кузова |
| `autoloads/nitro.cfg` | `nitro` | `NitroConfig` | заряд/расход/восстановление, лимиты, множители |
| `autoloads/chase.cfg` | `chase` | `ChaseConfig` | розыск, арифметика ареста, спавн/деспаун |
| `autoloads/chase.cfg` | `police` | `PoliceConfig` | число патрулей, дистанции, реакции, тараны, блокпосты |
| `autoloads/world.cfg` | `world` | `WorldConfig` | размер мира, чанки, сетка дорог, бетон, плотность реквизита, LOD-дистанции |
| `autoloads/camera.cfg` | `camera` | `CameraConfig` | высота/дистанция/FOV по ориентациям, уклон от стен, тряска |
| `autoloads/graphics.cfg` | `graphics`, `graphics.tier_low/medium/high` | `GraphicsConfig`, `QualityTier` | политика качества и три пресета |
| `autoloads/ui.cfg` | `ui` | `UiConfig` | тексты меню, список карт, размеры HUD, палитра |
| `autoloads/game.cfg` | `game`, `dev` | — (читается через `Config.str_value/num`) | версия, пакет, отчёт; режим харнесса |

Полный авторитетный список ключей — **сам класс** (`grep "@export" scripts/config/vehicle_config.gd`).
Не помни names: открой файл или `Config.snapshot()`.

## 3. Что чем настраивается (быстрые якоря)

### Машина, физика, дрифт — `[vehicle.player]`

| Ключ | Дефолт | Эффект |
| --- | --- | --- |
| `mass_kg` | 1380 | инерция, длина торможения, «тяжесть» |
| `center_of_mass_drop_m` | 0.52 | ниже = меньше крены, больше сцепление |
| `engine_force_n` | 24800 | разгон; 0–100 за ~5.6 с на дефолте |
| `max_speed_kmh` | 165 | потолок без нитро |
| `brake_force_n` | 15200 | с 100 км/ч ~36 м |
| `handbrake_force_n`, `grip_handbrake_mu` | 5200 / 0.42 | длина и предсказуемость заноса |
| `grip_front_mu`, `grip_rear_mu` | 1.24 / 1.16 | задняя ось скользит раньше — машина срывается в занос, а не в снос |
| `corner_stiffness_n_per_rad` | 62000 | резкость отклика на руль |
| `yaw_damping` | 1.55 | сколько заноса гасится само |
| `drag_coefficient`, `rolling_resistance_n`, `downforce_k` | 0.42 / 220 / 1.15 | расход скорости накатом, «прилипание» на прямике |
| `max_steer_deg`, `min_steer_deg`, `steer_at_full_speed_kmh` | 38 / 12 / 150 | прогрессивная рулёжка |
| `suspension_frequency_hz`, `damper_ratio`, `suspension_travel_m` | 1.75 / 0.68 / 0.11 | клевки, мягкость, работа подвески в визуале |
| `gear_ratios`, `final_drive`, `shift_time_s`, `redline_rpm` | см. файл | характер разгона и звук-подобная логика передач |

Баланс **между** классами проверяет `scripts/core/balance_rules.gd`:
`BalanceRules.check(player, police, nitro)` возвращает список проблем, если
`police.max_speed_kmh` отошёл от `player.max_speed_kmh * police_vs_player_ratio` (1,01)
или если `player*nitro.max_speed_multiplier` отошёл от `police * nitro_vs_police_ratio` (1,25);
`BalanceRules.describe(...)` печатает ту же связку чисел в отчёт. Дефолты:
`vehicle.police.max_speed_kmh = 166.65` и `nitro.max_speed_multiplier = 1.273`
(210 км/ч = 166.65 × 1,25). Инвариант держит автотест `_test_balance_rules` —
то есть «подкрутить скорость игрока и забыть про полицию» не получится: CI покраснеет.

### Полиция и погоня — `[police]`, `[chase]`

| Ключ | Дефолт | Что даёт |
| --- | --- | --- |
| `police.max_units` | 6 | жёсткий потолок живых патрулей (бюджет CPU) |
| `police.units_per_wanted_level` | `[1, 2, 3, 4, 6]` | сколько машин на уровне розыска 1..5 |
| `police.reaction_time_s` | 0.22 | задержка на смену стратегии (не даёт «идеального» ИИ) |
| `police.aggression` | 0.42 | склонность к тарану/подрезанию |
| `police.engage_distance_m` / `lose_distance_m` / `lose_time_s` | 210 / 430 / 9 | где патруль включается и когда теряет игрока |
| `police.roadblock_chance`, `roadblock_min_distance_m`, `roadblock_lifetime_s` | 0.45 / 110 / 26 | блокпосты |
| `chase.arrest_distance_m` / `arrest_max_speed_kmh` / `arrest_hold_s` | 3.6 / 13 / 2.4 | условия поимки |
| `chase.spawn_radius_m` / `despawn_radius_m` | 165 / 470 | кольцо спавна (за пределами ближнего кольца чанков не появляется) |
| `chase.police_enabled` | true | рубильник всей системы |
| `Settings.police_intensity` | 1.0 | живой множитель числа патрулей из меню настроек |

### Нитро — `[nitro]`

Физика, а не телепорт: нитро меняет `thrust_multiplier`, `max_speed_multiplier`,
`grip_multiplier`, `drag_multiplier`. Заряд: `max_charge = 100`, `drain_per_s = 22`,
`regen_per_s = 7.5` (+`regen_delay_s`), лимиты `min_to_start` / `min_sustained`,
дисквал на перегрев: `max_burst_s = 4.2`, `overheat_cooldown_s = 2.1`.
Индикатор в HUD читает состояние системы, а не пишет его: `charge_ratio()`,
`is_ready()`, `is_blocked_by_overheat()`, `visual_intensity()`. Физика берут из
`physics_multipliers()` (тяга/максимум/сцепление/сопротивление).

### Размер мира, стриминг, LOD — `[world]`

См. `docs/WORLD.md`. Коротко: `world_radius_m = 500` (бетонная плита во все стороны от спавна),
`chunk_size_m = 200`, `load_radius_chunks = 1`, `max_active_chunks = 12`,
`chunk_build_budget_ms = 5.5`, дистанции `detail_distance_m` / `lod1_distance_m` /
`lod2_distance_m` / `cull_distance_m`.

### Графика — `[graphics]`

См. `docs/GRAPHICS_AND_PERF.md`. Быстро: `auto_tier = true`, `forced_tier = -1`
(0 = low, 1 = medium, 2 = high), `fps_target = 60`, даунгрейд при 42, апгрейд при 57.

### Тексты, карты, HUD — `[ui]`

`project_version` («4.0.9 TEXT»), `version_line` («ВЕРСИЯ: %s»), `subtitle`
(«СИМУЛЯТОР УГОНА ОТ МУСОРОВ»), `play_label`, `developers_label`, `dev_lines`
(попап «Разработчики»: `тг бот для связи @connection9191_bot`, `МАТАДОРА МАТАДОРА МАТАДАОРА`),
`orientation_*` (первый запуск), и **список карт**:

```ini
maps = [{ "title": "TEST", "scene": "res://scenes/game/Game.tscn", "thumbnail": "res://assets/ui/map_card.png", "enabled": true }]
```

Одна запись = одна карточка в меню выбора карты. `thumbnail` — квадратная PNG;
её нет или она битая → `map_card_fallback`. Карточка — и есть «скриншот собранной карты»:
ее обновляет CI (`docs/CI.md`), локально — запуск сцены `Game` с `--capture-map`.

## 4. Пользовательские настройки (не конфиг-файл)

`Settings` (`scripts/core/settings_manager.gd`) хранит выбор игрока и пишет его
`SaveManager`-ом в `user://settings.cfg`: ориентация (выбор при первом запуске,
`orientation_chosen`), `camera_distance_offset`, `camera_height_offset`,
`camera_sensitivity`, `ui_scale`, `show_fps`, `auto_quality`, `forced_tier`,
`police_intensity`. `reset_all()` возвращает всё к дефолтам.

## 5. Горячая перезагрузка

`Config.mark_dirty()` + `Config.reload()` — из `DebugConsole`; автотесты делают именно так
(см. `_test_config_clamps`: пишут `user://override_cfg/zz_autotest_clamp.cfg`, перечитывают,
проверяют клампы и предупреждения, файл удаляют, конфиг собирают заново `build_configs(true)`).
