#!/usr/bin/env python3
"""Pre-implementation measurement gate for Part 2b split-exponent intensity encoding.

Tests hypothesis H9 from plan/v0.2.0-plan.md against the frozen fixture:

H9: The f32 intensity exponent byte (byte 3 = sign+exp) has ≤5 bits of Shannon
    entropy on the frozen fixture.  Hard gate: >5 bits → split-exponent gains
    <3 bits/peak → do not implement.

Also reports:
  - Per-byte Shannon entropy for all 4 bytes of each f32 intensity value
  - Dominant exponent values (top-20) with frequencies and cumulative coverage
  - Estimated split-exponent payload savings vs raw f32

Output:
    benchmark/intensity_entropy_analysis.txt  — written by this script; reviewed
    by the developer as the explicit gate decision before 2b.1 encoder work begins.

Usage:
    uv run python tools/analyze_intensity_entropy.py \\
        [--input test/fixtures/frozen.bin] \\
        [--output benchmark/intensity_entropy_analysis.txt]

Exit codes:
    0  — H9 passes (byte-3 entropy ≤5 bits); proceed to 2b.1
    1  — H9 fails (byte-3 entropy >5 bits); split-exponent not viable; defer
    2  — Input file not found or corrupt
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
from collections import Counter
from pathlib import Path

RECORD_HEADER = struct.Struct("<IfB3xdI4x")

# Decision gate threshold from plan H9
BYTE3_ENTROPY_THRESHOLD = 5.0  # bits
# Top exponent values to display in the report
TOP_N_EXPONENTS = 20
# Required cumulative coverage to display in summary
COVERAGE_TARGETS = (0.50, 0.80, 0.90, 0.95, 0.99)


def _shannon_entropy_bits(counts: Counter) -> float:
    """Shannon entropy in bits from a symbol counter."""
    total = sum(counts.values())
    if total == 0:
        return 0.0
    entropy = 0.0
    for n in counts.values():
        if n > 0:
            p = n / total
            entropy -= p * math.log2(p)
    return entropy


def read_intensities(path: Path) -> list[int]:
    """Read all intensity f32 values from a flat binary dump and return as raw u32 bits."""
    raw_bits: list[int] = []
    with path.open("rb") as fh:
        while True:
            hdr = fh.read(RECORD_HEADER.size)
            if not hdr:
                break
            if len(hdr) != RECORD_HEADER.size:
                raise ValueError(f"Truncated record header at offset {fh.tell()}")
            _, _, _, _, peak_count = RECORD_HEADER.unpack(hdr)
            fh.seek(peak_count * 8, 1)  # skip m/z f64 array
            int_blob = fh.read(peak_count * 4)
            if len(int_blob) != peak_count * 4:
                raise ValueError("Truncated intensity blob")
            for (bits,) in struct.iter_unpack("<I", int_blob):
                raw_bits.append(bits)
    return raw_bits


def analyze(raw_bits: list[int]) -> dict:
    """Compute per-byte entropy and exponent distribution from raw u32 intensity bits."""
    n_peaks = len(raw_bits)

    # Per-byte counters: byte 0 = LSB mantissa, byte 3 = sign+exponent
    byte_counters: list[Counter] = [Counter() for _ in range(4)]
    exp_counter: Counter = Counter()  # 8-bit exponent field (bits 23..30)
    sign_counter: Counter = Counter()  # 1-bit sign field (bit 31)

    for bits in raw_bits:
        byte_counters[0][bits & 0xFF] += 1
        byte_counters[1][(bits >> 8) & 0xFF] += 1
        byte_counters[2][(bits >> 16) & 0xFF] += 1
        byte_counters[3][(bits >> 24) & 0xFF] += 1
        exp_counter[(bits >> 23) & 0xFF] += 1   # 8-bit exponent
        sign_counter[(bits >> 31) & 0x1] += 1   # sign bit

    entropies = [_shannon_entropy_bits(bc) for bc in byte_counters]

    # FOR bit-width estimate for the exponent stream: log2(max_exp - min_exp + 1)
    all_exps = list(exp_counter.keys())
    min_exp = min(all_exps) if all_exps else 0
    max_exp = max(all_exps) if all_exps else 0
    exp_range = max_exp - min_exp
    for_bits_exp = max(1, exp_range.bit_length()) if exp_range > 0 else 1

    # Estimated savings: raw f32 = 4 bytes/peak = 32 bits/peak
    # Split-exponent: FOR-packed exponent + raw 3-byte mantissa
    # FOR-packed exponent: (for_bits_exp * n_peaks) / 8 bytes
    # Mantissa raw: 3 * n_peaks bytes
    raw_bytes = 4 * n_peaks
    split_exponent_bytes = math.ceil(for_bits_exp * n_peaks / 8) + 3 * n_peaks
    savings_bytes = raw_bytes - split_exponent_bytes
    savings_pct = 100.0 * savings_bytes / raw_bytes if raw_bytes > 0 else 0.0

    # Coverage by exponent value
    total = sum(exp_counter.values())
    top_exps = sorted(exp_counter.items(), key=lambda kv: -kv[1])[:TOP_N_EXPONENTS]
    coverage_table: list[tuple[int, int, float, float]] = []  # exp, count, pct, cumulative
    cumulative = 0.0
    for exp_val, count in top_exps:
        pct = 100.0 * count / total
        cumulative += pct
        coverage_table.append((exp_val, count, pct, cumulative))

    # How many distinct exponent values are needed to cover each target
    sorted_exps = sorted(exp_counter.items(), key=lambda kv: -kv[1])
    coverage_needed: dict[float, int] = {}
    running = 0.0
    for target in sorted(COVERAGE_TARGETS):
        coverage_needed[target] = 0
    ci = 0
    cum = 0.0
    for i, (_, c) in enumerate(sorted_exps):
        cum += 100.0 * c / total
        for target in COVERAGE_TARGETS:
            if target not in [k for k, v in coverage_needed.items() if v > 0]:
                if cum >= target * 100:
                    coverage_needed[target] = i + 1

    return {
        "n_peaks": n_peaks,
        "entropies": entropies,
        "for_bits_exp": for_bits_exp,
        "min_exp": min_exp,
        "max_exp": max_exp,
        "exp_range": exp_range,
        "raw_bytes": raw_bytes,
        "split_exponent_bytes": split_exponent_bytes,
        "savings_bytes": savings_bytes,
        "savings_pct": savings_pct,
        "coverage_table": coverage_table,
        "coverage_needed": coverage_needed,
        "sign_neg_count": sign_counter.get(1, 0),
        "total_exp_symbols": total,
    }


def format_report(path: Path, result: dict) -> str:
    lines: list[str] = []
    w = lines.append

    w("=" * 72)
    w("INTENSITY ENTROPY ANALYSIS — Part 2b.0 Measurement Gate")
    w(f"Input: {path}")
    w("=" * 72)
    w("")

    n = result["n_peaks"]
    w(f"Total peaks analyzed : {n:,}")
    w(f"Negative intensities : {result['sign_neg_count']:,} "
      f"({100.0 * result['sign_neg_count'] / n:.2f}% — should be 0 for MS data)")
    w("")

    w("-" * 72)
    w("PER-BYTE SHANNON ENTROPY (f32 intensity, IEEE 754 layout)")
    w(f"  Byte 0 (mantissa LSB) : {result['entropies'][0]:.4f} bits  (expect ~8)")
    w(f"  Byte 1 (mantissa mid) : {result['entropies'][1]:.4f} bits  (expect ~8)")
    w(f"  Byte 2 (mantissa+exp) : {result['entropies'][2]:.4f} bits  (expect ~5-8)")
    w(f"  Byte 3 (sign+exp MSB) : {result['entropies'][3]:.4f} bits  ← H9 gate")
    w("")

    passed = result["entropies"][3] <= BYTE3_ENTROPY_THRESHOLD
    w(f"H9 gate threshold      : ≤{BYTE3_ENTROPY_THRESHOLD:.1f} bits")
    w(f"H9 gate result         : {'PASS ✓' if passed else 'FAIL ✗'} "
      f"(byte-3 entropy = {result['entropies'][3]:.4f} bits)")
    if passed:
        w("DECISION               : PROCEED to Part 2b.1 (encoder implementation)")
    else:
        w("DECISION               : STOP — split-exponent not viable on this dataset;")
        w("                         defer to v0.3.0 pending analysis of dataset diversity")
    w("")

    w("-" * 72)
    w("EXPONENT FIELD ANALYSIS (8-bit field, bits 23..30 of f32)")
    w(f"  Exponent range : {result['min_exp']} – {result['max_exp']} "
      f"(span = {result['exp_range']} values)")
    w(f"  FOR bit width  : {result['for_bits_exp']} bits  "
      f"(ceil(log2({result['exp_range']} + 1)))")
    w("")

    w(f"  Top-{TOP_N_EXPONENTS} exponent values (by frequency):")
    w(f"  {'Exp':>5}  {'Biased':>7}  {'Decoded':>12}  {'Count':>10}  {'%':>6}  {'Cumul%':>7}")
    w(f"  {'-'*5}  {'-'*7}  {'-'*12}  {'-'*10}  {'-'*6}  {'-'*7}")
    for exp_val, count, pct, cumul in result["coverage_table"]:
        # Decode IEEE 754 biased exponent: actual exponent = exp_val - 127
        actual_exp = exp_val - 127
        decoded = f"2^{actual_exp}" if exp_val > 0 else "subnormal"
        w(f"  {exp_val:>5}  {actual_exp:>+7}  {decoded:>12}  {count:>10,}  {pct:>6.2f}%  {cumul:>6.2f}%")
    w("")

    w("  Exponent values needed to cover:")
    for target, needed in sorted(result["coverage_needed"].items()):
        w(f"    {target*100:5.0f}% of peaks : {needed:3d} distinct exponent values")
    w("")

    w("-" * 72)
    w("ESTIMATED SPLIT-EXPONENT PAYLOAD SAVINGS")
    w(f"  Raw f32 intensity payload      : {result['raw_bytes']:>12,} bytes  "
      f"({result['raw_bytes']/1024/1024:.3f} MiB)")
    w(f"  Split-exponent payload         : {result['split_exponent_bytes']:>12,} bytes  "
      f"({result['split_exponent_bytes']/1024/1024:.3f} MiB)")
    w(f"    FOR-packed exponent stream   : "
      f"{math.ceil(result['for_bits_exp'] * n / 8):>12,} bytes  "
      f"({result['for_bits_exp']} bits × {n:,} peaks / 8)")
    w(f"    Raw 3-byte mantissa stream   : {3 * n:>12,} bytes  (3 bytes × {n:,} peaks)")
    w(f"  Savings                        : {result['savings_bytes']:>12,} bytes  "
      f"({result['savings_pct']:.1f}%)")
    w(f"  Savings in MiB                 : {result['savings_bytes']/1024/1024:.3f} MiB")
    w("")
    if result["savings_bytes"] > 0:
        w(f"  Note: Savings estimate is FOR-only (no rANS). Adding rANS on the")
        w(f"  exponent stream will improve further (exponent entropy =")
        w(f"  {result['entropies'][3]:.2f} bits < FOR bits = {result['for_bits_exp']}).")
    w("")
    w("=" * 72)

    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Part 2b.0 measurement gate: intensity entropy analysis."
    )
    p.add_argument(
        "--input",
        type=Path,
        default=Path("test/fixtures/frozen.bin"),
        help="Flat binary dump to analyze (default: test/fixtures/frozen.bin)",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=Path("benchmark/intensity_entropy_analysis.txt"),
        help="Path for the written report (default: benchmark/intensity_entropy_analysis.txt)",
    )
    return p


def main() -> None:
    args = build_parser().parse_args()

    if not args.input.exists():
        print(f"ERROR: input file not found: {args.input}", file=sys.stderr)
        sys.exit(2)

    print(f"Reading intensities from {args.input} …")
    try:
        raw_bits = read_intensities(args.input)
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)

    print(f"Analyzing {len(raw_bits):,} peaks …")
    result = analyze(raw_bits)
    report = format_report(args.input, result)

    print(report)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report + "\n")
    print(f"\nReport written to {args.output}")

    byte3_entropy = result["entropies"][3]
    if byte3_entropy <= BYTE3_ENTROPY_THRESHOLD:
        print(f"\nH9 PASS: byte-3 entropy = {byte3_entropy:.4f} bits ≤ {BYTE3_ENTROPY_THRESHOLD} bits")
        print("→ Proceed to Part 2b.1")
        sys.exit(0)
    else:
        print(f"\nH9 FAIL: byte-3 entropy = {byte3_entropy:.4f} bits > {BYTE3_ENTROPY_THRESHOLD} bits")
        print("→ Split-exponent not viable. Defer to v0.3.0.")
        sys.exit(1)


if __name__ == "__main__":
    main()
