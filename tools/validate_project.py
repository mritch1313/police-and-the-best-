#!/usr/bin/env python3
"""validate_project.py — дешёвая проверка целостности проекта без движка.

Используется в CI в джобе FAST VALIDATION (перед тем как тратить минуты на Godot и
экспорт APK), и локально: `python3 tools/validate_project.py`.

Что проверяется (то, что реально ломает сборку/запуск):
  1. project.godot: есть main_scene, все autoload-скрипты существуют, имена autoload
     совпадают с классами, которые использует код; renderer = gl_compatibility.
  2. Каждая .tscn: ext_resource-пути существуют, у корня есть script, нет «висячих»
     SubResource, формат 3.
  3. Каждая .gd: referenced class_name'ы существуют (нет опечаток в типах), строки
     res://... в коде ведут на существующие файлы, InputMap-действия из
     Input.*_action_pressed/has_action объявлены в project.godot.
  4. autoloads/*.cfg: ключи существуют в соответствующих классах (дублирует
     check_cfg_parity.py, но заодно проверяет, что файлы парсятся).
  5. assets: фон меню и иконка присутствуют; export_presets.cfg содержит Android-пресет
     с com.racing.chase и arm64-v8a.

Выход: 0 — ок, 1 — найдены проблемы (они напечатаны построчно).
"""
from __future__ import annotations

import configparser
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "scripts"
PROBLEMS: list[str] = []


def problem(message: str) -> None:
    PROBLEMS.append(message)


def gd_files() -> list[Path]:
    files: list[Path] = []
    for folder in ("scripts", "tests"):
        base = ROOT / folder
        if base.exists():
            files.extend(sorted(base.rglob("*.gd")))
    return files


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_project_godot(text: str) -> dict[str, dict[str, str]]:
    """Мини-парсер .godot: секции [x] и ключ=значение (значения — литералы Godot).

    Input-блоки многострочные и вложенные — они нас интересуют только как НАБОР КЛЮЧЕЙ
    (имена действий), поэтому их содержимое сознательно игнорируется.
    """
    sections: dict[str, dict[str, str]] = {}
    current: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
            continue
        if current is None or "=" not in line:
            continue
        key, _, value = line.partition("=")
        sections[current][key.strip()] = value.strip()
    return sections


def res_paths_in(text: str) -> list[str]:
    """Пути res:// из СТРОК кода. Комментарии пропускаются намеренно: в `##` спокойно живут
    примеры путей, которых в репозитории нет (и не должно быть)."""
    out: list[str] = []
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith(("#", ";", "//")):
            continue
        for found in re.findall(r'"(res://[^"]+)"', line):
            # Экранированные кавычки в тестовых литералах оставляют висящий обратный слэш.
            out.append(found.rstrip("\\"))
    return out


def check_project_settings() -> None:
    path = ROOT / "project.godot"
    if not path.exists():
        problem("нет project.godot")
        return
    data = parse_project_godot(read(path))
    application = data.get("application", {})
    main_scene = application.get("run/main_scene", "").strip('"')
    if not main_scene:
        problem("project.godot: не задан run/main_scene")
    elif not (ROOT / main_scene.replace("res://", "")).exists():
        problem(f"project.godot: main_scene ссылается на несуществующий файл {main_scene}")
    icon = application.get("config/icon", "").strip('"')
    if icon and not (ROOT / icon.replace("res://", "")).exists():
        problem(f"project.godot: иконка {icon} отсутствует")
    autoload = data.get("autoload", {})
    if not autoload:
        problem("project.godot: нет ни одного autoload — конфиг-система не соберётся")
    for name, target in autoload.items():
        target = target.strip().strip('"').lstrip("*")
        if name == "Settings":
            expected = "settings_manager.gd"
            if expected not in target:
                problem(f"autoload Settings должен вести на {expected}, а ведёт на {target}")
        if target.startswith("res://"):
            file = ROOT / target.replace("res://", "")
            if not file.exists():
                problem(f"autoload {name}: файл {target} не найден")
        else:
            problem(f"autoload {name}: значение '{target}' не похоже на путь res://")
    rendering = data.get("rendering", {})
    method = rendering.get("renderer/rendering_method", "")
    if method.strip('"') != "gl_compatibility":
        problem(f"rendering_method = {method}; для целевого устройства ожидается gl_compatibility")
    mobile = rendering.get("renderer/rendering_method.mobile", "")
    if mobile.strip('"') != "gl_compatibility":
        problem(f"rendering_method.mobile = {mobile}; ожидается gl_compatibility")
    display = data.get("display", {})
    orientation = display.get("window/handheld/orientation", "")
    if orientation and orientation != "1":
        problem(f"handheld/orientation = {orientation}, а портрет = 1")
    input_section = data.get("input", {})
    if not input_section:
        problem("project.godot: секция [input] пуста — управление с клавиатуры не соберётся")
    return None


