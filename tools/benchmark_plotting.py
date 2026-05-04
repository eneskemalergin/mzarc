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
            "figure.facecolor": "#f8fafc",
            "axes.facecolor": "#fdfdfc",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.titleweight": "bold",
            "axes.edgecolor": "#cbd5e1",
            "axes.labelcolor": "#0f172a",
            "axes.titlesize": 18,
            "grid.color": "#cbd5e1",
            "grid.alpha": 0.35,
            "text.color": "#0f172a",
            "xtick.color": "#334155",
            "ytick.color": "#334155",
        }
    )


_apply_style()


def _artifact_palette(artifact_names: list[str]) -> list[str]:
    palette_map = {
        "mzML": "#64748b",
        "dump": "#2563eb",
        "gzip dump": "#475569",
        "zstd dump": "#0f172a",
        "bzip2 dump": "#1e40af",
        "lz4 dump": "#0369a1",
        "xz dump": "#3730a3",
        "gzip mzML": "#475569",
        "zstd mzML": "#334155",
        "bzip2 mzML": "#1e3a8a",
        "lz4 mzML": "#075985",
        "xz mzML": "#312e81",
        "mzarc lossless": "#0f766e",
        "mzarc lossy": "#d97706",
        "mzMLb": "#0ea5e9",
        "MS-Numpress in mzML": "#7c3aed",
        "MScompress": "#be185d",
        "MScompress (threaded)": "#9d174d",
    }
    colors: list[str] = []
    for name in artifact_names:
        if name.startswith("mzarc lossy q="):
            colors.append(palette_map["mzarc lossy"])
        else:
            colors.append(palette_map.get(name, "#475569"))
    return colors


