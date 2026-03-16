#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path

from benchmark_core import (
    DEFAULT_LOSSY_LEVEL,
    REPO_ROOT,
    collect_file_stats,
    compare_dumps,
    encode_lossy_command,
    parse_lossy_sweep,
    read_dump,
    require_tool,
    run_dump_mzml_quietly,
    run_timed_callable,
    run_timed_command,
    serialize_timing_result,
)
from benchmark_plotting import generate_plots
from benchmark_report import FUTURE_BASELINES, render_markdown


class ProgressBar:
    def __init__(self, total_steps: int, *, enabled: bool) -> None:
        self.total_steps = max(total_steps, 1)
        self.enabled = enabled
        self.current_step = 0
        self.last_message = ""

    def step(self, message: str) -> None:
        self.current_step = min(self.current_step + 1, self.total_steps)
        self.last_message = message
        if not self.enabled:
            return

        width = 32
        filled = int(width * self.current_step / self.total_steps)
        bar = "#" * filled + "." * (width - filled)
        percent = (self.current_step / self.total_steps) * 100.0
        sys.stderr.write(
            f"\r[{bar}] {self.current_step:>3}/{self.total_steps:<3} {percent:6.2f}%  {message:<50}"
        )
        sys.stderr.flush()

    def callback(self, label: str):
        def _callback(_: str, run_index: int, run_total: int) -> None:
            self.step(f"{label} [{run_index}/{run_total}]")

        return _callback

    def finish(self) -> None:
        if self.enabled:
            sys.stderr.write("\n")
            sys.stderr.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Benchmark the current mzarc prototype using the modular benchmark stack.")
    parser.add_argument("input", type=Path, help="Path to the mzML file to benchmark")
    parser.add_argument(
        "--zig-bin",
        type=Path,
        default=REPO_ROOT / "zig-out/bin/mzarc",
        help="Path to the built mzarc binary",
    )
    parser.add_argument("--repeats", type=int, default=10, help="Number of timing repeats per core operation")
    parser.add_argument(
        "--private-workdir",
        type=Path,
        default=None,
        help="Directory for generated dump, round-trip, and encoded intermediates",
    )
    parser.add_argument(
        "--public-dir",
        type=Path,
        default=REPO_ROOT / "benchmark",
        help="Directory for public report artifacts",
    )
    parser.add_argument(
        "--lossy-intensity-quant",
        type=int,
        default=DEFAULT_LOSSY_LEVEL,
        help="Selected lossy intensity quantization level",
    )
    parser.add_argument(
        "--lossy-sweep",
        type=str,
        default=None,
        help="Comma-separated lossy sweep levels, e.g. 256,1024,4096,16384",
    )
    parser.add_argument(
        "--no-progress",
        action="store_true",
        help="Disable the terminal progress bar",
    )
    return parser


def resolve_private_workdir(input_path: Path, override: Path | None) -> Path:
    if override is not None:
        return override
    return input_path.parent / "benchmarks" / input_path.stem


def repo_relative_path(path: Path) -> str:
    return Path(os.path.relpath(path, REPO_ROOT)).as_posix()


