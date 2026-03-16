#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path

import numpy as np
from pyteomics import mzml


RECORD_HEADER = struct.Struct("<IfB3xdI4x")
SCAN_ID_RE = re.compile(r"scan=(\d+)")


def _scan_id_from_spectrum(spectrum: dict) -> int:
    spectrum_id = spectrum.get("id")
    if isinstance(spectrum_id, str):
        match = SCAN_ID_RE.search(spectrum_id)
        if match:
            return int(match.group(1))

    index = spectrum.get("index")
    if index is not None:
        return int(index)

    raise ValueError("Could not determine scan id from spectrum")


def _rt_to_seconds(scan_start_time: object) -> float:
    if scan_start_time is None:
        return 0.0

    value = float(scan_start_time)
    unit_info = getattr(scan_start_time, "unit_info", None)
    if unit_info in {"minute", "minutes", "min"}:
        return value * 60.0
    return value


def _precursor_mz_from_spectrum(spectrum: dict) -> float:
    precursor_list = spectrum.get("precursorList") or {}
    precursors = precursor_list.get("precursor") or []
    if not precursors:
        return 0.0

    first_precursor = precursors[0]
    selected_ions = (first_precursor.get("selectedIonList") or {}).get("selectedIon") or []
    if not selected_ions:
        return 0.0

    return float(selected_ions[0].get("selected ion m/z", 0.0) or 0.0)


def _normalized_arrays(spectrum: dict) -> tuple[np.ndarray, np.ndarray]:
    mz_array = np.asarray(spectrum.get("m/z array", ()), dtype=np.float64)
    intensity_array = np.asarray(spectrum.get("intensity array", ()), dtype=np.float32)

    if mz_array.size != intensity_array.size:
        raise ValueError(
            f"m/z and intensity arrays differ in length: {mz_array.size} != {intensity_array.size}"
        )

    if mz_array.size == 0:
        return mz_array, intensity_array

    if np.all(mz_array[:-1] <= mz_array[1:]):
        return mz_array, intensity_array

    order = np.argsort(mz_array, kind="mergesort")
    return mz_array[order], intensity_array[order]


def dump_mzml(input_path: Path, output_path: Path) -> None:
    total_spectra = 0
    total_peaks = 0
    ms1_count = 0
    ms2_count = 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as out_handle:
        with mzml.read(str(input_path)) as reader:
            for spectrum in reader:
                scan = ((spectrum.get("scanList") or {}).get("scan") or [{}])[0]
                rt_seconds = _rt_to_seconds(scan.get("scan start time"))
                scan_id = _scan_id_from_spectrum(spectrum)
                ms_level = int(spectrum.get("ms level", 0) or 0)
                precursor_mz = _precursor_mz_from_spectrum(spectrum) if ms_level > 1 else 0.0
                mz_array, intensity_array = _normalized_arrays(spectrum)
                peak_count = int(mz_array.size)

                out_handle.write(
                    RECORD_HEADER.pack(
                        scan_id,
                        float(rt_seconds),
                        ms_level,
                        float(precursor_mz),
                        peak_count,
                    )
                )
                out_handle.write(mz_array.astype("<f8", copy=False).tobytes(order="C"))
                out_handle.write(intensity_array.astype("<f4", copy=False).tobytes(order="C"))

                total_spectra += 1
                total_peaks += peak_count
                if ms_level == 1:
                    ms1_count += 1
                elif ms_level == 2:
                    ms2_count += 1

    output_size = output_path.stat().st_size
    print(f"input: {input_path}")
    print(f"output: {output_path}")
    print(f"spectra: {total_spectra}")
    print(f"total peaks: {total_peaks}")
    print(f"ms1 count: {ms1_count}")
    print(f"ms2 count: {ms2_count}")
    print(f"output bytes: {output_size}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Dump mzML spectra into the V1 flat binary format.")
    parser.add_argument("input", type=Path, help="Path to the source mzML file")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Path to the output binary dump")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    dump_mzml(args.input, args.output)


if __name__ == "__main__":
    main()