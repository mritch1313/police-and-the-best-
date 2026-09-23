#!/usr/bin/env python3
"""YAML sanity check for every workflow / composite action in the repository.

GitHub fails a whole run with "This run likely failed because of a workflow file
issue" and gives no usable log, so the repository validates its own YAML instead.
Besides pure YAML parsing this also enforces the rules this project committed to:

  * every job that builds Godot or Android must use ``runs-on: ubuntu-latest``
  * ``ubuntu-slim`` is forbidden (no Android SDK / JDK there)
  * every ``uses: ./path`` reference must exist in the checkout

Run: python3 tools/ci/lint_workflows.py
Exit code 1 on any problem.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required: pip install pyyaml")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
ACTION_DIR = ROOT / ".github" / "actions"

FORBIDDEN_RUNNERS = ("ubuntu-slim",)
REQUIRED_RUNNER = "ubuntu-latest"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")


def check_workflow(path: Path) -> int:
    errors = 0
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        fail(f"{path.relative_to(ROOT)}: invalid YAML: {exc}")
        return 1

    if not isinstance(data, dict):
        fail(f"{path.relative_to(ROOT)}: top level must be a mapping")
        return 1

    if "jobs" not in data:
        fail(f"{path.relative_to(ROOT)}: no jobs defined")
        return 1

    for job_name, job in (data.get("jobs") or {}).items():
        if not isinstance(job, dict):
            fail(f"{path.relative_to(ROOT)}:{job_name}: job must be a mapping")
            errors += 1
            continue
        runner = job.get("runs-on")
        runner_text = str(runner)
        if REQUIRED_RUNNER not in runner_text:
            fail(
                f"{path.relative_to(ROOT)}:{job_name}: runs-on must be "
                f"'{REQUIRED_RUNNER}' (found: {runner_text})"
            )
            errors += 1
        for bad in FORBIDDEN_RUNNERS:
            if bad in runner_text:
                fail(f"{path.relative_to(ROOT)}:{job_name}: forbidden runner '{bad}'")
                errors += 1

        for step in job.get("steps") or []:
            uses = str(step.get("uses", ""))
            if uses.startswith("./"):
                target = (ROOT / uses[2:]).resolve()
                if not (target / "action.yml").is_file() and not (
                    target / "action.yaml"
                ).is_file():
                    fail(
                        f"{path.relative_to(ROOT)}:{job_name}: local action "
                        f"'{uses}' has no action.yml"
                    )
                    errors += 1

    print(f"OK: {path.relative_to(ROOT)}")
    return errors


def check_action(path: Path) -> int:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        fail(f"{path.relative_to(ROOT)}: invalid YAML: {exc}")
        return 1
    if not isinstance(data, dict) or "runs" not in data:
        fail(f"{path.relative_to(ROOT)}: composite action without 'runs'")
        return 1
    print(f"OK: {path.relative_to(ROOT)}")
    return 0


def main() -> int:
    errors = 0
    files = sorted(WORKFLOW_DIR.glob("*.y*ml"))
    if not files:
        fail("no workflow files found")
        return 1
    for path in files:
        errors += check_workflow(path)
    for path in sorted(ACTION_DIR.glob("*/action.y*ml")):
        errors += check_action(path)
    if errors:
        print(f"\n{errors} problem(s) found")
        return 1
    print("\nAll workflow/action files are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
