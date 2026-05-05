from __future__ import annotations

from pathlib import Path

import matplotlib
import matplotlib.patches as mpatches

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


# --------------------------------------------------------------------------- #
# Shared colour + annotation helpers                                          #
# --------------------------------------------------------------------------- #

# Threading: artifacts that use multiple cores automatically.
_MULTI_THREAD = frozenset([
    "pigz dump", "pigz mzML",
    "zstd mt dump", "zstd mt mzML",
    "MScompress",          # all cores by default
])

# Colour tokens -- one authoritative source used by every plot.
_COLORS = {
    # mzarc (always prominent)
    "mzarc_lossless": "#0d9488",   # vivid teal
    "mzarc_lossy":    "#f59e0b",   # amber

    # MS-domain external codecs
    "mzmlb":         "#0ea5e9",    # sky blue
    "numpress":      "#8b5cf6",    # violet
    "mscompress":    "#e11d48",    # rose (multi-thread default)
    "mscompress_st": "#f43f5e",    # lighter rose (single-thread)

    # Generic on dump input (slate family)
    "gzip_dump":   "#475569",
    "zstd_dump":   "#334155",
    "bzip2_dump":  "#1e3a5f",
    "lz4_dump":    "#0369a1",
    "xz_dump":     "#1d4ed8",
    "pigz_dump":   "#64748b",      # lighter slate = threaded variant
    "zstdmt_dump": "#94a3b8",      # even lighter = threaded

    # Generic on mzML input (blue-gray family, clearly distinct from dump)
    "gzip_mzml":   "#6b7280",
    "zstd_mzml":   "#52525b",
    "bzip2_mzml":  "#3f3f46",
    "lz4_mzml":    "#0891b2",
    "xz_mzml":     "#2563eb",
    "pigz_mzml":   "#9ca3af",      # lighter = threaded
    "zstdmt_mzml": "#cbd5e1",      # lightest = threaded

    # Reference bars
    "mzml": "#94a3b8",
    "dump": "#bfdbfe",
}


def _color(name: str) -> str:
    """Return a fill colour for an artifact bar."""
    if name.startswith("mzarc lossless"):
        return _COLORS["mzarc_lossless"]
    if name.startswith("mzarc lossy"):
        return _COLORS["mzarc_lossy"]
    key = (
        name.lower()
        .replace(" ", "_")
        .replace("-", "_")
        .replace("(", "")
        .replace(")", "")
        .replace("mt_", "mt")       # "zstd mt dump" -> "zstdmt_dump"
        .replace("zstd_mt", "zstdmt")
        .replace("1t", "st")        # "mscompress_(1t)" -> "mscompress_st"
    )
    return _COLORS.get(key, "#475569")


def _display_label(name: str) -> str:
    """Return display label, appending [MT] for multi-threaded artifacts."""
    if name in _MULTI_THREAD:
        return f"{name} [MT]"
    return name


def _input_facet(artifact: str) -> str:
    """Classify an artifact into 'ms_codec', 'dump', or 'mzML'."""
    if artifact.startswith("mzarc"):
        return "ms_codec"
    lc = artifact.lower()
    ms_names = {"mzmlb", "ms-numpress in mzml", "mscompress", "mscompress (1t)"}
    if artifact in ms_names or lc in ms_names:
        return "ms_codec"
    if "dump" in lc:
        return "dump"
    return "mzML"


