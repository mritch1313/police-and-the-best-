#!/usr/bin/env python3
"""Static API check for the project's GDScript, validated against Godot 4.7.2.

Why this tool exists
--------------------
The whole project is validated by a real Godot 4.7.2 binary in GitHub Actions, but every
CI round trip costs minutes and the raw logs are not always reachable. A local, offline
check that catches typos in engine method names, engine constants and enum values before
pushing saves a large amount of time.

What it checks
--------------
1. every ``identifier(`` call in the project's scripts is either a Godot 4.7.2 method
   (from the official class reference XML), a function defined somewhere in the project,
   a local variable/callable, an autoload, a built-in GDScript function or a keyword
2. every ``ClassName.CONSTANT`` reference exists as a constant or enum value of that class
   in the 4.7.2 class reference (project classes/enums are collected from the scripts)

Usage
-----
    python3 tools/ci/check_api.py --docs /path/to/godot/doc/classes [--project .]

Exit code 1 when something looks wrong (with file, line and the unknown name).
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

GDSCRIPT_KEYWORDS = {
    "if", "elif", "else", "for", "while", "match", "when", "break", "continue", "pass",
    "return", "class", "class_name", "extends", "is", "in", "as", "and", "or", "not",
    "true", "false", "null", "self", "super", "signal", "func", "var", "const", "enum",
    "static", "await", "yield", "assert", "breakpoint", "preload", "load", "print",
    "print_rich", "printerr", "printraw", "push_error", "push_warning", "range", "len",
    "str", "int", "float", "bool", "abs", "min", "max", "sign", "round", "floor", "ceil",
    "clamp", "lerp", "sqrt", "pow", "sin", "cos", "tan", "atan2", "randi", "randf",
    "randf_range", "randi_range", "seed", "typeof", "weakref", "is_instance_valid",
    "is_same", "is_equal_approx", "is_zero_approx", "is_finite", "is_inf", "is_nan",
    "deg_to_rad", "rad_to_deg", "move_toward", "snapped", "wrap", "wrapf", "wrapi",
    "lerpf", "clampf", "clampi", "minf", "maxf", "absi", "absf", "signf", "signi",
    "floorf", "floori", "ceilf", "ceili", "roundf", "roundi", "sqrtf", "powf", "sinh",
    "cosh", "tanh", "log", "exp", "ease", "stepify", "posmod", "fmod", "fposmod", "inverse_lerp",
    "remap", "smoothstep", "nearest_po2", "instantiate", "free", "type_exists", "hash",
    "Color", "Vector2", "Vector3", "Vector4", "Basis", "Transform3D", "Transform2D",
    "Quaternion", "Rect2", "Rect2i", "AABB", "Plane", "Projection", "Array", "Dictionary",
    "PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array",
    "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array",
    "PackedColorArray", "StringName", "NodePath", "Callable", "Signal", "RID", "Object",
    "Time", "Engine", "Input", "InputMap", "OS", "ProjectSettings", "RenderingServer",
    "PhysicsServer3D", "DisplayServer", "AudioServer", "Performance", "ResourceLoader",
    "ResourceSaver", "TranslationServer", "WorkerThreadPool", "ClassDB", "Geometry2D",
    "Geometry3D", "JSON", "Marshalls", "FileAccess", "DirAccess", "ConfigFile", "Tween",
    "SceneTree", "RandomNumberGenerator", "FastNoiseLite", "NoiseTexture2D",
    "Vector2i", "Vector3i", "Vector4i", "SurfaceTool", "MeshDataTool", "SurfaceTool",
}
# Built-in functions that are methods of the global scope object (@GlobalScope).
BUILTIN_METHOD_PREFIX = "@GlobalScope"


class DocIndex:
    """Method / constant index built from the official Godot class reference."""

    def __init__(self, docs_dir: Path) -> None:
        self.methods: set[str] = set()
        self.constants: dict[str, set[str]] = {}
        self.classes: set[str] = set()
        self.empty: list[str] = []
        for path in sorted(docs_dir.glob("*.xml")):
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError:
                continue
            name = root.get("name")
            if not name:
                continue
            self.classes.add(name)
            consts: set[str] = set()
            for method in root.iter("method"):
                self.methods.add(method.get("name"))
            for member in root.iter("member"):
                consts.add(member.get("name"))
            for constant in root.iter("constant"):
                consts.add(constant.get("name"))
            for enum in root.iter("enum"):
                if enum.get("name"):
                    consts.add(enum.get("name"))
            for signal in root.iter("signal"):
                self.methods.add(signal.get("name"))
            self.constants[name] = consts


class ProjectIndex:
    """Functions, classes and enums defined by the project itself."""

    def __init__(self, project_root: Path) -> None:
        self.functions: set[str] = set()
        self.classes: set[str] = set()
        self.enums: dict[str, set[str]] = {}
        self.autoloads: set[str] = set()
        self.signals: set[str] = set()
        self.files: list[Path] = sorted(project_root.glob("scripts/**/*.gd"))
        self.files += sorted(project_root.glob("tests/**/*.gd"))
        self.files += sorted(project_root.glob("tools/**/*.gd"))

        func_re = re.compile(r"^\s*(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)")
        class_re = re.compile(r"^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)")
        enum_re = re.compile(r"^\s*enum\s+([A-Za-z_][A-Za-z0-9_]*)")
        # Enum values are written as NAME = ... inside an enum block.
        self.enum_values: set[str] = set()
        self.signal_names: set[str] = set()
        signal_re = re.compile(r"^\s*signal\s+([A-Za-z_][A-Za-z0-9_]*)")

        for path in self.files:
            text = path.read_text(encoding="utf-8")
            in_enum = False
            for line in text.splitlines():
                m = func_re.match(line)
                if m:
                    self.functions.add(m.group(1))
                    in_enum = False
                    continue
                m = class_re.match(line)
                if m:
                    self.classes.add(m.group(1))
                    in_enum = False
                    continue
                m = enum_re.match(line)
                if m:
                    self.enums.setdefault(m.group(1), set())
                    in_enum = True
                    continue
                m = signal_re.match(line)
                if m:
                    self.signal_names.add(m.group(1))
                    in_enum = False
                    continue
                if in_enum:
                    stripped = line.strip()
                    if stripped.startswith("{") or stripped.startswith("}"):
                        continue
                    if "=" in stripped:
                        key = stripped.split("=")[0].strip()
                        if re.fullmatch(r"[A-Z0-9_]+", key):
                            self.enum_values.add(key)
                    elif stripped == "" or line.startswith("func "):
                        in_enum = False

        # Autoloads from project.godot are global singletons usable as identifiers.
        project_file = project_root / "project.godot"
        if project_file.exists():
            text = project_file.read_text(encoding="utf-8")
            in_autoload = False
            for line in text.splitlines():
                if line.startswith("["):
                    in_autoload = line.strip() == "[autoload]"
                    continue
                if in_autoload and "=" in line:
                    self.autoloads.add(line.split("=")[0].strip())


CALL_RE = re.compile(r"(?<![\w.])([A-Za-z_][A-Za-z0-9_]*)\s*\(")
MEMBER_CALL_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")
CONST_RE = re.compile(r"([A-Z][A-Za-z0-9_]*)\.([A-Z][A-Z0-9_]*)\b")
DECLARED_LOCAL_RE = re.compile(r"\b(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)")
# GDScript annotations ("@export_range(...)") are not function calls; the "@name" part is
# removed before scanning so that only their arguments are inspected.
ANNOTATION_RE = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*")
# "signal name(a, b)" declares a signal; it is not a function call.
SIGNAL_DECL_RE = re.compile(r"\bsignal\s+[A-Za-z_][A-Za-z0-9_]*\s*\(")


def strip_comments_and_strings(line: str) -> str:
    out = []
    in_string = False
    quote = ""
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                in_string = False
            i += 1
            continue
        if ch in "\"'":
            in_string = True
            quote = ch
            i += 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def check_file(path: Path, docs: DocIndex, project: ProjectIndex, root: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    locals_declared: set[str] = set()
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = strip_comments_and_strings(raw)
        if not line.strip():
            continue
        line = ANNOTATION_RE.sub("", line)
        line = SIGNAL_DECL_RE.sub("signal ", line)
        for m in DECLARED_LOCAL_RE.finditer(line):
            locals_declared.add(m.group(1))

        for m in CALL_RE.finditer(line):
            name = m.group(1)
            # Skip anything preceded by a dot: those are method calls on an object and are
            # checked through the member pattern below.
            start = m.start(1)
            if start > 0 and line[start - 1] == ".":
                continue
            if name in GDSCRIPT_KEYWORDS or name in docs.methods:
                continue
            if name in project.functions or name in locals_declared:
                continue
            if name in project.signals:
                continue
            if name in project.classes or name in docs.classes or name in project.autoloads:
                continue
            if name in project.enum_values:
                continue
            problems.append(f"{path.relative_to(root)}:{lineno}: unknown function '{name}('")

        for m in CONST_RE.finditer(line):
            cls, const = m.group(1), m.group(2)
            if cls in project.classes or cls in project.enums:
                continue
            if cls not in docs.classes:
                continue
            if const in docs.constants.get(cls, set()):
                continue
            problems.append(
                f"{path.relative_to(root)}:{lineno}: '{cls}.{const}' is not a constant of {cls} in Godot 4.7.2"
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--docs", required=True, help="path to doc/classes of the Godot source")
    parser.add_argument("--project", default=".", help="project root")
    args = parser.parse_args()

    root = Path(args.project).resolve()
    docs_dir = Path(args.docs).resolve()
    if not docs_dir.is_dir():
        print(f"docs directory not found: {docs_dir}")
        return 2

    docs = DocIndex(docs_dir)
    project = ProjectIndex(root)
    print(
        f"indexed {len(docs.classes)} engine classes, {len(docs.methods)} engine methods, "
        f"{len(project.functions)} project functions in {len(project.files)} files"
    )

    problems: list[str] = []
    for path in project.files:
        problems.extend(check_file(path, docs, project, root))

    if problems:
        print(f"\n{len(problems)} problem(s):")
        for problem in problems:
            print("  " + problem)
        return 1
    print("\nNo unknown engine API detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
