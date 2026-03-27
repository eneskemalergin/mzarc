#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from benchmark_core import (
    DEFAULT_LOSSY_LEVEL,
    REPO_ROOT,
    collect_file_stats,
    compare_dumps,
    parse_lossy_sweep,
    read_dump,
    require_tool,
    run_dump_mzml_quietly,
    run_timed_callable,
    run_timed_command,
    run_timed_path_command,
    serialize_timing_result,
)
from benchmark_external import (
    estimate_external_steps,
    parse_external_baselines,
    run_external_baselines,
)
from benchmark_metrics import (
    build_fidelity_metric_rows,
    build_performance_rows,
    build_search_impact_rows,
    load_search_impact,
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


def timed_command(
    name: str,
    command: list[str],
    *,
    repeats: int,
    progress: ProgressBar,
    progress_label: str,
    input_bytes: int | None = None,
    output_bytes: int | None = None,
    output_path: Path | None = None,
    stdout_path: Path | None = None,
):
    common = {
        "repeats": repeats,
        "input_bytes": input_bytes,
        "output_bytes": output_bytes,
        "progress_callback": progress.callback(progress_label),
    }
    if output_path is not None:
        return run_timed_path_command(name, command, output_path=output_path, **common)
    return run_timed_command(name, command, stdout_path=stdout_path, **common)


def benchmark_roundtrip(
    *,
    artifact: str,
    fidelity_name: str,
    encode_name: str,
    encode_command: list[str],
    encode_progress: str,
    encode_path: Path,
    decode_name: str,
    decode_command: list[str],
    decode_progress: str,
    decode_path: Path,
    reference_dump,
    repeats: int,
    progress: ProgressBar,
    encode_input_bytes: int,
    decode_output_bytes: int,
    encode_writes_file: bool = False,
    decode_writes_file: bool = False,
) -> dict[str, object]:
    encode_timing = timed_command(
        encode_name,
        encode_command,
        repeats=repeats,
        progress=progress,
        progress_label=encode_progress,
        input_bytes=encode_input_bytes,
        output_path=encode_path if encode_writes_file else None,
        stdout_path=None if encode_writes_file else encode_path,
    )
    decode_timing = timed_command(
        decode_name,
        decode_command,
        repeats=repeats,
        progress=progress,
        progress_label=decode_progress,
        input_bytes=encode_path.stat().st_size,
        output_bytes=decode_output_bytes,
        output_path=decode_path if decode_writes_file else None,
        stdout_path=None if decode_writes_file else decode_path,
    )
    fidelity = asdict(compare_dumps(fidelity_name, reference_dump, read_dump(decode_path)))
    progress.step(f"compare {artifact} fidelity")
    return {"path": encode_path, "encode_timing": encode_timing, "decode_timing": decode_timing, "fidelity": fidelity}


def lossy_sweep_row(*, quant: int, encoded_path: Path, encoded_rel: str, fidelity: dict[str, object]) -> dict[str, object]:
    return {
        "intensity_quant": quant,
        "path": encoded_rel,
        "bytes": encoded_path.stat().st_size,
        "size_mib": encoded_path.stat().st_size / (1024 * 1024),
        "fidelity": fidelity,
        "p95_rel_intensity_error_pct": fidelity["intensity_rel"]["p95"] * 100.0,
        "p99_rel_intensity_error_pct": fidelity["intensity_rel"]["p99"] * 100.0,
        "mean_rel_intensity_error_pct": fidelity["intensity_rel"]["mean"] * 100.0,
    }


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
        "--external-baselines",
        type=str,
        default="all",
        help="Comma-separated external baselines to attempt: mzmlb, ms-numpress, mscompress, all, or none",
    )
    parser.add_argument(
        "--mzmlb-compression",
        type=str,
        default="blosc:zstd",
        help="HDF5 compression mode for psims mzMLb output",
    )
    parser.add_argument(
        "--ms-numpress-command-template",
        type=str,
        default=None,
        help="Optional external command template for MS-Numpress output using {input} and {output} placeholders",
    )
    parser.add_argument(
        "--ms-numpress-to-dump-command-template",
        type=str,
        default=None,
        help="Optional command template to convert the MS-Numpress artifact back to a dump using {input} and {output}",
    )
    parser.add_argument(
        "--mscompress-command-template",
        type=str,
        default=None,
        help="Optional external command template for MScompress conversion using {input} and {output} placeholders",
    )
    parser.add_argument(
        "--mscompress-to-dump-command-template",
        type=str,
        default=None,
        help="Optional command template to convert the MScompress artifact back to a dump using {input} and {output}",
    )
    parser.add_argument(
        "--mscompress-benchmark-threaded",
        action="store_true",
        default=True,
        help="Also benchmark a second MScompress run using its threaded/default configuration (enabled by default)",
    )
    parser.add_argument(
        "--mscompress-thread-count",
        type=int,
        default=None,
        help="Explicit thread count for the additional threaded MScompress benchmark; omitted means use MScompress defaults",
    )
    parser.add_argument(
        "--search-impact-json",
        type=Path,
        default=None,
        help="Optional JSON file containing peptide-identification and FDR deltas keyed by artifact name",
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


def inspect_codec_artifact(zig_bin: Path, artifact_path: Path) -> dict[str, object]:
    command = [repo_relative_path(zig_bin), "inspect-v1", repo_relative_path(artifact_path), "--json"]
    try:
        completed = subprocess.run(
            command,
            check=True,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr or ""
        raise RuntimeError(f"Command failed for {' '.join(command)}\n{stderr}") from exc

    payload = (completed.stdout or "").strip()
    if not payload:
        raise RuntimeError(f"No inspection output returned for {artifact_path}")

    inspection = json.loads(payload)
    total_bytes = int(inspection["byte_breakdown"]["total_bytes"])
    actual_bytes = artifact_path.stat().st_size
    if total_bytes != actual_bytes:
        raise ValueError(
            f"Inspection byte total mismatch for {artifact_path}: reported {total_bytes}, actual {actual_bytes}"
        )
    return inspection


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
    require_tool("bzip2")
    require_tool("xz")
    require_tool("lz4")

    selected_quant = int(args.lossy_intensity_quant)
    lossy_sweep = parse_lossy_sweep(args.lossy_sweep, selected_quant)
    requested_external = parse_external_baselines(args.external_baselines)
    private_workdir = resolve_private_workdir(input_path, args.private_workdir.resolve() if args.private_workdir else None)
    public_dir = args.public_dir.resolve()
    plot_dir = public_dir / "plots"

    private_workdir.mkdir(parents=True, exist_ok=True)
    plot_dir.mkdir(parents=True, exist_ok=True)

    sample_name = input_path.stem
    paths = {
        "mzml": input_path,
        "dump": private_workdir / f"{sample_name}.bin",
        "gzip_dump": private_workdir / f"{sample_name}.bin.gz",
        "gzip_dump_roundtrip": private_workdir / f"{sample_name}.gzip.roundtrip.bin",
        "zstd_dump": private_workdir / f"{sample_name}.bin.zst",
        "zstd_dump_roundtrip": private_workdir / f"{sample_name}.zstd.roundtrip.bin",
        "gzip_mzml": private_workdir / f"{sample_name}.mzML.gz",
        "gzip_mzml_roundtrip": private_workdir / f"{sample_name}.gzip_mzml.roundtrip.mzML",
        "zstd_mzml": private_workdir / f"{sample_name}.mzML.zst",
        "zstd_mzml_roundtrip": private_workdir / f"{sample_name}.zstd_mzml.roundtrip.mzML",
        "bzip2_dump": private_workdir / f"{sample_name}.bin.bz2",
        "bzip2_dump_roundtrip": private_workdir / f"{sample_name}.bzip2.roundtrip.bin",
        "bzip2_mzml": private_workdir / f"{sample_name}.mzML.bz2",
        "bzip2_mzml_roundtrip": private_workdir / f"{sample_name}.bzip2_mzml.roundtrip.mzML",
        "lz4_dump": private_workdir / f"{sample_name}.bin.lz4",
        "lz4_dump_roundtrip": private_workdir / f"{sample_name}.lz4.roundtrip.bin",
        "lz4_mzml": private_workdir / f"{sample_name}.mzML.lz4",
        "lz4_mzml_roundtrip": private_workdir / f"{sample_name}.lz4_mzml.roundtrip.mzML",
        "xz_dump": private_workdir / f"{sample_name}.bin.xz",
        "xz_dump_roundtrip": private_workdir / f"{sample_name}.xz.roundtrip.bin",
        "xz_mzml": private_workdir / f"{sample_name}.mzML.xz",
        "xz_mzml_roundtrip": private_workdir / f"{sample_name}.xz_mzml.roundtrip.mzML",
        "mzv1_lossless": private_workdir / f"{sample_name}.lossless.mzv1",
        "roundtrip_lossless": private_workdir / f"{sample_name}.lossless.roundtrip.bin",
        "mzv1_lossy": private_workdir / f"{sample_name}.lossy.q{selected_quant}.mzv1",
        "roundtrip_lossy": private_workdir / f"{sample_name}.lossy.q{selected_quant}.roundtrip.bin",
    }

    extra_sweep_levels = [level for level in lossy_sweep if level != selected_quant]
    external_steps = estimate_external_steps(
        requested_external,
        args.repeats,
        numpress_command_template=args.ms_numpress_command_template,
        numpress_to_dump_command_template=args.ms_numpress_to_dump_command_template,
        mscompress_command_template=args.mscompress_command_template,
        mscompress_to_dump_command_template=args.mscompress_to_dump_command_template,
        mscompress_benchmark_threaded=args.mscompress_benchmark_threaded,
    )
    total_steps = (args.repeats * 25) + (2 * len(extra_sweep_levels)) + external_steps + 16
    progress = ProgressBar(total_steps, enabled=not args.no_progress)

    try:
        mzml_bytes = input_path.stat().st_size
        search_impact_data = load_search_impact(args.search_impact_json.resolve() if args.search_impact_json else None)

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
        mzml_rel = repo_relative_path(input_path)
        gzip_mzml_rel = repo_relative_path(paths["gzip_mzml"])
        zstd_mzml_rel = repo_relative_path(paths["zstd_mzml"])
        bzip2_dump_rel = repo_relative_path(paths["bzip2_dump"])
        bzip2_dump_roundtrip_rel = repo_relative_path(paths["bzip2_dump_roundtrip"])
        bzip2_mzml_rel = repo_relative_path(paths["bzip2_mzml"])
        lz4_dump_rel = repo_relative_path(paths["lz4_dump"])
        lz4_dump_roundtrip_rel = repo_relative_path(paths["lz4_dump_roundtrip"])
        lz4_mzml_rel = repo_relative_path(paths["lz4_mzml"])
        xz_dump_rel = repo_relative_path(paths["xz_dump"])
        xz_dump_roundtrip_rel = repo_relative_path(paths["xz_dump_roundtrip"])
        xz_mzml_rel = repo_relative_path(paths["xz_mzml"])

        gzip_result = benchmark_roundtrip(
            artifact="gzip dump",
            fidelity_name="gzip_dump",
            encode_name="dump -> gzip dump",
            encode_command=["gzip", "-n", "-c", dump_rel],
            encode_progress="dump -> gzip dump",
            encode_path=paths["gzip_dump"],
            decode_name="gzip dump -> dump",
            decode_command=["gzip", "-d", "-c", gzip_dump_rel],
            decode_progress="gzip dump -> dump",
            decode_path=paths["gzip_dump_roundtrip"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
        )
        zstd_result = benchmark_roundtrip(
            artifact="zstd dump",
            fidelity_name="zstd_dump",
            encode_name="dump -> zstd dump",
            encode_command=["zstd", "-q", "-c", dump_rel],
            encode_progress="dump -> zstd dump",
            encode_path=paths["zstd_dump"],
            decode_name="zstd dump -> dump",
            decode_command=["zstd", "-q", "-d", "-c", zstd_dump_rel],
            decode_progress="zstd dump -> dump",
            decode_path=paths["zstd_dump_roundtrip"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
        )
        bzip2_result = benchmark_roundtrip(
            artifact="bzip2 dump",
            fidelity_name="bzip2_dump",
            encode_name="dump -> bzip2 dump",
            encode_command=["bzip2", "-c", dump_rel],
            encode_progress="dump -> bzip2 dump",
            encode_path=paths["bzip2_dump"],
            decode_name="bzip2 dump -> dump",
            decode_command=["bzip2", "-d", "-c", bzip2_dump_rel],
            decode_progress="bzip2 dump -> dump",
            decode_path=paths["bzip2_dump_roundtrip"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
        )
        lz4_result = benchmark_roundtrip(
            artifact="lz4 dump",
            fidelity_name="lz4_dump",
            encode_name="dump -> lz4 dump",
            encode_command=["lz4", "-q", "-c", dump_rel],
            encode_progress="dump -> lz4 dump",
            encode_path=paths["lz4_dump"],
            decode_name="lz4 dump -> dump",
            decode_command=["lz4", "-q", "-d", "-c", lz4_dump_rel],
            decode_progress="lz4 dump -> dump",
            decode_path=paths["lz4_dump_roundtrip"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
        )
        xz_result = benchmark_roundtrip(
            artifact="xz dump",
            fidelity_name="xz_dump",
            encode_name="dump -> xz dump",
            encode_command=["xz", "-c", dump_rel],
            encode_progress="dump -> xz dump",
            encode_path=paths["xz_dump"],
            decode_name="xz dump -> dump",
            decode_command=["xz", "-d", "-c", xz_dump_rel],
            decode_progress="xz dump -> dump",
            decode_path=paths["xz_dump_roundtrip"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
        )

        # gzip, zstd, bzip2, lz4, xz applied directly to the mzML file (not
        # the dump).  Decompression gives raw inflate speed; mzML parsing
        # (~4.5 s) is still required before data is usable.
        gzip_mzml_encode_timing = timed_command(
            "mzML -> gzip mzML",
            ["gzip", "-n", "-c", mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="mzML -> gzip mzML",
            input_bytes=mzml_bytes,
            stdout_path=paths["gzip_mzml"],
        )
        gzip_mzml_decode_timing = timed_command(
            "gzip mzML -> mzML",
            ["gzip", "-d", "-c", gzip_mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="gzip mzML -> mzML",
            input_bytes=paths["gzip_mzml"].stat().st_size,
            output_bytes=mzml_bytes,
            stdout_path=paths["gzip_mzml_roundtrip"],
        )
        zstd_mzml_encode_timing = timed_command(
            "mzML -> zstd mzML",
            ["zstd", "-q", "-c", mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="mzML -> zstd mzML",
            input_bytes=mzml_bytes,
            stdout_path=paths["zstd_mzml"],
        )
        zstd_mzml_decode_timing = timed_command(
            "zstd mzML -> mzML",
            ["zstd", "-q", "-d", "-c", zstd_mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="zstd mzML -> mzML",
            input_bytes=paths["zstd_mzml"].stat().st_size,
            output_bytes=mzml_bytes,
            stdout_path=paths["zstd_mzml_roundtrip"],
        )
        bzip2_mzml_encode_timing = timed_command(
            "mzML -> bzip2 mzML",
            ["bzip2", "-c", mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="mzML -> bzip2 mzML",
            input_bytes=mzml_bytes,
            stdout_path=paths["bzip2_mzml"],
        )
        bzip2_mzml_decode_timing = timed_command(
            "bzip2 mzML -> mzML",
            ["bzip2", "-d", "-c", bzip2_mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="bzip2 mzML -> mzML",
            input_bytes=paths["bzip2_mzml"].stat().st_size,
            output_bytes=mzml_bytes,
            stdout_path=paths["bzip2_mzml_roundtrip"],
        )
        lz4_mzml_encode_timing = timed_command(
            "mzML -> lz4 mzML",
            ["lz4", "-q", "-c", mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="mzML -> lz4 mzML",
            input_bytes=mzml_bytes,
            stdout_path=paths["lz4_mzml"],
        )
        lz4_mzml_decode_timing = timed_command(
            "lz4 mzML -> mzML",
            ["lz4", "-q", "-d", "-c", lz4_mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="lz4 mzML -> mzML",
            input_bytes=paths["lz4_mzml"].stat().st_size,
            output_bytes=mzml_bytes,
            stdout_path=paths["lz4_mzml_roundtrip"],
        )
        xz_mzml_encode_timing = timed_command(
            "mzML -> xz mzML",
            ["xz", "-c", mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="mzML -> xz mzML",
            input_bytes=mzml_bytes,
            stdout_path=paths["xz_mzml"],
        )
        xz_mzml_decode_timing = timed_command(
            "xz mzML -> mzML",
            ["xz", "-d", "-c", xz_mzml_rel],
            repeats=args.repeats,
            progress=progress,
            progress_label="xz mzML -> mzML",
            input_bytes=paths["xz_mzml"].stat().st_size,
            output_bytes=mzml_bytes,
            stdout_path=paths["xz_mzml_roundtrip"],
        )
        progress.step("record gzip/zstd/bzip2/lz4/xz mzML sizes")

        lossless_result = benchmark_roundtrip(
            artifact="mzv1 lossless",
            fidelity_name="mzv1_lossless",
            encode_name="dump -> mzv1 lossless",
            encode_command=[zig_bin_rel, "encode-v1", dump_rel, "-o", lossless_path_rel],
            encode_progress="dump -> mzv1 lossless",
            encode_path=paths["mzv1_lossless"],
            decode_name="mzv1 lossless -> dump",
            decode_command=[zig_bin_rel, "decode-v1", lossless_path_rel, "-o", lossless_roundtrip_rel],
            decode_progress="mzv1 lossless -> dump",
            decode_path=paths["roundtrip_lossless"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
            encode_writes_file=True,
            decode_writes_file=True,
        )
        lossy_result = benchmark_roundtrip(
            artifact=f"mzv1 lossy q={selected_quant}",
            fidelity_name="mzv1_lossy",
            encode_name=f"dump -> mzv1 lossy q={selected_quant}",
            encode_command=[zig_bin_rel, "encode-v1", dump_rel, "-o", lossy_path_rel, "--lossy", "--intensity-quant", str(selected_quant)],
            encode_progress=f"dump -> mzv1 lossy q={selected_quant}",
            encode_path=paths["mzv1_lossy"],
            decode_name=f"mzv1 lossy q={selected_quant} -> dump",
            decode_command=[zig_bin_rel, "decode-v1", lossy_path_rel, "-o", lossy_roundtrip_rel],
            decode_progress=f"mzv1 lossy q={selected_quant} -> dump",
            decode_path=paths["roundtrip_lossy"],
            reference_dump=reference_dump,
            repeats=args.repeats,
            progress=progress,
            encode_input_bytes=dump_bytes,
            decode_output_bytes=dump_bytes,
            encode_writes_file=True,
            decode_writes_file=True,
        )

        gzip_fidelity = gzip_result["fidelity"]
        zstd_fidelity = zstd_result["fidelity"]
        bzip2_fidelity = bzip2_result["fidelity"]
        lz4_fidelity = lz4_result["fidelity"]
        xz_fidelity = xz_result["fidelity"]
        lossless_fidelity = lossless_result["fidelity"]
        lossy_fidelity = lossy_result["fidelity"]

        lossless_layout = inspect_codec_artifact(zig_bin, paths["mzv1_lossless"])
        progress.step("inspect mzv1 lossless layout")
        lossy_layout = inspect_codec_artifact(zig_bin, paths["mzv1_lossy"])
        progress.step("inspect mzv1 lossy layout")

        sizes = {
            "mzML": {"path": repo_relative_path(input_path), "bytes": mzml_bytes},
            "dump": {"path": dump_rel, "bytes": dump_bytes},
            "mzv1 lossless": {"path": lossless_path_rel, "bytes": paths["mzv1_lossless"].stat().st_size},
            "mzv1 lossy": {"path": lossy_path_rel, "bytes": paths["mzv1_lossy"].stat().st_size},
            "gzip dump": {"path": gzip_dump_rel, "bytes": paths["gzip_dump"].stat().st_size},
            "zstd dump": {"path": zstd_dump_rel, "bytes": paths["zstd_dump"].stat().st_size},
            "gzip mzML": {"path": gzip_mzml_rel, "bytes": paths["gzip_mzml"].stat().st_size},
            "zstd mzML": {"path": zstd_mzml_rel, "bytes": paths["zstd_mzml"].stat().st_size},
            "bzip2 dump": {"path": bzip2_dump_rel, "bytes": paths["bzip2_dump"].stat().st_size},
            "lz4 dump": {"path": lz4_dump_rel, "bytes": paths["lz4_dump"].stat().st_size},
            "xz dump": {"path": xz_dump_rel, "bytes": paths["xz_dump"].stat().st_size},
            "bzip2 mzML": {"path": bzip2_mzml_rel, "bytes": paths["bzip2_mzml"].stat().st_size},
            "lz4 mzML": {"path": lz4_mzml_rel, "bytes": paths["lz4_mzml"].stat().st_size},
            "xz mzML": {"path": xz_mzml_rel, "bytes": paths["xz_mzml"].stat().st_size},
        }

        external_results = run_external_baselines(
            requested=requested_external,
            input_path=input_path,
            sample_name=sample_name,
            private_workdir=private_workdir,
            reference_dump=reference_dump,
            dump_bytes=dump_bytes,
            repeats=args.repeats,
            mzmlb_compression=args.mzmlb_compression,
            repo_relative_path=repo_relative_path,
            progress=progress,
            numpress_command_template=args.ms_numpress_command_template,
            numpress_to_dump_command_template=args.ms_numpress_to_dump_command_template,
            mscompress_command_template=args.mscompress_command_template,
            mscompress_to_dump_command_template=args.mscompress_to_dump_command_template,
            mscompress_benchmark_threaded=args.mscompress_benchmark_threaded,
            mscompress_thread_count=args.mscompress_thread_count,
        )
        sizes.update(external_results["sizes"])

        lossy_sweep_rows: list[dict[str, object]] = []
        selected_sweep_row = lossy_sweep_row(
            quant=selected_quant,
            encoded_path=paths["mzv1_lossy"],
            encoded_rel=lossy_path_rel,
            fidelity=lossy_fidelity,
        )
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
                lossy_sweep_row(
                    quant=quant,
                    encoded_path=encoded_path,
                    encoded_rel=encoded_rel,
                    fidelity=fidelity,
                )
            )

        lossy_sweep_rows.sort(key=lambda row: int(row["intensity_quant"]))

        fidelity_rows = [
            {"artifact": "gzip dump", "data": gzip_fidelity},
            {"artifact": "zstd dump", "data": zstd_fidelity},
            {"artifact": "bzip2 dump", "data": bzip2_fidelity},
            {"artifact": "lz4 dump", "data": lz4_fidelity},
            {"artifact": "xz dump", "data": xz_fidelity},
            {"artifact": "mzv1 lossless", "data": lossless_fidelity},
            {"artifact": f"mzv1 lossy q={selected_quant}", "data": lossy_fidelity},
        ]
        for item in external_results["records"]:
            if item["fidelity"] is not None:
                fidelity_rows.append({"artifact": item["name"], "data": item["fidelity"]})

        serialized_timings = [
            serialize_timing_result(timing_dump),
            serialize_timing_result(gzip_result["encode_timing"]),
            serialize_timing_result(gzip_result["decode_timing"]),
            serialize_timing_result(zstd_result["encode_timing"]),
            serialize_timing_result(zstd_result["decode_timing"]),
            serialize_timing_result(bzip2_result["encode_timing"]),
            serialize_timing_result(bzip2_result["decode_timing"]),
            serialize_timing_result(lz4_result["encode_timing"]),
            serialize_timing_result(lz4_result["decode_timing"]),
            serialize_timing_result(xz_result["encode_timing"]),
            serialize_timing_result(xz_result["decode_timing"]),
            serialize_timing_result(gzip_mzml_encode_timing),
            serialize_timing_result(gzip_mzml_decode_timing),
            serialize_timing_result(zstd_mzml_encode_timing),
            serialize_timing_result(zstd_mzml_decode_timing),
            serialize_timing_result(bzip2_mzml_encode_timing),
            serialize_timing_result(bzip2_mzml_decode_timing),
            serialize_timing_result(lz4_mzml_encode_timing),
            serialize_timing_result(lz4_mzml_decode_timing),
            serialize_timing_result(xz_mzml_encode_timing),
            serialize_timing_result(xz_mzml_decode_timing),
            serialize_timing_result(lossless_result["encode_timing"]),
            serialize_timing_result(lossless_result["decode_timing"]),
            serialize_timing_result(lossy_result["encode_timing"]),
            serialize_timing_result(lossy_result["decode_timing"]),
        ]
        serialized_timings.extend(serialize_timing_result(item) for item in external_results["timings"])

        performance_rows = build_performance_rows(
            serialized_timings,
            selected_quant=selected_quant,
            external_baselines=external_results["records"],
        )
        fidelity_metric_rows = build_fidelity_metric_rows(
            fidelity_rows,
            selected_quant=selected_quant,
            external_baselines=external_results["records"],
        )
        search_impact_rows = build_search_impact_rows(
            selected_quant=selected_quant,
            external_baselines=external_results["records"],
            search_impact_data=search_impact_data,
            fidelity_metric_rows=fidelity_metric_rows,
        )
        plot_rows = {
            "sizes": [{"artifact": name, "size_mib": item["bytes"] / (1024 * 1024)} for name, item in sizes.items()],
            "performance": performance_rows,
            "fidelity": fidelity_metric_rows,
            "lossy_sweep": [
                {
                    "intensity_quant": row["intensity_quant"],
                    "size_mib": row["size_mib"],
                    "p95_rel_intensity_error_pct": row["p95_rel_intensity_error_pct"],
                }
                for row in lossy_sweep_rows
            ],
            "intensity_quantiles": [
                {"artifact": "lossless", "quantile_label": label, "value_pct": value * 100.0}
                for label, value in lossless_fidelity["intensity_rel"]["quantiles"].items()
            ]
            + [
                {"artifact": "selected lossy", "quantile_label": label, "value_pct": value * 100.0}
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
            "codec_byte_breakdown": {
                "mzv1 lossless": lossless_layout["byte_breakdown"],
                f"mzv1 lossy q={selected_quant}": lossy_layout["byte_breakdown"],
            },
            "timings": serialized_timings,
            "fidelity": {
                "mzv1_lossless": lossless_fidelity,
                "mzv1_lossy": lossy_fidelity,
            },
            "fidelity_rows": fidelity_rows,
            "fidelity_metrics": fidelity_metric_rows,
            "performance_rows": performance_rows,
            "search_impact_rows": search_impact_rows,
            "lossy_sweep": lossy_sweep_rows,
            "plot_rows": plot_rows,
            "external_baselines": external_results["records"],
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
            "lossless_byte_breakdown": lossless_layout["byte_breakdown"],
            "external_baselines": [
                {
                    "name": item["name"],
                    "status": item["status"],
                    "size_mib": None if item["artifact_bytes"] is None else round(item["artifact_bytes"] / (1024 * 1024), 2),
                }
                for item in external_results["records"]
            ],
        }
        print(json.dumps(summary, indent=2))
    finally:
        progress.finish()


if __name__ == "__main__":
    main()