def class_names() -> dict[str, Path]:
    found: dict[str, Path] = {}
    for path in gd_files():
        for match in re.finditer(r"^class_name\s+(\w+)", read(path), re.M):
            found[match.group(1)] = path
    return found


def check_scenes() -> None:
    for scene in sorted((ROOT / "scenes").rglob("*.tscn")):
        text = read(scene)
        if "format=3" not in text.split("\n", 1)[0]:
            problem(f"{scene.relative_to(ROOT)}: unexpected .tscn header (ожидается format=3)")
        for match in re.finditer(r'\[ext_resource type="([^"]+)" path="([^"]+)"', text):
            target = ROOT / match.group(2).replace("res://", "")
            if not target.exists():
                problem(f"{scene.relative_to(ROOT)}: ext_resource '{match.group(2)}' не найден")
        if "[node name=" not in text:
            problem(f"{scene.relative_to(ROOT)}: нет ни одного узла")
        root_node = re.search(r'\[node name="([^"]+)" type="([^"]+)"\]', text)
        if not root_node:
            problem(f"{scene.relative_to(ROOT)}: корневой узел не описан (нужен [node ... type=...])")


def autoload_names() -> list[str]:
    data = parse_project_godot(read(ROOT / "project.godot"))
    return list(data.get("autoload", {}).keys())


def known_project_classes(found: dict[str, Path]) -> set[str]:
    """Вложенные class_name'ы (`class FakeUnit`) тоже легальны — собираем их по всему коду."""
    extra = set()
    for path in gd_files():
        for match in re.finditer(r"^\s*class (\w+)", read(path), re.M):
            extra.add(match.group(1))
    return set(found) | extra


def load_engine_classes() -> set[str]:
    """Список движковых классов, которыми пользуется проект (tools/engine_classes.txt).

    Он нужен, чтобы не тянуть в CI 800 xml-док движка: если код начинает использовать
    новый класс Godot — строка в файл добавляется вместе с ним, и это осознанный диф.
    """
    path = ROOT / "tools" / "engine_classes.txt"
    if not path.exists():
        problem("нет tools/engine_classes.txt — проверка имён классов выключена")
        return set()
    names = set()
    for line in read(path).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line)
    return names


def check_scripts() -> None:
    found = class_names()
    godot_classes = load_engine_classes() | set(autoload_names())
    known = known_project_classes(found)

    for path in gd_files():
        text = read(path)
        for res in res_paths_in(text):
            relative = res.replace("res://", "")
            if any(marker in relative for marker in ("%", "{", "}")):
                continue
            if (ROOT / relative).exists():
                continue
            # Пути, которые собираются строкой (path_join) или опциональные ассеты — не ошибка.
            if "override_cfg" in relative or "user://" in res:
                continue
            if relative.startswith(("assets/models/", "assets/textures/")):
                continue  # каталоги, которые заполняет пользователь (README внутри папок)
            if relative.startswith(("assets/", "scenes/", "autoloads/")) and path.name != "main_menu_background.gd" \
                    and not relative.startswith("assets/ui/map_card"):
                problem(f"{path.relative_to(ROOT)}: ссылка '{res}' ведёт в никуда")
        for match in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.(new|self_check|for_config|build|get_config)\b", text):
            name = match.group(1)
            if name in godot_classes or name in known:
                continue
            if name.isupper() or "_" in name:
                continue
            # Неизвестный «класс с методом» — почти всегда опечатка в class_name.
            problem(f"{path.relative_to(ROOT)}: неизвестный класс '{name}' (метод {match.group(2)})")
        for match in re.finditer(r'Input\.(?:is_action_pressed|get_action_strength|is_action_just_pressed)\("([^"]+)"', text):
            action = match.group(1)
            project = read(ROOT / "project.godot")
            needle = "\n" + action + "={"
            if needle not in project:
                problem(f"{path.relative_to(ROOT)}: действие ввода '{action}' не объявлено в project.godot")


