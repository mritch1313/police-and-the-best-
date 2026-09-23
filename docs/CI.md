# CI: что реально проверяется и где смотреть правду

Файл: `.github/workflows/ci.yml`. Три джобы, от дешёвой к дорогой. Все три —
`runs-on: ubuntu-latest`: требование проекта, потому что на `ubuntu-slim` нет нужных
компонентов Android SDK и `xvfb-run`.

```
push / pull_request / workflow_dispatch
        │
        ├── 1) FAST VALIDATION      (~40 с, Godot не нужен вообще)
        │         └── needs ──► 2) HEADLESS TESTS   (~4 мин: движок + шаблоны + xvfb)
        │                              └── needs ──► 3) ANDROID BUILD   (~8 мин: экспорт APK)
```

Смысл разделения ровно один: опечатка в `.cfg` или несуществующее имя метода движка должна
быть видна за 40 секунд, а не после 12-минутной сборки APK.

`concurrency: ci-${{ github.ref }}` + `cancel-in-progress: true` — пуш в ту же ветку
отменяет предыдущий незавершённый прогон (не копим 5 одинаковых сборок).
`permissions: contents: write` — только ради шага «закоммитить кадр карты» (п. 2.4).

---

## 1. FAST VALIDATION

| Шаг | Команда | Что ловит |
| --- | --- | --- |
| Синтаксис | `gdparse <каждый .gd>` | «скрипт не читается» — доGodot-стадия |
| Стиль/грубые ошибки | `gdlint scripts tests` | дубли имён, неверные `@export`, мусорные строки, длина файла/строки |
| Структура проекта | `python3 tools/validate_project.py` | `project.godot` (main_scene, autoloads, рендерер, ориентация), существование `.tscn`-зависимостей, `res://`-пути в коде, неизвестные классы движка (по `tools/engine_classes.txt`), синтаксис `.cfg` и паритет ключ↔поле |
| Паритет конфигов | `python3 tools/check_cfg_parity.py` | каждый ключ `autoloads/*.cfg` реально существует у класса-владельца |
| Имена API Godot | `python3 tools/api_check.py <дерево движка> tools/api_surface.txt` | вызовы, которых **нет** в `doc/classes/*.xml` тега `v4.7.2-stable` |
| Гигиена `.cfg` | `grep -P "\t"`, `grep "= *$"` | табы (ломают `ConfigFile`), ключ без значения |

`gdtoolkit` ставится из `tools/requirements-lint.txt` (пин `gdtoolkit==4.5.0`), кэш pip —
по этому же файлу.

**`api_check` — честная часть.** Документация движка берётся `git clone --filter=blob:none
--sparse --branch v4.7.2-stable` и только `doc/classes`. Если клонировать не удалось (сеть),
шаг печатает `::warning::` и `API CHECK: SKIP` в summary — и **не** выдаёт это за успех
(у скрипта три кода возврата: 0 ok / 1 найдено несуществующее имя / 2 skip).
Список проверяемых имён — `tools/api_surface.txt`, перегенерируется локально:

```bash
python3 tools/api_check.py --dump            # пересобрать список
python3 tools/api_check.py ~/.src/godot-4.7.2-stable tools/api_surface.txt
```

Осознанные исключения (ложные срабатывания эвристики «тип переменной = класс Godot») лежат в
`tools/api_check.ignore.txt` — каждый пункт с причиной. Именно этот шаг поймал два реальных
бага до сборки: `ArrayOccluder3D.create_from_points()` (в 4.7 есть только `set_arrays()`) и
`MeshInstance3D.set_surface_material_override()` (правильно — `set_surface_override_material()`).

---

## 2. HEADLESS TESTS

### 2.1 Движок и шаблоны

`~/.cache/godot-ci/godot` и `~/godot-templates/4.7.2.stable` кэшируются `actions/cache@v4`
с ключом `godot-${GODOT_VERSION}-${GODOT_CHANNEL}-templates-v2` (меняешь версию Godot — кэш сам
по себе промахивается, что и нужно). Шаблоны кладутся в `~/.local/share/godot/export_templates/`
симлинком — это путь, который Godot ищет при экспорте.

### 2.2 `--import` обязателен

В `.gitignore` лежит `*.import`, поэтому в свежем чекауте нет `.godot/` и импорт нужно
сделать явно: `godot --headless --path . --import`. Без этого экспорт и часть загрузок
ведут себя «странно», а не «ошибочно».

### 2.3 Автотесты

```bash
godot --headless --path . res://tests/run_tests.tscn
```

