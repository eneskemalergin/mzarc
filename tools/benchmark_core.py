from __future__ import annotations

import contextlib
import io
import math
import os
import shutil
import statistics
import struct
import subprocess
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

from mzml_dump import dump_mzml


RECORD_HEADER = struct.Struct("<IfB3xdI4x")
REPORT_QUANTILES = (0.5, 0.9, 0.95, 0.99, 0.999, 1.0)
DEFAULT_LOSSY_LEVEL = 16384
DEFAULT_LOSSY_SWEEP_LEVELS = (256, 1024, 4096, 16384)
REPO_ROOT = Path(__file__).resolve().parents[1]

_T_CRITICAL_95_TWO_SIDED = {
    1: 12.706,
    2: 4.303,
    3: 3.182,
    4: 2.776,
    5: 2.571,
    6: 2.447,
    7: 2.365,
    8: 2.306,
    9: 2.262,
    10: 2.228,
    11: 2.201,
    12: 2.179,
    13: 2.16,
    14: 2.145,
    15: 2.131,
    16: 2.12,
    17: 2.11,
    18: 2.101,
    19: 2.093,
    20: 2.086,
    21: 2.08,
    22: 2.074,
    23: 2.069,
    24: 2.064,
    25: 2.06,
    26: 2.056,
    27: 2.052,
    28: 2.048,
    29: 2.045,
    30: 2.042,
}


@dataclass(slots=True)
class Spectrum:
    scan_id: int
    rt_seconds: float
    ms_level: int
    precursor_mz: float
    mz: np.ndarray
    intensity: np.ndarray


@dataclass(slots=True)
class FileStats:
    path: str
    bytes: int
    spectra: int
    total_peaks: int
    ms1_spectra: int
    ms2_spectra: int


@dataclass(slots=True)
class TimingResult:
    name: str
    command: list[str]
    runs_seconds: list[float]
    median_seconds: float
    mean_seconds: float
    min_seconds: float
    max_seconds: float
    throughput_mib_s: float | None
    throughput_input_mib_s: float | None
    throughput_output_mib_s: float | None
    throughput_basis: str | None
    input_bytes: int | None
    output_bytes: int | None


@dataclass(slots=True)
class ErrorSummary:
    count: int
    mean: float
    median: float
    p95: float
    p99: float
    p999: float
    max: float
    rmse: float
    quantiles: dict[str, float]


@dataclass(slots=True)
class FidelityResult:
    name: str
    matched_spectra: int
    matched_peaks: int
    global_order_preserved: bool
    ms1_relative_order_preserved: bool
    ms2_relative_order_preserved: bool
    max_abs_rt_error: float
    max_abs_precursor_mz_error: float
    exact_mz_count: int
    exact_intensity_count: int
    mz_abs: ErrorSummary
    mz_ppm: ErrorSummary
    intensity_abs: ErrorSummary
    intensity_rel: ErrorSummary
    intensity_log1p_abs: ErrorSummary


def read_dump(path: Path) -> list[Spectrum]:
    spectra: list[Spectrum] = []
    with path.open("rb") as handle:
        while True:
            header = handle.read(RECORD_HEADER.size)
            if not header:
                break
            if len(header) != RECORD_HEADER.size:
                raise ValueError(f"Truncated dump header in {path}")

            scan_id, rt_seconds, ms_level, precursor_mz, peak_count = RECORD_HEADER.unpack(header)
            mz_bytes = handle.read(peak_count * 8)
            intensity_bytes = handle.read(peak_count * 4)

            if len(mz_bytes) != peak_count * 8:
                raise ValueError(f"Truncated m/z payload in {path}")
            if len(intensity_bytes) != peak_count * 4:
                raise ValueError(f"Truncated intensity payload in {path}")

            spectra.append(
                Spectrum(
                    scan_id=scan_id,
                    rt_seconds=rt_seconds,
                    ms_level=ms_level,
                    precursor_mz=precursor_mz,
                    mz=np.frombuffer(mz_bytes, dtype="<f8").copy(),
                    intensity=np.frombuffer(intensity_bytes, dtype="<f4").copy(),
                )
            )

    return spectra