def main() -> None:
    args = build_parser().parse_args()

    input_path = args.input.resolve()
    zig_bin = args.zig_bin.resolve()
    if not input_path.exists():
        raise FileNotFoundError(input_path)
    if not zig_bin.exists():
        raise FileNotFoundError(zig_bin)
    if args.repeats <= 0:
        raise ValueError("--repeats must be positive")

    require_tool("gzip")
    require_tool("zstd")

    selected_quant = int(args.lossy_intensity_quant)
    lossy_sweep = parse_lossy_sweep(args.lossy_sweep, selected_quant)
    sample_name = input_path.stem
    private_workdir = resolve_private_workdir(input_path, args.private_workdir.resolve() if args.private_workdir else None)
    public_dir = args.public_dir.resolve()
    plot_dir = public_dir / "plots"

    private_workdir.mkdir(parents=True, exist_ok=True)
    plot_dir.mkdir(parents=True, exist_ok=True)

    paths = {
        "mzml": input_path,
        "dump": private_workdir / f"{sample_name}.bin",
        "gzip_dump": private_workdir / f"{sample_name}.bin.gz",
        "gzip_dump_roundtrip": private_workdir / f"{sample_name}.gzip.roundtrip.bin",
        "zstd_dump": private_workdir / f"{sample_name}.bin.zst",
        "zstd_dump_roundtrip": private_workdir / f"{sample_name}.zstd.roundtrip.bin",
        "mzv1_lossless": private_workdir / f"{sample_name}.lossless.mzv1",
        "roundtrip_lossless": private_workdir / f"{sample_name}.lossless.roundtrip.bin",
        "mzv1_lossy": private_workdir / f"{sample_name}.lossy.q{selected_quant}.mzv1",
        "roundtrip_lossy": private_workdir / f"{sample_name}.lossy.q{selected_quant}.roundtrip.bin",
    }

    extra_sweep_levels = [level for level in lossy_sweep if level != selected_quant]
    total_steps = (args.repeats * 9) + (2 * len(extra_sweep_levels)) + 4
    progress = ProgressBar(total_steps, enabled=not args.no_progress)

    try:
        mzml_bytes = input_path.stat().st_size

        timing_dump = run_timed_callable(
            "mzML -> dump",
            lambda: run_dump_mzml_quietly(input_path, paths["dump"]),
            repeats=args.repeats,
            input_bytes=mzml_bytes,
            progress_callback=progress.callback("mzML -> dump"),
        )

        reference_dump = read_dump(paths["dump"])
        dataset = asdict(collect_file_stats(paths["dump"], reference_dump))
        dataset["path"] = repo_relative_path(paths["dump"])
        dump_bytes = paths["dump"].stat().st_size

        zig_bin_rel = repo_relative_path(zig_bin)
        dump_rel = repo_relative_path(paths["dump"])
        lossless_path_rel = repo_relative_path(paths["mzv1_lossless"])
        lossless_roundtrip_rel = repo_relative_path(paths["roundtrip_lossless"])
        lossy_path_rel = repo_relative_path(paths["mzv1_lossy"])
        lossy_roundtrip_rel = repo_relative_path(paths["roundtrip_lossy"])
        gzip_dump_rel = repo_relative_path(paths["gzip_dump"])
        gzip_dump_roundtrip_rel = repo_relative_path(paths["gzip_dump_roundtrip"])
        zstd_dump_rel = repo_relative_path(paths["zstd_dump"])
        zstd_dump_roundtrip_rel = repo_relative_path(paths["zstd_dump_roundtrip"])

        lossless_encode_cmd = [zig_bin_rel, "encode-v1", dump_rel, "-o", lossless_path_rel]
        lossless_decode_cmd = [zig_bin_rel, "decode-v1", lossless_path_rel, "-o", lossless_roundtrip_rel]
        lossy_encode_cmd = encode_lossy_command(zig_bin, paths["dump"], paths["mzv1_lossy"], selected_quant)
        lossy_encode_cmd = [zig_bin_rel, "encode-v1", dump_rel, "-o", lossy_path_rel, "--lossy", "--intensity-quant", str(selected_quant)]
        lossy_decode_cmd = [zig_bin_rel, "decode-v1", lossy_path_rel, "-o", lossy_roundtrip_rel]

        gzip_dump_cmd = ["gzip", "-n", "-c", dump_rel]
        gzip_dump_decode_cmd = ["gzip", "-d", "-c", gzip_dump_rel]
        zstd_dump_cmd = ["zstd", "-q", "-c", dump_rel]
        zstd_dump_decode_cmd = ["zstd", "-q", "-d", "-c", zstd_dump_rel]

        timing_gzip_dump = run_timed_command(
            "dump -> gzip dump",
            gzip_dump_cmd,
            repeats=args.repeats,
            input_bytes=dump_bytes,
            stdout_path=paths["gzip_dump"],
            progress_callback=progress.callback("dump -> gzip dump"),
        )
        timing_gzip_dump_decode = run_timed_command(
            "gzip dump -> dump",
            gzip_dump_decode_cmd,
            repeats=args.repeats,
            input_bytes=paths["gzip_dump"].stat().st_size,
            output_bytes=dump_bytes,
            stdout_path=paths["gzip_dump_roundtrip"],
            progress_callback=progress.callback("gzip dump -> dump"),
        )
        timing_zstd_dump = run_timed_command(
            "dump -> zstd dump",
            zstd_dump_cmd,
            repeats=args.repeats,
            input_bytes=dump_bytes,
            stdout_path=paths["zstd_dump"],
            progress_callback=progress.callback("dump -> zstd dump"),
        )
        timing_zstd_dump_decode = run_timed_command(
            "zstd dump -> dump",
            zstd_dump_decode_cmd,
            repeats=args.repeats,
            input_bytes=paths["zstd_dump"].stat().st_size,
            output_bytes=dump_bytes,
            stdout_path=paths["zstd_dump_roundtrip"],
            progress_callback=progress.callback("zstd dump -> dump"),
        )

        timing_lossless_encode = run_timed_command(
            "dump -> mzv1 lossless",
            lossless_encode_cmd,
            repeats=args.repeats,
            input_bytes=dump_bytes,
            progress_callback=progress.callback("dump -> mzv1 lossless"),
        )
        timing_lossless_decode = run_timed_command(
            "mzv1 lossless -> dump",
            lossless_decode_cmd,
            repeats=args.repeats,
            input_bytes=paths["mzv1_lossless"].stat().st_size,
            output_bytes=dump_bytes,
            progress_callback=progress.callback("mzv1 lossless -> dump"),
        )
        lossless_roundtrip = read_dump(paths["roundtrip_lossless"])
        lossless_fidelity = asdict(compare_dumps("mzv1_lossless", reference_dump, lossless_roundtrip))
        progress.step("compare mzv1 lossless fidelity")

        timing_lossy_encode = run_timed_command(
            f"dump -> mzv1 lossy q={selected_quant}",
            lossy_encode_cmd,
            repeats=args.repeats,
            input_bytes=dump_bytes,
            progress_callback=progress.callback(f"dump -> mzv1 lossy q={selected_quant}"),
        )
        timing_lossy_decode = run_timed_command(
            f"mzv1 lossy q={selected_quant} -> dump",
            lossy_decode_cmd,
            repeats=args.repeats,
            input_bytes=paths["mzv1_lossy"].stat().st_size,
            output_bytes=dump_bytes,
            progress_callback=progress.callback(f"mzv1 lossy q={selected_quant} -> dump"),
        )
        lossy_roundtrip = read_dump(paths["roundtrip_lossy"])
        lossy_fidelity = asdict(compare_dumps("mzv1_lossy", reference_dump, lossy_roundtrip))
        progress.step(f"compare mzv1 lossy q={selected_quant} fidelity")

        sizes = {
            "mzML": {"path": repo_relative_path(input_path), "bytes": mzml_bytes},
            "dump": {"path": dump_rel, "bytes": dump_bytes},
            "mzv1 lossless": {"path": lossless_path_rel, "bytes": paths["mzv1_lossless"].stat().st_size},
            "mzv1 lossy": {"path": lossy_path_rel, "bytes": paths["mzv1_lossy"].stat().st_size},
            "gzip dump": {"path": gzip_dump_rel, "bytes": paths["gzip_dump"].stat().st_size},
            "zstd dump": {"path": zstd_dump_rel, "bytes": paths["zstd_dump"].stat().st_size},
        }

        lossy_sweep_rows: list[dict[str, object]] = []
        selected_sweep_row = {
            "intensity_quant": selected_quant,
            "path": lossy_path_rel,
            "bytes": paths["mzv1_lossy"].stat().st_size,
            "size_mib": paths["mzv1_lossy"].stat().st_size / (1024 * 1024),
            "fidelity": lossy_fidelity,
            "p95_rel_intensity_error_pct": lossy_fidelity["intensity_rel"]["p95"] * 100.0,
            "p99_rel_intensity_error_pct": lossy_fidelity["intensity_rel"]["p99"] * 100.0,
            "mean_rel_intensity_error_pct": lossy_fidelity["intensity_rel"]["mean"] * 100.0,
        }
        lossy_sweep_rows.append(selected_sweep_row)

        for quant in extra_sweep_levels:
            encoded_path = private_workdir / f"{sample_name}.lossy.q{quant}.mzv1"
            decoded_path = private_workdir / f"{sample_name}.lossy.q{quant}.roundtrip.bin"
            encoded_rel = repo_relative_path(encoded_path)
            decoded_rel = repo_relative_path(decoded_path)
            encode_cmd = [zig_bin_rel, "encode-v1", dump_rel, "-o", encoded_rel, "--lossy", "--intensity-quant", str(quant)]
            decode_cmd = [zig_bin_rel, "decode-v1", encoded_rel, "-o", decoded_rel]

            run_timed_command(
                f"lossy q={quant} encode artifact",
                encode_cmd,
                repeats=1,
                input_bytes=dump_bytes,
                progress_callback=progress.callback(f"lossy q={quant} encode"),
            )
            run_timed_command(
                f"lossy q={quant} decode artifact",
                decode_cmd,
                repeats=1,
                input_bytes=encoded_path.stat().st_size,
                output_bytes=dump_bytes,
                progress_callback=progress.callback(f"lossy q={quant} decode"),
            )

            fidelity = asdict(compare_dumps(f"mzv1_lossy_q{quant}", reference_dump, read_dump(decoded_path)))
            lossy_sweep_rows.append(
                {
                    "intensity_quant": quant,
                    "path": encoded_rel,
                    "bytes": encoded_path.stat().st_size,
                    "size_mib": encoded_path.stat().st_size / (1024 * 1024),
                    "fidelity": fidelity,
                    "p95_rel_intensity_error_pct": fidelity["intensity_rel"]["p95"] * 100.0,
                    "p99_rel_intensity_error_pct": fidelity["intensity_rel"]["p99"] * 100.0,
                    "mean_rel_intensity_error_pct": fidelity["intensity_rel"]["mean"] * 100.0,
                }
            )

        lossy_sweep_rows.sort(key=lambda row: int(row["intensity_quant"]))

        plot_rows = {
            "sizes": [
                {"artifact": name, "size_mib": item["bytes"] / (1024 * 1024)}
                for name, item in sizes.items()
            ],
            "lossy_sweep": [
                {
                    "intensity_quant": row["intensity_quant"],
                    "size_mib": row["size_mib"],
                    "p95_rel_intensity_error_pct": row["p95_rel_intensity_error_pct"],
                }
                for row in lossy_sweep_rows
            ],
            "intensity_quantiles": [
                {
                    "artifact": "lossless",
                    "quantile_label": label,
                    "value_pct": value * 100.0,
                }
                for label, value in lossless_fidelity["intensity_rel"]["quantiles"].items()
            ]
            + [
                {
                    "artifact": "selected lossy",
                    "quantile_label": label,
                    "value_pct": value * 100.0,
                }
                for label, value in lossy_fidelity["intensity_rel"]["quantiles"].items()
            ],
        }

        report = {
            "sample_name": sample_name,
            "repeats": args.repeats,
            "selected_lossy_intensity_quant": selected_quant,
            "paths": {
                "mzml": repo_relative_path(input_path),
                "private_workdir": repo_relative_path(private_workdir),
                "public_dir": repo_relative_path(public_dir),
            },
            "dataset": dataset,
            "sizes": sizes,
            "timings": [
                serialize_timing_result(timing_dump),
                serialize_timing_result(timing_gzip_dump),
                serialize_timing_result(timing_gzip_dump_decode),
                serialize_timing_result(timing_zstd_dump),
                serialize_timing_result(timing_zstd_dump_decode),
                serialize_timing_result(timing_lossless_encode),
                serialize_timing_result(timing_lossless_decode),
                serialize_timing_result(timing_lossy_encode),
                serialize_timing_result(timing_lossy_decode),
            ],
            "fidelity": {
                "mzv1_lossless": lossless_fidelity,
                "mzv1_lossy": lossy_fidelity,
            },
            "lossy_sweep": lossy_sweep_rows,
            "plot_rows": plot_rows,
            "comparison_candidates": FUTURE_BASELINES,
        }

        report["plots"] = generate_plots(report, plot_dir)
        progress.step("generate plots")

        (public_dir / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        (public_dir / "report.md").write_text(render_markdown(report), encoding="utf-8")
        progress.step("write report artifacts")

        summary = {
            "public_dir": repo_relative_path(public_dir),
            "private_workdir": repo_relative_path(private_workdir),
            "plots": report["plots"],
            "sizes_mib": {name: round(item["bytes"] / (1024 * 1024), 2) for name, item in sizes.items()},
            "lossless_mean_abs_mz": lossless_fidelity["mz_abs"]["mean"],
            "lossy_p95_rel_intensity_pct": round(lossy_fidelity["intensity_rel"]["p95"] * 100.0, 4),
        }
        print(json.dumps(summary, indent=2))
    finally:
        progress.finish()


if __name__ == "__main__":
    main()