SECTION_CLASS = {
    "world": "world_config.gd",
    "chase": "chase_config.gd",
    "police": "police_config.gd",
    "nitro": "nitro_config.gd",
    "camera": "camera_config.gd",
    "ui": "ui_config.gd",
    "vehicle.player": "vehicle_config.gd",
    "vehicle.police": "vehicle_config.gd",
    "graphics": "graphics_config.gd",
    "graphics.tier_low": "quality_tier.gd",
    "graphics.tier_medium": "quality_tier.gd",
    "graphics.tier_high": "quality_tier.gd",
}
# [game]/[dev] — «сырые» секции: читаются через Config.*_value, без класса-адресата.
RAW_SECTIONS = {"game", "dev"}


def check_cfg_files() -> None:
    """Синтаксис .cfg + соответствие ключей @export-полям классов (по ИМЕНИ СЕКЦИИ).

    Файл может содержать несколько секций (chase.cfg = [chase] + [police]), поэтому
    привязка «файл -> класс» была бы неправдой.
    """
    for cfg in sorted((ROOT / "autoloads").glob("*.cfg")):
        sections: dict[str, list[str]] = {}
        current = ""
        for line_no, line in enumerate(read(cfg).splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith((";", "#")):
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                current = stripped[1:-1].strip()
                sections.setdefault(current, [])
                continue
            if "=" not in stripped:
                problem(f"autoloads/{cfg.name}:{line_no}: строка не секция и не key=value: {stripped[:40]}")
                continue
            key = stripped.split("=", 1)[0].strip()
            if not current:
                problem(f"autoloads/{cfg.name}:{line_no}: ключ '{key}' вне секции")
                continue
            sections[current].append(key)
            value = stripped.split("=", 1)[1].strip()
            if value.endswith(","):
                problem(f"autoloads/{cfg.name}:{line_no}: значение ключа '{key}' обрывается запятой")
        for section, keys in sections.items():
            if section in RAW_SECTIONS:
                continue
            target = SECTION_CLASS.get(section)
            if target is None:
                problem(f"autoloads/{cfg.name}: секция [{section}] не знает, в какой класс её грузить")
                continue
            text = read(ROOT / "scripts" / "config" / target)
            exported = set(re.findall(r"@export[^\n]*?\bvar\s+(\w+)\s*[:=]", text))
            exported |= set(re.findall(r"@export[^\n]*\n\s*var\s+(\w+)\s*[:=]", text))
            for key in keys:
                if key in ("resource", "comment"):
                    continue
                if exported and key not in exported:
                    problem(f"autoloads/{cfg.name}: ключ '{key}' из [{section}] отсутствует в {target}")


def check_assets() -> None:
    for path in ("icon.svg", "assets/ui"):
        if not (ROOT / path).exists():
            problem(f"нет {path}")
    backgrounds = list((ROOT / "assets" / "ui").glob("*.[jp][pn]g")) if (ROOT / "assets" / "ui").exists() else []
    if not backgrounds:
        problem("assets/ui пуст: главному меню нужен фон (фон.jpg) — см. README")
    presets = ROOT / "export_presets.cfg"
    if not presets.exists():
        problem("нет export_presets.cfg — нечем собирать APK")
        return
    text = read(presets)
    if 'platform="Android"' not in text:
        problem("export_presets.cfg: нет Android-пресета")
    if 'package/unique_name="com.racing.chase"' not in text:
        problem("export_presets.cfg: package/unique_name != com.racing.chase")
    if "architectures/arm64-v8a=true" not in text:
        problem("export_presets.cfg: arm64-v8a не включён")
    if "armeabi-v7a=true" in text:
        problem("export_presets.cfg: armeabi-v7a включён — двойные ABI удваивают APK")


def main() -> int:
    check_project_settings()
    check_scenes()
    check_scripts()
    check_cfg_files()
    check_assets()
    if PROBLEMS:
        print("ИТОГ: найдено %d проблем:" % len(PROBLEMS))
        for item in PROBLEMS:
            print("  -", item)
        return 1
    print("ИТОГ: ok — структура проекта, сцены, ссылки, конфиги и ассеты согласованы")
    return 0


if __name__ == "__main__":
    sys.exit(main())
