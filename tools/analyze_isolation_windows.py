#!/usr/bin/env python3
"""Pre-implementation measurement gate for Part 2 cross-spectrum delta.

Tests hypotheses H1, H2, H3 from plan/v0.2.0-plan.md against the 15HCD_1 dataset.

H1: Consecutive spectra in the same isolation window share >70% of peak positions
    (within 5 mDa).  Hard gate: <50% mean overlap → cross-spectrum delta not viable.

H2: Cross-spectrum m/z residuals require fewer bits than intra-spectrum residuals in
    the majority of DIA windows.  Hard gate: <10% bit-width reduction → do not implement.

H3: Peak-count CV = σ/μ within a window is <20%, making union-grid alignment practical.
    Soft gate: >20% CV → use pair-match fallback in 2.2 instead of union-grid.

Output:
    benchmark/cross_spectrum_analysis.txt  — machine-readable summary + per-window table

Usage:
    uv run python tools/analyze_isolation_windows.py \\
        [--dump data/PXD075509/15HCD_1.bin] \\
        [--output benchmark/cross_spectrum_analysis.txt] \\
        [--min-window-size 3] \\
        [--overlap-tolerance-da 0.005]
"""

from __future__ import annotations

import argparse
import math
import statistics
import struct
import sys
from pathlib import Path

RECORD_HEADER = struct.Struct("<IfB3xdI4x")
MZ_SCALE = 1_000_000_000  # 1e9 → fixed-point u64 (matches codec's lossless scale)


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def read_dump(path: Path) -> list[dict]:
    """Read binary dump. Returns list of dicts with keys:
    scan_id, rt, ms_level, precursor_mz, mz (list[float]), intensity (list[float]).
    """
    spectra = []
    with path.open("rb") as fh:
        while True:
            hdr = fh.read(RECORD_HEADER.size)
            if not hdr:
                break
            scan_id, rt, ms_level, precursor_mz, peak_count = RECORD_HEADER.unpack(hdr)
            mz_blob = fh.read(peak_count * 8)
            int_blob = fh.read(peak_count * 4)
            mz = list(struct.unpack(f"<{peak_count}d", mz_blob)) if peak_count else []
            intensity = list(struct.unpack(f"<{peak_count}f", int_blob)) if peak_count else []
            spectra.append({
                "scan_id": scan_id,
                "rt": rt,
                "ms_level": ms_level,
                "precursor_mz": precursor_mz,
                "mz": mz,
                "intensity": intensity,
                "peak_count": peak_count,
                "window_id": round(precursor_mz),
            })
    return spectra


# ---------------------------------------------------------------------------
# Bit-width helpers (Python equivalent of requiredBitWidthForSlice from plan 2.2)
# ---------------------------------------------------------------------------

def required_bit_width(values: list[int]) -> int:
    """Minimum FOR bit width for a list of non-negative integers (no allocation)."""
    if not values:
        return 0
    mn = min(values)
    mx = max(values)
    range_val = mx - mn
    if range_val == 0:
        return 0
    return math.ceil(math.log2(range_val + 1))


def mz_to_u64(mz_values: list[float]) -> list[int]:
    """Convert sorted m/z floats to sorted u64 fixed-point (scale 1e9)."""
    return [round(m * MZ_SCALE) for m in mz_values]


def intra_deltas(mz_u64: list[int]) -> list[int]:
    """Adjacent differences for a sorted u64 m/z array (intra-spectrum delta)."""
    if len(mz_u64) < 2:
        return mz_u64[:]
    return [mz_u64[0]] + [mz_u64[i] - mz_u64[i - 1] for i in range(1, len(mz_u64))]


# ---------------------------------------------------------------------------
# H1: pairwise m/z overlap
# ---------------------------------------------------------------------------

def pairwise_overlap(mz_a: list[float], mz_b: list[float], tol_da: float) -> float:
    """Fraction of peaks in mz_a that have a match within tol_da in mz_b.
    Both arrays must be sorted ascending.
    """
    if not mz_a or not mz_b:
        return 0.0
    matched = 0
    j = 0
    for m in mz_a:
        # advance j to first element >= m - tol
        while j < len(mz_b) and mz_b[j] < m - tol_da:
            j += 1
        # check if any element in [m-tol, m+tol]
        k = j
        while k < len(mz_b) and mz_b[k] <= m + tol_da:
            if abs(mz_b[k] - m) <= tol_da:
                matched += 1
                break
            k += 1
    return matched / len(mz_a)


# ---------------------------------------------------------------------------
# H2: cross-spectrum vs intra-spectrum delta bit width estimate
# ---------------------------------------------------------------------------