def collect_file_stats(path: Path, spectra: list[Spectrum]) -> FileStats:
    total_peaks = sum(len(spectrum.mz) for spectrum in spectra)
    ms1_spectra = sum(1 for spectrum in spectra if spectrum.ms_level == 1)
    ms2_spectra = sum(1 for spectrum in spectra if spectrum.ms_level == 2)
    return FileStats(
        path=str(path),
        bytes=path.stat().st_size,
        spectra=len(spectra),
        total_peaks=total_peaks,
        ms1_spectra=ms1_spectra,
        ms2_spectra=ms2_spectra,
    )


def finalize_timing(
    name: str,
    command: list[str],
    runs: list[float],
    input_bytes: int | None,
    output_bytes: int | None,
) -> TimingResult:
    median_seconds = statistics.median(runs)
    mean_seconds = statistics.fmean(runs)
    throughput_input_mib_s = None
    throughput_output_mib_s = None
    throughput_mib_s = None
    throughput_basis = None
    if input_bytes:
        throughput_input_mib_s = (input_bytes / (1024 * 1024)) / mean_seconds
    if output_bytes:
        throughput_output_mib_s = (output_bytes / (1024 * 1024)) / mean_seconds

    if output_bytes:
        throughput_mib_s = throughput_output_mib_s
        throughput_basis = "output"
    elif input_bytes:
        throughput_mib_s = throughput_input_mib_s
        throughput_basis = "input"

    return TimingResult(
        name=name,
        command=command,
        runs_seconds=runs,
        median_seconds=median_seconds,
        mean_seconds=mean_seconds,
        min_seconds=min(runs),
        max_seconds=max(runs),
        throughput_mib_s=throughput_mib_s,
        throughput_input_mib_s=throughput_input_mib_s,
        throughput_output_mib_s=throughput_output_mib_s,
        throughput_basis=throughput_basis,
        input_bytes=input_bytes,
        output_bytes=output_bytes,
    )


def run_timed_callable(
    name: str,
    func,
    *,
    repeats: int,
    input_bytes: int | None = None,
    output_bytes: int | None = None,
    progress_callback: Callable[[str, int, int], None] | None = None,
) -> TimingResult:
    runs: list[float] = []
    for run_index in range(repeats):
        start = time.perf_counter()
        func()
        runs.append(time.perf_counter() - start)
        if progress_callback is not None:
            progress_callback(name, run_index + 1, repeats)
    return finalize_timing(name, ["<python-callable>"], runs, input_bytes, output_bytes)


def run_timed_command(
    name: str,
    command: list[str],
    *,
    repeats: int,
    input_bytes: int | None = None,
    output_bytes: int | None = None,
    stdout_path: Path | None = None,
    stdout_devnull: bool = False,
    progress_callback: Callable[[str, int, int], None] | None = None,
) -> TimingResult:
    runs: list[float] = []
    for run_index in range(repeats):
        if stdout_path is not None and stdout_path.exists():
            stdout_path.unlink()

        stdout_handle = None
        try:
            if stdout_path is not None:
                stdout_handle = stdout_path.open("wb")
                stdout_target = stdout_handle
            elif stdout_devnull:
                stdout_target = subprocess.DEVNULL
            else:
                stdout_target = subprocess.PIPE

            start = time.perf_counter()
            subprocess.run(
                command,
                check=True,
                cwd=REPO_ROOT,
                stdout=stdout_target,
                stderr=subprocess.PIPE,
            )
            runs.append(time.perf_counter() - start)
            if progress_callback is not None:
                progress_callback(name, run_index + 1, repeats)
        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.decode("utf-8", errors="replace") if exc.stderr else ""
            raise RuntimeError(f"Command failed for {name}: {' '.join(command)}\n{stderr}") from exc
        finally:
            if stdout_handle is not None:
                stdout_handle.close()

    return finalize_timing(name, command, runs, input_bytes, output_bytes)


