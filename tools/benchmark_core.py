from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np


RECORD_HEADER = struct.Struct("<IfB3xdI4x")
REPORT_QUANTILES = (0.5, 0.9, 0.95, 0.99, 0.999, 1.0)
DEFAULT_LOSSY_LEVEL = 16384
DEFAULT_LOSSY_SWEEP_LEVELS = (256, 1024, 4096, 16384)
REPO_ROOT = Path(__file__).resolve().parents[1]


def repo_relative_path(path: Path) -> str:
    return Path(os.path.relpath(path, REPO_ROOT)).as_posix()


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