def plot_size_comparison(size_rows: list[dict[str, object]], path: Path) -> None:
    frame = pd.DataFrame(size_rows)
    mzml_size = float(frame.loc[frame["artifact"] == "mzML", "size_mib"].iloc[0])

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
        reduction = (1.0 - (float(row["size_mib"]) / mzml_size)) * 100.0
        detail = "baseline" if str(row["artifact"]) == "mzML" else f"{reduction:.1f}% smaller than mzML"
        ax.text(
            patch.get_width() + 0.05,
            patch.get_y() + patch.get_height() / 2,
            f"{row['size_mib']:.2f} MiB  |  {detail}",
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


def plot_performance_overview(performance_rows: list[dict[str, object]], path: Path) -> None:
    frame = pd.DataFrame(performance_rows)
    frame = frame[(frame["status"] == "measured") & frame["throughput_mib_s"].notna()].copy()
    if frame.empty:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No measured throughput rows available for this run", ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    order = list(dict.fromkeys(str(item["artifact"]) for item in performance_rows if str(item["status"]) == "measured"))
    directions = [("compression", "Compression Speed (MiB/s)"), ("decompression", "Decompression Speed (MiB/s)")]
    fig, axes = plt.subplots(1, 2, figsize=(14.5, max(4.8, 0.62 * len(order) + 1.8)), sharey=True)

    for index, (direction, title) in enumerate(directions):
        ax = axes[index]
        subset = frame[frame["direction"] == direction].copy()
        if subset.empty:
            ax.axis("off")
            continue
        subset_order = [name for name in order if name in set(subset["artifact"])]
        ordered = subset.set_index("artifact").loc[subset_order].reset_index()
        colors = _artifact_palette(subset_order)
        ax.barh(ordered["artifact"], ordered["throughput_mib_s"], color=colors)
        max_value = float(ordered["throughput_mib_s"].max())
        for patch, (_, row) in zip(ax.patches, ordered.iterrows(), strict=True):
            basis = "restored bytes" if row.get("throughput_basis") == "output" else "source bytes"
            ax.text(
                patch.get_width() + max(max_value * 0.015, 0.05),
                patch.get_y() + patch.get_height() / 2,
                f"{float(row['throughput_mib_s']):.2f}  |  {basis}",
                va="center",
                ha="left",
                fontsize=10,
            )
        ax.set_title(title)
        ax.set_xlabel("MiB/s")
        ax.set_ylabel("")
        ax.margins(x=0.22)

        if direction == "compression":
            ax.invert_yaxis()

    fig.suptitle("Throughput Overview", y=1.02, fontsize=20, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_fidelity_overview(fidelity_rows: list[dict[str, object]], path: Path) -> None:
    frame = pd.DataFrame(fidelity_rows)
    frame = frame[frame["status"] == "measured"].copy()
    if frame.empty:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No measured fidelity rows available for this run", ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    order = list(frame.sort_values(["max_abs_mz_error", "mean_abs_intensity_error", "artifact"], ascending=[True, True, True])["artifact"])
    metrics = [
        ("max_abs_mz_error", "Max m/z Error", 1e-12, "{:.3g}"),
        ("mean_abs_intensity_error", "Mean Intensity Error", 1e-3, "{:.3g}"),
        ("p95_rel_intensity_error_pct", "P95 Rel Intensity Error (%)", 1e-4, "{:.3f}%"),
    ]
    fig, axes = plt.subplots(1, 3, figsize=(17.5, max(4.8, 0.62 * len(order) + 1.6)), sharey=True)

    for axis_index, (column, title, linthresh, value_format) in enumerate(metrics):
        ax = axes[axis_index]
        ordered = frame.set_index("artifact").loc[order].reset_index()
        colors = _artifact_palette(order)
        ax.barh(ordered["artifact"], ordered[column], color=colors)
        ax.set_xscale("symlog", linthresh=linthresh)
        for patch, (_, row) in zip(ax.patches, ordered.iterrows(), strict=True):
            value = float(row[column])
            anchor = max(abs(value), linthresh)
            text_x = anchor + (anchor * 0.18) + linthresh
            ax.text(
                text_x,
                patch.get_y() + patch.get_height() / 2,
                value_format.format(value),
                va="center",
                ha="left",
                fontsize=10,
            )
        ax.set_title(title)
        ax.set_xlabel("")
        ax.set_ylabel("")
        ax.margins(x=0.3)

        if axis_index == 0:
            ax.invert_yaxis()

    fig.suptitle("Data Fidelity Overview", y=1.02, fontsize=20, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_timing_intervals(timing_rows: list[dict[str, object]], path: Path) -> None:
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


def plot_memory_footprint(memory_rows: list[dict[str, object]], path: Path) -> None:
    frame = pd.DataFrame(memory_rows)
    if frame.empty:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No zebrac memory rows available for this run", ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    # Split into encode and decode rows for side-by-side display.
    def _is_encode(name: str) -> bool:
        lower = name.lower()
        return "encode" in lower or ("-> mzarc" in lower) or ("-> gzip" in lower) or ("-> zstd" in lower) or ("-> bzip2" in lower) or ("-> lz4" in lower) or ("-> xz" in lower) or ("mzml ->" in lower) or ("dump ->" in lower)

    frame["direction"] = frame["operation"].apply(lambda n: "encode / compress" if _is_encode(str(n)) else "decode / decompress")
    palette_map = {
        "encode / compress": "#0f766e",
        "decode / decompress": "#2563eb",
    }
    colors = [palette_map[d] for d in frame["direction"]]

    fig, ax = plt.subplots(figsize=(10.5, max(4.0, 0.55 * len(frame) + 1.6)))
    ax.barh(frame["operation"], frame["peak_rss_median_mib"], color=colors)
    max_rss = float(frame["peak_rss_median_mib"].max())
    for patch, (_, row) in zip(ax.patches, frame.iterrows(), strict=True):
        ax.text(
            patch.get_width() + max(max_rss * 0.015, 0.1),
            patch.get_y() + patch.get_height() / 2,
            f"{row['peak_rss_median_mib']:.1f} MiB",
            va="center",
            ha="left",
            fontsize=10,
        )
    ax.set_title("Peak RSS by Operation (zebrac median)")
    ax.set_xlabel("peak RSS (MiB)")
    ax.set_ylabel("")
    ax.margins(x=0.18)
    # Legend patches
    import matplotlib.patches as mpatches
    legend_handles = [mpatches.Patch(color=v, label=k) for k, v in palette_map.items()]
    ax.legend(handles=legend_handles, loc="lower right", fontsize=10)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_intensity_quantiles(quantile_rows: list[dict[str, object]], path: Path) -> None:
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


def plot_timing_validation(validation_rows: list[dict[str, object]], path: Path) -> None:
    """Scatter-plot comparing zebrac vs hyperfine wall-time medians.

    Each point is one operation. Points colored green when they agree (diff <= 10%)
    and red otherwise. The diagonal y=x reference line shows perfect agreement.
    """
    frame = pd.DataFrame(validation_rows)
    if frame.empty:
        fig, ax = plt.subplots(figsize=(7.0, 5.0))
        ax.axis("off")
        ax.text(0.5, 0.5, "No hyperfine comparison data available for this run", ha="center", va="center", fontsize=14)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    colors = ["#0f766e" if bool(a) else "#dc2626" for a in frame["agrees"]]
    fig, ax = plt.subplots(figsize=(8.0, 7.0))
    ax.scatter(frame["hyperfine_median_s"], frame["zebrac_median_s"], c=colors, s=90, zorder=3, edgecolors="#0f172a", linewidths=0.6)

    all_vals = list(frame["zebrac_median_s"]) + list(frame["hyperfine_median_s"])
    lo, hi = min(all_vals) * 0.9, max(all_vals) * 1.1
    ax.plot([lo, hi], [lo, hi], color="#94a3b8", linestyle="--", linewidth=1.2, label="y = x (perfect agreement)")

    for _, row in frame.iterrows():
        ax.annotate(
            str(row["name"]).replace("dump -> ", "").replace(" -> dump", ""),
            (float(row["hyperfine_median_s"]), float(row["zebrac_median_s"])),
            textcoords="offset points",
            xytext=(5, 3),
            fontsize=7,
            color="#334155",
        )

    import matplotlib.patches as mpatches
    legend_handles = [
        mpatches.Patch(color="#0f766e", label="agrees (diff \u2264 10%)"),
        mpatches.Patch(color="#dc2626", label="disagrees (diff > 10%)"),
        plt.Line2D([0], [0], color="#94a3b8", linestyle="--", label="y = x"),
    ]
    ax.legend(handles=legend_handles, fontsize=9)
    ax.set_title("Wall-Time Validation: zebrac vs hyperfine")
    ax.set_xlabel("hyperfine median (s)")
    ax.set_ylabel("zebrac median (s)")
    ax.set_xlim(lo, hi)
    ax.set_ylim(lo, hi)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def generate_plots(report: dict, plot_dir: Path) -> dict[str, str]:
    plot_dir.mkdir(parents=True, exist_ok=True)

    size_path = plot_dir / "size_comparison.png"
    performance_path = plot_dir / "performance_overview.png"
    fidelity_path = plot_dir / "fidelity_overview.png"
    tradeoff_path = plot_dir / "lossy_tradeoff.png"
    quantile_path = plot_dir / "intensity_relative_quantiles.png"
    memory_path = plot_dir / "memory_footprint.png"
    validation_path = plot_dir / "timing_validation.png"

    plot_size_comparison(report["plot_rows"]["sizes"], size_path)
    plot_performance_overview(report["plot_rows"]["performance"], performance_path)
    plot_fidelity_overview(report["plot_rows"]["fidelity"], fidelity_path)
    plot_lossy_tradeoff(report["plot_rows"]["lossy_sweep"], report["selected_lossy_intensity_quant"], tradeoff_path)
    plot_intensity_quantiles(report["plot_rows"]["intensity_quantiles"], quantile_path)

    plots = {
        "size_comparison": size_path.name,
        "performance_overview": performance_path.name,
        "fidelity_overview": fidelity_path.name,
        "lossy_tradeoff": tradeoff_path.name,
        "intensity_relative_quantiles": quantile_path.name,
    }

    memory_rows = report["plot_rows"].get("memory_metrics", [])
    if memory_rows:
        plot_memory_footprint(memory_rows, memory_path)
        plots["memory_footprint"] = memory_path.name

    validation_rows = report["plot_rows"].get("timing_validation", [])
    if validation_rows:
        plot_timing_validation(validation_rows, validation_path)
        plots["timing_validation"] = validation_path.name

    return plots