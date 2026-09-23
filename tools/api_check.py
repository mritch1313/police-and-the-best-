#!/usr/bin/env python3
"""api_check.py — сверяет имена свойств/методов/констант Godot, которые использует
проект, с официальной документацией ТОЙ версии движка, под которую он собирается.

Зачем: в песочнице нет Godot-бинаря, поэтому «скрипт распарсился gdparse'ом» — не
доказательство работоспособности. Код, обращающийся к несуществующему
`material.normal_depth` (в 4.7 это `normal_scale`), падает только на реальном запуске.
Проверка по `doc/classes/*.xml` дерева исходников движка ловит это статически.

Использование:
    python3 tools/api_check.py <путь_к_дереву_godot> [файл_поверхности]

По умолчанию: /home/user/.src/godot-4.7.2-stable и tools/api_surface.txt
Формат файла поверхности, по одной записи на строку:
    Node3D.position          # свойство/метод класса
    StandardMaterial3D.normal_scale
    BaseMaterial3D.TEXTURE_CHANNEL_RED
    Image.bump_map_to_normal_map
Строки `#` — комментарии. Собственные классы проекта (autoload'ы, class_name) пропускаются:
их проверяют gdparse и автотесты. Возврат: 0 — всё найдено, 1 — есть отсутствующие имена,
2 — нет дерева исходников (тогда SKIP, а не «успех»: отсутствие проверки называется явно).
"""
from __future__ import annotations

import pathlib
import re
import sys

OWN_CLASSES = {
    "Config", "AppState", "SaveManager", "SettingsManager", "ScreenFlow",
    "PerformanceManager", "DebugConsole", "GameSetup", "BalanceRules",
}


def _closest(name: str, classes: dict) -> str:
    """Похожее имя класса движка (расстояние Левенштейна <= 2) — чтобы ловить опечатки,
    а не глушить их как «возможно, это свой класс»."""
    best, best_d = "", 3
    for cand in classes:
        if abs(len(cand) - len(name)) > 2:
            continue
        d = _lev(name, cand)
        if d < best_d:
            best, best_d = cand, d
    return best if best_d <= 2 else ""


def _lev(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def load_classes(doc_dir: pathlib.Path) -> dict[str, dict]:
    classes: dict[str, dict] = {}
    for path in sorted(doc_dir.glob("*.xml")):
        text = path.read_text(encoding="utf-8", errors="replace")
        members = set(re.findall(r'<(?:member|method|signal|constant) name="([^"]+)"', text))
        head = text[:4000]
        inh = re.search(r'<class\b[^>]*?inherits="([^"]+)"', head, re.S)
        classes[path.stem] = {"members": members, "inherits": inh.group(1) if inh else ""}
    return classes


def chain(classes: dict[str, dict], name: str) -> list[str]:
    out: list[str] = []
    cur = name
    while cur in classes and cur not in out:
        out.append(cur)
        cur = classes[cur]["inherits"]
    return out


CLASS_DECL_RE = re.compile(r"\b(?:var|const)\s+[A-Za-z_][A-Za-z0-9_]*\s*(?::\s*([A-Z][A-Za-z0-9_]*)|=\s*([A-Z][A-Za-z0-9_]*)\.new\s*\()")
STATIC_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)")
PROP_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)")


def strip_code(text: str) -> str:
    """Убирает строковые литералы и комментарии: иначе `res://scenes/Game.tscn`
    превращается в «класс Game, метод tscn»."""
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in "\"'":
            quote = ch
            i += 1
            while i < n and text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            i += 1
            out.append(" ")
            continue
        if ch == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def load_ignore(path: pathlib.Path) -> set[str]:
    if not path.is_file():
        return set()
    return {ln.split("#")[0].strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.strip().startswith("#")}


def is_ignored(entry: str, ignore: set[str]) -> bool:
    cls, _, member = entry.partition(".")
    return entry in ignore or f"{cls}.*" in ignore or f"{cls}.{member}" in ignore


def project_classes(repo: pathlib.Path) -> set[str]:
    """Имена классов самого проекта — их проверяет gdparse/тесты, а не дока Godot."""
    names = set(OWN_CLASSES)
    for path in repo.rglob("*.gd"):
        for m in re.finditer(r"^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)", path.read_text(encoding="utf-8", errors="replace"), re.M):
            names.add(m.group(1))
        for m in re.finditer(r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)", path.read_text(encoding="utf-8", errors="replace"), re.M):
            names.add(m.group(1))
    return names


