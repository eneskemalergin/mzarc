#!/usr/bin/env python3
"""Compute round-trip fidelity metrics from manifest.json roundtrip files.

Called by validate.sh after benchmark.sh has produced all encoded/decoded files.

Usage:
    python3 tools/fidelity_check.py <manifest.json> [--output fidelity.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from benchmark_core import compare_dumps, read_dump  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Check round-trip fidelity from manifest.json.")
    p.add_argument("manifest", type=Path, help="manifest.json produced by benchmark.sh")
    p.add_argument("--output", type=Path, default=None, help="Output fidelity.json path")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))

    dump_path = REPO_ROOT / manifest["dump_path"]
    sample = manifest["sample"]
    workdir = REPO_ROOT / manifest["workdir"]
    selected_quant = manifest["selected_lossy_quant"]
    raw_dir = REPO_ROOT / manifest["raw_dir"]

    print(f"Loading reference dump: {dump_path.relative_to(REPO_ROOT)}", file=sys.stderr, flush=True)
    reference = read_dump(dump_path)

    by_artifact: dict[str, object] = {}

    for op in manifest["operations"]:
        rt = op.get("roundtrip_path")
        if rt is None:
            continue
        rt_path = REPO_ROOT / rt
        if not rt_path.exists():
            print(f"WARNING: roundtrip file missing: {rt}", file=sys.stderr)
            continue
        artifact = op["artifact"]
        # Only check the first (encode) operation per artifact to avoid double-checking
        if artifact in by_artifact:
            continue
        print(f"  fidelity: {artifact}", file=sys.stderr, flush=True)
        candidate = read_dump(rt_path)
        by_artifact[artifact] = asdict(compare_dumps(op["name"], reference, candidate))

    # Lossy sweep
    lossy_sweep: dict[str, object] = {}
    for row in manifest.get("lossy_sweep_rows", []):
        ql = int(row["intensity_quant"])
        rt_path = workdir / f"{sample}.lossy.q{ql}.roundtrip.bin"
        if not rt_path.exists():
            print(f"WARNING: lossy sweep roundtrip missing: q={ql}", file=sys.stderr)
            continue
        print(f"  fidelity: lossy q={ql}", file=sys.stderr, flush=True)
        candidate = read_dump(rt_path)
        lossy_sweep[str(ql)] = asdict(compare_dumps(f"mzarc_lossy_q{ql}", reference, candidate))

    output = {"by_artifact": by_artifact, "lossy_sweep": lossy_sweep}
    out_path = args.output or (raw_dir / "fidelity.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"Wrote {out_path.relative_to(REPO_ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
