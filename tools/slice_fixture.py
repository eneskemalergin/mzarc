#!/usr/bin/env python3
"""Slice a 1,000-spectrum frozen fixture from a reference binary dump.

Composition constraints (verified after generation):
  >= 100 MS1 spectra
  >= 800 MS2 spectra from >= 3 distinct isolation windows
  >= 10 sparse spectra (< 5 peaks)
  >= 5 dense spectra (> 1,000 peaks)
  >= 1 empty spectrum (0 peaks)
  exactly 1,000 spectra total

Sparse and empty spectra are fabricated deterministically (random.seed(42))
because the source dump (min 16 peaks) contains no such spectra naturally.
Fabricated spectra are appended after the real selection; scan_ids start
above the maximum real scan_id to avoid collisions.

Usage:
    uv run python tools/slice_fixture.py \\
        data/PXD075509/15HCD_1.bin fixtures/frozen.bin
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import random
import struct
import sys
from pathlib import Path

TARGET_COUNT = 1_000
MIN_MS1 = 100
MIN_MS2 = 800
MIN_WINDOWS = 3
MIN_SPARSE_COUNT = 10   # spectra with 0 < peak_count < 5
MIN_DENSE_COUNT = 5     # spectra with peak_count > 1_000
MIN_EMPTY_COUNT = 1     # spectra with peak_count == 0

RECORD_HEADER = struct.Struct("<IfB3xdI4x")   # scan_id u32, rt f32, ms_level u8, pad3, precursor_mz f64, peak_count u32, pad4


@dataclasses.dataclass
class Spectrum:
    scan_id: int
    rt_seconds: float
    ms_level: int
    precursor_mz: float
    mz: list[float]
    intensity: list[float]

    @property
    def peak_count(self) -> int:
        return len(self.mz)

    @property
    def window_id(self) -> int:
        """Isolation window as integer Da (same binning as the codec)."""
        return round(self.precursor_mz)


def read_dump(path: Path) -> list[Spectrum]:
    spectra: list[Spectrum] = []
    with path.open("rb") as fh:
        while True:
            hdr = fh.read(RECORD_HEADER.size)
            if not hdr:
                break
            if len(hdr) != RECORD_HEADER.size:
                raise ValueError(f"Truncated header at spectrum {len(spectra)}")
            scan_id, rt, ms_level, precursor_mz, peak_count = RECORD_HEADER.unpack(hdr)
            mz_blob = fh.read(peak_count * 8)
            int_blob = fh.read(peak_count * 4)
            if len(mz_blob) != peak_count * 8 or len(int_blob) != peak_count * 4:
                raise ValueError(f"Truncated peak data at spectrum {len(spectra)}")
            mz = list(struct.unpack(f"<{peak_count}d", mz_blob))
            intensity = list(struct.unpack(f"<{peak_count}f", int_blob))
            spectra.append(Spectrum(scan_id, rt, ms_level, precursor_mz, mz, intensity))
    return spectra


def write_dump(path: Path, spectra: list[Spectrum]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fh:
        for s in spectra:
            fh.write(RECORD_HEADER.pack(s.scan_id, s.rt_seconds, s.ms_level, s.precursor_mz, s.peak_count))
            for m in s.mz:
                fh.write(struct.pack("<d", m))
            for v in s.intensity:
                fh.write(struct.pack("<f", v))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(65536):
            h.update(chunk)
    return h.hexdigest()


def _fabricate_sparse(ref: Spectrum, rng: random.Random, next_scan_id: int, peak_count: int = 2) -> Spectrum:
    """Deterministic sparse MS2 spectrum with 2 peaks, metadata from ref."""
    mz_base = 100.0 + rng.random() * 800.0
    mz = sorted(mz_base + rng.random() * 2.0 for _ in range(peak_count))
    intensity = [float(int(rng.random() * 9000) + 1000) for _ in range(peak_count)]
    return Spectrum(
        scan_id=next_scan_id,
        rt_seconds=ref.rt_seconds,
        ms_level=2,
        precursor_mz=ref.precursor_mz,
        mz=list(mz),
        intensity=intensity,
    )


def _fabricate_empty(ref: Spectrum, next_scan_id: int) -> Spectrum:
    """Empty MS2 spectrum (0 peaks), metadata from ref."""
    return Spectrum(
        scan_id=next_scan_id,
        rt_seconds=ref.rt_seconds,
        ms_level=2,
        precursor_mz=ref.precursor_mz,
        mz=[],
        intensity=[],
    )


def select_fixture(all_spectra: list[Spectrum]) -> list[Spectrum]:
    rng = random.Random(42)

    ms1 = [s for s in all_spectra if s.ms_level == 1]
    ms2 = [s for s in all_spectra if s.ms_level == 2]
    dense = [s for s in all_spectra if s.peak_count > 1_000]

    # Windows sorted by count descending for reproducible selection
    from collections import defaultdict
    window_map: dict[int, list[Spectrum]] = defaultdict(list)
    for s in ms2:
        window_map[s.window_id].append(s)
    windows_by_size = sorted(window_map.items(), key=lambda x: -len(x[1]))

    if len(windows_by_size) < MIN_WINDOWS:
        raise ValueError(f"Source has only {len(windows_by_size)} isolation windows; need {MIN_WINDOWS}")

    # --- 1. Must-have dense real spectra (up to 10 for safety headroom) ---
    selected_dense = dense[:max(MIN_DENSE_COUNT, 10)]

    # --- 2. Must-have MS1 spectra (step-sampled for RT spread) ---
    ms1_step = max(1, len(ms1) // MIN_MS1)
    selected_ms1 = ms1[::ms1_step][:MIN_MS1]
    if len(selected_ms1) < MIN_MS1:
        # top-up in order
        in_selected = set(id(s) for s in selected_ms1)
        for s in ms1:
            if len(selected_ms1) >= MIN_MS1:
                break
            if id(s) not in in_selected:
                selected_ms1.append(s)
                in_selected.add(id(s))

    # --- 3. Real MS2 from >= 3 windows ---
    # Reserve budget: TARGET_COUNT - fabricated(11) - dense - ms1
    fabricated_count = 1 + MIN_SPARSE_COUNT   # 1 empty + 10 sparse
    real_budget = TARGET_COUNT - fabricated_count - len(selected_dense) - len(selected_ms1)

    already_ids = {id(s) for s in selected_dense} | {id(s) for s in selected_ms1}

    # Distribute real_budget across top windows proportionally
    top_windows = windows_by_size[:max(MIN_WINDOWS, 10)]  # use top 10 for variety
    total_in_top = sum(len(spectra) for _, spectra in top_windows)
    selected_ms2: list[Spectrum] = []
    for _wid, window_spectra in top_windows:
        want = max(1, int(real_budget * len(window_spectra) / total_in_top))
        step = max(1, len(window_spectra) // want)
        for s in window_spectra[::step]:
            if len(selected_ms2) >= real_budget:
                break
            if id(s) not in already_ids:
                selected_ms2.append(s)
                already_ids.add(id(s))
    # Top up if still short (fill from any remaining MS2 in order)
    if len(selected_ms2) < real_budget:
        for s in ms2:
            if len(selected_ms2) >= real_budget:
                break
            if id(s) not in already_ids:
                selected_ms2.append(s)
                already_ids.add(id(s))

    # --- 4. Fabricated sparse and empty spectra ---
    # Pick reference spectra from 3 different windows for the fabricated spectra
    fab_refs = [windows_by_size[i][1][0] for i in range(min(3, len(windows_by_size)))]
    max_scan_id = max(s.scan_id for s in all_spectra)
    next_scan_id = max_scan_id + 1

    fabricated: list[Spectrum] = []

    # 1 empty spectrum
    fabricated.append(_fabricate_empty(fab_refs[0], next_scan_id))
    next_scan_id += 1

    # 10 sparse spectra spread across 3 windows
    for i in range(MIN_SPARSE_COUNT):
        ref = fab_refs[i % len(fab_refs)]
        fabricated.append(_fabricate_sparse(ref, rng, next_scan_id))
        next_scan_id += 1

    # --- 5. Assemble and trim to exactly TARGET_COUNT ---
    result = list(selected_ms1) + list(selected_dense) + list(selected_ms2) + fabricated

    # Trim or top up to exactly TARGET_COUNT
    if len(result) > TARGET_COUNT:
        # Keep fabricated (last 11) + dense + ms1; trim ms2
        real_parts = list(selected_ms1) + list(selected_dense) + list(selected_ms2)
        trim_to = TARGET_COUNT - fabricated_count
        result = real_parts[:trim_to] + fabricated
    elif len(result) < TARGET_COUNT:
        shortage = TARGET_COUNT - len(result)
        for s in all_spectra:
            if shortage == 0:
                break
            if id(s) not in already_ids:
                result.append(s)
                already_ids.add(id(s))
                shortage -= 1

    assert len(result) == TARGET_COUNT, f"Got {len(result)} spectra, want {TARGET_COUNT}"
    return result


def verify_constraints(fixture: list[Spectrum]) -> None:
    ms1_count = sum(1 for s in fixture if s.ms_level == 1)
    ms2_count = sum(1 for s in fixture if s.ms_level == 2)
    windows = {s.window_id for s in fixture if s.ms_level == 2}
    sparse = sum(1 for s in fixture if 0 < s.peak_count < 5)
    dense = sum(1 for s in fixture if s.peak_count > 1_000)
    empty = sum(1 for s in fixture if s.peak_count == 0)

    errors: list[str] = []
    if len(fixture) != TARGET_COUNT:
        errors.append(f"total spectra: {len(fixture)} != {TARGET_COUNT}")
    if ms1_count < MIN_MS1:
        errors.append(f"ms1 count: {ms1_count} < {MIN_MS1}")
    if ms2_count < MIN_MS2:
        errors.append(f"ms2 count: {ms2_count} < {MIN_MS2}")
    if len(windows) < MIN_WINDOWS:
        errors.append(f"isolation windows: {len(windows)} < {MIN_WINDOWS}")
    if sparse < MIN_SPARSE_COUNT:
        errors.append(f"sparse spectra: {sparse} < {MIN_SPARSE_COUNT}")
    if dense < MIN_DENSE_COUNT:
        errors.append(f"dense spectra: {dense} < {MIN_DENSE_COUNT}")
    if empty < MIN_EMPTY_COUNT:
        errors.append(f"empty spectra: {empty} < {MIN_EMPTY_COUNT}")

    if errors:
        raise AssertionError("Fixture constraints not met:\n  " + "\n  ".join(errors))

    print(f"  total: {len(fixture)}")
    print(f"  ms1: {ms1_count}  ms2: {ms2_count}")
    print(f"  isolation windows: {len(windows)}")
    print(f"  sparse (<5 peaks): {sparse}")
    print(f"  dense (>1000 peaks): {dense}")
    print(f"  empty (0 peaks): {empty}")
    print(f"  min peaks: {min(s.peak_count for s in fixture)}")
    print(f"  max peaks: {max(s.peak_count for s in fixture)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="Source binary dump (e.g. data/PXD075509/15HCD_1.bin)")
    parser.add_argument("output", type=Path, help="Output fixture path (e.g. fixtures/frozen.bin)")
    args = parser.parse_args()

    print(f"Reading {args.source} ...", flush=True)
    all_spectra = read_dump(args.source)
    print(f"  {len(all_spectra)} spectra loaded")

    print("Selecting fixture ...", flush=True)
    fixture = select_fixture(all_spectra)

    print("Verifying constraints ...", flush=True)
    verify_constraints(fixture)

    print(f"Writing {args.output} ...", flush=True)
    write_dump(args.output, fixture)

    digest = sha256_file(args.output)
    size_mib = args.output.stat().st_size / (1024 * 1024)
    print(f"  size: {size_mib:.2f} MiB")
    print(f"  sha256: {digest}")


if __name__ == "__main__":
    main()
