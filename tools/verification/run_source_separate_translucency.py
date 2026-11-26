"""Run the source AfterDOF regression and its CPU analyzer from this checkout.

Requires Python with numpy and the locally installed Godot runtime/assets.
The intentional DOF failure must produce exactly one named ERROR; every other
engine error fails analysis. Numerical success is not original UE frame parity.
Existing output directories are never reused. Only this run's process tree is
terminated on timeout/interruption; other Godot instances are not selected.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


EXPECTED_ERROR = "Source HDR DOF: intentional integration diagnostic"


def checkout_root() -> Path:
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "project/project.godot").is_file():
            return candidate
    raise ValueError("Cannot find this checkout's project/project.godot")


def run_owned_tree(command: list[str], cwd: Path, log: Path, timeout: float) -> dict:
    started = time.monotonic()
    process = None
    result = {"exit": None, "timed_out": False, "interrupted": False, "runner_error": None}
    try:
        with log.open("wb") as output:
            process = subprocess.Popen(
                command, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
                start_new_session=os.name != "nt",
            )
            try:
                result["exit"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
            except KeyboardInterrupt:
                result["interrupted"] = True
    except Exception as exc:
        result["runner_error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if process is not None and process.poll() is None:
            termination = {"pid": process.pid, "exit": None, "output": "", "errors": [],
                           "owned_process_stopped": False}
            result["tree_termination"] = termination
            try:
                if os.name == "nt":
                    # No image-name selection: only the live process this call owns.
                    killed = subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                            capture_output=True, text=True, timeout=15)
                    termination.update(exit=killed.returncode, output=killed.stdout + killed.stderr)
                    if killed.returncode != 0:
                        termination["errors"].append(f"taskkill exited with code {killed.returncode}")
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                    termination["exit"] = 0
            except (Exception, KeyboardInterrupt) as exc:
                if isinstance(exc, KeyboardInterrupt):
                    result["interrupted"] = True
                termination["errors"].append(f"Termination failed: {type(exc).__name__}: {exc}")
            try:
                process.wait(timeout=15)
            except (Exception, KeyboardInterrupt) as exc:
                if isinstance(exc, KeyboardInterrupt):
                    result["interrupted"] = True
                termination["errors"].append(f"Termination wait failed: {type(exc).__name__}: {exc}")
            # A failed kill attempt is never evidence that the owned process stopped.
            result["exit"] = process.poll()
            termination["owned_process_stopped"] = result["exit"] is not None
            if not termination["owned_process_stopped"]:
                termination["errors"].append("Owned process is still running after cleanup")
            if termination["errors"]:
                messages = ([result["runner_error"]] if result["runner_error"] else [])
                result["runner_error"] = "; ".join(messages + termination["errors"])
    result["seconds"] = time.monotonic() - started
    return result


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, help="Godot executable (default: checkout tools/godot console runtime)")
    parser.add_argument("--out", type=Path, help="New output directory; relative paths resolve from checkout root")
    parser.add_argument("--timeout", type=float, default=360, help="Engine wall-clock timeout in seconds (default: 360)")
    args = parser.parse_args(argv)
    try:
        root = checkout_root()
        if args.timeout <= 0 or not float("inf") > args.timeout:
            raise ValueError("--timeout must be finite and greater than zero")
        godot = args.godot or Path("tools/godot/Godot_v4.7.2-stable_win64_console.exe")
        godot = (root / godot).resolve()
        analyzer = root / "tools/verification/analyze_source_separate_translucency.py"
        verifier = root / "project/scripts/verification/verify_source_separate_translucency.gd"
        for required in (godot, analyzer, verifier, analyzer.with_name("source_separate_readback.py")):
            if not required.is_file():
                raise ValueError(f"Required file missing: {required}")
        if importlib.util.find_spec("numpy") is None:
            raise ValueError("This Python needs numpy for the CPU analyzer")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        folder = (root / (args.out or Path("workbench/reports") / ("source-separate-" + stamp))).resolve()
        folder.mkdir(parents=True, exist_ok=False)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))

    command = [str(godot), "--path", str(root / "project"), "--script",
               "res://scripts/verification/verify_source_separate_translucency.gd",
               "--resolution", "1280x720", "--log-file", str(folder / "engine.log"),
               "--", "--separate-out=" + folder.as_posix()]
    write_json(folder / "invocation.json", command)
    print(f"Running source AfterDOF regression: {folder}", flush=True)
    result = run_owned_tree(command, root, folder / "stdout.log", args.timeout)
    lines = (folder / "stdout.log").read_text(encoding="utf-8", errors="replace").splitlines()
    clean = [re.sub(r"\x1b\[[0-9;]*m", "", line).strip() for line in lines]
    result["errors"] = [line for line in clean if re.match(r"^(?:SCRIPT )?ERROR:", line)]
    result["warnings"] = [line for line in clean if line.startswith("WARNING:")]
    result["expected_error"] = EXPECTED_ERROR
    result["expected_error_count"] = sum(line == "ERROR: " + EXPECTED_ERROR for line in result["errors"])
    result["unexpected_errors"] = [line for line in result["errors"] if line != "ERROR: " + EXPECTED_ERROR]
    result["error_boundary_passed"] = result["expected_error_count"] == 1 and not result["unexpected_errors"]
    write_json(folder / "run-result.json", result)

    analysis = run_owned_tree([sys.executable, str(analyzer), str(folder)], root,
                              folder / "analyzer.log", max(60.0, args.timeout))
    write_json(folder / "analyzer-result.json", analysis)
    passed = (result["exit"] == 0 and not result["timed_out"] and not result["interrupted"]
              and not result["runner_error"] and result["error_boundary_passed"]
              and analysis["exit"] == 0 and not analysis["timed_out"]
              and not analysis["interrupted"] and not analysis["runner_error"])
    print(json.dumps({"passed": passed, "output": str(folder), "engine": result,
                      "analyzer": analysis}, indent=2, ensure_ascii=False))
    return 0 if passed else (130 if result["interrupted"] else 1)


if __name__ == "__main__":
    raise SystemExit(main())
