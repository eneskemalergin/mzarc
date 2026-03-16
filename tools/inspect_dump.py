#!/usr/bin/env python3

from __future__ import annotations

import argparse
import statistics
import struct
from pathlib import Path


RECORD_HEADER = struct.Struct("<IfB3xdI4x")


def inspect_dump(path: Path) -> None:
    spectrum_count = 0
    total_peaks = 0
    ms1_count = 0
    ms2_count = 0
    zero_intensity_count = 0
    peak_counts: list[int] = []

    with path.open("rb") as handle:
        while True:
            header = handle.read(RECORD_HEADER.size)
            if not header:
                break
            if len(header) != RECORD_HEADER.size:
                raise ValueError("Truncated dump header")

            scan_id, rt_seconds, ms_level, precursor_mz, peak_count = RECORD_HEADER.unpack(header)
            _ = scan_id, rt_seconds, precursor_mz

            mz_bytes = peak_count * 8
            intensity_bytes = peak_count * 4

            handle.seek(mz_bytes, 1)
            intensity_blob = handle.read(intensity_bytes)
            if len(intensity_blob) != intensity_bytes:
                raise ValueError("Truncated intensity array")

            zero_intensity_count += sum(1 for (value,) in struct.iter_unpack("<f", intensity_blob) if value == 0.0)
            spectrum_count += 1
            total_peaks += peak_count
            peak_counts.append(peak_count)
            if ms_level == 1:
                ms1_count += 1
            elif ms_level == 2:
                ms2_count += 1

    median_peaks = statistics.median(peak_counts) if peak_counts else 0
    min_peaks = min(peak_counts) if peak_counts else 0
    max_peaks = max(peak_counts) if peak_counts else 0

    print(f"file: {path}")
    print(f"spectra: {spectrum_count}")
    print(f"total peaks: {total_peaks}")
    print(f"min peaks per spectrum: {min_peaks}")
    print(f"median peaks per spectrum: {median_peaks}")
    print(f"max peaks per spectrum: {max_peaks}")
    print(f"zero-intensity peaks: {zero_intensity_count}")
    print(f"ms1 count: {ms1_count}")
    print(f"ms2 count: {ms2_count}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect a V1 flat binary spectrum dump.")
    parser.add_argument("input", type=Path, help="Path to the dump file")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    inspect_dump(args.input)


if __name__ == "__main__":
    main()