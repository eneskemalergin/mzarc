#!/usr/bin/env python3
"""Generate benchmark report from manifest.json + zebrac JSON files.

This is the Python entry point for report generation.  All timing measurements
are provided by zebrac (via benchmark.sh); this script handles statistics,
plotting, and markdown rendering.

Usage:
    python3 tools/collect_report.py <manifest.json> [OPTIONS]

Options:
    --fidelity FILE      fidelity.json from validate.sh (default: auto-detect)
    --output-dir DIR     directory for report output (default: benchmark)
    --search-impact FILE optional search-impact JSON
    --no-plots           skip plot generation
    --no-stats           skip statistical tests (faster)
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from benchmark_core import (  # noqa: E402
    collect_file_stats,
    read_dump,
    repo_relative_path,
)
from benchmark_metrics import (  # noqa: E402
    build_fidelity_metric_rows,
    build_memory_rows,
    build_performance_rows,
    build_search_impact_rows,
    load_search_impact,
)
from benchmark_plotting import generate_plots  # noqa: E402
from benchmark_report import FUTURE_BASELINES, render_markdown  # noqa: E402
from benchmark_stats import compute_stats, run_all_comparisons  # noqa: E402


# --------------------------------------------------------------------------- #
# zebrac JSON loading                                                          #
# --------------------------------------------------------------------------- #

def _load_zebrac_json(path: str | Path) -> dict:
    """Load a single zebrac result JSON and return the first result entry."""
    full = REPO_ROOT / path
    if not full.exists():
        raise FileNotFoundError(full)
    return json.loads(full.read_text(encoding="utf-8"))["results"][0]


def _zebrac_to_serialized(op: dict, zdata: dict) -> dict:
    """Convert raw zebrac JSON + operation metadata to a serialised result dict.

    The structure mirrors what serialize_zebrac_result() produces from a
    ZebracResult dataclass, so downstream code (metrics, plotting) works
    with either source.
    """
    wt = zdata["wall_time"]
    rss = zdata["peak_rss"]
    n = int(zdata["sample_count"])

    wall_median_s  = wt["median"]   / 1e9
    wall_mean_s    = wt["mean"]     / 1e9
    wall_stddev_s  = wt["std_dev"]  / 1e9
    wall_min_s     = wt["min"]      / 1e9
    wall_max_s     = wt["max"]      / 1e9
    rss_median_mib = rss["median"]  / (1024 * 1024)

    inp = int(op.get("input_bytes") or 0)
    out = int(op.get("output_bytes") or 0)

    throughput_input  = (inp / (1024 * 1024)) / wall_median_s if (inp and wall_median_s > 0) else None
    throughput_output = (out / (1024 * 1024)) / wall_median_s if (out and wall_median_s > 0) else None

    if out:
        throughput_mib_s = throughput_output
        throughput_basis = "output"
    elif inp:
        throughput_mib_s = throughput_input
        throughput_basis = "input"
    else:
        throughput_mib_s = None
        throughput_basis = None

    return {
        "name": op["name"],
        "sample_count": n,
        "wall_time_median_seconds": wall_median_s,
        "wall_time_mean_seconds":   wall_mean_s,
        "wall_time_stddev_seconds": wall_stddev_s,
        "wall_time_min_seconds":    wall_min_s,
        "wall_time_max_seconds":    wall_max_s,
        "peak_rss_median_mib":      rss_median_mib,
        "peak_rss_bytes":           dict(rss),
        "instructions":             dict(zdata["instructions"]),
        "cache_misses":             dict(zdata["cache_misses"]),
        "cpu_cycles":               dict(zdata["cpu_cycles"])        if "cpu_cycles"        in zdata else None,
        "cache_references":         dict(zdata["cache_references"])  if "cache_references"  in zdata else None,
        "branch_misses":            dict(zdata["branch_misses"])     if "branch_misses"     in zdata else None,
        "input_bytes":              inp or None,
        "output_bytes":             out or None,
        "throughput_mib_s":         throughput_mib_s,
        "throughput_input_mib_s":   throughput_input,
        "throughput_output_mib_s":  throughput_output,
        "throughput_basis":         throughput_basis,
        # keep raw wall_time for IQR extraction in compute_stats
        "wall_time":                dict(wt),
    }


# --------------------------------------------------------------------------- #
# mzarc inspect                                                                #
# --------------------------------------------------------------------------- #

def _inspect_artifact(zig_bin: Path, artifact_path: Path) -> dict:
    cmd = [repo_relative_path(zig_bin), "inspect", repo_relative_path(artifact_path), "--json"]
    try:
        result = subprocess.run(
            cmd, check=True, cwd=REPO_ROOT,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return json.loads(result.stdout.strip())
    except Exception as exc:
        print(f"WARNING: mzarc inspect failed for {artifact_path.name}: {exc}", file=sys.stderr)
        return {"byte_breakdown": {}}


# --------------------------------------------------------------------------- #
# argument parsing                                                             #
# --------------------------------------------------------------------------- #

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate mzarc benchmark report.")
    p.add_argument("manifest", type=Path, help="manifest.json from benchmark.sh")
    p.add_argument("--fidelity",      type=Path, default=None,
                   help="fidelity.json from validate.sh")
    p.add_argument("--output-dir",    type=Path, default=None,
                   help="Directory for report output (default: benchmark)")
    p.add_argument("--search-impact", type=Path, default=None)
    p.add_argument("--no-plots",  action="store_true")
    p.add_argument("--no-stats",  action="store_true",
                   help="Skip statistical tests (bootstrap CI, Mann-Whitney)")
    return p.parse_args()


# --------------------------------------------------------------------------- #
# main                                                                         #
# --------------------------------------------------------------------------- #

def main() -> None:
    args = _parse_args()
    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    raw_dir    = REPO_ROOT / manifest["raw_dir"]
    output_dir = (args.output_dir or REPO_ROOT / "benchmark").resolve()
    plot_dir   = output_dir / "plots"
    sample     = manifest["sample"]
    selected_quant = manifest["selected_lossy_quant"]

    # fidelity data
    fidelity_path = args.fidelity or (raw_dir / "fidelity.json")
    if fidelity_path.exists():
        fidelity_data: dict = json.loads(fidelity_path.read_text(encoding="utf-8"))
    else:
        print(f"WARNING: fidelity.json not found at {fidelity_path}", file=sys.stderr)
        print("Run tools/validate.sh first for fidelity metrics.", file=sys.stderr)
        fidelity_data = {"by_artifact": {}, "lossy_sweep": {}}

    # ------------------------------------------------------------------ #
    # load zebrac results                                                 #
    # ------------------------------------------------------------------ #
    serialized_zebrac: list[dict] = []
    for op in manifest["operations"]:
        try:
            zdata = _load_zebrac_json(op["zebrac_json"])
            serialized_zebrac.append(_zebrac_to_serialized(op, zdata))
        except FileNotFoundError:
            print(f"WARNING: zebrac JSON missing for {op['name']}", file=sys.stderr)

    # ------------------------------------------------------------------ #
    # enrich with statistics                                              #
    # ------------------------------------------------------------------ #
    if not args.no_stats:
        serialized_zebrac = [compute_stats(r) for r in serialized_zebrac]
        stat_comparisons  = run_all_comparisons(serialized_zebrac)
    else:
        stat_comparisons = []

    # ------------------------------------------------------------------ #
    # dataset info                                                        #
    # ------------------------------------------------------------------ #
    dump_path = REPO_ROOT / manifest["dump_path"]
    reference_dump = read_dump(dump_path)
    dataset = asdict(collect_file_stats(dump_path, reference_dump))
    dataset["path"] = manifest["dump_path"]

    # ------------------------------------------------------------------ #
    # external_baselines: derived from manifest group="external" ops     #
    # ------------------------------------------------------------------ #
    _ext_ops: dict[str, dict] = {}
    for op in manifest["operations"]:
        if op.get("group") == "external":
            artifact = str(op["artifact"])
            if artifact not in _ext_ops:
                _ext_ops[artifact] = {
                    "name": artifact,
                    "status": "measured",
                    "reason": None,
                    "encode_operation": None,
                    "decode_operation": None,
                }
            if op["direction"] == "encode":
                _ext_ops[artifact]["encode_operation"] = op["name"]
            elif op["direction"] == "decode":
                _ext_ops[artifact]["decode_operation"] = op["name"]
    external_baselines: list[dict] = list(_ext_ops.values())

    # ------------------------------------------------------------------ #
    # fidelity rows                                                       #
    # ------------------------------------------------------------------ #
    fidelity_rows: list[dict] = [
        {"artifact": artifact, "data": fdata}
        for artifact, fdata in fidelity_data["by_artifact"].items()
    ]
    fidelity_metric_rows = build_fidelity_metric_rows(
        fidelity_rows,
        selected_quant=selected_quant,
        external_baselines=external_baselines,
    )

    # ------------------------------------------------------------------ #
    # lossy sweep rows                                                    #
    # ------------------------------------------------------------------ #
    lossy_sweep_rows: list[dict] = []
    for row in manifest.get("lossy_sweep_rows", []):
        ql = int(row["intensity_quant"])
        sweep_fid = fidelity_data["lossy_sweep"].get(str(ql), {})
        p95 = 0.0
        if sweep_fid:
            try:
                p95 = float(sweep_fid["intensity_rel"]["p95"]) * 100.0
            except (KeyError, TypeError):
                pass
        lossy_sweep_rows.append({**row, "fidelity": sweep_fid, "p95_rel_intensity_error_pct": p95})

    # ------------------------------------------------------------------ #
    # performance / memory rows                                           #
    # ------------------------------------------------------------------ #
    performance_rows = build_performance_rows(
        serialized_zebrac,
        selected_quant=selected_quant,
        external_baselines=external_baselines,
    )
    memory_metric_rows = build_memory_rows(serialized_zebrac)
    search_impact_data = load_search_impact(
        args.search_impact.resolve() if args.search_impact else None
    )
    search_impact_rows = build_search_impact_rows(
        selected_quant=selected_quant,
        external_baselines=external_baselines,
        search_impact_data=search_impact_data,
        fidelity_metric_rows=fidelity_metric_rows,
    )

    # ------------------------------------------------------------------ #
    # mzarc byte-breakdown inspection                                    #
    # ------------------------------------------------------------------ #
    zig_bin = REPO_ROOT / "zig-out" / "bin" / "mzarc"
    lossless_layout = _inspect_artifact(zig_bin, REPO_ROOT / manifest["sizes"]["mzarc lossless"]["path"])
    lossy_key       = f"mzarc lossy q={selected_quant}"
    lossy_layout    = _inspect_artifact(zig_bin, REPO_ROOT / manifest["sizes"][lossy_key]["path"])

    # ------------------------------------------------------------------ #
    # convenience fidelity keys                                          #
    # ------------------------------------------------------------------ #
    lossless_fidelity = fidelity_data["by_artifact"].get("mzarc lossless", {})
    lossy_fidelity    = fidelity_data["by_artifact"].get(lossy_key, {})

    def _quantile_rows(artifact: str, fid: dict) -> list[dict]:
        try:
            return [
                {"artifact": artifact, "quantile_label": lbl, "value_pct": v * 100.0}
                for lbl, v in fid["intensity_rel"]["quantiles"].items()
            ]
        except (KeyError, TypeError):
            return []

    # ------------------------------------------------------------------ #
    # plot rows                                                           #
    # ------------------------------------------------------------------ #
    plot_rows: dict = {
        "sizes": [
            {"artifact": name, "size_mib": item["bytes"] / (1024 * 1024)}
            for name, item in manifest["sizes"].items()
        ],
        "performance": performance_rows,
        "fidelity": fidelity_metric_rows,
        "memory_metrics": memory_metric_rows,
        "lossy_sweep": [
            {
                "intensity_quant": r["intensity_quant"],
                "size_mib": r["size_mib"],
                "p95_rel_intensity_error_pct": r["p95_rel_intensity_error_pct"],
            }
            for r in lossy_sweep_rows
        ],
        "intensity_quantiles": (
            _quantile_rows("lossless", lossless_fidelity)
            + _quantile_rows("selected lossy", lossy_fidelity)
        ),
        "stat_comparisons": stat_comparisons,
    }

    # ------------------------------------------------------------------ #
    # assemble report                                                     #
    # ------------------------------------------------------------------ #
    report: dict = {
        "sample_name": sample,
        "run_mode": "full",
        "selected_lossy_intensity_quant": selected_quant,
        "paths": {
            "mzml":         manifest["mzml_path"],
            "private_workdir": manifest["workdir"],
            "public_dir":   repo_relative_path(output_dir),
        },
        "dataset": dataset,
        "sizes":   manifest["sizes"],
        "codec_byte_breakdown": {
            "mzarc lossless":  lossless_layout["byte_breakdown"],
            lossy_key:         lossy_layout["byte_breakdown"],
        },
        "zebrac_results":     serialized_zebrac,
        "stat_comparisons":   stat_comparisons,
        "fidelity": {
            "mzarc_lossless": lossless_fidelity,
            "mzarc_lossy":    lossy_fidelity,
        },
        "fidelity_rows":      fidelity_rows,
        "fidelity_metrics":   fidelity_metric_rows,
        "performance_rows":   performance_rows,
        "memory_metric_rows": memory_metric_rows,
        "search_impact_rows": search_impact_rows,
        "lossy_sweep":        lossy_sweep_rows,
        "plot_rows":          plot_rows,
        "external_baselines": external_baselines,
        "comparison_candidates": FUTURE_BASELINES,
    }

    if not args.no_plots:
        report["plots"] = generate_plots(report, plot_dir)
    else:
        report["plots"] = {}

    (output_dir / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    (output_dir / "report.md").write_text(render_markdown(report), encoding="utf-8")

    summary = {
        "public_dir":   repo_relative_path(output_dir),
        "plots":        report["plots"],
        "sizes_mib":    {n: round(v["bytes"] / (1024 * 1024), 2) for n, v in manifest["sizes"].items()},
        "stat_comparisons": len(stat_comparisons),
        "zebrac_results":   len(serialized_zebrac),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