def run_timed_path_command(
    name: str,
    command: list[str],
    *,
    repeats: int,
    output_path: Path,
    input_bytes: int | None = None,
    output_bytes: int | None = None,
    progress_callback: Callable[[str, int, int], None] | None = None,
) -> TimingResult:
    runs: list[float] = []
    for run_index in range(repeats):
        if output_path.exists():
            output_path.unlink()

        try:
            start = time.perf_counter()
            subprocess.run(
                command,
                check=True,
                cwd=REPO_ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            runs.append(time.perf_counter() - start)
            if progress_callback is not None:
                progress_callback(name, run_index + 1, repeats)
        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.decode("utf-8", errors="replace") if exc.stderr else ""
            raise RuntimeError(f"Command failed for {name}: {' '.join(command)}\n{stderr}") from exc

    return finalize_timing(name, command, runs, input_bytes, output_bytes)


def t_critical_95_two_sided(sample_size: int) -> float:
    if sample_size <= 1:
        return 0.0
    degrees_of_freedom = sample_size - 1
    if degrees_of_freedom in _T_CRITICAL_95_TWO_SIDED:
        return _T_CRITICAL_95_TWO_SIDED[degrees_of_freedom]
    return 1.96


def summarize_timing_runs(runs_seconds: list[float]) -> dict[str, float | int]:
    repeats = len(runs_seconds)
    mean_seconds = statistics.fmean(runs_seconds)
    stdev_seconds = statistics.stdev(runs_seconds) if repeats > 1 else 0.0
    ci95_half_width = 0.0
    if repeats > 1:
        ci95_half_width = t_critical_95_two_sided(repeats) * stdev_seconds / math.sqrt(repeats)
    return {
        "repeats": repeats,
        "stdev_seconds": stdev_seconds,
        "ci95_low_seconds": mean_seconds - ci95_half_width,
        "ci95_high_seconds": mean_seconds + ci95_half_width,
        "ci95_half_width_seconds": ci95_half_width,
    }


def serialize_timing_result(result: TimingResult) -> dict[str, object]:
    payload = asdict(result)
    payload.update(summarize_timing_runs(result.runs_seconds))
    return payload


def unique_key(spectrum: Spectrum) -> tuple[int, int, int]:
    return (spectrum.ms_level, spectrum.scan_id, len(spectrum.mz))


def format_quantile(value: float) -> str:
    if value == 1.0:
        return "p100"
    return f"p{value * 100:g}"


def summarize_errors(values: np.ndarray) -> ErrorSummary:
    array = np.asarray(values, dtype=np.float64)
    if array.size == 0:
        empty_quantiles = {format_quantile(q): 0.0 for q in REPORT_QUANTILES}
        return ErrorSummary(0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, empty_quantiles)

    quantile_values = np.quantile(array, REPORT_QUANTILES)
    return ErrorSummary(
        count=int(array.size),
        mean=float(array.mean()),
        median=float(np.quantile(array, 0.5)),
        p95=float(np.quantile(array, 0.95)),
        p99=float(np.quantile(array, 0.99)),
        p999=float(np.quantile(array, 0.999)),
        max=float(array.max(initial=0.0)),
        rmse=float(np.sqrt(np.mean(np.square(array)))),
        quantiles={format_quantile(q): float(value) for q, value in zip(REPORT_QUANTILES, quantile_values, strict=True)},
    )


def compare_dumps(name: str, reference: list[Spectrum], candidate: list[Spectrum]) -> FidelityResult:
    reference_keys = [unique_key(spectrum) for spectrum in reference]
    candidate_keys = [unique_key(spectrum) for spectrum in candidate]

    reference_ms1 = [key for key in reference_keys if key[0] == 1]
    candidate_ms1 = [key for key in candidate_keys if key[0] == 1]
    reference_ms2 = [key for key in reference_keys if key[0] == 2]
    candidate_ms2 = [key for key in candidate_keys if key[0] == 2]

    by_key: dict[tuple[int, int, int], Spectrum] = {}
    for spectrum in candidate:
        key = unique_key(spectrum)
        if key in by_key:
            raise ValueError(f"Duplicate spectrum key in candidate dump: {key}")
        by_key[key] = spectrum

    mz_abs_chunks: list[np.ndarray] = []
    mz_ppm_chunks: list[np.ndarray] = []
    intensity_abs_chunks: list[np.ndarray] = []
    intensity_rel_chunks: list[np.ndarray] = []
    intensity_log_chunks: list[np.ndarray] = []
    max_abs_rt_error = 0.0
    max_abs_precursor_error = 0.0
    exact_mz_count = 0
    exact_intensity_count = 0
    matched_peaks = 0

    for spectrum in reference:
        key = unique_key(spectrum)
        other = by_key.get(key)
        if other is None:
            raise ValueError(f"Missing spectrum in candidate dump: {key}")
        if len(spectrum.mz) != len(other.mz):
            raise ValueError(f"Peak count mismatch for spectrum {key}")

        mz_diff = np.abs(spectrum.mz - other.mz)
        ref_intensity = spectrum.intensity.astype(np.float64)
        cand_intensity = other.intensity.astype(np.float64)
        intensity_diff = np.abs(ref_intensity - cand_intensity)

        positive_mz_mask = spectrum.mz > 0.0
        if np.any(positive_mz_mask):
            mz_ppm_chunks.append(mz_diff[positive_mz_mask] / spectrum.mz[positive_mz_mask] * 1e6)

        positive_mask = ref_intensity > 0.0
        if np.any(positive_mask):
            intensity_rel_chunks.append(intensity_diff[positive_mask] / ref_intensity[positive_mask])
            intensity_log_chunks.append(
                np.abs(np.log1p(ref_intensity[positive_mask]) - np.log1p(cand_intensity[positive_mask]))
            )

        mz_abs_chunks.append(mz_diff)
        intensity_abs_chunks.append(intensity_diff)
        max_abs_rt_error = max(max_abs_rt_error, abs(float(spectrum.rt_seconds) - float(other.rt_seconds)))
        max_abs_precursor_error = max(max_abs_precursor_error, abs(float(spectrum.precursor_mz) - float(other.precursor_mz)))
        exact_mz_count += int(np.count_nonzero(mz_diff == 0.0))
        exact_intensity_count += int(np.count_nonzero(intensity_diff == 0.0))
        matched_peaks += len(spectrum.mz)

    return FidelityResult(
        name=name,
        matched_spectra=len(reference),
        matched_peaks=matched_peaks,
        global_order_preserved=reference_keys == candidate_keys,
        ms1_relative_order_preserved=reference_ms1 == candidate_ms1,
        ms2_relative_order_preserved=reference_ms2 == candidate_ms2,
        max_abs_rt_error=max_abs_rt_error,
        max_abs_precursor_mz_error=max_abs_precursor_error,
        exact_mz_count=exact_mz_count,
        exact_intensity_count=exact_intensity_count,
        mz_abs=summarize_errors(np.concatenate(mz_abs_chunks) if mz_abs_chunks else np.array([], dtype=np.float64)),
        mz_ppm=summarize_errors(np.concatenate(mz_ppm_chunks) if mz_ppm_chunks else np.array([], dtype=np.float64)),
        intensity_abs=summarize_errors(
            np.concatenate(intensity_abs_chunks) if intensity_abs_chunks else np.array([], dtype=np.float64)
        ),
        intensity_rel=summarize_errors(
            np.concatenate(intensity_rel_chunks) if intensity_rel_chunks else np.array([], dtype=np.float64)
        ),
        intensity_log1p_abs=summarize_errors(
            np.concatenate(intensity_log_chunks) if intensity_log_chunks else np.array([], dtype=np.float64)
        ),
    )


def format_bytes(value: int) -> str:
    return f"{value / (1024 * 1024):.2f} MiB"


def format_percent(value: float) -> str:
    return f"{value * 100:.3f}%"


def format_interval(low: float, high: float, *, unit: str = "s") -> str:
    return f"[{low:.4f}{unit}, {high:.4f}{unit}]"


def require_tool(path_or_name: str) -> str:
    if os.sep in path_or_name:
        path = Path(path_or_name)
        if not path.exists():
            raise FileNotFoundError(path)
        return str(path)
    resolved = shutil.which(path_or_name)
    if resolved is None:
        raise FileNotFoundError(path_or_name)
    return resolved


def run_dump_mzml_quietly(input_path: Path, output_path: Path) -> None:
    with contextlib.redirect_stdout(io.StringIO()):
        dump_mzml(input_path, output_path)


def encode_lossy_command(zig_bin: Path, dump_path: Path, output_path: Path, intensity_quant: int) -> list[str]:
    return [
        str(zig_bin),
        "encode-v1",
        str(dump_path),
        "-o",
        str(output_path),
        "--lossy",
        "--intensity-quant",
        str(intensity_quant),
    ]


def parse_lossy_sweep(levels: str | None, selected_level: int) -> tuple[int, ...]:
    if not levels:
        values = list(DEFAULT_LOSSY_SWEEP_LEVELS)
    else:
        values = []
        for raw in levels.split(","):
            stripped = raw.strip()
            if not stripped:
                continue
            values.append(int(stripped))

    if selected_level not in values:
        values.append(selected_level)

    return tuple(sorted(set(values)))