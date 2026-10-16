#!/usr/bin/env python3
"""Compare real, repeated measurements from identical device/scenario configurations."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path

REQUIRED_CONTEXT = {
    "device", "os", "configuration", "scenario", "monitoring", "input_size", "toolchain"
}


def validate(record):
    if not isinstance(record, dict):
        raise ValueError("Measurement must be an object")
    context = record.get("context", {})
    if not isinstance(context, dict) or not REQUIRED_CONTEXT.issubset(context):
        raise ValueError("Missing device/scenario context")
    if any(not isinstance(context[key], str) or not context[key].strip()
           for key in REQUIRED_CONTEXT):
        raise ValueError("Context fields must be nonempty strings")
    if context["configuration"] != "Release":
        raise ValueError("Use Release measurements for regression decisions")
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", record.get("commit", "")):
        raise ValueError("A measured commit SHA is required")
    for key in ("metric", "unit", "raw_artifact"):
        if not isinstance(record.get(key), str) or not record[key].strip():
            raise ValueError(f"Missing {key}")
    samples = record.get("samples")
    if not isinstance(samples, list) or len(samples) < 5:
        raise ValueError("At least five repeated measurements are required")
    if any(isinstance(value, bool) or not isinstance(value, (int, float))
           or not math.isfinite(value) or value < 0 for value in samples):
        raise ValueError("Samples must be finite nonnegative numbers")
    return record


def compare(baseline, candidate, relative_budget=0.10, absolute_budget=0.0):
    validate(baseline)
    validate(candidate)
    for value in (relative_budget, absolute_budget):
        if not math.isfinite(value) or value < 0:
            raise ValueError("Budgets must be finite and nonnegative")
    if baseline["context"] != candidate["context"]:
        raise ValueError("Context mismatch: compare identical device, OS, build and scenario settings")
    if (baseline["metric"], baseline["unit"]) != (candidate["metric"], candidate["unit"]):
        raise ValueError("Metric or unit mismatch")
    before = statistics.median(baseline["samples"])
    after = statistics.median(candidate["samples"])
    allowed = max(before * relative_budget, absolute_budget)
    return {
        "metric": baseline["metric"],
        "unit": baseline["unit"],
        "baseline_median": before,
        "candidate_median": after,
        "delta": after - before,
        "relative_change": (after - before) / before if before else None,
        "allowed_increase": allowed,
        "regression": after - before > allowed,
        "baseline_commit": baseline["commit"],
        "candidate_commit": candidate["commit"],
        "note": "Lower is better. This threshold is a screening rule, not statistical significance."
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--relative-budget", type=float, default=0.10)
    parser.add_argument("--absolute-budget", type=float, default=0.0)
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.baseline.read_text(encoding="utf-8")),
                         json.loads(args.candidate.read_text(encoding="utf-8")),
                         args.relative_budget, args.absolute_budget)
    except (ValueError, OSError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
    return 1 if result["regression"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