def cross_spectrum_bit_width(mz_a: list[float], mz_b: list[float], tol_da: float) -> tuple[int, int]:
    """Estimate cross-spectrum delta bit width for the matched peaks between two spectra.

    Returns (cross_bits, matched_count).
    Only matched pairs (within tol_da) contribute to the residual array.
    Unmatched peaks fall back to intra-spectrum delta, which is not counted here.
    """
    residuals: list[int] = []
    j = 0
    a_u64 = mz_to_u64(mz_a)
    b_u64 = mz_to_u64(mz_b)
    tol_u64 = round(tol_da * MZ_SCALE)

    for i, av in enumerate(a_u64):
        while j < len(b_u64) and b_u64[j] < av - tol_u64:
            j += 1
        k = j
        while k < len(b_u64) and b_u64[k] <= av + tol_u64:
            delta = abs(int(b_u64[k]) - int(av))
            if delta <= tol_u64:
                # absolute delta in u64 units; shift to allow sign (centre at 0)
                residuals.append(delta)
                break
            k += 1

    if not residuals:
        return 0, 0
    # treat residuals as unsigned offsets from 0 (they are absolute differences)
    return required_bit_width(residuals), len(residuals)


# ---------------------------------------------------------------------------
# Per-window analysis
# ---------------------------------------------------------------------------

def analyze_window(spectra: list[dict], tol_da: float) -> dict:
    """Compute H1/H2/H3 stats for one isolation window (already sorted by RT)."""
    peak_counts = [s["peak_count"] for s in spectra]
    n = len(spectra)

    # H3: peak count statistics
    mean_peaks = statistics.mean(peak_counts)
    stdev_peaks = statistics.stdev(peak_counts) if n >= 2 else 0.0
    cv = stdev_peaks / mean_peaks if mean_peaks > 0 else 0.0

    # H1 + H2: consecutive pairwise analysis
    overlaps: list[float] = []
    intra_bits_total = 0
    cross_bits_total = 0
    intra_spectrum_count = 0
    cross_matched_total = 0

    for i in range(n - 1):
        a = spectra[i]
        b = spectra[i + 1]
        if not a["mz"] or not b["mz"]:
            continue

        # H1
        ov = pairwise_overlap(a["mz"], b["mz"], tol_da)
        overlaps.append(ov)

        # H2 — intra-spectrum bit width for spectrum b
        b_u64 = mz_to_u64(b["mz"])
        b_deltas = intra_deltas(b_u64)
        intra_bw = required_bit_width(b_deltas)
        intra_bits_total += intra_bw
        intra_spectrum_count += 1

        # H2 — cross-spectrum bit width estimate
        cross_bw, matched = cross_spectrum_bit_width(a["mz"], b["mz"], tol_da)
        if matched > 0:
            cross_bits_total += cross_bw
            cross_matched_total += matched

    mean_overlap = statistics.mean(overlaps) if overlaps else 0.0
    mean_intra_bw = intra_bits_total / intra_spectrum_count if intra_spectrum_count else 0.0
    mean_cross_bw = cross_bits_total / intra_spectrum_count if intra_spectrum_count else 0.0
    bit_reduction = 1.0 - (mean_cross_bw / mean_intra_bw) if mean_intra_bw > 0 else 0.0

    return {
        "n_spectra": n,
        "peak_count_min": min(peak_counts),
        "peak_count_max": max(peak_counts),
        "peak_count_mean": mean_peaks,
        "peak_count_stdev": stdev_peaks,
        "cv": cv,
        "mean_overlap": mean_overlap,
        "mean_intra_bw": mean_intra_bw,
        "mean_cross_bw": mean_cross_bw,
        "bit_reduction": bit_reduction,
        "cross_matched_total": cross_matched_total,
    }


# ---------------------------------------------------------------------------
# Hypothesis verdicts
# ---------------------------------------------------------------------------

H1_PASS = 0.70
H1_HARD_FAIL = 0.50
H2_PASS = 0.30   # >30% reduction
H2_HARD_FAIL = 0.10
H3_PASS = 0.20   # CV < 20%


