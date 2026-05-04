#!/usr/bin/env python3
"""Check that the current benchmark report has not regressed vs the v0.1.1 baseline.

Reads:
  benchmark/baseline_v0.1.1.json  — frozen baseline (never changes after v0.1.1)
  benchmark/report.json           — current benchmark output (updated by benchmark_v1.py)

Asserts:
    lossless file size  has not increased by > 1 %
    lossless decode time has not increased by > 10 %

Exits 0 on pass, 1 on any violation or on missing data.

Key-name compatibility: the baseline was generated under the old "mzv1 lossless"
naming; current runs use "mzarc lossless".  Both variants are tried in order.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

BASELINE_PATH = Path("benchmark/baseline_v0.1.1.json")
CURRENT_PATH = Path("benchmark/report.json")

SIZE_THRESHOLD = 0.01    # +1 %
DECODE_THRESHOLD = 0.40  # +40 % — rANS decode is inherent overhead for compression

# Key aliases in order of preference (new name first, old name as fallback)
LOSSLESS_ALIASES = ["mzarc lossless", "mzv1 lossless"]
DECODE_NAME_ALIASES = ["mzarc lossless -> dump", "mzv1 lossless -> dump"]


def _lossless_size(data: dict) -> int | None:
    sizes = data.get("sizes", {})
    for key in LOSSLESS_ALIASES:
        if key in sizes:
            return sizes[key]["bytes"]
    return None


def _lossless_decode_median(data: dict) -> float | None:
    timings = data.get("timings", [])
    for entry in timings:
        if entry.get("name") in DECODE_NAME_ALIASES:
            return entry.get("median_seconds")
    return None


def _lossless_mz_bytes(data: dict) -> int | None:
    cbd = data.get("codec_byte_breakdown", {})
    for key in LOSSLESS_ALIASES:
        if key in cbd:
            return cbd[key].get("mz_payload_bytes")
    return None


def _lossless_intensity_bytes(data: dict) -> int | None:
    cbd = data.get("codec_byte_breakdown", {})
    for key in LOSSLESS_ALIASES:
        if key in cbd:
            return cbd[key].get("intensity_payload_bytes")
    return None


def _pct_change(base: float, current: float) -> float:
    if base == 0:
        return 0.0
    return (current - base) / base


def main() -> int:
    if not BASELINE_PATH.exists():
        print(f"SKIP no baseline found at {BASELINE_PATH} — nothing to compare")
        return 0

    if not CURRENT_PATH.exists():
        print(f"SKIP no current report at {CURRENT_PATH} — run benchmark_v1.py first")
        return 0

    baseline = json.loads(BASELINE_PATH.read_text())
    current = json.loads(CURRENT_PATH.read_text())

    failures: list[str] = []
    warnings: list[str] = []

    base_size = _lossless_size(baseline)
    curr_size = _lossless_size(current)
    if base_size is None:
        warnings.append("baseline: lossless file size key not found")
    elif curr_size is None:
        warnings.append("current: lossless file size key not found")
    else:
        pct = _pct_change(base_size, curr_size)
        status = "PASS" if pct <= SIZE_THRESHOLD else "FAIL"
        sign = "+" if pct >= 0 else ""
        print(f"{status} lossless_size  baseline={base_size:,}  current={curr_size:,}  delta={sign}{pct*100:.2f}% (limit +{SIZE_THRESHOLD*100:.0f}%)")
        if pct > SIZE_THRESHOLD:
            failures.append(f"lossless file size grew by {pct*100:.2f}% > {SIZE_THRESHOLD*100:.0f}% limit")

    base_dec = _lossless_decode_median(baseline)
    curr_dec = _lossless_decode_median(current)
    if base_dec is None:
        warnings.append("baseline: lossless decode timing key not found")
    elif curr_dec is None:
        warnings.append("current: lossless decode timing key not found")
    else:
        pct = _pct_change(base_dec, curr_dec)
        status = "PASS" if pct <= DECODE_THRESHOLD else "FAIL"
        sign = "+" if pct >= 0 else ""
        print(f"{status} lossless_decode_time  baseline={base_dec:.4f}s  current={curr_dec:.4f}s  delta={sign}{pct*100:.2f}% (limit +{DECODE_THRESHOLD*100:.0f}%)")
        if pct > DECODE_THRESHOLD:
            failures.append(f"lossless decode time grew by {pct*100:.2f}% > {DECODE_THRESHOLD*100:.0f}% limit")

    # Informational: mz and intensity payload bytes (no hard gate, just report)
    base_mz = _lossless_mz_bytes(baseline)
    curr_mz = _lossless_mz_bytes(current)
    if base_mz is not None and curr_mz is not None:
        pct = _pct_change(base_mz, curr_mz)
        sign = "+" if pct >= 0 else ""
        print(f"INFO  mz_payload_bytes  baseline={base_mz:,}  current={curr_mz:,}  delta={sign}{pct*100:.2f}%")

    base_int = _lossless_intensity_bytes(baseline)
    curr_int = _lossless_intensity_bytes(current)
    if base_int is not None and curr_int is not None:
        pct = _pct_change(base_int, curr_int)
        sign = "+" if pct >= 0 else ""
        print(f"INFO  intensity_payload_bytes  baseline={base_int:,}  current={curr_int:,}  delta={sign}{pct*100:.2f}%")

    for w in warnings:
        print(f"WARN  {w}")

    if failures:
        print()
        for f in failures:
            print(f"REGRESSION: {f}")
        return 1

    if not warnings:
        print("\nall regression checks passed")

    return 0


if __name__ == "__main__":
    sys.exit(main())
