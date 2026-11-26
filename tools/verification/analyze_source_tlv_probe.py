"""Validate real shadow-query controls, preserving failed captures as evidence."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def analyze(directory: Path, scene: bool = False) -> dict:
    result = {"scope": "Godot shadow producer controls, not original UE parity", "checks": [], "failures": []}

    def check(name: str, value: bool, **details):
        result["checks"].append({"name": name, "passed": bool(value), **details})
        if not value:
            result["failures"].append(name)

    metadata = json.loads((directory / ("scene-probe.json" if scene else "probe.json")).read_text())
    check("runtime completed", metadata.get("stage") == "complete" and not metadata.get("failures"), runtime_failures=metadata.get("failures"))
    runner = json.loads((directory / "runner.json").read_text())
    check("owned process completed", runner.get("exit") == 0 and not runner.get("timed_out") and not runner.get("runner_error"))
    log = (directory / "engine.log").read_text(encoding="utf-8", errors="replace")
    errors = [line for line in log.splitlines() if "ERROR:" in line or "WARNING:" in line]
    check("no engine errors or warnings", not errors, lines=errors)
    captures = {}
    for entry in metadata["captures"]:
        label = entry["label"]
        raw = np.fromfile(directory / (label + ".rgba16f"), dtype="<f2").astype(np.float32)
        check(label + " complete finite HDR", raw.size == 512 * 512 * 4 and np.isfinite(raw).all())
        if raw.size != 512 * 512 * 4:
            continue
        captures[label] = raw.reshape(512, 512, 4)
    check("expected capture set", len(captures) == (10 if scene else 5))
    if scene:
        for slug in ("wuming", "youxian"):
            for cascade in range(2):
                name = f"{slug}-cascade{cascade}"
                shadow = captures[name + "-shadow"]
                unshadowed = captures[name + "-unshadowed-control"]
                check(name + " real occlusion", (shadow[..., 0] < 0.01).any() and (shadow[..., 0] == 1).any(), shadowed_voxels=int(np.count_nonzero(shadow[..., 0] < .99)))
                check(name + " unshadowed control", np.all(unshadowed[..., 0] == 1))
                check(name + " LF independent of shadow", np.array_equal(shadow[..., 1], unshadowed[..., 1]))
                check(name + " source LF spatially varies", np.ptp(shadow[..., 1]) > 0.1, minimum=float(shadow[..., 1].min()), maximum=float(shadow[..., 1].max()))
                check(name + " sun present at every voxel", np.all(shadow[..., 2] == 1))
            before = captures[slug + "-cascade1-shadow"]
            after = captures[slug + "-cascade1-live"]
            delta = np.abs(before[..., 1] - after[..., 1])
            check(slug + " source LF evolves", np.count_nonzero(delta > .001) > 100, mean_abs_difference=float(delta.mean()))
    else:
        axis = (np.arange(64) + .5) * .125 - 4
        z, y, x = np.meshgrid(axis, axis, axis, indexing="ij")
        for label, image in captures.items():
            volume = image.reshape(64, 64, 64, 4)
            shift = 1.0 if label.startswith("deformed") else 0.0
            occluded = (np.abs(x - shift) < 2) & (np.abs(y) < 2) & (z < 0)
            if label.startswith(("masked", "deformed")):
                occluded &= x >= shift
            expected = np.ones((64, 64, 64), dtype=np.float32)
            expected[occluded] = 0
            present = 1
            if label == "shadow-disabled-control":
                expected[:] = 1
            if label == "light-absent-control":
                expected[:] = 0
                present = 0
            difference = np.abs(volume[..., 0] - expected)
            check(label + " analytic shadow equality", not np.any(difference), max_abs_difference=float(difference.max()), voxels=expected.size)
            check(label + " light presence", np.all(volume[..., 1] == present))
    result["passed"] = not result["failures"]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--scene", action="store_true")
    args = parser.parse_args()
    result = analyze(args.directory, args.scene)
    (args.directory / "cpu-validation.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({"passed": result["passed"], "checks": len(result["checks"]), "failures": result["failures"]}))
    raise SystemExit(0 if result["passed"] else 1)