def verdict(value: float, pass_thresh: float, fail_thresh: float,
            higher_is_better: bool = True) -> str:
    if higher_is_better:
        if value >= pass_thresh:
            return "PASS"
        if value < fail_thresh:
            return "HARD_FAIL"
        return "MARGINAL"
    else:
        if value < pass_thresh:
            return "PASS"
        if value >= fail_thresh:
            return "HARD_FAIL"
        return "MARGINAL"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", default="data/PXD075509/15HCD_1.bin",
                        help="Path to binary dump (default: data/PXD075509/15HCD_1.bin)")
    parser.add_argument("--output", default="benchmark/cross_spectrum_analysis.txt",
                        help="Output summary file (default: benchmark/cross_spectrum_analysis.txt)")
    parser.add_argument("--min-window-size", type=int, default=3,
                        help="Minimum spectra per window to include in analysis (default: 3)")
    parser.add_argument("--overlap-tolerance-da", type=float, default=0.005,
                        help="m/z match tolerance for H1 overlap (default: 0.005 = 5 mDa)")
    args = parser.parse_args()

    dump_path = Path(args.dump)
    if not dump_path.exists():
        sys.stderr.write(f"error: dump file not found: {dump_path}\n")
        return 1

    sys.stderr.write(f"reading {dump_path} ...\n")
    spectra = read_dump(dump_path)
    ms2 = [s for s in spectra if s["ms_level"] == 2]
    sys.stderr.write(f"loaded {len(spectra)} spectra ({len(ms2)} MS2)\n")

    # Group by window, sort by RT within each window
    windows: dict[int, list[dict]] = {}
    for s in ms2:
        windows.setdefault(s["window_id"], []).append(s)
    for wid in windows:
        windows[wid].sort(key=lambda s: s["rt"])

    # Filter to windows with enough spectra
    qualified = {wid: ss for wid, ss in windows.items()
                 if len(ss) >= args.min_window_size}

    sys.stderr.write(f"windows total: {len(windows)}, with >= {args.min_window_size} spectra: {len(qualified)}\n")

    # Analyze each qualified window
    results: dict[int, dict] = {}
    for wid, ss in sorted(qualified.items()):
        results[wid] = analyze_window(ss, args.overlap_tolerance_da)
        sys.stderr.write(f"  w={wid:5d}: n={results[wid]['n_spectra']:3d}  "
                         f"overlap={results[wid]['mean_overlap']:.2%}  "
                         f"cv={results[wid]['cv']:.2%}  "
                         f"bit_red={results[wid]['bit_reduction']:.2%}\n")

    if not results:
        sys.stderr.write("no qualified windows — cannot evaluate hypotheses\n")
        return 1

    # Aggregate stats across all qualified windows
    all_overlaps = [r["mean_overlap"] for r in results.values()]
    all_cvs = [r["cv"] for r in results.values()]
    all_bit_reds = [r["bit_reduction"] for r in results.values()]
    all_n = [r["n_spectra"] for r in results.values()]

    overall_mean_overlap = statistics.mean(all_overlaps)
    overall_median_overlap = statistics.median(all_overlaps)
    overall_mean_cv = statistics.mean(all_cvs)
    overall_median_cv = statistics.median(all_cvs)
    overall_mean_bit_red = statistics.mean(all_bit_reds)
    overall_median_bit_red = statistics.median(all_bit_reds)

    # Fraction of windows passing each hard gate
    frac_h1_pass = sum(1 for o in all_overlaps if o >= H1_PASS) / len(all_overlaps)
    frac_h1_hardfail = sum(1 for o in all_overlaps if o < H1_HARD_FAIL) / len(all_overlaps)
    frac_h2_pass = sum(1 for r in all_bit_reds if r >= H2_PASS) / len(all_bit_reds)
    frac_h2_hardfail = sum(1 for r in all_bit_reds if r < H2_HARD_FAIL) / len(all_bit_reds)
    frac_h3_pass = sum(1 for c in all_cvs if c < H3_PASS) / len(all_cvs)

    # Hypothesis verdicts (majority-based: check mean and median)
    h1_verdict = verdict(overall_mean_overlap, H1_PASS, H1_HARD_FAIL)
    h2_verdict = verdict(overall_mean_bit_red, H2_PASS, H2_HARD_FAIL)
    h3_verdict = verdict(overall_mean_cv, H3_PASS, 1.0, higher_is_better=False)  # always soft

    # Dataset type hint (DDA vs DIA)
    max_spectra_per_window = max(all_n)
    total_qualified_windows = len(qualified)
    is_likely_dda = (max_spectra_per_window < 50 and total_qualified_windows > 500)
    dataset_note = (
        "LIKELY DDA: high window count with very few spectra per window — "
        "precursor m/z values represent individual peptide charges, not "
        "predefined isolation windows. Cross-spectrum delta assumptions "
        "designed for DIA (repeated window scans) may not apply."
        if is_likely_dda else
        "dataset type: DIA (repeated isolation windows detected)"
    )

    # Build output
    lines: list[str] = []

    def ln(s: str = "") -> None:
        lines.append(s)

    ln("# Cross-Spectrum Analysis: 15HCD_1")
    ln(f"# dump: {dump_path}")
    ln(f"# generated by: tools/analyze_isolation_windows.py")
    ln()
    ln("## Dataset")
    ln(f"  total spectra       : {len(spectra)}")
    ln(f"  ms2 spectra         : {len(ms2)}")
    ln(f"  total windows (all) : {len(windows)}")
    ln(f"  qualified windows   : {len(qualified)}  (>= {args.min_window_size} spectra)")
    ln(f"  max spectra/window  : {max_spectra_per_window}")
    ln(f"  NOTE: {dataset_note}")
    ln()
    ln("## Hypothesis Results")
    ln()
    ln(f"H1 — m/z overlap (tol={args.overlap_tolerance_da*1000:.1f} mDa)")
    ln(f"  mean overlap across windows  : {overall_mean_overlap:.4f}  ({overall_mean_overlap:.2%})")
    ln(f"  median overlap               : {overall_median_overlap:.4f}  ({overall_median_overlap:.2%})")
    ln(f"  frac windows >= 70% (pass)   : {frac_h1_pass:.2%}")
    ln(f"  frac windows <  50% (hard fail) : {frac_h1_hardfail:.2%}")
    ln(f"  VERDICT: {h1_verdict}  (pass >= {H1_PASS:.0%}, hard fail < {H1_HARD_FAIL:.0%})")
    ln()
    ln("H2 — cross-spectrum bit-width reduction")
    ln(f"  mean bit reduction across windows  : {overall_mean_bit_red:.4f}  ({overall_mean_bit_red:.2%})")
    ln(f"  median bit reduction               : {overall_median_bit_red:.4f}  ({overall_median_bit_red:.2%})")
    ln(f"  frac windows >= 30% reduction      : {frac_h2_pass:.2%}")
    ln(f"  frac windows <  10% reduction      : {frac_h2_hardfail:.2%}")
    ln(f"  VERDICT: {h2_verdict}  (pass >= {H2_PASS:.0%}, hard fail < {H2_HARD_FAIL:.0%})")
    ln()
    ln("H3 — peak-count coefficient of variation (CV)")
    ln(f"  mean CV across windows  : {overall_mean_cv:.4f}  ({overall_mean_cv:.2%})")
    ln(f"  median CV               : {overall_median_cv:.4f}  ({overall_median_cv:.2%})")
    ln(f"  frac windows CV < 20%   : {frac_h3_pass:.2%}")
    ln(f"  VERDICT: {h3_verdict}  (pass CV < {H3_PASS:.0%}; soft gate — affects 2.2 alignment strategy)")
    ln()
    ln("## Decision Gate")
    ln()
    if h1_verdict == "HARD_FAIL":
        ln("DECISION: STOP — H1 hard fail.")
        ln("  Cross-spectrum delta is not viable on this dataset.")
        ln("  m/z overlap between consecutive spectra in the same window is below 50%.")
        ln("  Action: document finding, defer to v0.3.0 with a second DIA dataset.")
    elif h2_verdict == "HARD_FAIL":
        ln("DECISION: STOP — H2 hard fail.")
        ln("  Bit-width reduction from cross-spectrum residuals is below 10%.")
        ln("  The gain does not justify the decoder complexity.")
        ln("  Action: document finding, defer to v0.3.0.")
    elif h1_verdict == "MARGINAL" or h2_verdict == "MARGINAL":
        ln("DECISION: MARGINAL — proceed with caution.")
        ln("  H1 or H2 is marginal (between hard-fail and pass thresholds).")
        ln("  Implement 2.1 window grouping, measure H4/H5 on frozen fixture,")
        ln("  and abort if measured gain is <5%.")
    else:
        ln("DECISION: PROCEED to Part 2.1 — H1 and H2 both pass.")
        ln("  Isolation-window correlation is sufficient to justify cross-spectrum delta.")
    ln()
    if h3_verdict == "PASS":
        ln("H3 alignment strategy: UNION-GRID (CV < 20% — stable peak counts per window)")
    else:
        ln("H3 alignment strategy: PAIR-MATCH FALLBACK (CV >= 20% — use 2.2 pair-match path)")
    ln()
    ln("## Per-Window Table")
    ln()
    ln(f"{'window_id':>10}  {'n':>5}  {'pk_min':>6}  {'pk_max':>6}  "
       f"{'pk_mean':>7}  {'cv':>7}  {'overlap':>9}  {'intra_bw':>9}  {'cross_bw':>9}  {'bit_red':>9}")
    ln("-" * 100)
    for wid, r in sorted(results.items()):
        ln(f"{wid:>10}  {r['n_spectra']:>5}  {r['peak_count_min']:>6}  "
           f"{r['peak_count_max']:>6}  {r['peak_count_mean']:>7.1f}  "
           f"{r['cv']:>7.2%}  {r['mean_overlap']:>9.2%}  "
           f"{r['mean_intra_bw']:>9.2f}  {r['mean_cross_bw']:>9.2f}  "
           f"{r['bit_reduction']:>9.2%}")

    output_text = "\n".join(lines) + "\n"

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(output_text)
    sys.stderr.write(f"\nwrote {out_path}\n")

    # Print summary to stdout
    print(output_text[:output_text.find("## Per-Window Table")])

    # Exit code: 0 = proceed, 2 = hard fail
    if h1_verdict == "HARD_FAIL" or h2_verdict == "HARD_FAIL":
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
