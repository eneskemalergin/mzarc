#!/usr/bin/env python3
"""Statistical analysis utilities for zebrac benchmark results.

zebrac produces summary statistics (mean, std_dev, min, max, median, q1, q3,
sample_count) but not individual samples.  Statistical tests here work by
synthesising samples from a log-normal distribution fitted to those summary
stats.  Log-normal is appropriate for execution-time distributions: it is
right-skewed, strictly positive, and well-behaved under scaling.

Public API
----------
bootstrap_ci_median   -- 95 % CI for the median (bootstrap on synthetic samples)
mann_whitney_compare  -- Mann-Whitney U between two operations
wilcoxon_paired       -- Wilcoxon signed-rank for paired encode/decode comparison
compute_stats         -- Enrich one serialised zebrac result with CI + IQR + CV
run_all_comparisons   -- Batch Mann-Whitney: mzarc lossless vs selected baselines
"""
from __future__ import annotations

import math
from typing import Any

import numpy as np

try:
    from scipy import stats as _scipy_stats  # type: ignore[import-untyped]
    _HAS_SCIPY = True
except ImportError:  # pragma: no cover
    _HAS_SCIPY = False


# --------------------------------------------------------------------------- #
# internal helpers                                                            #
# --------------------------------------------------------------------------- #

def _lognormal_params(mean: float, std_dev: float) -> tuple[float, float]:
    """Return (mu, sigma) for a log-normal distribution matching (mean, std_dev)."""
    if mean <= 0 or std_dev <= 0:
        return (math.log(max(mean, 1e-12)), 0.0)
    var = std_dev ** 2
    sigma = math.sqrt(math.log(1.0 + var / mean ** 2))
    mu = math.log(mean) - 0.5 * sigma ** 2
    return mu, sigma


def _op_samples(stats: dict[str, Any], n: int, seed: int) -> np.ndarray:
    """Generate synthetic wall-time samples from a zebrac result dict."""
    return _synthetic_samples(
        mean=float(stats.get("wall_time_mean_seconds") or stats.get("wall_time_median_seconds", 1.0)),
        std_dev=float(stats.get("wall_time_stddev_seconds") or 0.001),
        n=n,
        min_val=float(stats.get("wall_time_min_seconds", 0.0)),
        max_val=float(stats.get("wall_time_max_seconds", 1.0)),
        seed=seed,
    )


def _synthetic_samples(
    mean: float,
    std_dev: float,
    n: int,
    min_val: float,
    max_val: float,
    *,
    seed: int = 42,
) -> np.ndarray:
    """Generate up to n synthetic samples from a clipped log-normal distribution.

    Samples are drawn with the log-normal parameters fitted from (mean, std_dev)
    and then clipped to [min_val, max_val] to honour the observed extremes.
    """
    rng = np.random.default_rng(seed)
    mu, sigma = _lognormal_params(mean, std_dev)
    draw_count = max(n, 200)
    if sigma == 0.0:
        raw = np.full(draw_count, mean)
    else:
        raw = rng.lognormal(mu, sigma, size=draw_count)
    clipped = np.clip(raw, max(min_val, 1e-12), max(max_val, mean))
    chosen = rng.choice(len(clipped), size=min(n, len(clipped)), replace=False)
    return np.sort(clipped[chosen])


# --------------------------------------------------------------------------- #
# bootstrap CI on the median                                                  #
# --------------------------------------------------------------------------- #

def bootstrap_ci_median(
    mean: float,
    std_dev: float,
    n: int,
    min_val: float,
    max_val: float,
    *,
    ci: float = 0.95,
    n_boot: int = 2000,
    seed: int = 42,
) -> tuple[float, float]:
    """Return a bootstrap (lower, upper) confidence interval for the median.

    Uses synthetic samples generated from a log-normal fit to the summary
    statistics provided.  When n < 4 or std_dev is zero the interval collapses
    to (min_val, max_val).
    """
    if n < 4 or std_dev <= 0.0:
        return (min_val, max_val)
    samples = _synthetic_samples(mean, std_dev, n, min_val, max_val, seed=seed)
    if len(samples) < 4:
        return (min_val, max_val)
    rng = np.random.default_rng(seed + 1)
    boot_medians = np.median(
        rng.choice(samples, size=(n_boot, len(samples)), replace=True),
        axis=1,
    )
    alpha = (1.0 - ci) / 2.0
    return (float(np.quantile(boot_medians, alpha)), float(np.quantile(boot_medians, 1.0 - alpha)))


