#!/usr/bin/env python3
"""Проверка соответствия `autoloads/*.cfg` и @export-полей классов ConfigResource.

Зачем: конфиг — источник правды для чисел, а класс ресурса описывает структуру.
Если в .cfg опечатка в имени ключа, класс переименовали, или значение не парсится
как литерал Godot — ловить это нужно до Godot-сборки, за 0.3 секунды, а не в CI.

Скрипт сверяет:
  1) каждая секция .cfg соответствует классу (class_name -> файл), заданному в CLASS_MAP;
  2) каждый ключ .cfg существует как @export-свойство класса;
  3) значение парсится в Python-аналог Godot-литерала и СОВПАДАЕТ со значением по умолчанию
     класса (иначе .tres/дефолт и .cfg разъедутся — запутанное поведение);
  4) у класса нет @export-ключей, молча отсутствующих в .cfg (только предупреждение).

Выход: 0 = ок, 1 = найдены расхождения, 2 = сломан сам инструмент.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CFG_DIR = ROOT / "autoloads"
CFG_DIR_OVERRIDE = ROOT / "override_cfg"

# секция .cfg -> class_name ресурса
CLASS_MAP = {
    "world": "WorldConfig",
    "vehicle.player": "VehicleConfig",
    "vehicle.police": "VehicleConfig",
    "nitro": "NitroConfig",
    "chase": "ChaseConfig",
    "police": "PoliceConfig",
    "camera": "CameraConfig",
    "graphics": "GraphicsConfig",
    "graphics.tier_low": "QualityTier",
    "graphics.tier_medium": "QualityTier",
    "graphics.tier_high": "QualityTier",
    "ui": "UiConfig",
}
# секции без привязки к ресурсу (сырые значения через Config.num/str/...)
RAW_ONLY = {"game", "dev"}
# Секции-«варианты»: они намеренно отличаются от встроенных значений по умолчанию
# класса (иначе это был бы тот же самый автомобиль/тот же самый пресет).
# Для них несовпадение — заметка, а не ошибка.
VARIANT_SECTIONS = {"vehicle.police", "graphics.tier_low", "graphics.tier_high"}

EXPORT_RE = re.compile(r"^[ \t]*@export(?:_range\((?P<rng>[^)]*)\))?\s+var\s+(?P<name>\w+)\s*(:\s*(?P<type>[\w.\[\]]+))?\s*=\s*(?P<val>.+?)\s*$")
CLASS_RE = re.compile(r"^class_name\s+(\w+)", re.MULTILINE)
GROUP_RE = re.compile(r'^\s*@export_group\("(?P<t>[^"]*)"\)')
ARRAY_DEFAULT_START = re.compile(r"^[ \t]*@export\s+var\s+(?P<name>\w+)\s*:\s*(?P<type>[\w.\[\]]+)\s*=\s*\[")


def parse_class(path: Path) -> dict:
    """Возвращает {имя_свойства: {"type":..., "default":..., "range":...}} для одного .gd."""
    props = {}
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = ARRAY_DEFAULT_START.match(lines[i])
        if m:
            # многострочный литерал массива: собираем до закрывающей скобки
            buf = lines[i][lines[i].index("["):]
            depth = buf.count("[") - buf.count("]")
            j = i + 1
            while depth > 0 and j < len(lines):
                buf += " " + lines[j].strip()
                depth += lines[j].count("[") - lines[j].count("]")
                j += 1
            props[m.group("name")] = {
                "type": m.group("type"),
                "default": buf.strip(),
                "range": None,
            }
            i = j
            continue
        m = EXPORT_RE.match(lines[i])
        if m and m.group("name") != "config_section":
            props[m.group("name")] = {
                "type": m.group("type") or "Variant",
                "default": m.group("val"),
                "range": m.group("rng"),
            }
        i += 1
    return {"class": (CLASS_RE.search(text).group(1) if CLASS_RE.search(text) else "?"), "props": props}


def index_classes() -> dict:
    by_class = {}
    for path in sorted((ROOT / "scripts").rglob("*.gd")):
        m = CLASS_RE.search(path.read_text(encoding="utf-8"))
        if m:
            by_class[m.group(1)] = path
    return by_class


def parse_cfg(path: Path) -> dict:
    """Простейший парсер наших .cfg: секции + 'key = value' (строк-массивов не используем)."""
    sections = {}
    current = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            sections[current] = {}
            continue
        if "=" in line and current is not None:
            k, v = line.split("=", 1)
            sections[current][k.strip()] = v.strip()
    return sections


def strip_comment(text: str) -> str:
    out, quote = [], None
    for ch in text:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch in ";#":
            break
        out.append(ch)
    return "".join(out).strip()


def norm_scalar(text: str) -> float | None:
    t = strip_comment(text)
    try:
        return float(t)
    except ValueError:
        return None


def norm_literal(text: str) -> str:
    """Схлопывает Godot-литерал в сравнимую форму: без комментариев, аннотаций типа
    (`[float] = [...]`), пробелов и хвостовых запятых."""
    t = strip_comment(text)
    t = re.sub(r"^\[[\w,\s]*\]\s*=\s*", "", t)
    t = t.replace("\n", " ")
    t = re.sub(r"\s+", "", t)
    t = re.sub(r",([\]}])", r"\1", t)
    return t


def same_scalar(cfg: str, default: str) -> bool:
    a, b = norm_scalar(cfg), norm_scalar(default)
    if a is not None and b is not None:
        return abs(a - b) <= max(1e-4, abs(b) * 1e-5)
    return norm_literal(cfg).strip('"').lower() == norm_literal(default).strip('"').lower()


def same_color(cfg: str, default: str) -> bool:
    def nums(s):
        return [float(x) for x in re.findall(r"-?\d+\.?\d*(?:e-?\d+)?", strip_comment(s))]
    a, b = nums(cfg), nums(default)
    if len(a) != len(b) or not a:
        return False
    return all(abs(x - y) < 1e-3 for x, y in zip(a, b))


def main() -> int:
    problems: list[str] = []
    notes: list[str] = []
    by_class = index_classes()
    sections: dict = {}
    for cfg in sorted(list(CFG_DIR.glob("*.cfg")) + (list(CFG_DIR_OVERRIDE.glob("*.cfg")) if CFG_DIR_OVERRIDE.exists() else [])):
        for sec, kv in parse_cfg(cfg).items():
            sections.setdefault(sec, {}).update(kv)
            sections.setdefault(sec + "@file", cfg.name)

    unknown = set(sections) - set(CLASS_MAP) - RAW_ONLY - {s + "@file" for s in list(sections)}
    for sec in sorted(unknown):
        if not sec.endswith("@file"):
            problems.append(f"{sections.get(sec + '@file', '?')}: секция [{sec}] не описана в CLASS_MAP (её никто не читает типизированно)")

    for sec, cls in CLASS_MAP.items():
        if sec not in sections:
            problems.append(f"нет секции [{sec}] (ожидался класс {cls})")
            continue
        path = by_class.get(cls)
        if path is None:
            problems.append(f"класс {cls} не найден ни в одном .gd (секция [{sec}])")
            continue
        info = parse_class(path)
        props = info["props"]
        kv = sections[sec]
        for key, value in sorted(kv.items()):
            if key not in props:
                problems.append(f"[{sec}] '{key}': нет такого @export у {cls} ({path.name})")
                continue
            default = props[key]["default"]
            mismatch = None
            if "Color(" in default or "Color(" in value:
                if not same_color(value, default):
                    mismatch = f"cfg={value} != дефолт класса={default}"
            elif value.startswith("[") or default.startswith("["):
                if norm_literal(value).lower() != norm_literal(default).lower():
                    mismatch = f"массив различается: {value} / {default}"
            elif not same_scalar(value, default):
                mismatch = f"cfg={value} != дефолт класса={default}"
            if mismatch:
                if sec in VARIANT_SECTIONS:
                    notes.append(f"[{sec}] '{key}' намеренно отличается от дефолта: {mismatch}")
                else:
                    problems.append(f"[{sec}] '{key}': {mismatch}")
        for key in sorted(props):
            if key == "config_section" or key.startswith("visual"):
                continue
            if key not in kv:
                notes.append(f"[{sec}] {cls}.{key} не задан в .cfg — работает встроенное значение {props[key]['default']}")
        # проверка, что числовой ключ парсится (Godot требует валидный литерал)
        for key, value in sorted(kv.items()):
            d = props.get(key, {}).get("default", "")
            if re.match(r"^-?\d+\.\d+$", d.strip()) and not re.match(r"^-?\d+(\.\d+)?([eE][-+]?\d+)?$", value.split(";")[0].strip()):
                if norm_scalar(value) is None:
                    problems.append(f"[{sec}] '{key}': значение '{value}' не парсится в float")
    print(f"Проверено секций: {len(CLASS_MAP)}  ключей в cfg: {sum(len(v) for k, v in sections.items() if not k.endswith('@file'))}")
    for n in notes:
        print("  note:", n)
    for p in problems:
        print("  FAIL:", p)
    print("ИТОГ: ok" if not problems else f"ИТОГ: провалено {len(problems)} расхождений")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
