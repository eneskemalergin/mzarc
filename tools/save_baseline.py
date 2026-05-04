#!/usr/bin/env python3
"""Snapshot the current benchmark report as a versioned baseline.

Reads the version from build.zig.zon and copies benchmark/report.json to
benchmark/baseline_v<VERSION>.json.  If the destination already exists the
script exits with an error rather than silently overwriting a frozen baseline.

Usage:
    python3 tools/save_baseline.py [--report FILE] [--version VERSION] [--force]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _detect_version() -> str:
    zon = REPO_ROOT / "build.zig.zon"
    if not zon.exists():
        return None
    text = zon.read_text(encoding="utf-8")
    m = re.search(r'\.version\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None


def main() -> int:
    p = argparse.ArgumentParser(description="Snapshot versioned benchmark baseline.")
    p.add_argument("--report",  type=Path, default=REPO_ROOT / "benchmark" / "report.json")
    p.add_argument("--version", default=None, help="Version string (auto-detected from build.zig.zon if omitted)")
    p.add_argument("--force",   action="store_true", help="Overwrite if destination already exists")
    args = p.parse_args()

    report_path = args.report.resolve()
    if not report_path.exists():
        print(f"ERROR: report not found at {report_path}", file=sys.stderr)
        print("Run benchmark.sh + collect_report.py first.", file=sys.stderr)
        return 1

    version = args.version or _detect_version()
    if not version:
        print("ERROR: could not detect version from build.zig.zon; pass --version explicitly", file=sys.stderr)
        return 1

    dest = report_path.parent / f"baseline_v{version}.json"
    if dest.exists() and not args.force:
        print(f"ERROR: {dest.name} already exists.  Use --force to overwrite.", file=sys.stderr)
        return 1

    # Validate the source is valid JSON before copying.
    json.loads(report_path.read_text(encoding="utf-8"))

    shutil.copy2(report_path, dest)
    print(f"Saved: {dest.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