# «Мягкие» базовые типы: узел передаётся как Node/Control, а методы у него — из
# собственного класса проекта (ChaseManager, PlayerCar, ...). Проверяем, что имя члена
# вообще объявлено в проекте, и только тогда не считаем это обращением к API Godot.
SOFT_BASE_TYPES = {
    "Node", "Object", "Control", "Resource", "Node3D", "CanvasItem", "RefCounted",
    "Area3D", "RigidBody3D", "Node2D", "Variant",
}


def project_members(repo: pathlib.Path) -> set[str]:
    names: set[str] = set()
    for path in repo.rglob("*.gd"):
        text = strip_code(path.read_text(encoding="utf-8", errors="replace"))
        for m in re.finditer(r"^(?:static )?(?:func|var|const|signal)\s+([A-Za-z_]\w*)", text, re.M):
            names.add(m.group(1))
    return names


def dump_surface(repo: pathlib.Path) -> list[str]:
    """Собирает список `Class.member` из кода: статические вызовы и обращения к
    локальным переменным, чей тип выводится из явной аннотации или `Class.new()`."""
    out: set[str] = set()
    own = project_classes(repo)
    members = project_members(repo)
    for path in sorted(repo.rglob("*.gd")):
        text = strip_code(path.read_text(encoding="utf-8", errors="replace"))
        locals_by_type: dict[str, str] = {}
        for m in CLASS_DECL_RE.finditer(text):
            cls = m.group(1) or m.group(2)
            name = re.search(r"\b(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)", m.group(0))
            if cls and name:
                locals_by_type[name.group(1)] = cls
        for m in STATIC_RE.finditer(text):
            if m.group(1) in own:
                continue
            if m.group(1) in SOFT_BASE_TYPES and m.group(2) in members:
                continue
            out.add(f"{m.group(1)}.{m.group(2)}")
        for m in PROP_RE.finditer(text):
            cls = locals_by_type.get(m.group(1))
            if not cls:
                continue
            if cls in SOFT_BASE_TYPES and m.group(2) in members:
                continue
            out.add(f"{cls}.{m.group(2)}")
    return sorted(out)


def main() -> int:
    if "--dump" in sys.argv:
        idx = sys.argv.index("--dump")
        repo = pathlib.Path(sys.argv[idx + 1]) if len(sys.argv) > idx + 1 else pathlib.Path(__file__).resolve().parent.parent
        items = dump_surface(repo)
        dest = repo / "tools" / "api_surface.txt"
        header = (
            "# Автоматически собрано: python3 tools/api_check.py --dump\n"
            "# Проверка: python3 tools/api_check.py <дерево_исходников_godot> tools/api_surface.txt\n"
            "# Собственные классы проекта фильтруются внутри скрипта.\n"
        )
        dest.write_text(header + "\n".join(items) + "\n", encoding="utf-8")
        print(f"DUMP: {len(items)} записей -> {dest}")
        return 0
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] != "--dump" else pathlib.Path("/home/user/.src/godot-4.7.2-stable")
    surface = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parent / "api_surface.txt"
    doc_dir = root / "doc" / "classes"
    if not doc_dir.is_dir():
        print(f"SKIP: нет {doc_dir} — проверка API невозможна (не называть это успехом)")
        return 2
    if not surface.is_file():
        print(f"SKIP: нет файла поверхности {surface}")
        return 2
    classes = load_classes(doc_dir)
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    own = project_classes(repo_root)
    ignore = load_ignore(repo_root / "tools" / "api_check.ignore.txt")
    missing: list[str] = []
    skipped: list[str] = []
    checked = 0
    for raw in surface.read_text(encoding="utf-8").splitlines():
        token = raw.split("#")[0].strip()
        if not token or "." not in token:
            continue
        cls, member = token.split(".", 1)
        cls = cls.lstrip("@")
        if cls.isupper():
            continue  # ALL_CAPS — константа/имя файла самого проекта, не класс движка
        if cls in own or member == "new" or is_ignored(token, ignore):
            continue
        if cls not in classes:
            near = _closest(cls, classes)
            if near:
                missing.append(f"{token} — нет класса {cls}, возможно имелось в виду {near}")
            else:
                skipped.append(token)
            continue
        checked += 1
        found = any(member in classes[c]["members"] for c in chain(classes, cls))
        if not found:
            missing.append(f"{token} — нет члена {member} у {cls} (и предков)")
    print(f"API CHECK: классов в доке {len(classes)}, записей проверено {checked}, "
          f"не найдено {len(missing)}, пропущено (свои/недокументированные) {len(skipped)}")
    for item in missing:
        print("  FAIL", item)
    if missing:
        print("Подсказка: осознанные исключения — в tools/api_check.ignore.txt (с причиной).")
    print("ИТОГ:", "ok" if not missing else "FAIL")
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
