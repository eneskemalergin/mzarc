#!/usr/bin/env python3
"""Recompute fidelity metrics for an existing benchmark report.json.

This script reads an already-generated report.json, re-runs compare_dumps on
the existing roundtrip dump files, and rewrites both report.json and report.md
with updated fidelity data (e.g. after the FidelityResult schema gains new
fields like mz_ppm).

Usage:
    uv run python tools/refresh_fidelity.py

The script locates the report.json and all roundtrip files using the paths
already recorded in the report.  No timing benchmarks are re-run.
"""

from __future__ import annotations

import json
import sys
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from benchmark_core import compare_dumps, read_dump
from benchmark_metrics import build_fidelity_metric_rows
from benchmark_report import FUTURE_BASELINES, render_markdown


def main() -> None:
    report_path = REPO_ROOT / "benchmark" / "report.json"
    if not report_path.exists():
        raise FileNotFoundError(report_path)

    report: dict = json.loads(report_path.read_text(encoding="utf-8"))

    private_workdir = REPO_ROOT / report["paths"]["private_workdir"]
    sample_name = report["sample_name"]
    selected_quant = int(report["selected_lossy_intensity_quant"])

    dump_path = REPO_ROOT / report["dataset"]["path"]
    print(f"Loading reference dump: {dump_path.relative_to(REPO_ROOT)}", flush=True)
    reference = read_dump(dump_path)

    roundtrip_map: dict[str, Path] = {
        "gzip dump": private_workdir / f"{sample_name}.gzip.roundtrip.bin",
        "zstd dump": private_workdir / f"{sample_name}.zstd.roundtrip.bin",
        "mzv1 lossless": private_workdir / f"{sample_name}.lossless.roundtrip.bin",
        f"mzv1 lossy q={selected_quant}": private_workdir / f"{sample_name}.lossy.q{selected_quant}.roundtrip.bin",
    }

    # Also pick up any external baseline roundtrip files recorded in fidelity_rows.
    for row in report.get("fidelity_rows", []):
        artifact = str(row["artifact"])
        if artifact not in roundtrip_map:
            # Try to find the roundtrip file by looking for a .roundtrip.bin file
            # whose name contains a known keyword from the artifact name.
            keyword = artifact.lower().replace(" ", "_").replace("-", "").replace("/", "_")
            candidates = list(private_workdir.glob(f"*{keyword}*.roundtrip.bin"))
            if len(candidates) == 1:
                roundtrip_map[artifact] = candidates[0]
            else:
                # Try a broader pattern for known external baselines
                for ext_candidate in private_workdir.glob("*.roundtrip.bin"):
                    name_lower = ext_candidate.stem.lower()
                    if keyword in name_lower or any(part in name_lower for part in keyword.split("_")):
                        if artifact not in roundtrip_map:
                            roundtrip_map[artifact] = ext_candidate

    # Additionally, discover MScompress roundtrip files from report
    for ext in report.get("external_baselines", []):
        artifact = str(ext["name"])
        if artifact in roundtrip_map:
            continue
        # MScompress roundtrip bin might be recorded in the external record
        decode_op = ext.get("decode_operation")
        if decode_op and "->" in decode_op:
            dest = decode_op.split("->")[-1].strip()
            # The destination is an artifact name, not a path.  Skip; handled above.

    new_fidelity_rows: list[dict] = []
    new_direct_fidelity: dict[str, dict] = {}

    for artifact, roundtrip_path in roundtrip_map.items():
        if not roundtrip_path.exists():
            print(f"  SKIP  {artifact}: roundtrip file not found at {roundtrip_path.name}", flush=True)
            continue

        print(f"  compute  {artifact}...", end="", flush=True)
        candidate = read_dump(roundtrip_path)
        result = asdict(compare_dumps(artifact, reference, candidate))
        new_fidelity_rows.append({"artifact": artifact, "data": result})

        # Map to the internal key used in report["fidelity"]
        internal_key = artifact.replace(" ", "_").replace("-", "_").replace("=", "").replace("/", "")
        new_direct_fidelity[internal_key] = result
        print(f" max_ppm_mz={result['mz_ppm']['max']:.4g}", flush=True)

    # Also refresh external baseline fidelity rows from the existing fidelity_rows
    # that do NOT have a corresponding roundtrip file.
    existing_by_artifact = {row["artifact"]: row["data"] for row in report.get("fidelity_rows", [])}
    for row in report.get("fidelity_rows", []):
        artifact = str(row["artifact"])
        if artifact not in roundtrip_map:
            print(f"  retain  {artifact} (no roundtrip file found, keeping existing data)", flush=True)
            new_fidelity_rows.append(row)

    # Build fidelity_metrics using the updated rows
    external_baselines = report.get("external_baselines", [])
    new_fidelity_metrics = build_fidelity_metric_rows(
        new_fidelity_rows,
        selected_quant=selected_quant,
        external_baselines=external_baselines,
    )

    # Patch report in-place
    report["fidelity_rows"] = new_fidelity_rows
    report["fidelity_metrics"] = new_fidelity_metrics
    report["fidelity"].update(new_direct_fidelity)

    # Also update plot_rows fidelity
    if "plot_rows" in report:
        report["plot_rows"]["fidelity"] = new_fidelity_metrics

    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nWrote {report_path.relative_to(REPO_ROOT)}", flush=True)

    md_path = REPO_ROOT / "benchmark" / "report.md"
    md_path.write_text(render_markdown(report), encoding="utf-8")
    print(f"Wrote {md_path.relative_to(REPO_ROOT)}", flush=True)


if __name__ == "__main__":
    main()