# --------------------------------------------------------------------------- #
# Mann-Whitney U (two independent groups)                                     #
# --------------------------------------------------------------------------- #

def mann_whitney_compare(
    name_a: str,
    stats_a: dict[str, Any],
    name_b: str,
    stats_b: dict[str, Any],
    *,
    n_synthetic: int = 2000,
) -> dict[str, Any]:
    """Compare two operations using Mann-Whitney U on synthetic samples.

    Parameters
    ----------
    name_a, name_b:
        Human-readable operation names.
    stats_a, stats_b:
        Serialised zebrac result dicts.  Required keys (all in seconds):
        wall_time_mean_seconds, wall_time_stddev_seconds, sample_count,
        wall_time_min_seconds, wall_time_max_seconds, wall_time_median_seconds.

    Returns
    -------
    dict with keys: name_a, name_b, u_statistic, p_value, significant
    (p < 0.05), speed_ratio (median_a / median_b, > 1 means a is slower),
    effect_size_r (rank-biserial correlation).
    """
    if not _HAS_SCIPY:
        return {
            "name_a": name_a, "name_b": name_b,
            "u_statistic": None, "p_value": None, "significant": None,
            "speed_ratio": None, "effect_size_r": None,
            "note": "scipy not installed",
        }

    sa = _op_samples(stats_a, int(stats_a.get("sample_count", n_synthetic)), seed=42)
    sb = _op_samples(stats_b, int(stats_b.get("sample_count", n_synthetic)), seed=42)
    result = _scipy_stats.mannwhitneyu(sa, sb, alternative="two-sided")
    n_a, n_b = len(sa), len(sb)
    u = float(result.statistic)
    # Rank-biserial correlation: ranges -1..1; positive means a tends to be larger
    r = (2.0 * u / (n_a * n_b)) - 1.0
    median_a = float(np.median(sa))
    median_b = float(np.median(sb))
    speed_ratio = median_a / median_b if median_b > 0 else None
    return {
        "name_a": name_a,
        "name_b": name_b,
        "u_statistic": u,
        "p_value": float(result.pvalue),
        "significant": bool(result.pvalue < 0.05),
        "speed_ratio": speed_ratio,
        "effect_size_r": float(r),
    }


# --------------------------------------------------------------------------- #
# Wilcoxon signed-rank (paired, e.g. encode vs decode)                        #
# --------------------------------------------------------------------------- #

def wilcoxon_paired(
    name_a: str,
    stats_a: dict[str, Any],
    name_b: str,
    stats_b: dict[str, Any],
    *,
    n_synthetic: int = 500,
) -> dict[str, Any]:
    """Wilcoxon signed-rank test for paired encode/decode comparison.

    The two operations are assumed to have been run on the same hardware under
    similar conditions, making their per-sample measurements correlated.  We
    synthesise matching sample pairs.
    """
    if not _HAS_SCIPY:
        return {
            "name_a": name_a, "name_b": name_b,
            "statistic": None, "p_value": None, "significant": None,
            "note": "scipy not installed",
        }

    sa = _op_samples(stats_a, n_synthetic, seed=99)
    sb = _op_samples(stats_b, n_synthetic, seed=99)
    n = min(len(sa), len(sb))
    if n < 10:
        return {
            "name_a": name_a, "name_b": name_b,
            "statistic": None, "p_value": None, "significant": None,
            "note": "too few synthetic samples",
        }
    result = _scipy_stats.wilcoxon(sa[:n], sb[:n], alternative="two-sided")
    return {
        "name_a": name_a,
        "name_b": name_b,
        "statistic": float(result.statistic),
        "p_value": float(result.pvalue),
        "significant": bool(result.pvalue < 0.05),
    }


