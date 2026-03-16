from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


def _apply_style() -> None:
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams.update(
        {
            "figure.dpi": 180,
            "savefig.dpi": 180,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.titleweight": "bold",
        }
    )


def _artifact_palette(artifact_names: list[str]) -> list[str]:
    palette_map = {
        "mzML": "#64748b",
        "dump": "#2563eb",
        "mzv1 lossless": "#0f766e",
        "mzv1 lossy": "#d97706",
    }
    return [palette_map.get(name, "#475569") for name in artifact_names]


def plot_size_comparison(size_rows: list[dict[str, object]], path: Path) -> None:
    _apply_style()
    frame = pd.DataFrame(size_rows)

    fig, ax = plt.subplots(figsize=(10.5, 4.8))
    sns.barplot(
        data=frame,
        y="artifact",
        x="size_mib",
        order=list(frame["artifact"]),
        hue="artifact",
        palette=_artifact_palette(list(frame["artifact"])),
        dodge=False,
        legend=False,
        ax=ax,
    )

    for patch, (_, row) in zip(ax.patches, frame.iterrows(), strict=True):
        ax.text(
            patch.get_width() + 0.05,
            patch.get_y() + patch.get_height() / 2,
            f"{row['size_mib']:.2f} MiB",
            va="center",
            ha="left",
            fontsize=11,
        )

    ax.set_title("Artifact Size Comparison")
    ax.set_xlabel("size (MiB)")
    ax.set_ylabel("")
    ax.margins(x=0.18)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_timing_intervals(timing_rows: list[dict[str, object]], path: Path) -> None:
    _apply_style()
    order = [str(row["name"]) for row in timing_rows]
    run_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for row in timing_rows:
        name = str(row["name"])
        summary_rows.append(
            {
                "operation": name,
                "mean_seconds": float(row["mean_seconds"]),
                "stdev_seconds": float(row["stdev_seconds"]),
                "ci95_half_width_seconds": float(row["ci95_half_width_seconds"]),
            }
        )
        for index, seconds in enumerate(row["runs_seconds"], start=1):
            run_rows.append({"operation": name, "run": index, "seconds": float(seconds)})

    runs_frame = pd.DataFrame(run_rows)
    summary_frame = pd.DataFrame(summary_rows)
    max_seconds = max(float(runs_frame["seconds"].max()), float(summary_frame["mean_seconds"].max()))

    fig, ax = plt.subplots(figsize=(12.5, max(5.0, 0.75 * len(order) + 1.5)))
    sns.stripplot(
        data=runs_frame,
        y="operation",
        x="seconds",
        order=order,
        orient="h",
        size=7,
        color="#94a3b8",
        alpha=0.75,
        ax=ax,
    )

    ax.errorbar(
        summary_frame["mean_seconds"],
        list(range(len(summary_frame))),
        xerr=summary_frame["ci95_half_width_seconds"],
        fmt="o",
        color="#0f172a",
        ecolor="#0f172a",
        elinewidth=2,
        capsize=5,
        markersize=8,
        zorder=5,
    )

    for idx, row in summary_frame.iterrows():
        ax.text(
            float(row["mean_seconds"]) + float(row["ci95_half_width_seconds"]) + max_seconds * 0.03,
            idx,
            f"{row['mean_seconds']:.3f}s ± {row['stdev_seconds']:.3f}s",
            va="center",
            ha="left",
            fontsize=10,
        )

    ax.set_title("Timing Variability Across Runs")
    ax.set_xlabel("seconds; dots are individual runs, black points show mean with 95% CI")
    ax.set_ylabel("")
    ax.margins(x=0.28)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_lossy_tradeoff(lossy_rows: list[dict[str, object]], selected_quant: int, path: Path) -> None:
    _apply_style()
    frame = pd.DataFrame(lossy_rows)
    frame["selected"] = frame["intensity_quant"].astype(int) == int(selected_quant)

    fig, ax = plt.subplots(figsize=(9.8, 5.8))
    sns.lineplot(data=frame, x="size_mib", y="p95_rel_intensity_error_pct", color="#c2410c", linewidth=2.5, ax=ax)
    sns.scatterplot(
        data=frame,
        x="size_mib",
        y="p95_rel_intensity_error_pct",
        hue="selected",
        palette={True: "#b91c1c", False: "#7c3aed"},
        s=110,
        legend=False,
        ax=ax,
    )

    for _, row in frame.iterrows():
        ax.text(
            float(row["size_mib"]) + 0.03,
            float(row["p95_rel_intensity_error_pct"]) + 0.03,
            f"q={int(row['intensity_quant'])}",
            fontsize=10,
        )

    ax.set_title("Lossy Tradeoff")
    ax.set_xlabel("encoded size (MiB)")
    ax.set_ylabel("p95 relative intensity error (%)")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_intensity_quantiles(quantile_rows: list[dict[str, object]], path: Path) -> None:
    _apply_style()
    frame = pd.DataFrame(quantile_rows)

    fig, ax = plt.subplots(figsize=(10.0, 5.4))
    sns.lineplot(
        data=frame,
        x="quantile_label",
        y="value_pct",
        hue="artifact",
        style="artifact",
        markers=True,
        dashes=False,
        linewidth=2.5,
        palette={"lossless": "#2563eb", "selected lossy": "#b91c1c"},
        ax=ax,
    )

    ax.set_title("Relative Intensity Error Quantiles")
    ax.set_xlabel("quantile")
    ax.set_ylabel("relative intensity error (%)")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def generate_plots(report: dict, plot_dir: Path) -> dict[str, str]:
    plot_dir.mkdir(parents=True, exist_ok=True)

    size_path = plot_dir / "size_comparison.png"
    timing_path = plot_dir / "timing_intervals.png"
    tradeoff_path = plot_dir / "lossy_tradeoff.png"
    quantile_path = plot_dir / "intensity_relative_quantiles.png"

    plot_size_comparison(report["plot_rows"]["sizes"], size_path)
    plot_timing_intervals(report["timings"], timing_path)
    plot_lossy_tradeoff(report["plot_rows"]["lossy_sweep"], report["selected_lossy_intensity_quant"], tradeoff_path)
    plot_intensity_quantiles(report["plot_rows"]["intensity_quantiles"], quantile_path)

    return {
        "size_comparison": size_path.name,
        "timing_intervals": timing_path.name,
        "lossy_tradeoff": tradeoff_path.name,
        "intensity_relative_quantiles": quantile_path.name,
    }