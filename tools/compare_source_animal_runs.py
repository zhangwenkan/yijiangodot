"""Compare deterministic behavior evidence, excluding wall-clock sprite phase.

Usage: python compare_seeded_runs.py FIRST_JSON SECOND_JSON OUTPUT_JSON
This compares all requests, initial/final actor state, RNG and movement counters;
it does not call two visually different frame sequences equal.
"""
import argparse
import hashlib
import json
from pathlib import Path


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def digest(value):
    canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def first_difference(a, b, where=""):
    if type(a) is not type(b):
        return {"path": where, "first": a, "second": b}
    if isinstance(a, dict):
        if set(a) != set(b):
            return {"path": where, "first_keys": sorted(a), "second_keys": sorted(b)}
        for key in sorted(a):
            result = first_difference(a[key], b[key], f"{where}.{key}")
            if result is not None:
                return result
    elif isinstance(a, list):
        if len(a) != len(b):
            return {"path": where, "first_length": len(a), "second_length": len(b)}
        for index, (left, right) in enumerate(zip(a, b)):
            result = first_difference(left, right, f"{where}[{index}]")
            if result is not None:
                return result
    elif a != b:
        return {"path": where, "first": a, "second": b}
    return None


def comparable(data):
    movement_keys = ["active", "moves", "path_failures", "surface_failures", "local_support_actors",
                     "local_support_updates", "local_support_rejected", "local_support_max_nav_delta",
                     "partial_requests", "partial_end", "partial_zero_displacement_requests", "complete_end",
                     "partial_request_samples", "partial_end_samples", "path_failure_samples"]
    rejection_samples = [{k: v for k, v in row.items() if k != "physics_frame"}
                         for row in data["behavior_report"]["local_support_rejections"]]
    return {
        "setup": {k: data[k] for k in ["map", "fixed_step", "ticks", "seed_at_setup", "seed_source",
                                       "rng_state_after_initialization", "rng_final_state", "active", "expected_active",
                                       "approached", "departed", "seen_after_depart"]},
        "initial_actors": data["initial_actors"],
        "final_actors": data["final_actors"],
        "request_trace": data["request_trace"],
        "movement": {k: data["behavior_report"][k] for k in movement_keys},
        "support_rejection_samples_except_absolute_frame": rejection_samples,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    left, right = load(args.first), load(args.second)
    a, b = comparable(left), comparable(right)
    difference = first_difference(a, b)
    report = {
        "first": str(args.first), "second": str(args.second),
        "first_file_sha256": hashlib.sha256(args.first.read_bytes()).hexdigest(),
        "second_file_sha256": hashlib.sha256(args.second.read_bytes()).hexdigest(),
        "all_behavior_evidence_exactly_equal": difference is None,
        "request_count_first": len(a["request_trace"]), "request_count_second": len(b["request_trace"]),
        "canonical_behavior_sha256_first": digest(a), "canonical_behavior_sha256_second": digest(b),
        "first_difference": difference,
        "runtime_errors_first": left.get("errors", []), "runtime_errors_second": right.get("errors", []),
        "support_rejections_first": left["behavior_report"]["local_support_rejected"],
        "support_rejections_second": right["behavior_report"]["local_support_rejected"],
        "support_rejections_resolved": False,
        "comparison_purpose": "Repeatability of source-request adapter and unchanged rejection behavior; equality is not full locomotion acceptance.",
        "excluded": ["AnimatedSprite3D rendered frame timing", "screenshots and full-world lighting", "absolute engine physics frame numbers", "wall-clock time"],
        "limits": "Fixed-step original-collision behavior regression with an observer subclass. It does not establish original UE RNG, capsule locomotion, full-scene performance, or visual parity.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ["all_behavior_evidence_exactly_equal", "request_count_first", "request_count_second", "support_rejections_first", "support_rejections_second", "first_difference", "runtime_errors_first", "runtime_errors_second"]}, ensure_ascii=False))
    raise SystemExit(0 if difference is None and not left.get("errors") and not right.get("errors") else 1)


if __name__ == "__main__":
    main()
