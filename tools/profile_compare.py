#!/usr/bin/env python3
"""Compare two profiling run directories produced by tools/profile.sh.

Usage:
    python3 tools/profile_compare.py <before_dir> <after_dir> [OPTIONS]

Options:
    --metric METRIC   wall_time | peak_rss | instructions | cache_misses
                      (default: wall_time)
    --unit UNIT       auto | ms | s | mib  (default: auto)

Each directory must contain zebrac JSON files named <operation>.json.
Operations found in both directories are compared.  Operations only present
in one directory are listed separately.

Output columns:
    operation | before (median) | after (median) | delta | IQR before | IQR after
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# zebrac JSON helpers
# ---------------------------------------------------------------------------

def _load_result(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    results = data.get("results", [])
    if not results:
        raise ValueError(f"no results in {path}")
    return results[0]


def _metric_stats(result: dict, metric: str) -> dict:
    m = result.get(metric)
    if m is None:
        raise KeyError(f"metric '{metric}' not found in result")
    return m


def _auto_scale(value_ns: float, metric: str) -> tuple[float, str]:
    """Return (scaled_value, unit_label) with sensible human-readable units."""
    if metric == "wall_time":
        if value_ns >= 1e9:
            return value_ns / 1e9, "s"
        if value_ns >= 1e6:
            return value_ns / 1e6, "ms"
        return value_ns / 1e3, "us"
    if metric == "peak_rss":
        mib = value_ns / (1024 * 1024)
        return mib, "MiB"
    # instructions / cache_misses: raw counts
    if value_ns >= 1e9:
        return value_ns / 1e9, "G"
    if value_ns >= 1e6:
        return value_ns / 1e6, "M"
    if value_ns >= 1e3:
        return value_ns / 1e3, "K"
    return value_ns, ""


def _force_scale(value_ns: float, unit: str) -> tuple[float, str]:
    if unit == "ms":
        return value_ns / 1e6, "ms"
    if unit == "s":
        return value_ns / 1e9, "s"
    if unit == "mib":
        return value_ns / (1024 * 1024), "MiB"
    return value_ns, ""


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Compare two profile.sh output directories.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("before", type=Path, help="directory from the earlier run")
    p.add_argument("after",  type=Path, help="directory from the later run")
    p.add_argument(
        "--metric",
        default="wall_time",
        choices=["wall_time", "peak_rss", "instructions", "cache_misses"],
        help="zebrac metric to compare (default: wall_time)",
    )
    p.add_argument(
        "--unit",
        default="auto",
        choices=["auto", "ms", "s", "mib"],
        help="output unit (default: auto)",
    )
    return p.parse_args()


def _fmt(raw: float, metric: str, unit: str) -> str:
    if unit == "auto":
        v, u = _auto_scale(raw, metric)
    else:
        v, u = _force_scale(raw, metric)
    if u:
        return f"{v:.2f} {u}"
    return f"{v:.0f}"


def main() -> int:
    args = parse_args()

    before_dir: Path = args.before
    after_dir:  Path = args.after

    if not before_dir.is_dir():
        print(f"ERROR: not a directory: {before_dir}", file=sys.stderr)
        return 1
    if not after_dir.is_dir():
        print(f"ERROR: not a directory: {after_dir}", file=sys.stderr)
        return 1

    before_files = {p.stem: p for p in before_dir.glob("*.json")}
    after_files  = {p.stem: p for p in after_dir.glob("*.json")}

    shared    = sorted(before_files.keys() & after_files.keys())
    only_before = sorted(before_files.keys() - after_files.keys())
    only_after  = sorted(after_files.keys()  - before_files.keys())

    if not shared:
        print("No operations in common between the two directories.", file=sys.stderr)
        if only_before:
            print(f"  only in before: {', '.join(only_before)}", file=sys.stderr)
        if only_after:
            print(f"  only in after:  {', '.join(only_after)}", file=sys.stderr)
        return 1

    metric = args.metric
    unit   = args.unit

    # Column widths
    op_w = max(len(s) for s in shared) + 2

    header = (
        f"{'operation':<{op_w}}  {'before (med)':>14}  {'after (med)':>14}"
        f"  {'delta':>8}  {'IQR before':>12}  {'IQR after':>12}"
    )
    sep = "-" * len(header)
    print(header)
    print(sep)

    for op in shared:
        try:
            b_result = _load_result(before_files[op])
            a_result = _load_result(after_files[op])
        except (ValueError, KeyError) as exc:
            print(f"{op:<{op_w}}  ERROR: {exc}")
            continue

        try:
            b_stats = _metric_stats(b_result, metric)
            a_stats = _metric_stats(a_result, metric)
        except KeyError as exc:
            print(f"{op:<{op_w}}  SKIP: {exc}")
            continue

        b_median = b_stats["median"]
        a_median = a_stats["median"]
        b_iqr    = b_stats["q3"] - b_stats["q1"]
        a_iqr    = a_stats["q3"] - a_stats["q1"]

        delta_pct = ((a_median - b_median) / b_median * 100) if b_median else 0.0
        sign = "+" if delta_pct >= 0 else ""

        b_med_s = _fmt(b_median, metric, unit)
        a_med_s = _fmt(a_median, metric, unit)
        b_iqr_s = _fmt(b_iqr,    metric, unit)
        a_iqr_s = _fmt(a_iqr,    metric, unit)
        delta_s = f"{sign}{delta_pct:.1f}%"

        marker = "  <<" if abs(delta_pct) >= 5 else ""
        print(
            f"{op:<{op_w}}  {b_med_s:>14}  {a_med_s:>14}"
            f"  {delta_s:>8}  {b_iqr_s:>12}  {a_iqr_s:>12}{marker}"
        )

    if only_before:
        print()
        print(f"Only in before: {', '.join(only_before)}")
    if only_after:
        print()
        print(f"Only in after:  {', '.join(only_after)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
