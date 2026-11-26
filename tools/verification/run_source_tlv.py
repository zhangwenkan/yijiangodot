"""Bounded serial runner for TLV diagnostics. Never selects unrelated processes."""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from run_source_separate_translucency import run_owned_tree, checkout_root

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["probe", "scene", "compute", "receiver"])
    parser.add_argument("output", type=Path)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--local-probe", action="store_true")
    parser.add_argument("--force-shadow-refresh", action="store_true")
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    if args.kind == "compute" and args.inputs is None:
        parser.error("compute requires --inputs with a manifest.json")
    root = checkout_root()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = list((root / "project/source_tlv_candidate").glob("*"))
    sources += list((root / "project/scripts/verification").glob("verify_source_tlv_*.gd"))
    sources += [Path(__file__), Path(__file__).with_name("run_source_separate_translucency.py")]
    hashes = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sources if p.is_file()}
    (output / "input-sha256.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
    command = [str(root / "tools/godot/Godot_v4.7.2-stable_win64_console.exe"), "--path", str(root / "project"),
               "--resolution", "960x540", "--script", f"res://scripts/verification/verify_source_tlv_{args.kind}.gd",
               "--", "--tlv-out=" + output.as_posix(), "--hide-ui"]
    if args.inputs:
        command.append("--tlv-input=" + args.inputs.resolve().as_posix())
    if args.local_probe:
        command.append("--local-probe")
    if args.force_shadow_refresh:
        command.append("--force-shadow-refresh")
    result = run_owned_tree(command, root, output / "engine.log", args.timeout)
    log = (output / "engine.log").read_text(encoding="utf-8", errors="replace")
    result["engine_errors"] = [line for line in log.splitlines() if "ERROR:" in line or "WARNING:" in line]
    name = {"probe": "probe.json", "scene": "scene-probe.json", "compute": "compute.json", "receiver": "receiver.json"}[args.kind]
    result["report_present"] = (output / name).exists()
    if result["report_present"]:
        metadata = json.loads((output / name).read_text(encoding="utf-8"))
        result["runtime_failures"] = metadata.get("failures", ["missing failure list"])
        if args.kind != "compute" and metadata.get("stage") != "complete":
            result["runtime_failures"].append("Missing completed runtime stage")
        if args.kind == "compute" and not metadata.get("cases"):
            result["runtime_failures"].append("No compute cases completed")
    else:
        result["runtime_failures"] = ["Missing final report"]
    result["engine_passed"] = (result["exit"] == 0 and not result["timed_out"] and not result["runner_error"]
                               and not result["engine_errors"] and not result["runtime_failures"])
    analyzer = None
    scripts = root / "tools/verification"
    if args.kind == "receiver":
        analyzer = ["analyze_source_tlv_receiver.py", "--run", str(output), "--out", str(output / "cpu-comparison")]
    elif args.kind == "compute":
        analyzer = ["analyze_source_tlv_volumes.py", "--manifest", str(args.inputs / "manifest.json"),
                    "--gpu", str(output), "--out", str(output / "cpu-comparison")]
    elif not args.local_probe:
        analyzer = ["analyze_source_tlv_probe.py", str(output)] + (["--scene"] if args.kind == "scene" else [])
    result["cpu_passed"] = None
    if analyzer and result["report_present"] and result["exit"] in (0, 1) and not result["engine_errors"]:
        try:
            with (output / "cpu-analysis.log").open("w", encoding="utf-8") as log_file:
                cpu = subprocess.run([sys.executable, "-B", "-X", "utf8", str(scripts / analyzer[0]), *analyzer[1:]],
                                     cwd=root, stdout=log_file, stderr=subprocess.STDOUT, timeout=240)
            result["cpu_passed"] = cpu.returncode == 0
        except (OSError, subprocess.TimeoutExpired) as exc:
            result["cpu_passed"] = False
            result["cpu_error"] = str(exc)
    result["cpu_scope"] = "No local-probe CPU oracle is installed" if args.local_probe else "Independent numerical/image audit"
    result["passed"] = result["engine_passed"] and (result["cpu_passed"] is True if analyzer else True)
    (output / "runner.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)