def plot_size_comparison(size_rows: list[dict[str, object]], path: Path) -> None:
    """Faceted size comparison: MS-domain codecs (left) vs general-purpose (right).

    Within the general-purpose panel bars are coloured by input: dump (slate)
    or mzML (blue-gray).  Multi-thread variants get an [MT] label suffix.
    mzarc is highlighted with vivid teal/amber and a bold label.
    """
    frame = pd.DataFrame(size_rows)
    mzml_size = float(frame.loc[frame["artifact"] == "mzML", "size_mib"].iloc[0])
    dump_size  = float(frame.loc[frame["artifact"] == "dump", "size_mib"].iloc[0])

    frame["facet"] = frame["artifact"].apply(_input_facet)
    frame["label"] = frame["artifact"].apply(_display_label)

    # Exclude the raw reference bars from the comparison panels.
    ref = frame[frame["artifact"].isin({"mzML", "dump"})]
    ms  = frame[frame["facet"] == "ms_codec"].copy()
    gen = frame[~frame["artifact"].isin({"mzML", "dump"}) & (frame["facet"] != "ms_codec")].copy()

    # Order: ms_codec sorted ascending by size; general-purpose: all dump first
    # then mzML, within each sorted ascending by size.
    ms  = ms.sort_values("size_mib")
    dump_gen = gen[gen["facet"] == "dump"].sort_values("size_mib")
    mzml_gen = gen[gen["facet"] == "mzML"].sort_values("size_mib")
    gen = pd.concat([dump_gen, mzml_gen], ignore_index=True)

    fig, (ax_ms, ax_gen) = plt.subplots(
        1, 2,
        figsize=(18, max(5.0, 0.52 * max(len(ms), len(gen)) + 2.0)),
        sharey=False,
    )

    def _draw_panel(ax: plt.Axes, sub: pd.DataFrame, title: str) -> None:
        colors = [_color(str(a)) for a in sub["artifact"]]
        bars = ax.barh(sub["label"], sub["size_mib"], color=colors, edgecolor="#e2e8f0", linewidth=0.5)

        max_w = float(sub["size_mib"].max())
        for patch, (_, row) in zip(ax.patches, sub.iterrows(), strict=True):
            pct_mzml = (float(row["size_mib"]) / mzml_size) * 100.0
            ax.text(
                patch.get_width() + max_w * 0.015,
                patch.get_y() + patch.get_height() / 2,
                f"{float(row['size_mib']):.2f} MiB  ({pct_mzml:.0f}% of mzML)",
                va="center", ha="left", fontsize=9.5,
            )

        # Reference lines: mzML and dump baselines.
        ax.axvline(mzml_size, color="#94a3b8", linestyle=":",  linewidth=1.2, label=f"mzML {mzml_size:.1f} MiB")
        ax.axvline(dump_size, color="#bfdbfe", linestyle="--", linewidth=1.2, label=f"dump {dump_size:.1f} MiB")
        ax.legend(fontsize=8, loc="lower right")
        ax.set_title(title, fontsize=14)
        ax.set_xlabel("size (MiB)")
        ax.set_ylabel("")
        ax.margins(x=0.26)
        ax.invert_yaxis()

        # Bold mzarc labels.
        for tick in ax.get_yticklabels():
            if "mzarc" in tick.get_text().lower():
                tick.set_fontweight("bold")
                tick.set_color(_COLORS["mzarc_lossless"])

    _draw_panel(ax_ms,  ms,  "MS-domain codecs")
    _draw_panel(ax_gen, gen, "General-purpose (dump = slate, mzML = blue-gray)")

    # Legend patches for input-format colours in the general panel.
    legend_items = [
        mpatches.Patch(color="#475569", label="generic — dump input"),
        mpatches.Patch(color="#6b7280", label="generic — mzML input"),
        mpatches.Patch(facecolor="white", edgecolor="#334155", label="[MT] = multi-threaded"),
    ]
    fig.legend(handles=legend_items, loc="lower center", ncol=3, fontsize=9,
               bbox_to_anchor=(0.5, -0.03))
    fig.suptitle("Artifact Size Comparison", fontsize=19, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_performance_overview(performance_rows: list[dict[str, object]], path: Path) -> None:
    """2×2 faceted throughput chart: rows=direction, cols=input format (dump|mzML).

    MS-domain codecs are shown in both columns with their appropriate input.
    mzarc is highlighted; [MT] suffix marks multi-threaded tools.
    """
    frame = pd.DataFrame(performance_rows)
    frame = frame[(frame["status"] == "measured") & frame["throughput_mib_s"].notna()].copy()
    if frame.empty:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No measured throughput rows", ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    # Classify each row's input format from source_format field.
    def _facet(row: dict) -> str:
        sf = str(row.get("source_format") or "")
        if "dump" in sf.lower():
            return "dump"
        return "mzML"

    frame["input_facet"] = frame.apply(_facet, axis=1)
    frame["label"] = frame["artifact"].apply(_display_label)

    directions = [
        ("compression",   "Compression / Encode  (MiB/s)"),
        ("decompression", "Decompression / Decode  (MiB/s)"),
    ]
    facets = [("dump", "Input: binary dump"), ("mzML", "Input: mzML")]

    # Determine a shared y-label order per facet so both direction panels align.
    def _panel_order(direction: str, facet: str) -> list[str]:
        sub = frame[(frame["direction"] == direction) & (frame["input_facet"] == facet)]
        # Sort descending by throughput so fastest at top.
        return list(sub.sort_values("throughput_mib_s", ascending=False)["artifact"])

    fig, axes = plt.subplots(
        2, 2,
        figsize=(22, max(8.0, 0.52 * frame["artifact"].nunique() + 3.0)),
        sharey=False,
    )

    for row_idx, (direction, dir_title) in enumerate(directions):
        for col_idx, (facet, facet_title) in enumerate(facets):
            ax = axes[row_idx][col_idx]
            sub = frame[
                (frame["direction"] == direction) & (frame["input_facet"] == facet)
            ].copy()

            if sub.empty:
                ax.axis("off")
                continue

            order = _panel_order(direction, facet)
            sub = sub.set_index("artifact").loc[order].reset_index()
            sub["label"] = sub["artifact"].apply(_display_label)
            colors = [_color(str(a)) for a in sub["artifact"]]

            ax.barh(sub["label"], sub["throughput_mib_s"], color=colors,
                    edgecolor="#e2e8f0", linewidth=0.5)

            max_v = float(sub["throughput_mib_s"].max())
            for patch, (_, r) in zip(ax.patches, sub.iterrows(), strict=True):
                ax.text(
                    patch.get_width() + max_v * 0.015,
                    patch.get_y() + patch.get_height() / 2,
                    f"{float(r['throughput_mib_s']):.1f}",
                    va="center", ha="left", fontsize=9,
                )

            ax.set_title(f"{dir_title}\n{facet_title}", fontsize=12)
            ax.set_xlabel("MiB/s")
            ax.set_ylabel("")
            ax.margins(x=0.18)
            ax.invert_yaxis()

            for tick in ax.get_yticklabels():
                if "mzarc" in tick.get_text().lower():
                    tick.set_fontweight("bold")
                    tick.set_color(_COLORS["mzarc_lossless"])

    # Shared legend
    legend_items = [
        mpatches.Patch(color=_COLORS["mzarc_lossless"], label="mzarc lossless"),
        mpatches.Patch(color=_COLORS["mzarc_lossy"],    label="mzarc lossy"),
        mpatches.Patch(color=_COLORS["mzmlb"],          label="mzMLb"),
        mpatches.Patch(color=_COLORS["mscompress"],     label="MScompress [MT]"),
        mpatches.Patch(color="#475569",                  label="generic — dump"),
        mpatches.Patch(color="#6b7280",                  label="generic — mzML"),
        mpatches.Patch(facecolor="white", edgecolor="#334155", label="[MT] = multi-threaded"),
    ]
    fig.legend(handles=legend_items, loc="lower center", ncol=4, fontsize=9,
               bbox_to_anchor=(0.5, -0.02))
    fig.suptitle("Throughput Overview", fontsize=20, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_fidelity_overview(fidelity_rows: list[dict[str, object]], path: Path) -> None:
    """Fidelity metrics for all measured codecs; mzarc highlighted."""
    frame = pd.DataFrame(fidelity_rows)
    frame = frame[frame["status"] == "measured"].copy()
    if frame.empty:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No measured fidelity rows available for this run",
                ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    order = list(frame.sort_values(
        ["max_abs_mz_error", "mean_abs_intensity_error", "artifact"],
        ascending=[True, True, True],
    )["artifact"])
    metrics = [
        ("max_abs_mz_error",            "Max m/z Error",              1e-12, "{:.3g}"),
        ("mean_abs_intensity_error",     "Mean Intensity Error",        1e-3,  "{:.3g}"),
        ("p95_rel_intensity_error_pct",  "P95 Rel Intensity Error (%)", 1e-4,  "{:.3f}%"),
    ]
    fig, axes = plt.subplots(
        1, 3,
        figsize=(17.5, max(4.8, 0.62 * len(order) + 1.6)),
        sharey=True,
    )

    colors = [_color(str(a)) for a in order]

    for axis_index, (column, title, linthresh, value_format) in enumerate(metrics):
        ax = axes[axis_index]
        ordered = frame.set_index("artifact").loc[order].reset_index()
        ax.barh(ordered["artifact"], ordered[column], color=colors,
                edgecolor="#e2e8f0", linewidth=0.5)
        ax.set_xscale("symlog", linthresh=linthresh)
        for patch, (_, row) in zip(ax.patches, ordered.iterrows(), strict=True):
            value = float(row[column])
            anchor = max(abs(value), linthresh)
            text_x = anchor + (anchor * 0.18) + linthresh
            ax.text(
                text_x,
                patch.get_y() + patch.get_height() / 2,
                value_format.format(value),
                va="center", ha="left", fontsize=10,
            )
        ax.set_title(title, fontsize=13)
        ax.set_xlabel("")
        ax.set_ylabel("")
        ax.margins(x=0.3)

        if axis_index == 0:
            ax.invert_yaxis()
            for tick in ax.get_yticklabels():
                if "mzarc" in tick.get_text().lower():
                    tick.set_fontweight("bold")
                    tick.set_color(_COLORS["mzarc_lossless"])

    fig.suptitle("Data Fidelity Overview", fontsize=20, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_lossy_tradeoff(lossy_rows: list[dict[str, object]], selected_quant: int, path: Path) -> None:
    """Size vs intensity error tradeoff across mzarc lossy quantization levels.

    The currently-selected quantization level is highlighted in vivid amber;
    other sweep points are shown in lighter amber.  An annotation on each
    point shows the quantization step and the p95 error value.
    """
    if not lossy_rows:
        fig, ax = plt.subplots(figsize=(9.8, 5.8))
        ax.axis("off")
        ax.text(0.5, 0.5, "No lossy sweep data available",
                ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    frame = pd.DataFrame(lossy_rows)
    frame["selected"] = frame["intensity_quant"].astype(int) == int(selected_quant)

    unsel_color = "#fcd34d"   # light amber for other sweep points
    sel_color   = _COLORS["mzarc_lossy"]  # vivid amber for selected

    fig, ax = plt.subplots(figsize=(9.8, 5.8))
    ax.plot(
        frame["size_mib"], frame["p95_rel_intensity_error_pct"],
        color=sel_color, linewidth=2.2, zorder=1,
    )
    for _, row in frame.iterrows():
        is_sel = bool(row["selected"])
        ax.scatter(
            float(row["size_mib"]), float(row["p95_rel_intensity_error_pct"]),
            color=sel_color if is_sel else unsel_color,
            edgecolors="#78350f",
            s=140 if is_sel else 90,
            linewidths=1.2,
            zorder=2,
        )
        ax.text(
            float(row["size_mib"]) + 0.03,
            float(row["p95_rel_intensity_error_pct"]) + 0.005,
            f"q={int(row['intensity_quant'])}\n({float(row['p95_rel_intensity_error_pct']):.3f}%)",
            fontsize=9.5,
            color="#78350f" if is_sel else "#92400e",
            fontweight="bold" if is_sel else "normal",
        )

    ax.set_title("mzarc Lossy Quantization Tradeoff", fontsize=16, fontweight="bold")
    ax.set_xlabel("encoded size (MiB)")
    ax.set_ylabel("p95 relative intensity error (%)")
    legend_items = [
        plt.scatter([], [], color=sel_color, edgecolors="#78350f", s=140, linewidths=1.2,
                    label=f"selected  (q={selected_quant})"),
        plt.scatter([], [], color=unsel_color, edgecolors="#78350f", s=90, linewidths=1.2,
                    label="other sweep points"),
    ]
    ax.legend(handles=legend_items, fontsize=10)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_memory_footprint(memory_rows: list[dict[str, object]], path: Path) -> None:
    """Peak RSS by operation, faceted encode|decode; mzarc highlighted.

    Operations follow the format "src -> artifact" (encode) or "artifact -> src"
    (decode).  Bars are coloured per artifact; mzarc labels are bold teal.
    [MT] suffix marks multi-thread variants.
    """
    if not memory_rows:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No zebrac memory rows available for this run",
                ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    frame = pd.DataFrame(memory_rows)
    _sources = {"dump", "mzML", "mzml"}

    def _parse(op: str) -> tuple[str, str]:
        """Return (artifact, direction) from an operation string."""
        if " -> " not in op:
            # e.g. "mzml dump" - treat as the dump conversion itself
            return op, "encode / compress"
        lhs, rhs = op.split(" -> ", 1)
        if lhs in _sources:
            return rhs, "encode / compress"
        return lhs, "decode / decompress"

    frame[["artifact", "direction"]] = pd.DataFrame(
        frame["operation"].apply(_parse).tolist(), index=frame.index
    )
    frame["label"] = frame["artifact"].apply(_display_label)

    enc = frame[frame["direction"] == "encode / compress"].copy()
    dec = frame[frame["direction"] == "decode / decompress"].copy()
    enc = enc.sort_values("peak_rss_median_mib")
    dec = dec.sort_values("peak_rss_median_mib")

    fig, (ax_enc, ax_dec) = plt.subplots(
        1, 2,
        figsize=(20, max(5.0, 0.52 * max(len(enc), len(dec)) + 2.0)),
        sharey=False,
    )

    def _draw(ax: plt.Axes, sub: pd.DataFrame, title: str) -> None:
        colors = [_color(str(a)) for a in sub["artifact"]]
        ax.barh(sub["label"], sub["peak_rss_median_mib"], color=colors,
                edgecolor="#e2e8f0", linewidth=0.5)
        max_v = float(sub["peak_rss_median_mib"].max())
        for patch, (_, row) in zip(ax.patches, sub.iterrows(), strict=True):
            ax.text(
                patch.get_width() + max_v * 0.015,
                patch.get_y() + patch.get_height() / 2,
                f"{float(row['peak_rss_median_mib']):.1f} MiB",
                va="center", ha="left", fontsize=9.5,
            )
        ax.set_title(title, fontsize=13)
        ax.set_xlabel("peak RSS (MiB)")
        ax.set_ylabel("")
        ax.margins(x=0.22)
        ax.invert_yaxis()
        for tick in ax.get_yticklabels():
            if "mzarc" in tick.get_text().lower():
                tick.set_fontweight("bold")
                tick.set_color(_COLORS["mzarc_lossless"])

    _draw(ax_enc, enc, "Encode / Compress  — peak RSS")
    _draw(ax_dec, dec, "Decode / Decompress  — peak RSS")

    fig.suptitle("Peak Memory Footprint (zebrac median)", fontsize=18, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_intensity_quantiles(quantile_rows: list[dict[str, object]], path: Path) -> None:
    """Relative intensity error at each quantile for mzarc lossless and selected lossy.

    Lossless is shown in vivid teal (error is zero everywhere).
    The selected lossy configuration uses amber to match the lossy color scheme.
    """
    if not quantile_rows:
        fig, ax = plt.subplots(figsize=(10.0, 5.4))
        ax.axis("off")
        ax.text(0.5, 0.5, "No quantile data available",
                ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    frame = pd.DataFrame(quantile_rows)
    palette = {
        "lossless":      _COLORS["mzarc_lossless"],
        "selected lossy": _COLORS["mzarc_lossy"],
    }
    marker_map = {"lossless": "o", "selected lossy": "s"}

    fig, ax = plt.subplots(figsize=(10.0, 5.4))
    for artifact, group in frame.groupby("artifact", sort=False):
        color  = palette.get(str(artifact), "#94a3b8")
        marker = marker_map.get(str(artifact), "o")
        ax.plot(
            group["quantile_label"], group["value_pct"],
            color=color, linewidth=2.5, marker=marker, markersize=8,
            label=str(artifact),
        )

    ax.set_title("Relative Intensity Error Quantiles", fontsize=16, fontweight="bold")
    ax.set_xlabel("quantile")
    ax.set_ylabel("relative intensity error (%)")
    ax.legend(fontsize=11)
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_stat_comparisons(comparisons: list[dict], path: Path) -> None:
    """Speed-ratio bar chart from Mann-Whitney U / Wilcoxon comparisons.

    Only comparisons that carry a speed_ratio are plotted (encode vs decode
    comparisons have no meaningful ratio, so they are omitted here).
    Bars < 1.0 mean mzarc is faster.  Colour by statistical significance:
    teal = significant and mzarc faster, rose = significant and mzarc slower,
    gray = not significant.
    """
    if not comparisons:
        fig, ax = plt.subplots(figsize=(7.0, 4.0))
        ax.axis("off")
        ax.text(0.5, 0.5, "No statistical comparison data available",
                ha="center", va="center", fontsize=13)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    labels, ratios, colors = [], [], []
    for c in comparisons:
        ratio = c.get("speed_ratio")
        if ratio is None:
            continue   # skip encode-vs-decode entries (no meaningful ratio)
        sig = bool(c.get("significant", False))
        name_a = str(c.get("name_a", c.get("operation_a", "")))
        name_b = str(c.get("name_b", c.get("operation_b", "")))
        p_val  = c.get("p_value")
        p_str  = f"  (p={p_val:.3f})" if p_val is not None else ""
        labels.append(f"{name_a}\nvs {name_b}{p_str}")
        ratios.append(float(ratio))
        if sig and ratio < 1.0:
            colors.append(_COLORS["mzarc_lossless"])   # teal: mzarc faster
        elif sig and ratio > 1.0:
            colors.append("#e11d48")                    # rose: mzarc slower
        else:
            colors.append("#94a3b8")                    # gray: not significant

    if not labels:
        fig, ax = plt.subplots(figsize=(7.0, 4.0))
        ax.axis("off")
        ax.text(0.5, 0.5, "All comparisons missing speed_ratio",
                ha="center", va="center", fontsize=13)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    fig_height = max(4.0, len(labels) * 1.1 + 1.5)
    fig, ax = plt.subplots(figsize=(10.0, fig_height))
    y_pos = range(len(labels))
    ax.barh(list(y_pos), ratios, color=colors, edgecolor="#0f172a",
            linewidth=0.5, height=0.55)
    ax.axvline(1.0, color="#475569", linestyle="--", linewidth=1.2)
    ax.set_yticks(list(y_pos))
    ax.set_yticklabels(labels, fontsize=9)
    ax.set_xlabel("speed ratio  (mzarc time / baseline time — lower = mzarc faster)")
    ax.set_title("Statistical Speed Comparisons  (Mann-Whitney U)", fontsize=15, fontweight="bold")

    legend_handles = [
        mpatches.Patch(color=_COLORS["mzarc_lossless"], label="mzarc faster (significant)"),
        mpatches.Patch(color="#e11d48",                  label="mzarc slower (significant)"),
        mpatches.Patch(color="#94a3b8",                  label="not significant"),
        plt.Line2D([0], [0], color="#475569", linestyle="--", label="ratio = 1  (equal)"),
    ]
    ax.legend(handles=legend_handles, fontsize=9, loc="lower right")
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def plot_hardware_efficiency(memory_rows: list[dict[str, object]], path: Path) -> None:
    """Two-panel bar chart: IPC (left) and cache miss rate (right) per operation.

    IPC (instructions per CPU cycle) measures computation density.  Higher
    means the CPU is doing useful work rather than stalling on memory.

    Cache miss rate (cache_misses / cache_references) measures data locality.
    Lower is better; a value near 1 means nearly every cache access is a miss.

    Bars are coloured by artifact; mzarc labels are bold teal.
    """
    rows_with_hw = [
        r for r in memory_rows
        if r.get("ipc") is not None and r.get("cache_miss_rate") is not None
    ]
    if not rows_with_hw:
        fig, ax = plt.subplots(figsize=(10.0, 3.2))
        ax.axis("off")
        ax.text(0.5, 0.5, "No hardware counter data available for this run",
                ha="center", va="center", fontsize=16)
        fig.tight_layout()
        fig.savefig(path, bbox_inches="tight")
        plt.close(fig)
        return

    frame = pd.DataFrame(rows_with_hw)
    _sources = {"dump", "mzML", "mzml"}

    def _artifact_from_op(op: str) -> str:
        if " -> " not in op:
            return op
        lhs, rhs = op.split(" -> ", 1)
        return rhs if lhs in _sources else lhs

    frame["artifact"] = frame["operation"].apply(_artifact_from_op)
    frame["op_label"]  = frame["operation"]
    colors = [_color(str(a)) for a in frame["artifact"]]

    fig, axes = plt.subplots(1, 2, figsize=(20, max(4.0, 0.45 * len(frame) + 1.8)))

    def _annotate_yaxis(ax: plt.Axes, artifacts: list[str]) -> None:
        for tick, art in zip(ax.get_yticklabels(), artifacts):
            if "mzarc" in art.lower():
                tick.set_fontweight("bold")
                tick.set_color(_COLORS["mzarc_lossless"])

    # Left: IPC
    ax_ipc = axes[0]
    ax_ipc.barh(frame["op_label"], frame["ipc"].astype(float), color=colors,
                edgecolor="#e2e8f0", linewidth=0.5)
    max_ipc = float(frame["ipc"].max())
    for patch, (_, row) in zip(ax_ipc.patches, frame.iterrows(), strict=True):
        ax_ipc.text(
            patch.get_width() + max(max_ipc * 0.015, 0.01),
            patch.get_y() + patch.get_height() / 2,
            f"{float(row['ipc']):.2f}",
            va="center", ha="left", fontsize=9,
        )
    ax_ipc.set_title("IPC (instructions / cycle)\nhigher = more compute-efficient", fontsize=12)
    ax_ipc.set_xlabel("IPC")
    ax_ipc.set_ylabel("")
    ax_ipc.margins(x=0.22)
    ax_ipc.invert_yaxis()
    _annotate_yaxis(ax_ipc, list(frame["artifact"]))

    # Right: Cache miss rate
    ax_cmr = axes[1]
    ax_cmr.barh(frame["op_label"], (frame["cache_miss_rate"].astype(float) * 100), color=colors,
                edgecolor="#e2e8f0", linewidth=0.5)
    max_cmr = float(frame["cache_miss_rate"].max()) * 100
    for patch, (_, row) in zip(ax_cmr.patches, frame.iterrows(), strict=True):
        ax_cmr.text(
            patch.get_width() + max(max_cmr * 0.015, 0.01),
            patch.get_y() + patch.get_height() / 2,
            f"{float(row['cache_miss_rate']) * 100:.1f}%",
            va="center", ha="left", fontsize=9,
        )
    ax_cmr.set_title("Cache miss rate (misses / references)\nlower = better data locality", fontsize=12)
    ax_cmr.set_xlabel("cache miss rate (%)")
    ax_cmr.set_ylabel("")
    ax_cmr.margins(x=0.22)
    ax_cmr.invert_yaxis()
    _annotate_yaxis(ax_cmr, list(frame["artifact"]))

    legend_items = [
        mpatches.Patch(color=_COLORS["mzarc_lossless"], label="mzarc lossless"),
        mpatches.Patch(color=_COLORS["mzarc_lossy"],    label="mzarc lossy"),
    ]
    fig.legend(handles=legend_items, loc="lower center", ncol=2, fontsize=10,
               bbox_to_anchor=(0.5, -0.02))
    fig.suptitle("Hardware Algorithm Efficiency", fontsize=18, fontweight="bold")
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
    hw_efficiency_path = plot_dir / "hardware_efficiency.png"
    stat_comparisons_path = plot_dir / "stat_comparisons.png"

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
        plot_hardware_efficiency(memory_rows, hw_efficiency_path)
        plots["hardware_efficiency"] = hw_efficiency_path.name

    stat_rows = report["plot_rows"].get("stat_comparisons", [])
    if stat_rows:
        plot_stat_comparisons(stat_rows, stat_comparisons_path)
        plots["stat_comparisons"] = stat_comparisons_path.name

    return plots