39 тестов (`tests/run_tests.gd`) — настоящие проверки, а не «вызов не упал»:
замер терминальной скорости и разгона/торможения на реальной физике, инвариант баланса
игрок/полиция/нитро, состояния блокировки ввода, потеря цели и переключение стратегий ИИ,
правила ареста и спавна, детерминизм планировки, геометрия чанка и число поверхностей,
замена `visual_scene` из override-конфига, клампы конфигов, размеры тач-целей,
ровность строк меню, запись ориентации, контракт `export_presets.cfg`.
`get_tree().quit(1)` при любом провале или при найденных `SCRIPT ERROR` (счётчик ведёт
`DebugConsole`) — то есть красный CI = реально красная игра.

Плюс жёсткая проверка вывода: `grep -qE "SCRIPT ERROR|Failed loading resource|Cannot open file"`
по логу тестов → падение, даже если сам харнесс «прощёлкал» ошибку.

### 2.4 Кадры и карта меню

```bash
xvfb-run -a -s "-screen 0 720x1280x24" godot --path . res://scenes/game/Game.tscn \
  -- --capture-map --capture-out=res://assets/ui/map_card.png
```

`Xvfb` + Mesa `llvmpipe` (программный GL, без GPU) — это **не** проверка на телефоне, а
доказательство, что сцена собирается в кадр 720×1280 без ошибок шейдеров и ресурсов
(любой `SCRIPT ERROR`/`ERROR: Failed` в логе → красная джоба). Игра в режиме `--capture-map`
сама строит все чанки, ставит камеру сверху, сохраняет PNG и выходит с кодом 0.

Полученный `assets/ui/map_card.png` джоба коммитит обратно **в рабочую ветку** (не во `main`),
с `[skip ci]` в сообщении — чтобы кнопка «TEST» в меню всегда показывала реальный скриншот
собранной карты, а не нарисованную заглушку.

Артефакты: `godot-test-reports` → `ci-reports/` (тесты, capture.log, скриншоты).

---

## 3. ANDROID BUILD

Запускается только если обе предыдущие зелёные (`needs: [fast-validation, headless-tests]`).

1. `actions/setup-java@v4` (Temurin 17) — нужен `keytool`/`apksigner` из `ANDROID_HOME`;
2. keystore: генерим `~/.local/share/godot/keystores/debug.keystore` (дефолтный путь движка)
   **и** отдаём `GODOT_ANDROID_KEYSTORE_DEBUG_{PATH,USER,PASSWORD}` — в headless-экспорте
   автосоздание keystore движком не происходит, а без него экспорт падает с
   «Could not find debug keystore, unable to export»;
3. `godot --headless --path . --export-debug "Android" build/android/police-chase-arm64.apk`
   — пресет `Android` из `export_presets.cfg` (arm64-v8a, `min_sdk 24`, `target_sdk 34`,
   `package/unique_name=com.racing.chase`, без градиля, без разрешений);
4. проверка результата, а не «экспертная оценка»: файл существует, размер > 8 МиБ
   (меньше = ресурсы не упакованы), внутри есть `AndroidManifest.xml`, `resources.arsc`,
   `classes.dex`, `lib/arm64-v8a/libgodot_android.so`, затем `apksigner verify --print-certs`;
5. артефакты: `police-chase-android-arm64-apk` (сам APK) и `android-build-logs`
   (`ci-reports/android-export.log`, `apk-contents.txt`, `apksigner.txt`).

В `GITHUB_STEP_SUMMARY` джоба явно пишет: **«запуск на Infinix HOT 40i в CI НЕ выполнялся»**.
Это не формальность: CI доказывает сборку, содержимое APK и подпись, но не FPS, не тач и не
поведение на реальном железе.

---

## 4. Чего CI не делает (и не будет делать)

* не запускает игру на устройстве (нет физического девайса) → потолок честности:
  `BUILD VERIFIED / DEVICE RUNTIME NOT VERIFIED`;
* не собирает Godot из исходников и не ставит 4.8/beta/nightly: пин `4.7.2-stable` в `env`;
* не запускает дорогую сборку APK при провале дешёвых проверок (`needs`);
* не коммитит `map_card.png` во `main` (только в ветку прогона, и только на `push`).

## 5. Локальный «мини-CI» перед пушем

```bash
export PATH="$HOME/.local/bin:$PATH"
pip install -r tools/requirements-lint.txt
gdlint scripts tests
python3 tools/validate_project.py
python3 tools/check_cfg_parity.py
python3 tools/api_check.py ~/.src/godot-4.7.2-stable tools/api_surface.txt   # если есть дерево исходников
```

Этого хватает, чтобы поймать ~80 % будущего красного CI за 30 секунд и не гонять
12-минутную сборку ради опечатки в `.cfg`.