# --------------------------------------------------------------------------- #
# per-operation stats enrichment                                              #
# --------------------------------------------------------------------------- #

def compute_stats(zebrac_item: dict[str, Any]) -> dict[str, Any]:
    """Enrich a serialised zebrac result with bootstrap CI, IQR, and CV.

    Added keys
    ----------
    ci95_lo_seconds, ci95_hi_seconds -- bootstrap 95 % CI for the median
    iqr_seconds                      -- Q3 - Q1 (from zebrac's wall_time dict)
    cv                               -- coefficient of variation (std / mean)
    """
    item = dict(zebrac_item)
    mean = float(item.get("wall_time_mean_seconds") or item.get("wall_time_median_seconds") or 0.0)
    std_dev = float(item.get("wall_time_stddev_seconds") or 0.0)
    n = int(item.get("sample_count") or 1)
    min_v = float(item.get("wall_time_min_seconds") or mean * 0.8)
    max_v = float(item.get("wall_time_max_seconds") or mean * 1.2)

    if mean > 0 and std_dev > 0 and n >= 4:
        ci_lo, ci_hi = bootstrap_ci_median(mean, std_dev, n, min_v, max_v)
    else:
        ci_lo, ci_hi = min_v, max_v

    # IQR: zebrac stores raw nanoseconds in the nested wall_time dict
    wt_raw = item.get("wall_time")
    iqr_s: float | None = None
    if isinstance(wt_raw, dict):
        q1_ns = wt_raw.get("q1")
        q3_ns = wt_raw.get("q3")
        if q1_ns is not None and q3_ns is not None:
            iqr_s = (float(q3_ns) - float(q1_ns)) / 1e9

    cv: float | None = (std_dev / mean) if mean > 0 else None

    item["ci95_lo_seconds"] = ci_lo
    item["ci95_hi_seconds"] = ci_hi
    item["iqr_seconds"] = iqr_s
    item["cv"] = cv
    return item


# --------------------------------------------------------------------------- #
# batch comparison suite                                                      #
# --------------------------------------------------------------------------- #

def run_all_comparisons(
    zebrac_results: list[dict[str, Any]],
    *,
    mzarc_vs: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Run Mann-Whitney U comparing mzarc lossless encode vs selected baselines.

    Also runs Wilcoxon signed-rank for paired encode/decode within mzarc.

    Parameters
    ----------
    zebrac_results:
        List of enriched serialised zebrac result dicts (output of compute_stats).
    mzarc_vs:
        Artifact names to compare mzarc against.  Defaults to gzip and zstd.
    """
    if mzarc_vs is None:
        mzarc_vs = ["gzip dump", "zstd dump"]

    by_name = {str(r["name"]): r for r in zebrac_results}
    comparisons: list[dict[str, Any]] = []

    mzarc_enc = by_name.get("dump -> mzarc lossless")
    mzarc_dec = None
    for k, v in by_name.items():
        if "mzarc lossless" in k and "-> dump" in k:
            mzarc_dec = v
            break

    # mzarc encode vs baselines
    for baseline_artifact in mzarc_vs:
        enc_key = f"dump -> {baseline_artifact}"
        baseline_enc = by_name.get(enc_key)
        if mzarc_enc is None or baseline_enc is None:
            continue
        row = mann_whitney_compare(
            "dump -> mzarc lossless", mzarc_enc,
            enc_key, baseline_enc,
        )
        row["comparison_type"] = "encode_vs_baseline"
        row["mzarc_artifact"] = "mzarc lossless"
        row["baseline_artifact"] = baseline_artifact
        comparisons.append(row)

    # mzarc encode vs mzarc decode (Wilcoxon paired)
    if mzarc_enc is not None and mzarc_dec is not None:
        row = wilcoxon_paired(
            "dump -> mzarc lossless", mzarc_enc,
            "mzarc lossless -> dump", mzarc_dec,
        )
        row["comparison_type"] = "encode_vs_decode"
        comparisons.append(row)

    return comparisons
